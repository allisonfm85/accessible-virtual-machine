# avm-own-copy.sh
# AVM — Accessible Virtual Machine
#
# Sourced by the Tools scripts that run AVM for a job of their own
# (2026-10-30). While AVM is running, macOS's loginwindow sends a second
# process with AVM's bundle identifier SIGTERM after about 30 seconds, so
# a longer job (the full accessibility audit, building install media, a
# test) ended part way, with exit 143. The job then runs a clone of the app
# with an identifier of its own, "<AVM's>.<suffix>": cp -c makes it in no
# time or space, and it's signed for this Mac.
#
#   avm_own_copy APP SUFFIX [always]
#
# Sets AVM_COPY to the app to run and AVM_COPY_DIR to remove afterwards.
# With AVM not running, AVM_COPY is APP itself and AVM_COPY_DIR is empty:
# the camera and microphone tests need the app's own signature, which a
# copy signed here doesn't have. "always" makes the copy anyway (the
# audit, whose settings are then its own).
avm_own_copy() {
    local app="$1" suffix="$2" always="${3:-}" id
    AVM_COPY="$app"
    AVM_COPY_DIR=""
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" || return 1
    if [ -z "$always" ] && [ -z "$(lsappinfo find bundleid="$id" 2>/dev/null)" ]; then
        return 0
    fi
    AVM_COPY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/avm-$suffix-app-XXXXXX")"
    AVM_COPY="$AVM_COPY_DIR/AVM.app"
    cp -cR "$app" "$AVM_COPY" 2>/dev/null || cp -R "$app" "$AVM_COPY"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id.$suffix" "$AVM_COPY/Contents/Info.plist"
    codesign --force --deep --sign - "$AVM_COPY" >/dev/null 2>&1
}
