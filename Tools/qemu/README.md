# Building AVM's QEMU

AVM ships its own build of QEMU 10.0.2, made from the official source with a
few patches. This folder holds what you need to repeat that build.

AVM does not use UTM's prebuilt QEMU. UTM's 10.0.2 has a SPICE crash on macOS
that official QEMU fixed later. The firmware files and libraries still come
from UTM's sysroot.

## What's patched

1. **SPICE crash fix** (QEMU issue 3070, fixed upstream in 10.1.1 as commit
   e7ecb533). In `ui/spice-core.c`, `channel_event()` changes
   `bool need_lock = !qemu_thread_is_self(&me);` to
   `bool need_lock = !bql_locked();`, and the unused `static QemuThread me;`
   and `qemu_thread_get_self(&me);` lines go away. Done by hand, as in
   Handoff 3.
2. **TPM PPI on the ARM virt machine** (issue 17). This is nine official QEMU
   commits from March 2026, backported to 10.0.2. Without them, Windows 11
   ARM64 logs Event 15 at every boot and can't use the TPM. With them, the
   TPM reports ready. The commits, in order: 60ab4a04, 6f4a95995, 0a468236,
   3912e312a, 859252e1, 46cd2c10, dc6444b9, f644d268, 5f0348bf.
   `apply-tpm-ppi.py` applies them. The same change is in `tpm-ppi.diff` for
   reading.

## Steps

The source folder is `~/Developer/qemu-build/qemu-10.0.2`, from the
qemu-10.0.2.tar.xz release, and the build folder is
`~/Developer/qemu-build/build-arm64`. Configure options are in Handoff 3.

1. Apply the SPICE fix by hand (see above).
2. Run `/usr/bin/python3 apply-tpm-ppi.py`. It checks that all ten files are
   stock 10.0.2 before changing anything, verifies every result, and keeps a
   `.pre-ppi` backup of each file. Running it twice is safe.
3. Leave out the macOS-guest graphics device. The macOS 27 SDK removed
   interfaces it needs (`PGTask_t` and others), so it no longer compiles.
   AVM never uses it. In the build folder, with the sysroot's pkg-config
   settings from Handoff 3, run `./pyvenv/bin/meson configure -Dpvg=disabled`.
4. Run `ninja qemu-system-aarch64`.
5. Check the build: `./qemu-system-aarch64 -device tpm-tis-device,help` must
   list `ppi=<bool>` with the default `on`.
6. Copy the binary over `sysroot/bin/qemu-system-aarch64`, keeping the old
   one as a backup. AVM's Run Script picks it up from there on the next build.

## Firmware, for reference

The firmware isn't built here. The Run Script copies it from the sysroot's
`share/qemu`:

- `edk2-aarch64-secure-code.fd` has Secure Boot and the TPM 2.0 drivers.
  Windows VMs on firmware generation 2 boot it.
- `edk2-aarch64-code.fd` has neither. It's for Ubuntu, and for Windows VMs
  that are partway through setup on the original firmware.

AVM's own Secure Boot settings template is `Resources/avm-secure-vars.fd`.
It holds AVM's platform key plus Microsoft's 2011 and 2023 certificates,
with Secure Boot on. The platform key's private half is never in the repo.
