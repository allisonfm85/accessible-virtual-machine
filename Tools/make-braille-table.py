# Regenerates AVM/USBBrailleDeviceTable.swift from BRLTTY's USB device table.
# Usage: python3 make-braille-table.py <brltty.usermap> <revision> <output.swift>
import re, sys, hashlib
src, rev, out = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
if "BEGIN_USB_BRAILLE_DEVICES" not in text:
    sys.exit("REFUSED: input does not look like BRLTTY's brltty.usermap. Nothing written.")
blocks, cur = [], None
for line in text.split("\n"):
    m = re.match(r"# Device: ([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})$", line)
    if m:
        cur = {"v": m.group(1).lower(), "p": m.group(2).lower(), "generic": False, "models": []}
        blocks.append(cur)
        continue
    if cur is None:
        continue
    if line.startswith("# Generic Identifier"):
        cur["generic"] = True
    elif line.startswith("# Vendor:") or line.startswith("# Product:"):
        pass
    elif line.startswith("# ") and not line.startswith("#  "):
        cur["models"].append(line[2:].strip())
    elif not line.strip():
        cur = None
seen, specific, generic = set(), [], []
for b in blocks:
    key = (b["v"], b["p"])
    if key in seen:
        sys.exit(f"REFUSED: duplicate device {b['v']}:{b['p']}. Nothing written.")
    seen.add(key)
    (generic if b["generic"] else specific).append(b)
if len(specific) < 50:
    sys.exit(f"REFUSED: only {len(specific)} braille-specific devices found; expected over 100. Nothing written.")

def entry(b):
    models = "; ".join(b["models"]) or "no model listed"
    return f"        0x{b['v']}_{b['p']}, // {models}"

L = []
L.append("//")
L.append("//  USBBrailleDeviceTable.swift")
L.append("//  AVM")
L.append("//")
L.append("//  GENERATED FILE. Do not edit by hand. Regenerate with")
L.append("//  make-braille-table.py from a newer BRLTTY instead.")
L.append("//")
L.append(f"//  Source: BRLTTY revision {rev}, Autostart/Hotplug/brltty.usermap.")
L.append("//  BRLTTY is Copyright (C) 1995-2026 by The BRLTTY Developers and is")
L.append("//  licensed under the GNU Lesser General Public License, version 2.1")
L.append("//  or later. https://brltty.app/  AVM uses only the list of USB vendor")
L.append("//  and product IDs, and the model names as comments.")
L.append("//")
L.append("//  Why AVM needs this: braille displays that speak HID braille, like")
L.append("//  the Monarch, identify themselves by usage page 0x41 and need no")
L.append("//  table. Older displays use serial-style or vendor-specific USB")
L.append("//  interfaces and can only be recognized by their IDs.")
L.append("//")
L.append("//  Generic chips: six entries are USB-to-serial chips that braille")
L.append("//  displays share with unrelated gadgets such as Arduino boards.")
L.append("//  Decision of record (2026-09-26): AVM treats every one of them as a")
L.append("//  possible braille display. Missing a braille display would take")
L.append("//  someone's braille away without asking; an extra question for a")
L.append("//  gadget costs little.")
L.append("//")
L.append("")
L.append("enum USBBrailleDeviceTable {")
L.append("")
L.append(f'    static let source = "BRLTTY {rev[:12]}"')
L.append("")
L.append("    enum Match {")
L.append("        /// An ID BRLTTY lists only for braille devices.")
L.append("        case braille")
L.append("        /// A generic serial chip that some braille displays use.")
L.append("        case genericChip")
L.append("    }")
L.append("")
L.append("    static func match(vendorID: UInt16, productID: UInt16) -> Match? {")
L.append("        let key = UInt32(vendorID) << 16 | UInt32(productID)")
L.append("        if brailleDevices.contains(key) { return .braille }")
L.append("        if genericChips.contains(key) { return .genericChip }")
L.append("        return nil")
L.append("    }")
L.append("")
L.append(f"    /// {len(specific)} braille-specific devices, as vendor << 16 | product.")
L.append("    private static let brailleDevices: Set<UInt32> = [")
L += [entry(b) for b in specific]
L.append("    ]")
L.append("")
L.append(f"    /// {len(generic)} generic serial chips, as vendor << 16 | product.")
L.append("    private static let genericChips: Set<UInt32> = [")
L += [entry(b) for b in generic]
L.append("    ]")
L.append("}")
L.append("")
data = "\n".join(L)
open(out, "w", encoding="utf-8").write(data)
print(f"{len(specific)} braille-specific, {len(generic)} generic chips")
print("sha256:", hashlib.sha256(data.encode()).hexdigest())
print("WROTE", out)
