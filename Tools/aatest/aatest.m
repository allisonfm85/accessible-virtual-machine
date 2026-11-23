// aatest.m - DEBUG test tool for AVM's Claim USB Accessory test (Handoff 69).
//
// Handoff 69 result 1: a child started before the grant could already
// open the device's interfaces, grant hand-off or not. So the probe now
// also tries libusb, the library QEMU uses: once with the context made
// at launch (as QEMU does) and once with a brand-new context.
//
// Question: can a child process that was already running when a device
// was granted to AVM use that device, once AVM hands it the grant?
// Handoff 69 found QEMU can't open devices granted after it started.
// Thread 851767 shows the intended hand-off: the app sends the bytes of
// -[AAUSBAccessory createXPCRepresentation], and the child rebuilds the
// accessory and opens it.
//
// AVM starts this tool and talks to it over stdin, one command per line:
//   probe VVVV PPPP   open the device the way libusb does (IOUSBLib) and
//                     log every result code
//   grant BASE64      rebuild an accessory from its XPC representation
//                     and open it with AccessoryAccess
//   close             close every accessory opened by grant
//   quit              exit
// Every result is one line on stdout, which AVM writes to its log.
// The tool exits when AVM closes stdin (AVM quit or Stop Child Tool).

#import <Foundation/Foundation.h>
#import <AccessoryAccess/AccessoryAccess.h>
#import <IOUSBHost/IOUSBHost.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#include <xpc/xpc.h>
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static NSMutableArray *gAccessories;
static NSMutableArray *gDevices;
static libusb_context *gUsb;

static void say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String);
    fflush(stdout);
}

static io_service_t findDevice(uint16_t vid, uint16_t pid)
{
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (match == NULL)
        return 0;
    int v = vid, p = pid;
    CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
    CFNumberRef np = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
    CFDictionarySetValue(match, CFSTR("idVendor"), nv);
    CFDictionarySetValue(match, CFSTR("idProduct"), np);
    CFRelease(nv);
    CFRelease(np);
    return IOServiceGetMatchingService(kIOMainPortDefault, match); // consumes match
}

static void probe(uint16_t vid, uint16_t pid)
{
    NSString *tag = [NSString stringWithFormat:@"probe %04x:%04x", vid, pid];
    io_service_t svc = findDevice(vid, pid);
    if (svc == 0) {
        say(@"%@: not found in the I/O Registry", tag);
        return;
    }
    uint64_t rid = 0;
    IORegistryEntryGetRegistryEntryID(svc, &rid);

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    say(@"%@ (registry %llu): device plug-in 0x%08x", tag, rid, kr);
    if (kr != KERN_SUCCESS || plug == NULL)
        return;

    IOUSBDeviceInterface **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                         (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr != S_OK || dev == NULL) {
        say(@"%@: device interface 0x%08x", tag, (unsigned)hr);
        return;
    }

    IOReturn opened = (*dev)->USBDeviceOpenSeize(dev);
    say(@"%@: IOKit device open 0x%08x%@", tag, opened,
        opened == kIOReturnSuccess ? @" (opened)" : (opened == kIOReturnExclusiveAccess ? @" (exclusive access; libusb carries on)" : @" (failed)"));

    UInt8 index = 0;
    (*dev)->USBGetProductStringIndex(dev, &index);
    if (index != 0) {
        UInt8 buf[256];
        IOUSBDevRequest req;
        memset(&req, 0, sizeof(req));
        req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
        req.bRequest = kUSBRqGetDescriptor;
        req.wValue = (UInt16)((kUSBStringDesc << 8) | index);
        req.wIndex = 0x0409;
        req.wLength = sizeof(buf);
        req.pData = buf;
        IOReturn r = (*dev)->DeviceRequest(dev, &req);
        NSString *name = @"";
        if (r == kIOReturnSuccess && req.wLenDone > 2)
            name = [[NSString alloc] initWithBytes:buf + 2 length:req.wLenDone - 2
                                          encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
        say(@"%@: product name request 0x%08x \"%@\"", tag, r, name);
    }

    IOUSBFindInterfaceRequest find = {
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare
    };
    io_iterator_t it = 0;
    IOReturn ir = (*dev)->CreateInterfaceIterator(dev, &find, &it);
    if (ir != kIOReturnSuccess)
        say(@"%@: interface list 0x%08x", tag, ir);
    io_service_t intf;
    int count = 0;
    while (it != 0 && (intf = IOIteratorNext(it)) != 0) {
        count++;
        IOCFPlugInInterface **iplug = NULL;
        kern_return_t k = IOCreatePlugInInterfaceForService(intf, kIOUSBInterfaceUserClientTypeID,
                                                            kIOCFPlugInInterfaceID, &iplug, &score);
        IOObjectRelease(intf);
        if (k != KERN_SUCCESS || iplug == NULL) {
            say(@"%@: interface %d plug-in 0x%08x", tag, count, k);
            continue;
        }
        IOUSBInterfaceInterface **ii = NULL;
        (*iplug)->QueryInterface(iplug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&ii);
        (*iplug)->Release(iplug);
        if (ii == NULL) {
            say(@"%@: interface %d has no interface object", tag, count);
            continue;
        }
        UInt8 cls = 0, num = 0;
        (*ii)->GetInterfaceClass(ii, &cls);
        (*ii)->GetInterfaceNumber(ii, &num);
        IOReturn o = (*ii)->USBInterfaceOpenSeize(ii);
        say(@"%@: interface %u (class %u) USBInterfaceOpenSeize 0x%08x", tag, num, cls, o);
        if (o == kIOReturnSuccess)
            (*ii)->USBInterfaceClose(ii);
        (*ii)->Release(ii);
    }
    if (it != 0)
        IOObjectRelease(it);
    if (count == 0 && ir == kIOReturnSuccess)
        say(@"%@: no interfaces listed", tag);
    if (opened == kIOReturnSuccess)
        (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    say(@"%@: IOKit done", tag);
}

static const char *speedName(int s)
{
    switch (s) {
    case LIBUSB_SPEED_LOW: return "1.5 Mb/s";
    case LIBUSB_SPEED_FULL: return "12 Mb/s";
    case LIBUSB_SPEED_HIGH: return "480 Mb/s";
    case LIBUSB_SPEED_SUPER: return "5000 Mb/s";
    default: return "unknown speed";
    }
}

// The libusb way, as QEMU's usb-host does it: list, match, open, read
// the product name, claim and release interface 0.
static void lprobe(uint16_t vid, uint16_t pid, int fresh)
{
    NSString *tag = [NSString stringWithFormat:@"libusb %@ %04x:%04x",
                     fresh ? @"fresh context" : @"launch context", vid, pid];
    libusb_context *ctx = gUsb;
    if (fresh) {
        int r = libusb_init(&ctx);
        if (r != 0) {
            say(@"%@: libusb_init %s", tag, libusb_error_name(r));
            return;
        }
    } else if (ctx == NULL) {
        say(@"%@: no launch context", tag);
        return;
    }
    libusb_device **list = NULL;
    ssize_t n = libusb_get_device_list(ctx, &list);
    int found = 0;
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) != 0 || d.idVendor != vid || d.idProduct != pid)
            continue;
        found++;
        say(@"%@: listed at bus %u, address %u, %s", tag, libusb_get_bus_number(list[i]),
            libusb_get_device_address(list[i]), speedName(libusb_get_device_speed(list[i])));
        libusb_device_handle *h = NULL;
        int r = libusb_open(list[i], &h);
        say(@"%@: libusb_open %s", tag, r == 0 ? "succeeded" : libusb_error_name(r));
        if (r != 0)
            continue;
        unsigned char name[128] = {0};
        int s = libusb_get_string_descriptor_ascii(h, d.iProduct, name, sizeof(name));
        say(@"%@: product name %s", tag, s > 0 ? (const char *)name : libusb_error_name(s));
        int c = libusb_claim_interface(h, 0);
        say(@"%@: claim interface 0 %s", tag, c == 0 ? "succeeded" : libusb_error_name(c));
        if (c == 0)
            libusb_release_interface(h, 0);
        libusb_close(h);
    }
    if (n >= 0)
        libusb_free_device_list(list, 1);
    if (found == 0)
        say(@"%@: not in libusb's list (%zd devices listed)", tag, n);
    if (fresh)
        libusb_exit(ctx);
}

static void grant(NSString *base64)
{
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (data == nil) {
        say(@"grant: the bytes could not be decoded");
        return;
    }
    xpc_object_t x = xpc_data_create(data.bytes, data.length);
    AAUSBAccessory *accessory = [[AAUSBAccessory alloc] initWithXPCRepresentation:x];
    if (accessory == nil) {
        say(@"grant: rebuilding the accessory failed (%lu bytes)", (unsigned long)data.length);
        return;
    }
    [gAccessories addObject:accessory];
    uint64_t rid = accessory.registryID;
    say(@"grant: rebuilt the accessory (registry %llu, %lu bytes)", rid, (unsigned long)data.length);
    dispatch_queue_t q = dispatch_queue_create("aatest.service", DISPATCH_QUEUE_SERIAL);
    [accessory openWithServiceQueue:q completionHandler:^(IOUSBHostDevice *device, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (device != nil) {
                [gDevices addObject:device];
                say(@"grant: open succeeded (registry %llu)", rid);
            } else {
                say(@"grant: open failed (registry %llu): %@", rid, error);
            }
        });
    }];
}

static void closeAll(void)
{
    if (gAccessories.count == 0) {
        say(@"close: nothing to close");
        return;
    }
    for (AAUSBAccessory *accessory in gAccessories) {
        uint64_t rid = accessory.registryID;
        [accessory closeWithCompletionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                say(@"close: registry %llu %@", rid, error == nil ? @"closed" : error.description);
            });
        }];
    }
    [gAccessories removeAllObjects];
    [gDevices removeAllObjects];
}

static void handle(NSString *line)
{
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject ?: @"";
    if ([cmd isEqualToString:@"probe"] && parts.count == 3) {
        uint16_t vid = (uint16_t)strtoul(parts[1].UTF8String, NULL, 16);
        uint16_t pid = (uint16_t)strtoul(parts[2].UTF8String, NULL, 16);
        probe(vid, pid);
        lprobe(vid, pid, 0);
        lprobe(vid, pid, 1);
        say(@"probe %04x:%04x: all done", vid, pid);
    } else if ([cmd isEqualToString:@"grant"] && parts.count == 2) {
        grant(parts[1]);
    } else if ([cmd isEqualToString:@"close"]) {
        closeAll();
    } else if ([cmd isEqualToString:@"quit"]) {
        say(@"quitting");
        exit(0);
    } else if (line.length > 0) {
        say(@"unknown command: %@", [line substringToIndex:MIN(line.length, (NSUInteger)40)]);
    }
}

int main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        gAccessories = [NSMutableArray new];
        gDevices = [NSMutableArray new];
        say(@"started, pid %d, parent %d", getpid(), getppid());
        // Handoff 69: show libusb's own warnings (the open retry logs here).
        libusb_set_option(NULL, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_WARNING);
        int ur = libusb_init(&gUsb);
        const struct libusb_version *lv = libusb_get_version();
        say(@"libusb %u.%u.%u launch context: %s", lv->major, lv->minor, lv->micro,
            ur == 0 ? "ready" : libusb_error_name(ur));
        if (ur != 0)
            gUsb = NULL;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char *buf = NULL;
            size_t cap = 0;
            while (getline(&buf, &cap, stdin) > 0) {
                NSString *s = [[NSString stringWithUTF8String:buf]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (s == nil)
                    continue;
                dispatch_sync(dispatch_get_main_queue(), ^{ handle(s); });
            }
            say(@"stdin closed; exiting");
            exit(0);
        });
        dispatch_main();
    }
}
