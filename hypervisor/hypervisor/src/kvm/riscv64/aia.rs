// Copyright © 2024 Institute of Software, CAS. All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0

use std::any::Any;
use std::cmp;

use kvm_ioctls::DeviceFd;
use serde::{Deserialize, Serialize};

use crate::arch::riscv64::aia::{Error, Result, Vaia, VaiaConfig};
use crate::device::HypervisorDeviceError;
use crate::kvm::KvmVm;
use crate::Vm;

// Offsets inside an APLIC domain, from include/linux/irqchip/riscv-aplic.h.
// kvm-bindings exposes the AIA device attribute groups but nothing about the
// register layout reached through them.
const APLIC_DOMAINCFG: u32 = 0x0000;
const APLIC_SOURCECFG_BASE: u32 = 0x0004;
const APLIC_SETIP_BASE: u32 = 0x1c00;
const APLIC_SETIE_BASE: u32 = 0x1e00;
const APLIC_TARGET_BASE: u32 = 0x3004;

// Interrupt selects inside an IMSIC interrupt file, from
// include/linux/irqchip/riscv-imsic.h.
const IMSIC_EIDELIVERY: u32 = 0x70;
const IMSIC_EITHRESHOLD: u32 = 0x72;
const IMSIC_EIP0: u32 = 0x80;
const IMSIC_EIE0: u32 = 0xc0;

/// The parts of the AIA configuration that a saved register dump depends on.
///
/// The register sets below are derived from these values, so state saved under
/// one configuration cannot be replayed against another.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct AiaSnapshotConfig {
    /// Number of vCPUs, and so of IMSIC interrupt files, covered.
    pub vcpu_count: u32,
    /// Number of IMSIC interrupt identities.
    pub imsic_num_ids: u32,
    /// Number of wired interrupt sources the APLIC domain handles.
    pub srcs: u32,
}

/// APLIC register offsets whose contents survive a save/restore round trip, in
/// the order they must be written back.
///
/// The domain covers `srcs + 1` interrupt identities and keeps one bitmap word
/// per 32 of them, so SOURCECFG and TARGET span `srcs` registers each while
/// SETIP and SETIE span `(srcs + 1).div_ceil(32)` words.
///
/// Only registers that read back what was written are listed. Writing CLRIP or
/// CLRIE clears pending or enabled bits, SETIPNUM, CLRIPNUM, SETIENUM,
/// CLRIENUM and the two SETIPNUM doorbells always read as zero, and a write to
/// GENMSI injects an MSI into the guest. SOURCECFG comes first because the
/// kernel drops a pending write for an identity whose source mode is still
/// INACTIVE, and DOMAINCFG comes last so that delivery stays off until the
/// routing it would act on is in place.
fn aplic_state_offsets(srcs: u32) -> Vec<u32> {
    // KVM leaves the APLIC domain unallocated when no wired source is
    // configured, so there is nothing to read back.
    if srcs == 0 {
        return Vec::new();
    }

    let nr_words = (srcs + 1).div_ceil(32);

    let mut offsets = Vec::with_capacity(1 + srcs as usize * 2 + nr_words as usize * 2);
    offsets.extend((0..srcs).map(|i| APLIC_SOURCECFG_BASE + i * 4));
    offsets.extend((0..nr_words).map(|i| APLIC_SETIE_BASE + i * 4));
    offsets.extend((0..srcs).map(|i| APLIC_TARGET_BASE + i * 4));
    offsets.extend((0..nr_words).map(|i| APLIC_SETIP_BASE + i * 4));
    offsets.push(APLIC_DOMAINCFG);
    offsets
}

/// IMSIC interrupt selects worth saving for `imsic_num_ids` identities.
///
/// The kernel only accepts EIDELIVERY, EITHRESHOLD and the EIP/EIE words, and
/// only as many of the latter as the identity count needs: bit 0 of EIP0 and
/// EIE0 is the reserved identity 0, so `imsic_num_ids + 1` identities take
/// `(imsic_num_ids + 1).div_ceil(64)` 64-bit words each.
fn imsic_isels(imsic_num_ids: u32) -> Vec<u32> {
    let nr_eix = (imsic_num_ids + 1).div_ceil(64);

    let mut isels = Vec::with_capacity(2 + nr_eix as usize * 2);
    isels.push(IMSIC_EIDELIVERY);
    isels.push(IMSIC_EITHRESHOLD);
    isels.extend((0..nr_eix).map(|i| IMSIC_EIP0 + i * 2));
    isels.extend((0..nr_eix).map(|i| IMSIC_EIE0 + i * 2));
    isels
}

/// Attribute number addressing `isel` in the interrupt file of `vcpu_id`.
fn imsic_attr(vcpu_id: u32, isel: u32) -> u64 {
    (u64::from(vcpu_id) << kvm_bindings::KVM_DEV_RISCV_AIA_IMSIC_ISEL_BITS) | u64::from(isel)
}

pub struct KvmAiaImsics {
    /// The KVM device for the Aia
    device: DeviceFd,

    /// AIA APLIC address
    aplic_addr: u64,

    /// AIA IMSIC address
    imsic_addr: u64,

    /// Number of CPUs handled by the device
    vcpu_count: u32,

    /// Number of IMSIC interrupt identities configured by KVM.
    imsic_num_ids: u32,

    /// Number of wired APLIC interrupt sources configured by KVM.
    aplic_num_sources: u32,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct AiaImsicsState {
    /// The configuration the register values below were read under.
    pub config: AiaSnapshotConfig,

    /// Saved APLIC registers, as `(offset, value)`.
    pub aplic_regs: Vec<(u32, u32)>,

    /// Saved IMSIC registers, as `(vcpu_id, isel, value)`.
    pub imsic_regs: Vec<(u32, u32, u64)>,
}

impl KvmAiaImsics {
    /// Device trees specific constants

    fn version() -> u32 {
        kvm_bindings::kvm_device_type_KVM_DEV_TYPE_RISCV_AIA
    }

    /// Setup the device-specific attributes
    fn init_device_attributes(&mut self, nr_irqs: u32) -> Result<()> {
        // AIA part attributes
        // Getting the working mode of RISC-V AIA, defaults to EMUL, passible
        // variants are EMUL, HW_ACCL, AUTO
        let mut aia_mode = kvm_bindings::KVM_DEV_RISCV_AIA_MODE_EMUL;
        Self::get_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_CONFIG,
            u64::from(kvm_bindings::KVM_DEV_RISCV_AIA_CONFIG_MODE),
            &mut aia_mode as *mut u32 as u64,
            0,
        )?;

        // Report AIA MODE

        // Get the number of interrupt identities supported by KVM before
        // selecting the number of wired APLIC sources.
        let mut aia_nr_ids: u32 = 0;
        Self::get_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_CONFIG,
            u64::from(kvm_bindings::KVM_DEV_RISCV_AIA_CONFIG_IDS),
            &mut aia_nr_ids as *mut u32 as u64,
            0,
        )?;

        self.imsic_num_ids = aia_nr_ids;

        let safe_nr_irqs = cmp::min(nr_irqs, aia_nr_ids);
        self.aplic_num_sources = safe_nr_irqs;
        Self::set_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_CONFIG,
            u64::from(kvm_bindings::KVM_DEV_RISCV_AIA_CONFIG_SRCS),
            &safe_nr_irqs as *const u32 as u64,
            0,
        )?;

        // Setting up hart_bits
        let max_hart_index = self.vcpu_count as u64 - 1;
        let hart_bits = std::cmp::max(64 - max_hart_index.leading_zeros(), 1);
        Self::set_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_CONFIG,
            u64::from(kvm_bindings::KVM_DEV_RISCV_AIA_CONFIG_HART_BITS),
            &hart_bits as *const u32 as u64,
            0,
        )?;

        // Designate addresses of APLIC and IMSICS

        // Setting up RISC-V APLIC
        Self::set_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_ADDR,
            u64::from(kvm_bindings::KVM_DEV_RISCV_AIA_ADDR_APLIC),
            &self.aplic_addr as *const u64 as u64,
            0,
        )?;

        // Helpers to calculate address and attribute of IMSIC of each vCPU
        let riscv_imsic_addr_of = |cpu_index: u32| -> u64 {
            self.imsic_addr + (cpu_index * kvm_bindings::KVM_DEV_RISCV_IMSIC_SIZE) as u64
        };
        let riscv_imsic_attr_of = |cpu_index: u32| -> u64 { cpu_index as u64 + 1 };

        // Setting up RISC-V IMSICs
        for cpu_index in 0..self.vcpu_count {
            let cpu_imsic_addr = riscv_imsic_addr_of(cpu_index);
            Self::set_device_attribute(
                &self.device,
                kvm_bindings::KVM_DEV_RISCV_AIA_GRP_ADDR,
                riscv_imsic_attr_of(cpu_index),
                &cpu_imsic_addr as *const u64 as u64,
                0,
            )?;
        }

        // Finalizing the AIA device
        Self::set_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_CTRL,
            u64::from(kvm_bindings::KVM_DEV_RISCV_AIA_CTRL_INIT),
            0,
            0,
        )
    }

    /// Create a KVM Vaia device
    fn create_device(vm: &KvmVm) -> Result<DeviceFd> {
        let mut aia_device = kvm_bindings::kvm_create_device {
            type_: Self::version(),
            fd: 0,
            flags: 0,
        };

        let device_fd = vm
            .create_device(&mut aia_device)
            .map_err(Error::CreateAia)?;

        // We know for sure this is a KVM fd
        Ok(device_fd.to_kvm().unwrap())
    }

    /// Get an AIA device attribute
    fn get_device_attribute(
        device: &DeviceFd,
        group: u32,
        attr: u64,
        addr: u64,
        flags: u32,
    ) -> Result<()> {
        let mut attr = kvm_bindings::kvm_device_attr {
            flags,
            group,
            attr,
            addr,
        };
        // SAFETY: attr.addr is safe to write to.
        unsafe {
            device.get_device_attr(&mut attr).map_err(|e| {
                Error::GetDeviceAttribute(HypervisorDeviceError::GetDeviceAttribute(e.into()))
            })
        }
    }

    /// Set an AIA device attribute
    fn set_device_attribute(
        device: &DeviceFd,
        group: u32,
        attr: u64,
        addr: u64,
        flags: u32,
    ) -> Result<()> {
        let attr = kvm_bindings::kvm_device_attr {
            flags,
            group,
            attr,
            addr,
        };
        device.set_device_attr(&attr).map_err(|e| {
            Error::SetDeviceAttribute(HypervisorDeviceError::SetDeviceAttribute(e.into()))
        })
    }

    /// Read one APLIC register.
    ///
    /// `KVM_DEV_RISCV_AIA_GRP_APLIC` attributes move a `u32`.
    fn get_aplic(&self, offset: u32) -> Result<u32> {
        let mut val: u32 = 0;
        Self::get_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_APLIC,
            u64::from(offset),
            &mut val as *mut u32 as u64,
            0,
        )?;
        Ok(val)
    }

    /// Write one APLIC register.
    fn set_aplic(&self, offset: u32, val: u32) -> Result<()> {
        Self::set_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_APLIC,
            u64::from(offset),
            &val as *const u32 as u64,
            0,
        )
    }

    /// Read one IMSIC interrupt file register.
    ///
    /// `KVM_DEV_RISCV_AIA_GRP_IMSIC` attributes move an `unsigned long`, which
    /// is 8 bytes wide here; a narrower buffer would be overwritten.
    fn get_imsic(&self, vcpu_id: u32, isel: u32) -> Result<u64> {
        let mut val: u64 = 0;
        Self::get_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_IMSIC,
            imsic_attr(vcpu_id, isel),
            &mut val as *mut u64 as u64,
            0,
        )?;
        Ok(val)
    }

    /// Write one IMSIC interrupt file register.
    fn set_imsic(&self, vcpu_id: u32, isel: u32, val: u64) -> Result<()> {
        Self::set_device_attribute(
            &self.device,
            kvm_bindings::KVM_DEV_RISCV_AIA_GRP_IMSIC,
            imsic_attr(vcpu_id, isel),
            &val as *const u64 as u64,
            0,
        )
    }

    fn snapshot_config(&self) -> AiaSnapshotConfig {
        AiaSnapshotConfig {
            vcpu_count: self.vcpu_count,
            imsic_num_ids: self.imsic_num_ids,
            srcs: self.aplic_num_sources,
        }
    }

    /// Method to initialize the AIA device
    pub fn new(vm: &dyn Vm, config: VaiaConfig) -> Result<KvmAiaImsics> {
        // This is inside KVM module
        let vm = vm.as_any().downcast_ref::<KvmVm>().expect("Wrong VM type?");

        let vaia = Self::create_device(vm)?;

        let mut aia_device = KvmAiaImsics {
            device: vaia,
            vcpu_count: config.vcpu_count,
            aplic_addr: config.aplic_addr,
            imsic_addr: config.imsic_addr,
            imsic_num_ids: 0,
            aplic_num_sources: 0,
        };

        aia_device.init_device_attributes(config.nr_irqs)?;

        Ok(aia_device)
    }
}

impl Vaia for KvmAiaImsics {
    fn aplic_compatibility(&self) -> &str {
        "riscv,aplic"
    }

    fn aplic_properties(&self) -> [u32; 4] {
        [
            0,
            self.aplic_addr as u32,
            0,
            kvm_bindings::KVM_DEV_RISCV_APLIC_SIZE,
        ]
    }

    fn imsic_compatibility(&self) -> &str {
        "riscv,imsics"
    }

    fn imsic_properties(&self) -> [u32; 4] {
        [
            0,
            self.imsic_addr as u32,
            0,
            kvm_bindings::KVM_DEV_RISCV_IMSIC_SIZE * self.vcpu_count,
        ]
    }

    fn imsic_num_ids(&self) -> u32 {
        self.imsic_num_ids
    }

    fn aplic_num_sources(&self) -> u32 {
        self.aplic_num_sources
    }

    fn vcpu_count(&self) -> u32 {
        self.vcpu_count
    }

    fn msi_compatible(&self) -> bool {
        true
    }

    fn as_any_concrete_mut(&mut self) -> &mut dyn Any {
        self
    }

    /// Save the state of AIA.
    fn state(&self) -> Result<AiaImsicsState> {
        // TODO(port): Not covered here -- the PMU, and any AIA state KVM
        // exposes only through the guest memory window rather than a device
        // attribute. Only the APLIC/IMSIC device-attribute registers round-trip.
        let mut aplic_regs = Vec::new();
        for offset in aplic_state_offsets(self.aplic_num_sources) {
            aplic_regs.push((offset, self.get_aplic(offset)?));
        }

        // The kernel addresses an interrupt file by vCPU id. CH creates vCPUs
        // with `create_vcpu(cpu_index)`, which KVM also uses as the id.
        let isels = imsic_isels(self.imsic_num_ids);
        let mut imsic_regs = Vec::with_capacity(self.vcpu_count as usize * isels.len());
        for vcpu_id in 0..self.vcpu_count {
            for isel in &isels {
                imsic_regs.push((vcpu_id, *isel, self.get_imsic(vcpu_id, *isel)?));
            }
        }

        Ok(AiaImsicsState {
            config: self.snapshot_config(),
            aplic_regs,
            imsic_regs,
        })
    }

    /// Restore the state of AIA_IMSICs.
    fn set_state(&mut self, state: &AiaImsicsState) -> Result<()> {
        // Both register sets were derived from the configuration that was in
        // force when they were read, so replaying them against a differently
        // configured AIA would write the wrong registers.
        let current = self.snapshot_config();
        if state.config != current {
            return Err(Error::IncompatibleState {
                saved: state.config,
                current,
            });
        }

        for (offset, val) in &state.aplic_regs {
            self.set_aplic(*offset, *val)?;
        }

        for (vcpu_id, isel, val) in &state.imsic_regs {
            self.set_imsic(*vcpu_id, *isel, *val)?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        aplic_state_offsets, imsic_attr, imsic_isels, APLIC_DOMAINCFG, APLIC_SOURCECFG_BASE,
    };
    use crate::arch::riscv64::aia::VaiaConfig;
    use crate::kvm::KvmAiaImsics;

    fn create_test_vaia_config() -> VaiaConfig {
        VaiaConfig {
            vcpu_count: 1,
            aplic_addr: 0xd000000,
            imsic_addr: 0x2800000,
            nr_irqs: 256,
        }
    }

    #[test]
    fn test_aplic_state_offsets() {
        // 255 sources means 256 identities and 8 bitmap words: DOMAINCFG plus
        // 255 SOURCECFG, 8 SETIE, 255 TARGET and 8 SETIP.
        let offsets = aplic_state_offsets(255);
        assert_eq!(offsets.len(), 527);

        // SOURCECFG first, DOMAINCFG last: a pending write is dropped while the
        // source mode is still INACTIVE, and delivery should stay off until the
        // routing it acts on is in place.
        assert_eq!(offsets[0], APLIC_SOURCECFG_BASE);
        assert_eq!(offsets[254], APLIC_SOURCECFG_BASE + 254 * 4);
        assert_eq!(offsets[255 + 8 + 254], 0x3004 + 254 * 4);
        assert_eq!(*offsets.last().unwrap(), APLIC_DOMAINCFG);

        // An unaligned offset is answered with EOPNOTSUPP.
        assert!(offsets.iter().all(|off| off & 0x3 == 0));

        // A repeated offset would mean reading one register twice.
        let mut deduped = offsets.clone();
        deduped.sort_unstable();
        deduped.dedup();
        assert_eq!(deduped.len(), offsets.len());

        // With no wired source KVM allocates no APLIC domain, so any read of it
        // would fail with ENODEV.
        assert!(aplic_state_offsets(0).is_empty());
    }

    #[test]
    fn test_imsic_isels() {
        // 255 identities take 4 64-bit words each of pending and enable bits.
        assert_eq!(
            imsic_isels(255),
            vec![0x70, 0x72, 0x80, 0x82, 0x84, 0x86, 0xc0, 0xc2, 0xc4, 0xc6]
        );

        // 63 identities fit in a single word.
        assert_eq!(imsic_isels(63), vec![0x70, 0x72, 0x80, 0xc0]);

        // The attribute number packs the vCPU id above the interrupt select.
        assert_eq!(imsic_attr(3, 0x70), (3 << 12) | 0x70);
    }

    #[test]
    fn test_create_aia() {
        let hv = crate::new().unwrap();
        let vm = hv.create_vm().unwrap();
        let _vcpu = vm.create_vcpu(0, None).unwrap();

        assert!(KvmAiaImsics::new(&*vm, create_test_vaia_config()).is_ok());
    }

    // 0009 validation: save the APLIC/IMSIC device-attribute registers off a real
    // KVM AIA (KVM_DEV_RISCV_AIA_GRP_*) and replay them, then re-save. Needs
    // /dev/kvm, so this runs on a riscv64 KVM host (L1), not inside L2.
    #[test]
    fn test_aia_state_roundtrip() {
        use crate::arch::riscv64::aia::Vaia;
        let hv = crate::new().unwrap();
        let vm = hv.create_vm().unwrap();
        let _vcpu = vm.create_vcpu(0, None).unwrap();
        let mut aia = KvmAiaImsics::new(&*vm, create_test_vaia_config()).unwrap();

        let state = aia.state().expect("state() save failed");
        assert!(!state.aplic_regs.is_empty(), "no APLIC registers captured");
        assert!(!state.imsic_regs.is_empty(), "no IMSIC registers captured");

        aia.set_state(&state).expect("set_state() restore failed");

        let state2 = aia.state().expect("second state() failed");
        assert_eq!(state2.config, state.config);
        assert_eq!(state2.aplic_regs.len(), state.aplic_regs.len());
        assert_eq!(state2.imsic_regs.len(), state.imsic_regs.len());

        // A differently-configured AIA must refuse the snapshot rather than
        // replay registers onto the wrong layout (Error::IncompatibleState).
        let mut other_cfg = create_test_vaia_config();
        other_cfg.vcpu_count = 2;
        let vm2 = hv.create_vm().unwrap();
        let _v0 = vm2.create_vcpu(0, None).unwrap();
        let _v1 = vm2.create_vcpu(1, None).unwrap();
        let mut aia2 = KvmAiaImsics::new(&*vm2, other_cfg).unwrap();
        assert!(
            aia2.set_state(&state).is_err(),
            "set_state must reject a mismatched AIA config"
        );
    }
}
