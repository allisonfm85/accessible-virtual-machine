//
//  AVMUSBHelper-Bridging-Header.h
//  AVMUSBHelper
//
//  Exposes the C usbredirhost wrapper to the helper's Swift code.
//  Nothing else belongs here. libusb and usbredir headers stay behind
//  usbstream.h on purpose: Swift only ever sees the wrapper.
//

#import "usbstream.h"
