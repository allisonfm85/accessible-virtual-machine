# AVM's patched libusb

AVM bundles libusb from UTM's sysroot. QEMU uses it to give a USB device to Windows with usb-host. The root USB helper uses it on macOS 13 to 26. AVM builds use libusb 1.0.30 with one patch, `darwin-reload-device-interface.patch`.

## Why it's patched

On macOS 27, AVM gets USB devices through Apple's AccessoryAccess. When macOS grants a device to AVM, accessoryaccessd takes exclusive ownership of it. The device keeps the same registry entry and sessionID, so no arrival or departure notification fires. But device interfaces (user clients) made before the grant stop working.

libusb makes a device interface when it first sees a device and keeps it. So a QEMU that was already running when the device was granted holds a dead interface. Opening the device fails with kIOReturnNoDevice (0xe00002c0), and QEMU gives Windows a 1.5 Mb/s placeholder instead of the device.

The patch changes `darwin_open` in `libusb/os/darwin_usb.c`. If opening the device fails with anything other than success or kIOReturnExclusiveAccess, or making the async event source fails, it calls libusb's own `darwin_reload_device` to make a fresh interface from the same service, then tries once more. It logs these warnings:

- "reloaded the device interface; trying the open again"
- "opened after reloading the device interface"

With the patch, a device granted while Windows is running reaches Windows at full speed. A device that macOS re-enumerates after another device is given back returns to Windows on its own.

This is a libusb bug, so the fix should go upstream too.

## Building it

You need Xcode's command line tools and UTM's sysroot at `~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64`.

1. Download the libusb 1.0.30 release: https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2

   Its SHA-256 is `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`.

2. Unpack it and apply the patch. Run this from the folder with the tarball, with `REPO` set to your clone:

   ```
   REPO=~/Developer/accessible-virtual-machine
   tar -xjf libusb-1.0.30.tar.bz2 && cd libusb-1.0.30 && patch -p1 < "$REPO/Tools/libusb/darwin-reload-device-interface.patch" && shasum -a 256 libusb/os/darwin_usb.c
   ```

   The patched file's SHA-256 is `e12e84fec6cd70d3a98fa6b4d6bb8d6578f79548e79536bfe3b31dad06bd8f9d`. The unpatched file's is `290b9913eba18e0f9f9fa0de75c59bec0daa4ccd02740a96fd8479d20da06557`.

3. Build it, still in `libusb-1.0.30`. The release's `Xcode/config.h` stands in for running configure. The install name must stay the sysroot's, because AVM's build rewrites library paths from it.

   ```
   SYSROOT=~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64
   clang -arch arm64 -mmacosx-version-min=13.0 -O2 -dynamiclib -I Xcode -I libusb \
     libusb/core.c libusb/descriptor.c libusb/hotplug.c libusb/io.c libusb/strerror.c libusb/sync.c \
     libusb/os/darwin_usb.c libusb/os/events_posix.c libusb/os/threads_posix.c \
     -framework IOKit -framework CoreFoundation -framework Security \
     -install_name "$SYSROOT/lib/libusb-1.0.dylib" -compatibility_version 7.0.0 -current_version 7.0.0 \
     -o libusb-1.0.0.dylib
   ```

   The minimum macOS must be 13.0, because the root USB helper loads this library on macOS 13 to 26.

4. Check it. `otool -l libusb-1.0.0.dylib | grep minos` should say 13.0, and `strings libusb-1.0.0.dylib | grep "reloaded the device interface"` should find the warning.

5. Back up the sysroot's `lib/libusb-1.0.0.dylib`, then copy the new build over it. Keep backups outside the AVM project folder, or Xcode bundles them into the app.

Every AVM build from that sysroot then bundles the patched libusb, for QEMU and for the root USB helper. AVM's Debug build command checks this and says "Bundled libusb: PATCHED".

## Re-downloading the sysroot

A fresh copy of UTM's sysroot has the unpatched libusb. Redo steps 3 to 5 after re-downloading it, like the GStreamer osxaudio fix.

## Testing without QEMU

`Tools/aatest` is a small test tool for AccessoryAccess and libusb questions. It uses this library and doesn't need a QEMU rebuild.
