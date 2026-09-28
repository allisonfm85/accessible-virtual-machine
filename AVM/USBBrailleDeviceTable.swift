//
//  USBBrailleDeviceTable.swift
//  AVM
//
//  GENERATED FILE. Do not edit by hand. Regenerate with
//  make-braille-table.py from a newer BRLTTY instead.
//
//  Source: BRLTTY revision d0ea21c2340ccdc67325e31f2a0f8ca6f53830f4, Autostart/Hotplug/brltty.usermap.
//  BRLTTY is Copyright (C) 1995-2026 by The BRLTTY Developers and is
//  licensed under the GNU Lesser General Public License, version 2.1
//  or later. https://brltty.app/  AVM uses only the list of USB vendor
//  and product IDs, and the model names as comments.
//
//  Why AVM needs this: braille displays that speak HID braille, like
//  the Monarch, identify themselves by usage page 0x41 and need no
//  table. Older displays use serial-style or vendor-specific USB
//  interfaces and can only be recognized by their IDs.
//
//  Generic chips: six entries are USB-to-serial chips that braille
//  displays share with unrelated gadgets such as Arduino boards.
//  Decision of record (2026-09-26): AVM treats every one of them as a
//  possible braille display. Missing a braille display would take
//  someone's braille away without asking; an extra question for a
//  gadget costs little.
//

enum USBBrailleDeviceTable {

    static let source = "BRLTTY d0ea21c2340c"

    enum Match {
        /// An ID BRLTTY lists only for braille devices.
        case braille
        /// A generic serial chip that some braille displays use.
        case genericChip
    }

    static func match(vendorID: UInt16, productID: UInt16) -> Match? {
        let key = UInt32(vendorID) << 16 | UInt32(productID)
        if brailleDevices.contains(key) { return .braille }
        if genericChips.contains(key) { return .genericChip }
        return nil
    }

    /// 128 braille-specific devices, as vendor << 16 | product.
    private static let brailleDevices: Set<UInt32> = [
        0x0403_de58, // Hedo [MobilLine]
        0x0403_de59, // Hedo [ProfiLine]
        0x0403_f208, // Papenmeier [all models]
        0x0403_fe70, // Baum [Vario 40 (40 cells)]
        0x0403_fe71, // Baum [PocketVario (24 cells)]
        0x0403_fe72, // Baum [SuperVario 40 (40 cells)]
        0x0403_fe73, // Baum [SuperVario 32 (32 cells)]
        0x0403_fe74, // Baum [SuperVario 64 (64 cells)]
        0x0403_fe75, // Baum [SuperVario 80 (80 cells)]
        0x0403_fe76, // Baum [VarioPro 80 (80 cells)]
        0x0403_fe77, // Baum [VarioPro 64 (64 cells)]
        0x0452_0100, // Metec [all models]
        0x045e_930a, // HIMS [Braille Sense (USB 1.1)]; HIMS [Braille Sense (USB 2.0)]; HIMS [Braille Sense U2 (USB 2.0)]; HIMS [BrailleSense 6 (USB 2.1)]
        0x045e_930b, // HIMS [Braille Edge and QBrailleXL]
        0x045e_940a, // HIMS [eMotion (HID)]
        0x0483_a1d3, // Baum [Orbit Reader 20 (20 cells)]
        0x0483_a366, // Baum [Orbit Reader 40 (40 cells)]
        0x06b0_0001, // Alva [Satellite (5nn)]
        0x0798_0001, // Voyager [all models]
        0x0798_0600, // Alva [Voyager Protocol Converter]
        0x0798_0624, // Alva [BC624]
        0x0798_0640, // Alva [BC640]
        0x0798_0680, // Alva [BC680]
        0x0904_1016, // FrankAudiodata [B2K84 (before firmware installation)]
        0x0904_1017, // FrankAudiodata [B2K84 (after firmware installation)]
        0x0904_2000, // Baum [VarioPro 40 (40 cells)]
        0x0904_2001, // Baum [EcoVario 24 (24 cells)]
        0x0904_2002, // Baum [EcoVario 40 (40 cells)]
        0x0904_2007, // Baum [VarioConnect 40 (40 cells)]
        0x0904_2008, // Baum [VarioConnect 32 (32 cells)]
        0x0904_2009, // Baum [VarioConnect 24 (24 cells)]
        0x0904_2010, // Baum [VarioConnect 64 (64 cells)]
        0x0904_2011, // Baum [VarioConnect 80 (80 cells)]
        0x0904_2014, // Baum [EcoVario 32 (32 cells)]
        0x0904_2015, // Baum [EcoVario 64 (64 cells)]
        0x0904_2016, // Baum [EcoVario 80 (80 cells)]
        0x0904_3000, // Baum [Refreshabraille 18 (18 cells)]
        0x0904_3001, // Baum [Orbit in Refreshabraille Emulation Mode (18 cells)]; Baum [Refreshabraille 18 (18 cells)]
        0x0904_4004, // Baum [Pronto! V3 18 (18 cells)]
        0x0904_4005, // Baum [Pronto! V3 40 (40 cells)]
        0x0904_4007, // Baum [Pronto! V4 18 (18 cells)]
        0x0904_4008, // Baum [Pronto! V4 40 (40 cells)]
        0x0904_6001, // Baum [SuperVario2 40 (40 cells)]
        0x0904_6002, // Baum [PocketVario2 (24 cells)]
        0x0904_6003, // Baum [SuperVario2 32 (32 cells)]
        0x0904_6004, // Baum [SuperVario2 64 (64 cells)]
        0x0904_6005, // Baum [SuperVario2 80 (80 cells)]
        0x0904_6006, // Baum [Brailliant2 40 (40 cells)]
        0x0904_6007, // Baum [Brailliant2 24 (24 cells)]
        0x0904_6008, // Baum [Brailliant2 32 (32 cells)]
        0x0904_6009, // Baum [Brailliant2 64 (64 cells)]
        0x0904_600a, // Baum [Brailliant2 80 (80 cells)]
        0x0904_6011, // Baum [VarioConnect 24 (24 cells)]
        0x0904_6012, // Baum [VarioConnect 32 (32 cells)]
        0x0904_6013, // Baum [VarioConnect 40 (40 cells)]
        0x0904_6101, // Baum [VarioUltra 20 (20 cells)]
        0x0904_6102, // Baum [VarioUltra 40 (40 cells)]
        0x0904_6103, // Baum [VarioUltra 32 (32 cells)]
        0x0921_1200, // HandyTech [GoHubs chip]
        0x0f4e_0100, // FreedomScientific [Focus 1]
        0x0f4e_0111, // FreedomScientific [PAC Mate]
        0x0f4e_0112, // FreedomScientific [Focus 2]
        0x0f4e_0114, // FreedomScientific [Focus 3+]
        0x1148_0301, // BrailleMemo [Smart]
        0x1209_abc0, // Inceptor [all models]
        0x16c0_05e1, // Canute [all models]
        0x1c71_c004, // BrailleNote [HumanWare APEX]
        0x1c71_c005, // HumanWare [Brailliant BI 32/40, Brailliant B 80 (serial protocol)]
        0x1c71_c006, // HumanWare [non-Touch models (HID protocol)]
        0x1c71_c00a, // HumanWare [BrailleNote Touch (HID protocol)]
        0x1c71_c021, // HumanWare [Brailliant BI 14 (serial protocol)]
        0x1c71_c101, // HumanWare [APH Chameleon 20 (HID protocol, firmware 1.0)]; HumanWare [APH Chameleon 20 (HID protocol, firmware 1.1)]
        0x1c71_c104, // HumanWare [APH Chameleon 20 (serial protocol)]
        0x1c71_c111, // HumanWare [APH Mantis Q40 (HID protocol, firmware 1.0)]; HumanWare [APH Mantis Q40 (HID protocol, firmware 1.1)]
        0x1c71_c114, // HumanWare [APH Mantis Q40 (serial protocol)]
        0x1c71_c121, // HumanWare [Humanware BrailleOne (HID protocol, firmware 1.0)]; HumanWare [Humanware BrailleOne (HID protocol, firmware 1.1)]
        0x1c71_c124, // HumanWare [Humanware BrailleOne (serial protocol)]
        0x1c71_c131, // HumanWare [Humanware Brailliant BI 40X (HID protocol, firmware 1.0)]; HumanWare [Humanware Brailliant BI 40X (HID protocol, firmware 1.1)]
        0x1c71_c141, // HumanWare [Humanware Brailliant BI 20X (HID protocol, firmware 1.0)]; HumanWare [Humanware Brailliant BI 20X (HID protocol, firmware 1.1)]
        0x1c71_ce01, // HumanWare [NLS eReader (HID protocol, firmware 1.0)]; HumanWare [NLS eReader (HID protocol, firmware 1.1)]
        0x1c71_ce04, // HumanWare [NLS eReader (serial protocol)]
        0x1fe4_0003, // HandyTech [USB-HID adapter]
        0x1fe4_0044, // HandyTech [Easy Braille (HID)]
        0x1fe4_0054, // HandyTech [Active Braille]
        0x1fe4_0055, // HandyTech [Connect Braille 40]
        0x1fe4_0061, // HandyTech [Actilino]
        0x1fe4_0064, // HandyTech [Active Star 40]
        0x1fe4_0074, // HandyTech [Braille Star 40 (HID)]
        0x1fe4_0081, // HandyTech [Basic Braille 16]
        0x1fe4_0082, // HandyTech [Basic Braille 20]
        0x1fe4_0083, // HandyTech [Basic Braille 32]
        0x1fe4_0084, // HandyTech [Basic Braille 40]
        0x1fe4_0086, // HandyTech [Basic Braille 64]
        0x1fe4_0087, // HandyTech [Basic Braille 80]
        0x1fe4_008a, // HandyTech [Basic Braille 48]
        0x1fe4_008b, // HandyTech [Basic Braille 160]
        0x1fe4_0092, // HandyTech [Basic Braille 20 Plus]
        0x1fe4_0093, // HandyTech [Basic Braille 32 Plus]
        0x1fe4_0094, // HandyTech [Basic Braille 40 Plus]
        0x1fe4_0096, // HandyTech [Basic Braille 64 Plus]
        0x1fe4_0097, // HandyTech [Basic Braille 80 Plus]
        0x1fe4_009a, // HandyTech [Basic Braille 48 Plus]
        0x1fe4_009c, // HandyTech [Basic Braille 84 Plus]
        0x1fe4_00a4, // HandyTech [Activator]
        0x1fe4_00a6, // HandyTech [Activator Pro 64]
        0x1fe4_00a8, // HandyTech [Activator Pro 80]
        0x28ac_0012, // EuroBraille [b.note]
        0x28ac_0013, // EuroBraille [b.note 2]
        0x28ac_0020, // EuroBraille [b.book (internal)]
        0x28ac_0021, // EuroBraille [b.book (external)]
        0x4242_0001, // Pegasus [all models]
        0xc251_1122, // EuroBraille [Esys (version < 3.0, no SD card)]
        0xc251_1123, // EuroBraille [reserved]
        0xc251_1124, // EuroBraille [Esys (version < 3.0, with SD card)]
        0xc251_1125, // EuroBraille [reserved]
        0xc251_1126, // EuroBraille [Esys (version >= 3.0, no SD card)]
        0xc251_1127, // EuroBraille [reserved]
        0xc251_1128, // EuroBraille [Esys (version >= 3.0, with SD card)]
        0xc251_1129, // EuroBraille [reserved]
        0xc251_112a, // EuroBraille [reserved]
        0xc251_112b, // EuroBraille [reserved]
        0xc251_112c, // EuroBraille [reserved]
        0xc251_112d, // EuroBraille [reserved]
        0xc251_112e, // EuroBraille [reserved]
        0xc251_112f, // EuroBraille [reserved]
        0xc251_1130, // EuroBraille [Esytime (firmware 1.03, 2014-03-31)]; EuroBraille [Esytime]
        0xc251_1131, // EuroBraille [reserved]
        0xc251_1132, // EuroBraille [reserved]
    ]

    /// 6 generic serial chips, as vendor << 16 | product.
    private static let genericChips: Set<UInt32> = [
        0x0403_6001, // Albatross [all models]; Cebra [all models]; HIMS [Sync Braille]; HandyTech [FTDI chip]; Hedo [MobilLine]; MDV [all models]
        0x0403_6010, // DotPad [all models]
        0x10c4_ea60, // BrailleMemo [Next Touch 40]; BrailleMemo [Pocket]; Seika [Braille Display]
        0x10c4_ea80, // Seika [Note Taker]
        0x1a86_55d3, // HIMS [eMotion (legacy)]
        0x1a86_7523, // Baum [NLS eReader Zoomax (20 cells)]
    ]
}
