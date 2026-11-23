# aatest

A small test tool for AVM's Claim USB Accessory work on macOS 27. It answers AccessoryAccess and libusb questions without rebuilding QEMU. It isn't part of the app.

AVM's Debug build starts it the way it starts QEMU, from the Debug menu:

- Grant Test: Start Child Tool
- Grant Test: Child Tool Probe
- Grant Test: Send Grants to Child Tool
- Grant Test: Stop Child Tool

AVM looks for the tool at `~/Developer/AVM-dist/aatest` and writes everything it prints to AVM's log, each line starting with "child:".

## Commands

AVM sends one command per line on stdin:

- `probe VVVV PPPP`: open the device with this vendor and product ID the way libusb does (IOUSBLib), then with libusb using the context made at launch, then with a fresh libusb context. Logs every result code.
- `grant BASE64`: rebuild an accessory from the bytes of its XPC representation and open it with AccessoryAccess.
- `close`: close every accessory opened by `grant`.
- `quit`: exit. The tool also exits when AVM closes stdin.

## What it found (Handoff 69)

- A process started before a device was granted can open it once libusb reloads its stale device interface. See `Tools/libusb`.
- The XPC representation hand-off from Apple forum thread 851767 works, but a non-sandboxed child doesn't need it.
- A device-level open that returns kIOReturnExclusiveAccess (0xe00002c5) is normal. libusb tolerates it, and the interfaces still open.

The comments at the top of `aatest.m` were written before these results, so they describe the question, not the answer.

## Building it

Build the patched libusb first (see `Tools/libusb`). Run these in `~/Developer/AVM-dist`, with `REPO` set to your clone and `LIBUSB` set to the unpacked, patched libusb 1.0.30 folder.

1. Copy the patched libusb next to the tool and point its install name there:

   ```
   cp "$LIBUSB/libusb-1.0.0.dylib" . && install_name_tool -id @executable_path/libusb-1.0.0.dylib libusb-1.0.0.dylib
   ```

2. Build the tool:

   ```
   clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 -O2 -I "$LIBUSB/libusb" \
     "$REPO/Tools/aatest/aatest.m" libusb-1.0.0.dylib \
     -framework Foundation -framework IOKit -framework IOUSBHost -framework AccessoryAccess \
     -o aatest
   ```

3. Sign both with your Apple Development identity, the library first:

   ```
   codesign --force -s "Apple Development" libusb-1.0.0.dylib && codesign --force -s "Apple Development" aatest
   ```

After rebuilding, stop the child tool and start it again from the Debug menu. To act like a running QEMU, start it before granting the device.
