// SPDX-License-Identifier: Apache-2.0
//
// l2pause -- minimal static pause binary used as the L2 container entrypoint
// in the riscv64 snapshot/restore integration test
// (hypervisor/scripts/run_integration_tests_riscv64.sh, spec args
// /usr/bin/l2pause). The generated guest image ships an otherwise empty
// /cube-root, so the workload image's only process is this: park on pause()
// until the shim kills the task. Static + no libc calls beyond the syscall
// wrapper, because the mini-rootfs has no loader.
#include <unistd.h>

int main(void)
{
	for (;;)
		pause();
}
