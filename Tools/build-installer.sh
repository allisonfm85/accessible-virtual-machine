#!/bin/bash
# build-installer.sh
# AVM — Accessible Virtual Machine
#
# Builds AVM for release and makes the installer: a signed, notarized,
# stapled DMG with AVM and an Applications shortcut, plus the zip Sparkle
# updates use.
#
#   Tools/build-installer.sh                      build, sign, notarize
#   Tools/build-installer.sh --skip-notarize      build and sign only
#   Tools/build-installer.sh --help               every option
#
# WHAT IT DOES, IN ORDER
#   1. Checks: Apple Silicon, Xcode, the UTM sysroot (and its xorriso
#      version), a Developer ID Application identity.
#   2. Archives the AVM scheme (Release), signed with that identity.
#   3. Re-signs everything the build phase staged from the sysroot. The
#      Run Script phase signs QEMU, its libraries and the install tools
#      ad hoc (or team-signs without a timestamp, for the USB helper's
#      libraries), which runs locally but is refused by notarization.
#      Every Mach-O in the app gets the Developer ID identity, hardened
#      runtime and a secure timestamp, inside out, and the app is sealed
#      last. Entitlements and identifiers already present are kept.
#   4. Verifies the signatures, and that every binary carries one Team ID.
#   5. Makes and signs the DMG.
#   6. Notarizes the DMG with notarytool, staples it, and staples the app.
#   7. Zips the stapled app for Sparkle.
#
# Output goes to build/installer/. Messages are plain text, one line per
# step, no colors, so they read cleanly in a screen reader. When the run
# ends the system voice says whether it worked (turn off with --no-speech).
#
# NOTARIZATION needs a notarytool keychain profile, made once:
#   xcrun notarytool store-credentials AVM-notary \
#       --apple-id you@example.com --team-id YOURTEAMID
# (it asks for an app-specific password from appleid.apple.com). Then pass
# --notary-profile AVM-notary, or set AVM_NOTARY_PROFILE.

set -euo pipefail

# MARK: - Settings

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="${AVM_SYSROOT:-$HOME/Developer/sysroot-macos-arm64/sysroot-macOS-arm64}"
IDENTITY="${AVM_SIGN_IDENTITY:-}"
TEAM_ID="${AVM_TEAM_ID:-}"
NOTARY_PROFILE="${AVM_NOTARY_PROFILE:-}"
SKIP_NOTARIZE=0
SIGN_FOR_UPDATES=1
SPEAK=1
# Work happens outside the repository: a folder synced by iCloud Drive or
# another File Provider (Documents and Desktop often are) keeps adding
# extended attributes that codesign refuses. Only the finished DMG and zip
# are copied into the repository's build/installer.
BUILD_DIR="${AVM_BUILD_DIR:-$HOME/Library/Caches/AVM-build}"
OUT_DIR="$REPO_ROOT/build/installer"

usage() {
    cat <<'EOF'
Usage: Tools/build-installer.sh [options]

Options:
  --sysroot PATH          UTM sysroot (default: $AVM_SYSROOT, or
                          ~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64)
  --identity NAME         Signing identity, e.g. "Developer ID Application:
                          Name (TEAMID)". Default: $AVM_SIGN_IDENTITY, or the
                          first Developer ID Application identity found.
  --team TEAMID           Team ID. Default: read from the identity's name.
  --notary-profile NAME   notarytool keychain profile (or $AVM_NOTARY_PROFILE).
  --skip-notarize         Sign only. The DMG then opens only on this Mac.
  --no-update-signing     Don't sign the Sparkle zip or write the update feed
                          entry (a test build that won't be published).
  --no-speech             Don't speak the result at the end.

Work files (archive, logs) go to $AVM_BUILD_DIR, default
~/Library/Caches/AVM-build. The DMG and zip land in build/installer.
  -h, --help              This help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sysroot)        SYSROOT="$2"; shift 2 ;;
        --identity)       IDENTITY="$2"; shift 2 ;;
        --team)           TEAM_ID="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        --no-update-signing) SIGN_FOR_UPDATES=0; shift ;;
        --no-speech)      SPEAK=0; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 64 ;;
    esac
done

# MARK: - Messages

CURRENT_STEP="starting"

step() {
    CURRENT_STEP="$1"
    echo
    echo "== $1"
}

info() { echo "   $1"; }

fail() {
    echo
    echo "FAILED during: $CURRENT_STEP"
    echo "Reason: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    speak "AVM installer build failed during $CURRENT_STEP."
    trap - EXIT
    exit 1
}

speak() {
    [ "$SPEAK" = "1" ] && command -v say >/dev/null 2>&1 && say "$1" || true
}

# A command that fails without going through fail() still gets named.
# 64 is a usage error, which usage() has already explained. Every other
# failure, exit 2 included, is named and spoken.
trap 'rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 64 ]; then echo; echo "FAILED during: $CURRENT_STEP (exit $rc). The output above shows why."; speak "AVM installer build failed during $CURRENT_STEP."; fi' EXIT

# MARK: - 1. Checks

step "Checking the build machine"

[ "$(uname -m)" = "arm64" ] || fail "AVM builds only on Apple Silicon; this Mac is $(uname -m)."
command -v xcodebuild >/dev/null || fail "xcodebuild was not found." "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
info "$(xcodebuild -version | sed -n 1p)"

[ -d "$SYSROOT" ] || fail "The UTM sysroot was not found at $SYSROOT." \
    "Put the sysroot there, or pass --sysroot /path/to/sysroot-macOS-arm64 (see Building from source in the README)."
# The real, absolute spelling (2026-10-25, code audit): the build phase
# rewrites library paths that start with exactly "$AVM_SYSROOT/lib", so a
# trailing slash, a relative path or a symlink left every path unrewritten,
# and the release only ran on the Mac that built it.
SYSROOT="$(cd "$SYSROOT" && pwd -P)"
# The build phase splits library paths on spaces, so a sysroot path with one
# silently skips the rewrite (2026-10-25, code audit).
case "$SYSROOT" in
    *" "*) fail "The sysroot path has a space in it: $SYSROOT" "Move the sysroot to a path without spaces, such as ~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64." ;;
esac
# Everything the build phase stages. It only warns when one is missing, so
# a gap would otherwise ship: no TPM, no install tools, no Secure Boot.
for need in bin/qemu-system-aarch64 bin/qemu-img bin/swtpm bin/xorriso bin/wimlib-imagex bin/mtools \
            lib lib/libswtpm_libtpms.0.dylib lib/libwim.15.dylib Frameworks \
            share/qemu/edk2-aarch64-code.fd share/qemu/edk2-arm-vars.fd share/qemu/vgabios-ramfb.bin share/qemu/efi-virtio.rom \
            share/qemu/edk2-aarch64-secure-code.fd share/qemu/edk2-arm-secure-vars.fd share/qemu/edk2-licenses.txt; do
    [ -e "$SYSROOT/$need" ] || fail "The sysroot at $SYSROOT has no $need." \
        "Check that it is a complete sysroot; Tools/build-sysroot.sh builds one."
done
info "Sysroot: $SYSROOT"

# The README's rule: earlier xorriso makes install ISOs Windows can't boot.
XORRISO_VERSION="$("$SYSROOT/bin/xorriso" -version 2>/dev/null | sed -nE 's/^(GNU )?xorriso ([0-9]+\.[0-9]+\.[0-9]+(\.pl[0-9]+)?).*/\2/p' | sed -n 1p)"
[ -n "$XORRISO_VERSION" ] || fail "Could not read the sysroot's xorriso version."
xorriso_key() {
    local v="$1" pl=0
    case "$v" in *.pl*) pl="${v##*.pl}"; v="${v%.pl*}" ;; esac
    IFS=. read -r a b c <<<"$v"
    echo $(( 10#$a * 1000000 + 10#$b * 10000 + 10#$c * 100 + 10#$pl ))
}
[ "$(xorriso_key "$XORRISO_VERSION")" -ge "$(xorriso_key 1.5.8.pl02)" ] || \
    fail "The sysroot's xorriso is $XORRISO_VERSION; AVM needs 1.5.8.pl02 or later." \
         "Earlier versions make install ISOs the Windows boot loader cannot read. Update xorriso in the sysroot."
info "xorriso $XORRISO_VERSION"

if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | sed -n 1p)"
    [ -n "$IDENTITY" ] || fail "No Developer ID Application signing identity is in your keychain." \
        "Create one in Xcode, Settings, Accounts, Manage Certificates, or pass --identity."
fi
IDENTITIES="$(security find-identity -v -p codesigning)"
case "$IDENTITIES" in
    *"\"$IDENTITY\""*) ;;
    *) fail "The signing identity \"$IDENTITY\" is not in your keychain." ;;
esac
if [ -z "$TEAM_ID" ]; then
    TEAM_ID="$(echo "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
    [ -n "$TEAM_ID" ] || fail "Could not read a Team ID from \"$IDENTITY\"." "Pass --team TEAMID."
fi
info "Signing as: $IDENTITY"
info "Team: $TEAM_ID"

if [ "$SKIP_NOTARIZE" = "0" ]; then
    [ -n "$NOTARY_PROFILE" ] || fail "No notarytool profile was given." \
        "Pass --notary-profile NAME (see the top of this script for making one), or --skip-notarize for a build that opens only on this Mac."
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || \
        fail "The notarytool profile \"$NOTARY_PROFILE\" did not work." \
             "Make it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
    info "Notary profile: $NOTARY_PROFILE"
fi

cd "$REPO_ROOT"
SETTINGS="$(xcodebuild -project AVM.xcodeproj -scheme AVM -configuration Release -showBuildSettings 2>/dev/null)"
VERSION="$(echo "$SETTINGS" | sed -nE 's/^ *MARKETING_VERSION = (.*)$/\1/p' | sed -n 1p)"
BUILD_NUMBER="$(echo "$SETTINGS" | sed -nE 's/^ *CURRENT_PROJECT_VERSION = (.*)$/\1/p' | sed -n 1p)"
[ -n "$VERSION" ] || fail "Could not read MARKETING_VERSION from the project."
info "Version $VERSION, build $BUILD_NUMBER"

# MARK: - 2. Archive

step "Archiving AVM $VERSION (this takes several minutes)"

ARCHIVE="$BUILD_DIR/AVM.xcarchive"
ARCHIVE_LOG="$BUILD_DIR/archive.log"
mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE" "$BUILD_DIR/AVM.app" "$OUT_DIR"
mkdir -p "$OUT_DIR"

# ARCHS=arm64: AVM runs only on Apple Silicon and the sysroot is arm64
# only, so a universal build fails to link its x86_64 half.
# Settings given on the command line outrank the project's, including its
# [sdk=macosx*] variant of CODE_SIGN_IDENTITY. (That variant can't be
# passed here anyway: xcodebuild splits at the first "=", so it would set
# a setting named "CODE_SIGN_IDENTITY[sdk" instead.)
if ! xcodebuild archive \
        -project AVM.xcodeproj \
        -scheme AVM \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        AVM_SYSROOT="$SYSROOT" \
        ARCHS=arm64 \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER= \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        >"$ARCHIVE_LOG" 2>&1; then
    echo "   Last lines of the build log:"
    grep -E "error:|\*\* ARCHIVE FAILED" "$ARCHIVE_LOG" | tail -20 | sed 's/^/   /' || true
    fail "xcodebuild archive failed." "Read the full log at $ARCHIVE_LOG"
fi
info "Build log: $ARCHIVE_LOG"

APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/AVM.app"
[ -d "$APP_IN_ARCHIVE" ] || fail "The archive has no AVM.app at $APP_IN_ARCHIVE."
APP="$BUILD_DIR/AVM.app"
ditto "$APP_IN_ARCHIVE" "$APP"
# codesign refuses files carrying extended attributes ("detritus"), and
# everything here is re-signed below, so nothing of value is lost.
xattr -cr "$APP"

# MARK: - 3. Signing

step "Signing every binary with Developer ID"

# QEMU gets the release entitlements (no library-validation exception,
# 2026-10-26), as the app does, plus allow-jit.
# Hardened runtime is new for QEMU here (notarization requires it on every
# executable); allow-jit keeps QEMU's TCG code buffer working under it, so
# a fallback from HVF can't crash at the first translated block.
QEMU_ENTITLEMENTS="$BUILD_DIR/qemu.entitlements"
cp "$REPO_ROOT/AVM/AVM-Release.entitlements" "$QEMU_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.allow-jit bool true" "$QEMU_ENTITLEMENTS" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.cs.allow-jit true" "$QEMU_ENTITLEMENTS"

is_macho() {
    case "$(file -b "$1")" in
        *Mach-O*) return 0 ;;
        *) return 1 ;;
    esac
}

sign() {
    # Keeps the identifier and entitlements already on the item; the
    # designated requirement is regenerated for the new certificate.
    codesign --force --timestamp --options runtime \
        --preserve-metadata=identifier,entitlements \
        --sign "$IDENTITY" "$@" >/dev/null 2>&1 || {
        codesign --force --timestamp --options runtime \
            --preserve-metadata=identifier,entitlements \
            --sign "$IDENTITY" "$@" || true
        fail "codesign refused ${*: -1}."
    }
}

# Sign bundles and Mach-O files under one directory, deepest first, so
# every nested item is signed before whatever contains it. Sets
# SIGNED_COUNT. Symlinks (Versions/Current and friends) are skipped.
sign_tree() {
    local root="$1" path
    SIGNED_COUNT=0
    while IFS= read -r path; do
        sign "$path"
        SIGNED_COUNT=$((SIGNED_COUNT + 1))
    done < <(
        find "$root" \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.bundle' \) -print \) -o \( -type f -print \) |
        while IFS= read -r p; do
            if [ -d "$p" ] || is_macho "$p"; then echo "$p"; fi
        done | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-
    )
}

RES="$APP/Contents/Resources"
count=0
for item in "$RES"/*; do
    [ -f "$item" ] && [ ! -L "$item" ] && is_macho "$item" || continue
    case "$(basename "$item")" in
        qemu-system-aarch64|qemu-img|libqemu-aarch64-softmmu.dylib)
            codesign --force --timestamp --options runtime \
                --entitlements "$QEMU_ENTITLEMENTS" \
                --sign "$IDENTITY" "$item" >/dev/null 2>&1 || fail "codesign refused $item."
            ;;
        *)
            sign "$item"
            ;;
    esac
    count=$((count + 1))
done
info "Resources: $count binaries (QEMU, its libraries, swtpm, install tools)"

if [ -d "$APP/Contents/Frameworks" ]; then
    sign_tree "$APP/Contents/Frameworks"
    info "Frameworks: $SIGNED_COUNT items (sysroot frameworks and Sparkle, inside out)"
fi

for exe in "$APP/Contents/MacOS"/*; do
    [ "$(basename "$exe")" = "AVM" ] && continue
    if is_macho "$exe"; then
        sign "$exe"
        info "Signed $(basename "$exe")"
    fi
done

sign "$APP"
info "Sealed AVM.app"

# MARK: - 4. Verify

step "Verifying signatures"

codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/   /' || fail "The app's signature does not verify." "See the codesign output above."

# Every binary must carry this team. A stray ad-hoc signature is exactly
# what notarization rejects, and the USB helper only trusts its own team.
bad=0
while IFS= read -r f; do
    is_macho "$f" || continue
    team="$(codesign -dv "$f" 2>&1 | sed -nE 's/^TeamIdentifier=(.*)$/\1/p')"
    if [ "$team" != "$TEAM_ID" ]; then
        echo "   Wrong or missing Team ID (${team:-none}): ${f#"$APP"/}"
        bad=$((bad + 1))
    fi
done < <(find "$APP" -type f)
[ "$bad" = "0" ] || fail "$bad binaries are not signed by team $TEAM_ID."
info "Every binary is signed by team $TEAM_ID."

# Nothing may still point at the build Mac: every library reference must
# be inside the app (@rpath, @loader_path, @executable_path) or macOS's own
# (/usr/lib, /System). Anything else works here and fails on every other Mac.
leaks=0
while IFS= read -r f; do
    is_macho "$f" || continue
    # Lines ending in ":" are otool's headers (one per architecture in a
    # universal binary such as Sparkle's), not references.
    refs="$(otool -L "$f" 2>/dev/null | awk '!/:$/ {print $1}')"
    for ref in $refs; do
        case "$ref" in
            @*|/usr/lib/*|/System/*) ;;
            *) echo "   Library path outside the app in ${f#"$APP"/}: $ref"; leaks=$((leaks + 1)) ;;
        esac
    done
done < <(find "$APP" -type f)
[ "$leaks" = "0" ] || fail "$leaks library references point outside the app; it would run only on this Mac." \
    "Check that --sysroot names the same folder the build phase used, then build again."
info "Every library reference is inside the app or macOS."

# MARK: - 5. DMG

step "Making the disk image"

DMG="$BUILD_DIR/AVM-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AVM.app"
ln -s /Applications "$STAGE/Applications"
# macOS 27 calls hdiutil create deprecated but it still works; only that
# notice is hidden, real errors still show.
hdiutil create -volname "AVM $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" \
        >/dev/null 2> >(grep -v "is deprecated" >&2) || \
    fail "hdiutil could not make the disk image."
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG" >/dev/null 2>&1 || fail "codesign refused the disk image."
info "Made AVM-$VERSION.dmg"

# MARK: - 6. Notarize

if [ "$SKIP_NOTARIZE" = "0" ]; then
    step "Notarizing (Apple usually answers in a few minutes)"
    SUBMIT_LOG="$BUILD_DIR/notarize.log"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait >"$SUBMIT_LOG" 2>&1 || true
    sed 's/^/   /' "$SUBMIT_LOG" | grep -E "id:|status:" || true
    if ! grep -q "status: Accepted" "$SUBMIT_LOG"; then
        SUB_ID="$(sed -nE 's/^ *id: ([0-9a-f-]+)$/\1/p' "$SUBMIT_LOG" | sed -n 1p)"
        if [ -n "$SUB_ID" ]; then
            xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" "$BUILD_DIR/notary-issues.json" >/dev/null 2>&1 || true
            fail "Apple did not accept the disk image." "Apple's list of problems is in $BUILD_DIR/notary-issues.json"
        fi
        fail "The notarization request did not complete." "See $SUBMIT_LOG"
    fi
    xcrun stapler staple "$DMG" >/dev/null || fail "Stapling the disk image failed."
    xcrun stapler staple "$APP" >/dev/null || fail "Stapling the app failed."
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/   /' || \
        info "Gatekeeper's check of the stapled image didn't pass on this Mac; the notarization itself succeeded."
    info "Notarized and stapled."
else
    step "Skipping notarization"
    info "This DMG opens on this Mac. On other Macs, Gatekeeper blocks it until it is notarized."
fi

# MARK: - 7. Sparkle zip

step "Making the Sparkle update zip"
ZIP="$OUT_DIR/AVM-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
info "$ZIP"
# Signed with the update key (2026-10-26): Sparkle's EdDSA key in the
# login keychain (Sparkle's default account, ed25519, unless
# AVM_SPARKLE_ACCOUNT names another), whose public half is
# SUPublicEDKey in AVM/Info.plist. The first time, macOS asks to let
# sign_update use the key; choose Always Allow. The result is the update
# feed entry for this release, which Tools/publish-release.sh adds to
# appcast.xml when the release is published.
SPARKLE_ACCOUNT="${AVM_SPARKLE_ACCOUNT:-ed25519}"
REPO_SLUG="${AVM_REPO:-allisonfm85/accessible-virtual-machine}"
SIGN_UPDATE="$(find "$BUILD_DIR/DerivedData/SourcePackages/artifacts" -path '*Sparkle/bin/sign_update' -type f 2>/dev/null | sed -n 1p || true)"
if [ "$SIGN_FOR_UPDATES" = "0" ]; then
    info "Not signing for updates (--no-update-signing); this build can't be published."
elif [ -z "$SIGN_UPDATE" ]; then
    fail "Sparkle's sign_update tool was not found in the build." "Check that the archive step resolved the Sparkle package."
else
info "Signing the update zip with the update key ($SPARKLE_ACCOUNT). If macOS asks, choose Always Allow."
SIGNATURE="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ZIP")" || \
    fail "sign_update could not sign the zip." "Check the key: run generate_keys --account $SPARKLE_ACCOUNT, and allow keychain access."
ITEM="$OUT_DIR/appcast-item.xml"
cat > "$ITEM" <<ITEMXML
        <item>
            <title>Version $VERSION</title>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <enclosure url="https://github.com/$REPO_SLUG/releases/download/v$VERSION/AVM-$VERSION.zip" $SIGNATURE type="application/octet-stream" />
        </item>
ITEMXML
info "Update feed entry: $ITEM"
fi

# MARK: - Done

cp "$DMG" "$OUT_DIR/"
DMG="$OUT_DIR/$(basename "$DMG")"

trap - EXIT
CURRENT_STEP="done"
echo
echo "== Done. AVM $VERSION installer:"
echo "   $DMG"
echo "   To publish it as an update: Tools/publish-release.sh"
speak "AVM $VERSION installer is ready."
