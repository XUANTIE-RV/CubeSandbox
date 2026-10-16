// Copyright © 2024 Institute of Software, CAS. All rights reserved.
// Copyright 2020, ARM Limited.
//
// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause

use std::io;
use std::result;
use vmm_sys_util::eventfd::EventFd;

#[derive(Debug)]
pub enum Error {
    /// Invalid trigger mode.
    InvalidTriggerMode,
    /// Invalid delivery mode.
    InvalidDeliveryMode,
    /// Failed creating the interrupt source group.
    CreateInterruptSourceGroup(io::Error),
    /// Failed triggering the interrupt.
    TriggerInterrupt(io::Error),
    /// Failed masking the interrupt.
    MaskInterrupt(io::Error),
    /// Failed unmasking the interrupt.
    UnmaskInterrupt(io::Error),
    /// Failed updating the interrupt.
    UpdateInterrupt(io::Error),
    /// Failed enabling the interrupt.
    EnableInterrupt(io::Error),
    /// Failed creating GIC device.
    CreateGic(hypervisor::HypervisorVmError),
    #[cfg(target_arch = "riscv64")]
    /// Failed creating AIA device.
    CreateAia(hypervisor::HypervisorVmError),
    #[cfg(target_arch = "riscv64")]
    /// Failed restoring AIA device.
    RestoreAia(hypervisor::arch::riscv64::aia::Error),
    #[cfg(target_arch = "riscv64")]
    /// Failed deasserting the interrupt.
    DeassertInterrupt(hypervisor::HypervisorVmError),
}

type Result<T> = result::Result<T, Error>;

pub struct MsiMessage {
    // Message Address Register
    //   31-20: Base address. Fixed value (0x0FEE)
    //   19-12: Destination ID
    //   11-4:  Reserved
    //   3:     Redirection Hint indication
    //   2:     Destination Mode
    //   1-0:   Reserved
    pub addr: u32,
    // Message Data Register
    //   32-16: Reserved
    //   15:    Trigger Mode. 0 = Edge, 1 = Level
    //   14:    Level. 0 = Deassert, 1 = Assert
    //   13-11: Reserved
    //   10-8:  Delivery Mode
    //   7-0:   Vector
    pub data: u32,
}

// Introduce trait InterruptController to uniform the interrupt
// service provided for devices.
// Device manager uses this trait without caring whether it is a
// IOAPIC (X86), GIC (Arm) or AIA (RISC-V).
pub trait InterruptController: Send {
    fn service_irq(&mut self, irq: usize) -> Result<()>;
    // Lower the controller input for `irq`. Controllers that latch the level of
    // their inputs need this, so a device can tell them it has nothing pending.
    fn deassert_irq(&mut self, _irq: usize) -> Result<()> {
        Ok(())
    }
    #[cfg(target_arch = "aarch64")]
    fn enable(&self) -> Result<()>;
    #[cfg(target_arch = "x86_64")]
    fn end_of_interrupt(&mut self, vec: u8);
    fn notifier(&self, irq: usize) -> Option<EventFd>;
}
