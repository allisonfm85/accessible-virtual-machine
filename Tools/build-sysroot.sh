#!/bin/bash
# build-sysroot.sh
# AVM — Accessible Virtual Machine
#
# Builds, from source, the sysroot AVM's build phase stages QEMU, SPICE,
# GStreamer and the install tools from (the AVM_SYSROOT build setting).
#
#   Tools/build-sysroot.sh            build into the default AVM_SYSROOT
#   Tools/build-sysroot.sh --licenses-only
#                                     collect the licence texts into an
#                                     existing sysroot and stop (a minute)
#   Tools/build-sysroot.sh --help     every option
#
# WHAT IT BUILDS
#   1. UTM's macOS arm64 dependency build (scripts/build_dependencies.sh),
#      at the pinned UTM commit below, with two changes:
#        - Only the OpenGL part of the GPU stack is built (2026-10-27):
#          ANGLE (OpenGL ES on Metal), libepoxy and virglrenderer without
#          Vulkan (venus) or Direct3D (neptune), for Linux machines' 3D
#          acceleration (virtio-gpu-gl-pci, VMConfiguration.gpu3D). The
#          Vulkan loader, Mesa, MoltenVK, LLVM and the D3D drivers are left
#          out: AVM offers neither Vulkan nor Windows 3D, and they cost
#          hours.
#        - AVM's patches in Tools/sysroot-patches are applied after UTM's
#          own patch for the same package: the GStreamer osxaudio
#          deadlock fix, a QEMU build fix so UTM's Metal display code
#          is compiled only when OpenGL is, QEMU's coreaudio playback and
#          microphone, usb-camera (the Mac's camera as a USB webcam), and
#          usb-hid-bridge (Bluetooth HID devices, relayed by AVM's helper).
#          Each patch's header says what it does and where it comes from.
#          Patches for git clones, which UTM's build doesn't patch, are in
#          Tools/sysroot-patches/clones, applied just before their build:
#          ANGLE and libepoxy opening ANGLE's libraries beside
#          themselves.
#   2. The install-pipeline tools UTM doesn't build: xorriso 1.5.8.pl02
#      (the README's minimum), wimlib-imagex and mtools. They link only
#      macOS's own libraries, as the build phase expects.
#   3. The licence text of every package (2026-10-29, seventh audit), from
#      the source tarballs and clones, into share/licenses; the build
#      phase stages it as Resources/Licenses. See collect_licenses below.
#   4. A check of the result against what AVM actually uses: every
#      framework and library the Xcode project links, every file the build
#      phase stages, the deadlock fix, and no Homebrew paths anywhere.
#
# WHERE
#   The sysroot is built in place, because its libraries record their own
#   absolute path and the build phase rewrites exactly that prefix. The
#   folder must therefore be named sysroot-macOS-arm64; UTM's sources and
#   build folders go next to it. Default:
#     ~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64
#   Keep it out of folders synced by iCloud Drive or another File Provider
#   (Documents, Desktop): they add file attributes that break code signing.
#
# TIME AND SPACE
#   Most of an hour on a recent Mac, and about 20 GB of disk. Homebrew
#   packages it needs are installed if missing; Python tools go into a
#   private virtual environment next to the sysroot.
#
# Messages are plain text, one line per step, no colors. The system voice
# says whether it worked at the end (turn off with --no-speech). The full
# UTM build log is written next to the sysroot.

set -euo pipefail

# MARK: - Pinned sources

UTM_REPO="https://github.com/utmapp/UTM.git"
UTM_COMMIT="1c5e2150696cf86dc6e451212a8ad4555b2b63b2"   # 2026-10-20, QEMU 10.0.12-utm

XORRISO_URL="https://ftp.gnu.org/gnu/xorriso/xorriso-1.5.8.pl02.tar.gz"
XORRISO_SHA256="b1455ecafbf0692ddafe1d71002a96f2ce2d77f4deae602678261ce033f97bc8"
WIMLIB_URL="https://wimlib.net/downloads/wimlib-1.14.5.tar.gz"
WIMLIB_SHA256="84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194"
MTOOLS_URL="https://ftp.gnu.org/gnu/mtools/mtools-4.0.49.tar.gz"
MTOOLS_SHA256="10cd1111da87bf2400a380c1639a6cba8bfb937a24f9c51f5f88d393ae5f6f76"
# Only for swtpm's configure, which insists on it (swtpm_cert uses it;
# AVM runs only swtpm). Built static into a private prefix.
LIBTASN1_URL="https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz"
LIBTASN1_SHA256="92e0e3bd4c02d4aeee76036b2ddd83f0c732ba4cda5cb71d583272b23587a76c"

BREW_PACKAGES="python@3.12 glib libgpg-error bison automake libtool gettext"
PIP_PACKAGES="meson ninja six pyparsing pyyaml distlib setuptools packaging"

# MARK: - Settings

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${AVM_SYSROOT:-$HOME/Developer/sysroot-macos-arm64/sysroot-macOS-arm64}"
JOBS="$(sysctl -n hw.ncpu)"
SPEAK=1
SKIP_UTM=0
MARK_BUILT=0
LICENSES_ONLY=0

usage() {
    cat <<'EOF'
Usage: Tools/build-sysroot.sh [options]

Options:
  --out PATH      Where to build the sysroot. The last folder must be named
                  sysroot-macOS-arm64. Default: $AVM_SYSROOT, or
                  ~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64
  --jobs N        Parallel compile jobs (default: every core).
  --tools-only    Skip the UTM build; rebuild the install tools and
                  re-check an existing sysroot.
  --mark-built    Record that the sysroot at --out was built from this
                  checkout's patches, after QEMU was rebuilt by hand from
                  exactly them, and stop. Tools/build-installer.sh checks it.
  --licenses-only Collect the licence texts of every source tarball and
                  clone into the existing sysroot's share/licenses, and
                  stop. About a minute; the normal build does it too.
  --no-speech     Don't speak the result at the end.
  -h, --help      This help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)        OUT="$2"; shift 2 ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        --tools-only) SKIP_UTM=1; shift ;;
        --mark-built) MARK_BUILT=1; shift ;;
        --licenses-only) LICENSES_ONLY=1; shift ;;
        --no-speech)  SPEAK=0; shift ;;
        -h|--help)    usage; exit 0 ;;
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

speak() {
    if [ "$SPEAK" = "1" ] && command -v say >/dev/null 2>&1; then say "$1" || true; fi
}

fail() {
    echo
    echo "FAILED during: $CURRENT_STEP"
    echo "Reason: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    speak "AVM sysroot build failed during $CURRENT_STEP."
    trap - EXIT
    exit 1
}

# 64 is a usage error, already explained by usage(); every other failure
# is named and spoken.
trap 'rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 64 ]; then echo; echo "FAILED during: $CURRENT_STEP (exit $rc). The output above shows why."; speak "AVM sysroot build failed during $CURRENT_STEP."; fi' EXIT

# MARK: - 1. Checks

step "Checking the build machine"

[ "$(uname -m)" = "arm64" ] || fail "The sysroot builds only on Apple Silicon; this Mac is $(uname -m)."
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || \
    fail "The macOS SDK was not found." "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
command -v brew >/dev/null || fail "Homebrew is not installed." "Install it from https://brew.sh, then run this again."

case "$(basename "$OUT")" in
    sysroot-macOS-arm64) ;;
    *) fail "The sysroot folder must be named sysroot-macOS-arm64; got $(basename "$OUT")." \
            "Pass --out /some/folder/sysroot-macOS-arm64." ;;
esac
# No spaces (2026-10-25, code audit): the app's build phase splits library
# paths on them, so a sysroot under such a path is built fine and then
# staged wrong, with nothing said.
case "$OUT" in
    *" "*) fail "The sysroot path has a space in it: $OUT" "Pass --out with a path without spaces." ;;
esac
# Resolved before the check (2026-10-25, code audit): a relative --out, or
# one through a symlink, used to slip past it into a synced folder.
PARENT="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$(dirname "$OUT")")"
case "$PARENT/" in
    "$HOME/Documents/"*|"$HOME/Desktop/"*|"$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*)
        fail "$PARENT may be synced by iCloud Drive or another File Provider, which breaks code signing." \
             "Pass --out with a folder outside Documents and Desktop, for example ~/Developer/sysroot-macos-arm64/sysroot-macOS-arm64." ;;
esac
mkdir -p "$PARENT"
PARENT="$(cd "$PARENT" && pwd)"
OUT="$PARENT/sysroot-macOS-arm64"

# UTM's build empties the sysroot folder first. Only ever empty one this
# script made.
MARKER="$OUT/.avm-sysroot-build"
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && [ ! -f "$MARKER" ]; then
    fail "$OUT already exists and was not made by this script, so it was left alone." \
         "Move it aside, or pass --out with a different folder."
fi

# Which patches the sysroot was built from (2026-10-29, sixth audit):
# Tools/build-installer.sh compares this with the checkout, so a release
# never ships a QEMU older than its patches, or built from edits no commit has.
# In one collation (2026-10-29, seventh audit): bash sorts the globs by the
# shell's locale, so a sysroot marked from a shell with no LANG was refused
# from Terminal, and the other way round. The export has to be its own
# statement; a prefix assignment doesn't change the glob's order.
patch_fingerprint() {
    ( cd "$REPO_ROOT" && export LC_ALL=C && { echo "utm $UTM_COMMIT"; shasum -a 256 Tools/sysroot-patches/*.patch Tools/sysroot-patches/clones/*.patch; } )
}
# Taken now, before the hour's build (seventh audit): taken after it, a
# patch edited meanwhile was recorded as built.
FINGERPRINT="$(patch_fingerprint)"
# Every clone patch is one the rewrite below applies (seventh audit): a new
# name was fingerprinted as built without being applied.
for p in "$REPO_ROOT"/Tools/sysroot-patches/clones/*.patch; do
    case "$(basename "$p")" in
        WebKit+*.patch|libepoxy+*.patch) ;;
        *) fail "Tools/sysroot-patches/clones/$(basename "$p") isn't applied by this script." "Clone patches are named <clone>+<what>.patch, for WebKit or libepoxy; add the clone to the rewrite of UTM's GPU block first." ;;
    esac
done
if [ "$MARK_BUILT" = "1" ]; then
    [ -f "$MARKER" ] || fail "There is no sysroot made by this script at $OUT." "Pass --out with the sysroot to mark."
    patch_fingerprint > "$OUT/.avm-sysroot-patches"
    info "Recorded this checkout's patches as the ones $OUT was built from."
    trap - EXIT
    exit 0
fi

# MARK: - Licence texts

# The licence text of every package in the sysroot (2026-10-29, seventh
# audit): the app ships GPL, LGPL, BSD and OpenSSL binaries, so it has to
# ship their licences. The build phase stages share/licenses as
# Resources/Licenses, and Resources/THIRD-PARTY-NOTICES.txt says what each
# package is in AVM. Only the licence members are extracted from each
# tarball, into a scratch folder, after its checksum is checked again;
# nothing in a tarball is run. A tarball with no licence file stops the
# build, so a new package's licence is found, not skipped. Also collected:
# the licences of the git clones (ANGLE, libepoxy, virglrenderer,
# libucontext), of the subprojects compiled into GLib and QEMU (PCRE2,
# libfdt, Berkeley SoftFloat), and UTM's own QEMU patch, which with AVM's
# patches is the difference between the tarball and the QEMU that ships.
collect_licenses() {
    local build="$PARENT/build-macOS-arm64" tools="$PARENT/build-avm-tools" utm="$PARENT/UTM"
    local dest="$OUT/share/licenses" pins="$REPO_ROOT/Tools/sysroot-sources.sha256"
    local scratch tarball file pin qemu_name="" pcre2 count=0

    step "Collecting licence texts"
    [ -d "$build" ] || fail "There are no source tarballs at $build." "Run without --licenses-only first, so UTM's build downloads them."
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/avm-licenses.XXXXXX")"
    rm -rf "$dest"
    mkdir -p "$dest"
    {
        echo "Licence texts of the packages this sysroot was built from, collected by"
        echo "Tools/build-sysroot.sh on $(date +%Y-%m-%d) from the pinned source tarballs"
        echo "(Tools/sysroot-sources.sha256 and the URLs in that script), the git clones"
        echo "UTM's build makes, and the subprojects compiled into GLib and QEMU. One"
        echo "folder per package; the files are the package's own, unchanged. The app's"
        echo "THIRD-PARTY-NOTICES.txt says what each one is in AVM and how to get the source."
        echo
        printf '%-22s %-20s %s\n' "Package" "Version" "Files"
    } > "$dest/INDEX.txt"

    # One line per package in INDEX.txt.
    record() {
        printf '%-22s %-20s %s\n' "$1" "$2" "$3" >> "$dest/INDEX.txt"
        count=$((count + 1))
    }

    # The licence files at a tarball's top level (COPYING*, LICENSE*,
    # COPYRIGHT*, NOTICE*), plus any members the caller names, into
    # share/licenses/<package>. A top-level symlink (GLib's COPYING points
    # into its LICENSES folder) is copied as the file it points to.
    from_tarball() {
        local tarball="$1" sha="$2"; shift 2
        local file name package version top listing wanted="" copies="" member target
        file="$(basename "$tarball")"
        [ -f "$tarball" ] || fail "$file is not at $(dirname "$tarball")." \
            "Run Tools/build-sysroot.sh without --licenses-only first, so it is downloaded (--tools-only is enough for xorriso, wimlib, mtools and libtasn1)."
        [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$sha" ] || \
            fail "$file does not match its pinned checksum, so nothing was read from it." "Delete it and run Tools/build-sysroot.sh again."
        name="${file%.tar.*}"
        package="$(echo "$name" | sed -E 's/-v?[0-9].*$//')"
        version="${name#"$package"-}"
        listing="$(tar -tvf "$tarball")" || fail "Could not list $file."
        top="$(echo "$listing" | awk '{ print $9 }' | sed -n -E 's#^([^/]+)/.*#\1#p' | sed -n 1p)"
        [ -n "$top" ] || fail "$file has no top-level folder."
        # One "member<TAB>link target" line per licence file; the target is
        # empty for a regular file. tar -tv prints the name ninth, then
        # "-> target" for a symlink.
        while IFS=$'\t' read -r member target; do
            [ -n "$member" ] || continue
            if [ -n "$target" ]; then
                case "$target" in /*|*..*) fail "$file: $member links outside the tarball ($target)." ;; esac
                target="$top/$target"
                wanted="$wanted $target"
                copies="$copies $target>$(basename "$member")"
            else
                wanted="$wanted $member"
                copies="$copies $member>$(basename "$member")"
            fi
        done <<< "$(echo "$listing" | awk -v top="$top/" '
            $1 !~ /^d/ && index($9, top) == 1 {
                rest = substr($9, length(top) + 1)
                if (index(rest, "/") == 0 && toupper(rest) ~ /^(COPYING|LICEN[CS]E|COPYRIGHT|NOTICE)/)
                    print $9 "\t" ($1 ~ /^l/ ? $11 : "")
            }')"
        # Members the caller names keep their path under the package folder.
        for member in "$@"; do
            wanted="$wanted $top/$member"
            copies="$copies $top/$member>$member"
        done
        [ -n "$wanted" ] || fail "$file has no licence file at its top level (COPYING, LICENSE, COPYRIGHT or NOTICE)." \
            "Find where this package keeps its licence and name it in collect_licenses."
        mkdir -p "$scratch/$name"
        # shellcheck disable=SC2086
        tar -xf "$tarball" -C "$scratch/$name" $wanted || fail "Could not extract the licence files from $file."
        mkdir -p "$dest/$package"
        local files="" pair src out
        for pair in $copies; do
            src="$scratch/$name/${pair%%>*}"; out="${pair#*>}"
            [ -f "$src" ] && [ ! -L "$src" ] || fail "$file: ${pair%%>*} is not a regular file."
            mkdir -p "$(dirname "$dest/$package/$out")"
            cp "$src" "$dest/$package/$out"
            files="$files${files:+, }$out"
        done
        record "$package" "$version" "$files"
    }

    # Licence files from a git clone or an unpacked subproject tree.
    from_tree() {
        local package="$1" version="$2" dir="$3"; shift 3
        local f files=""
        [ -d "$dir" ] || fail "$package's source is not at $dir." "Run without --licenses-only first, so UTM's build fetches it."
        mkdir -p "$dest/$package"
        for f in "$@"; do
            [ -f "$dir/$f" ] || fail "$package has no $f in $dir." "Find where it keeps its licence now and name it in collect_licenses."
            cp "$dir/$f" "$dest/$package/$(basename "$f")"
            files="$files${files:+, }$(basename "$f")"
        done
        record "$package" "$version" "$files"
    }
    clone_version() { git -C "$1" rev-parse --short=12 HEAD 2>/dev/null || echo "git"; }

    # UTM's tarballs, each against Tools/sysroot-sources.sha256. pkg-config
    # is a build tool: nothing from it ships. gettext's runtime libraries
    # (libintl, libasprintf) keep their own LGPL text below the GPL at the
    # top; the ROMs the build phase stages are iPXE's and SeaBIOS's.
    for tarball in "$build"/*.tar.*; do
        file="$(basename "$tarball")"
        case "$file" in pkg-config-*) continue ;; esac
        pin="$( (grep "  $file\$" "$pins" || true) | cut -d' ' -f1)"
        [ -n "$pin" ] || fail "$file has no pinned checksum in Tools/sysroot-sources.sha256." "Add it; UTM's build would have refused the file too."
        case "$file" in
            gettext-*) from_tarball "$tarball" "$pin" gettext-runtime/intl/COPYING.LIB gettext-runtime/libasprintf/COPYING.LIB ;;
            qemu-*)    from_tarball "$tarball" "$pin" pc-bios/README roms/ipxe/COPYING roms/ipxe/COPYING.GPLv2 roms/ipxe/COPYING.UBDL roms/seabios/COPYING roms/seabios/COPYING.LESSER
                       qemu_name="${file%.tar.*}" ;;
            *)         from_tarball "$tarball" "$pin" ;;
        esac
    done
    [ -n "$qemu_name" ] || fail "There is no QEMU tarball in $build."

    # The tarballs this script downloads itself, against the pins at the top.
    from_tarball "$tools/$(basename "$XORRISO_URL")" "$XORRISO_SHA256"
    from_tarball "$tools/$(basename "$WIMLIB_URL")" "$WIMLIB_SHA256"
    from_tarball "$tools/$(basename "$MTOOLS_URL")" "$MTOOLS_SHA256"
    from_tarball "$tools/$(basename "$LIBTASN1_URL")" "$LIBTASN1_SHA256"

    # The git clones, and the subprojects compiled into GLib (PCRE2) and
    # QEMU (libfdt from dtc, Berkeley SoftFloat).
    from_tree ANGLE "$(clone_version "$build/WebKit.git")" "$build/WebKit.git/Source/ThirdParty/ANGLE" LICENSE
    from_tree libepoxy "$(clone_version "$build/libepoxy.git")" "$build/libepoxy.git" COPYING
    from_tree virglrenderer "$(clone_version "$build/virglrenderer.git")" "$build/virglrenderer.git" COPYING
    from_tree libucontext "$(clone_version "$build/libucontext.git")" "$build/libucontext.git" LICENSE
    pcre2="$( (find "$build"/glib-*/subprojects -maxdepth 1 -type d -name 'pcre2-*' 2>/dev/null || true) | sed -n 1p)"
    [ -n "$pcre2" ] || fail "GLib's PCRE2 subproject was not found under $build." "Run without --licenses-only first, so GLib's build unpacks it."
    from_tree pcre2 "${pcre2##*/pcre2-}" "$pcre2" LICENCE
    from_tree dtc "QEMU's" "$build/$qemu_name/subprojects/dtc" BSD-2-Clause GPL README.license
    from_tree berkeley-softfloat-3 "QEMU's" "$build/$qemu_name/subprojects/berkeley-softfloat-3" COPYING.txt

    # UTM's QEMU patch, from the pinned commit, beside QEMU's licences.
    [ -d "$utm/.git" ] || fail "UTM's checkout is not at $utm." "Run without --licenses-only first, so it is fetched."
    git -C "$utm" show "$UTM_COMMIT:patches/$qemu_name.patch" > "$dest/qemu/$qemu_name.patch" || \
        fail "UTM commit ${UTM_COMMIT:0:7} has no patches/$qemu_name.patch."
    {
        echo
        echo "qemu/$qemu_name.patch is UTM's patch to QEMU, from UTM commit $UTM_COMMIT."
        echo "AVM's own patches follow it; they are Tools/sysroot-patches in AVM's repository."
    } >> "$dest/INDEX.txt"

    rm -rf "$scratch"
    info "Licence texts for $count packages in $dest (INDEX.txt lists them)"
}

if [ "$LICENSES_ONLY" = "1" ]; then
    [ -f "$MARKER" ] || fail "There is no sysroot made by this script at $OUT." "Pass --out with the sysroot to add the licence texts to."
    collect_licenses
    trap - EXIT
    echo
    echo "== Done. Licence texts:"
    echo "   $OUT/share/licenses"
    exit 0
fi

FREE_GB=$(( $(df -k "$PARENT" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
[ "$FREE_GB" -ge 25 ] || fail "Only $FREE_GB GB free on the disk holding $PARENT; the build needs about 20 GB." \
    "Free some space, or pass --out on another disk."
info "Sysroot: $OUT"
info "Free space: $FREE_GB GB, $JOBS jobs"

# MARK: - 2. Host tools

step "Getting the build tools"

missing=""
for pkg in $BREW_PACKAGES; do
    brew list --formula "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
    info "Installing from Homebrew:$missing"
    # shellcheck disable=SC2086
    brew install $missing >"$PARENT/brew.log" 2>&1 || fail "brew install failed." "See $PARENT/brew.log"
fi
info "Homebrew packages present: $BREW_PACKAGES"

VENV="$PARENT/host-venv"
if [ ! -x "$VENV/bin/python3" ]; then
    "$(brew --prefix python@3.12)/bin/python3.12" -m venv "$VENV" || fail "Could not make the Python virtual environment."
fi
# shellcheck disable=SC2086
"$VENV/bin/pip" install --quiet --upgrade $PIP_PACKAGES >"$PARENT/pip.log" 2>&1 || \
    fail "pip could not install the Python build tools." "See $PARENT/pip.log"
info "Python $("$VENV/bin/python3" -c 'import sys; print(sys.version.split()[0])'), meson $("$VENV/bin/meson" --version)"

# bison and gettext are keg-only; UTM needs bison 2.4 or later ahead of
# the system's 2.3.
BUILD_PATH="$VENV/bin:$(brew --prefix bison)/bin:$(brew --prefix gettext)/bin:$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# MARK: - 3. UTM build

if [ "$SKIP_UTM" = "0" ]; then
    step "Getting UTM ${UTM_COMMIT:0:7}"

    UTM_DIR="$PARENT/UTM"
    if [ ! -d "$UTM_DIR/.git" ]; then
        git init -q "$UTM_DIR"
        git -C "$UTM_DIR" remote add origin "$UTM_REPO"
    fi
    if [ "$(git -C "$UTM_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$UTM_COMMIT" ]; then
        git -C "$UTM_DIR" fetch -q --depth 1 origin "$UTM_COMMIT" || fail "Could not fetch UTM commit $UTM_COMMIT."
        git -C "$UTM_DIR" checkout -q --detach FETCH_HEAD
    fi
    # Back to the pinned tree before changing it, so a second run starts
    # from the same place as the first.
    git -C "$UTM_DIR" reset -q --hard "$UTM_COMMIT"
    git -C "$UTM_DIR" clean -q -fdx
    info "UTM at $(git -C "$UTM_DIR" log -1 --format='%h, %cd' --date=short)"

    step "Adapting UTM's build for AVM"

    # Exact text replacements: if UTM's script ever stops matching, this
    # stops with the line that is missing instead of building something
    # different from what it says.
    python3 - "$UTM_DIR" "$REPO_ROOT/Tools/sysroot-patches" <<'PY'
import pathlib, sys
utm, patches = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
script = utm / "scripts/build_dependencies.sh"
s = script.read_text()

def drop(text, why):
    global s
    if text not in s:
        sys.exit(f"UTM's build_dependencies.sh no longer contains the {why} text this script removes:\n{text}")
    s = s.replace(text, "", 1)

# Host checks only the GPU stack needs.
for tool in ("llvm", "spirv-llvm-translator", "libxcb", "libxrandr"):
    line = next((l for l in s.splitlines(True) if f"brew --prefix {tool} " in l), None)
    if line is None:
        sys.exit(f"UTM's check_env no longer checks for {tool}.")
    drop(line, f"{tool} check")
for check in ("python_module_test mako ", "command -v cmake "):
    line = next((l for l in s.splitlines(True) if check in l), None)
    if line is None:
        sys.exit(f"UTM's check_env no longer has: {check}")
    drop(line, check.strip())

# GPU sources, except the OpenGL ones (WebKit for ANGLE, libepoxy,
# virglrenderer), which Linux 3D acceleration uses.
for line in [
    "clone $VULKAN_LOADER_REPO $VULKAN_LOADER_COMMIT\n",
    "clone $HYPERVISOR_REPO $HYPERVISOR_COMMIT\n",
    "clone $MESA_REPO $MESA_COMMIT\n",
    "clone $MOLTENVK_REPO $MOLTENVK_COMMIT\n",
    "clone_moltenvk_dependences $MOLTENVK_REPO\n",
    "download $LLVM15_SRC\n",
    "clone $DXMT_REPO $DXMT_COMMIT\n",
    "clone $D3DMETAL_REPO $D3DMETAL_COMMIT\n",
]:
    drop("    " + line, "GPU download")

# GPU builds inside build_qemu_dependencies, up to the iOS-only hypervisor:
# only ANGLE, libepoxy and virglrenderer, without Vulkan or Direct3D
# (2026-10-27). QEMU's configure finds them and turns on OpenGL and VirGL.
start = s.find("    # GPU support\n")
end = s.find("    # Hypervisor for iOS\n")
if start < 0 or end < start:
    sys.exit("UTM's build_qemu_dependencies no longer has its GPU support block.")
block = s[start:end]
for needed in ("    build_angle\n", "meson_build $EPOXY_REPO", "meson_darwin_build $VIRGLRENDERER_REPO"):
    if needed not in block:
        sys.exit(f"UTM's GPU support block no longer has: {needed.strip()}")
s = s[:start] + """    # GPU support: OpenGL only (AVM)
    # AVM's patches for git clones, which UTM's build doesn't patch:
    # ANGLE and libepoxy open ANGLE's libraries beside themselves
    # (Tools/sysroot-patches/clones).
    git -C "$BUILD_DIR/WebKit.git" checkout -q -- Source/ThirdParty/ANGLE/src
    for p in "$AVM_CLONE_PATCHES"/WebKit+*.patch; do patch -d "$BUILD_DIR/WebKit.git" -p1 < "$p"; done
    build_angle
    git -C "$BUILD_DIR/libepoxy.git" checkout -q -- .
    for p in "$AVM_CLONE_PATCHES"/libepoxy+*.patch; do patch -d "$BUILD_DIR/libepoxy.git" -p1 < "$p"; done
    meson_build $EPOXY_REPO -Dtests=false -Dglx=no -Degl=yes
    meson_darwin_build $VIRGLRENDERER_REPO -Dtests=false -Dcheck-gl-errors=false -Dvenus=false -Dneptune=false
""" + s[end:]

# The GPU driver stages in the main sequence.
drop("build_vulkan_drivers\nbuild_d3d_drivers\n", "GPU driver stages")

# Every downloaded tarball checked against Tools/sysroot-sources.sha256
# before it is unpacked (2026-10-25, code audit). UTM's download() checks
# nothing and reuses whatever is cached, so pinning UTM's commit didn't pin
# what it fetched. A file with no pin, or a different hash, stops the
# build; a mismatched file is deleted so the next run fetches it fresh.
anchor = '        mv "$FILE" "$TARGET"\n    fi\n'
if s.count(anchor) != 1:
    sys.exit("UTM's download() no longer has the step this script checks after.")
s = s.replace(anchor, anchor + """    AVM_PIN="$(grep "  $FILE\\$" "$AVM_SOURCES_SHA256" | cut -d' ' -f1)"
    if [ -z "$AVM_PIN" ]; then
        echo "AVM: $FILE has no pinned checksum in sysroot-sources.sha256" >&2
        exit 1
    fi
    if [ "$(shasum -a 256 "$TARGET" | cut -d' ' -f1)" != "$AVM_PIN" ]; then
        echo "AVM: $FILE does not match its pinned checksum; deleted it" >&2
        rm -f "$TARGET"
        exit 1
    fi
""", 1)

script.write_text(s)

# AVM's patches go after UTM's own patch for the same package, so they
# apply to the tree UTM's patch leaves. Each is named
# <UTM patch name>+<what it does>.patch.
for p in sorted(patches.glob("*.patch")):
    package = p.name.split("+")[0]
    target = utm / "patches" / f"{package}.patch"
    if not target.exists():
        sys.exit(f"{p.name} is for {package}, but UTM has no patches/{package}.patch to add it to.")
    with target.open("a") as f:
        f.write("\n" + p.read_text())
    print(f"   Added {p.name} after UTM's patches/{target.name}")
PY
    info "GPU stack: OpenGL only (ANGLE, epoxy, virglrenderer); Vulkan, Mesa, MoltenVK, LLVM and D3D left out"

    step "Building UTM's dependencies (most of an hour)"

    mkdir -p "$OUT"
    touch "$MARKER"
    UTM_LOG="$PARENT/utm-build.log"
    info "Full log: $UTM_LOG"
    # UTM's script works relative to the current folder: it builds in
    # build-macOS-arm64 and installs into sysroot-macOS-arm64, which is OUT.
    # Progress shows one line per package; the colors UTM prints are removed.
    set +e
    (
        cd "$PARENT"
        env PATH="$BUILD_PATH" NCPU="$JOBS" AVM_SOURCES_SHA256="$REPO_ROOT/Tools/sysroot-sources.sha256" \
            AVM_CLONE_PATCHES="$REPO_ROOT/Tools/sysroot-patches/clones" \
            "$UTM_DIR/scripts/build_dependencies.sh" -p macos -a arm64
    ) 2>&1 | tee "$UTM_LOG" \
        | sed -u -E 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g' \
        | grep --line-buffered -E '^Building [^ ]+\.\.\.$|^All done' \
        | awk '!seen[$0]++ { print "   " $0; fflush() }'
    utm_rc=${PIPESTATUS[0]}
    set -e
    if [ "$utm_rc" != "0" ]; then
        echo "   Last lines of the log:"
        sed -E 's/\x1b\[[0-9;]*m//g' "$UTM_LOG" | grep -v '^\s*$' | tail -25 | sed 's/^/   /'
        fail "UTM's dependency build stopped (exit $utm_rc)." "Read $UTM_LOG; the error is usually near the end."
    fi
    touch "$MARKER"
    printf '%s\n' "$FINGERPRINT" > "$OUT/.avm-sysroot-patches"
else
    step "Skipping the UTM build (--tools-only)"
    [ -x "$OUT/host/bin/pkg-config" ] || fail "There is no earlier UTM build in $OUT to add the tools to." "Run without --tools-only first."
    # The re-check the usage text promises (seventh audit): a sysroot built
    # from other patches, or one from before the fingerprint, was called
    # ready and then refused by Tools/build-installer.sh.
    if [ ! -f "$OUT/.avm-sysroot-patches" ]; then
        fail "$OUT has no record of the patches it was built from." "Run Tools/build-sysroot.sh (most of an hour), or Tools/build-sysroot.sh --mark-built if its QEMU was rebuilt by hand from exactly this checkout's patches."
    elif [ "$(cat "$OUT/.avm-sysroot-patches")" != "$FINGERPRINT" ]; then
        fail "$OUT was built from other QEMU or GStreamer patches than this checkout's." "Run Tools/build-sysroot.sh (most of an hour), or Tools/build-sysroot.sh --mark-built if its QEMU was rebuilt by hand from exactly these patches."
    fi
    info "Built from this checkout's patches"
fi

# MARK: - 4. Install tools

step "Building xorriso, wimlib and mtools"

TOOLS_DIR="$PARENT/build-avm-tools"
mkdir -p "$TOOLS_DIR/empty-pkgconfig"

# Sets FETCHED to the verified tarball's path. Not called in $(...), so
# a failure here stops the script with its message.
fetch() {
    local url="$1" sha="$2" file
    file="$TOOLS_DIR/$(basename "$url")"
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        curl -fsSL "$url" -o "$file.part" || fail "Could not download $url."
        mv "$file.part" "$file"
    fi
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ] || \
        fail "$(basename "$file") does not match its pinned checksum." "Delete $file and run again; if it still fails, the file on the server changed."
    FETCHED="$file"
}

# Clean environment: no Homebrew on the path and an empty pkg-config
# search path, so nothing outside macOS can be linked in. wimlib's
# configure insists on running pkg-config even with every option off,
# so it gets the sysroot's own.
build_tool() {
    local name="$1" tarball="$2" dir log; shift 2
    log="$TOOLS_DIR/$name.log"
    rm -rf "$TOOLS_DIR/src-$name"
    mkdir -p "$TOOLS_DIR/src-$name"
    tar -xzf "$tarball" -C "$TOOLS_DIR/src-$name"
    dir="$(find "$TOOLS_DIR/src-$name" -mindepth 1 -maxdepth 1 -type d | sed -n 1p)"
    if ! (
        cd "$dir"
        env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
            CC=clang \
            CFLAGS="-arch arm64 -mmacosx-version-min=12.0 -O2" \
            LDFLAGS="-arch arm64 -mmacosx-version-min=12.0" \
            PKG_CONFIG="$OUT/host/bin/pkg-config" \
            PKG_CONFIG_LIBDIR="$TOOLS_DIR/empty-pkgconfig" \
            PKG_CONFIG_PATH= \
            sh -c "./configure --prefix='$OUT' $* && make -j$JOBS && make install"
    ) >"$log" 2>&1; then
        tail -15 "$log" | sed 's/^/   /'
        fail "$name did not build." "See $log"
    fi
    info "Built $name"
}

fetch "$XORRISO_URL" "$XORRISO_SHA256"
build_tool xorriso "$FETCHED" \
    --disable-libreadline --disable-libedit --disable-libacl --disable-zlib \
    --disable-libbz2 --disable-jtethreads --disable-launch-frontend --disable-external-filters
fetch "$WIMLIB_URL" "$WIMLIB_SHA256"
build_tool wimlib "$FETCHED" --without-ntfs-3g --without-fuse --disable-static
fetch "$MTOOLS_URL" "$MTOOLS_SHA256"
build_tool mtools "$FETCHED" --disable-floppyd

# MARK: - 4b. swtpm as a program

# AVM runs swtpm as its own process for the TPM. UTM now builds swtpm only
# as a library it loads in-process (--enable-shared-lib), so the sysroot
# has no swtpm program; this builds the ordinary swtpm, from the same
# source UTM downloaded, against the sysroot's libtpms, OpenSSL and glib.
# Its configure insists on libtasn1 and, for its tests only, on expect,
# gawk and socat; the tests never run here, so those three are pointed at
# stand-ins. It runs pkg-config by name, so the sysroot's comes first on
# the path.
step "Building swtpm as a program"

SWTPM_TARBALL="$PARENT/build-macOS-arm64/swtpm-0.8.99.tar.gz"
[ -f "$SWTPM_TARBALL" ] || fail "UTM's swtpm source is not at $SWTPM_TARBALL." "Run without --tools-only so UTM downloads it."
DEPS="$TOOLS_DIR/deps"
SWTPM_LOG="$TOOLS_DIR/swtpm.log"

fetch "$LIBTASN1_URL" "$LIBTASN1_SHA256"
rm -rf "$DEPS"
build_tool_into() {
    # Like build_tool, but into a prefix other than the sysroot.
    local prefix="$1" name="$2" tarball="$3" dir log; shift 3
    log="$TOOLS_DIR/$name.log"
    rm -rf "$TOOLS_DIR/src-$name"
    mkdir -p "$TOOLS_DIR/src-$name"
    tar -xzf "$tarball" -C "$TOOLS_DIR/src-$name"
    dir="$(find "$TOOLS_DIR/src-$name" -mindepth 1 -maxdepth 1 -type d | sed -n 1p)"
    if ! (
        cd "$dir"
        env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CC=clang \
            CFLAGS="-arch arm64 -mmacosx-version-min=12.0 -O2" \
            LDFLAGS="-arch arm64 -mmacosx-version-min=12.0" \
            sh -c "./configure --prefix='$prefix' $* && make -j$JOBS && make install"
    ) >"$log" 2>&1; then
        tail -15 "$log" | sed 's/^/   /'
        fail "$name did not build." "See $log"
    fi
}
build_tool_into "$DEPS" libtasn1 "$FETCHED" --disable-shared --disable-doc
info "Built libtasn1 (private, for swtpm's configure only)"

rm -rf "$TOOLS_DIR/src-swtpm"
mkdir -p "$TOOLS_DIR/src-swtpm"
tar -xzf "$SWTPM_TARBALL" -C "$TOOLS_DIR/src-swtpm"
SWTPM_SRC="$(find "$TOOLS_DIR/src-swtpm" -mindepth 1 -maxdepth 1 -type d | sed -n 1p)"
if ! (
    cd "$SWTPM_SRC"
    env -i HOME="$HOME" PATH="$OUT/host/bin:/usr/bin:/bin:/usr/sbin:/sbin" CC=clang \
        CFLAGS="-arch arm64 -mmacosx-version-min=12.0 -O2 -I$OUT/include" \
        LDFLAGS="-arch arm64 -mmacosx-version-min=12.0 -L$OUT/lib" \
        PKG_CONFIG="$OUT/host/bin/pkg-config" \
        PKG_CONFIG_LIBDIR="$OUT/lib/pkgconfig:$DEPS/lib/pkgconfig" \
        PKG_CONFIG_PATH= \
        GAWK=/usr/bin/awk SOCAT=/usr/bin/false \
        sh -c "./configure --prefix='$OUT' --without-gnutls --without-seccomp --without-cuse --without-selinux \
               && make -j$JOBS -C src/utils && make -j$JOBS -C src/swtpm && make -C src/swtpm install"
) >"$SWTPM_LOG" 2>&1; then
    tail -20 "$SWTPM_LOG" | sed 's/^/   /'
    fail "swtpm did not build." "See $SWTPM_LOG"
fi

# swtpm installs its library in lib/swtpm; the build phase copies and
# signs lib/libswtpm_libtpms.0.dylib, so it moves up one folder and the
# two references to it follow.
if [ -f "$OUT/lib/swtpm/libswtpm_libtpms.0.dylib" ]; then
    mv -f "$OUT/lib/swtpm/libswtpm_libtpms.0.dylib" "$OUT/lib/libswtpm_libtpms.0.dylib"
    rm -rf "$OUT/lib/swtpm"
    install_name_tool -id "$OUT/lib/libswtpm_libtpms.0.dylib" "$OUT/lib/libswtpm_libtpms.0.dylib" 2>/dev/null
    install_name_tool -change "$OUT/lib/swtpm/libswtpm_libtpms.0.dylib" "$OUT/lib/libswtpm_libtpms.0.dylib" "$OUT/bin/swtpm" 2>/dev/null
fi
info "Built swtpm $("$OUT/bin/swtpm" --version 2>/dev/null | sed -n 1p | sed -E 's/.*version ([^ ,]+).*/\1/')"

# MARK: - 4c. Licence texts

collect_licenses

# MARK: - 5. Check against AVM

step "Checking the sysroot against what AVM uses"

problems=0
problem() { echo "   MISSING OR WRONG: $1"; problems=$((problems + 1)); }

# What the build phase stages.
for f in bin/qemu-system-aarch64 bin/qemu-img bin/swtpm lib/libswtpm_libtpms.0.dylib bin/xorriso bin/wimlib-imagex bin/mtools \
         bin/mformat bin/mcopy bin/mdir lib/libwim.15.dylib \
         share/qemu/edk2-aarch64-code.fd share/qemu/edk2-arm-vars.fd share/qemu/vgabios-ramfb.bin share/qemu/efi-virtio.rom \
         include/libusb-1.0/libusb.h lib/libusb-1.0.0.dylib lib/libusbredirhost.1.dylib lib/libusbredirparser.1.dylib \
         share/licenses/INDEX.txt; do
    [ -e "$OUT/$f" ] || problem "$f"
done

# What the Xcode project links: every -framework, -l and $(AVM_SYSROOT)
# path in its OTHER_LDFLAGS.
# Read first, then checked: as a process substitution its failure was
# invisible, and the "every library is present" line printed anyway.
LINKED="$(python3 - "$REPO_ROOT/AVM.xcodeproj/project.pbxproj" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
seen = set()
for block in re.findall(r"OTHER_LDFLAGS = \((.*?)\);", text, re.S):
    tokens = [t.strip().strip('"') for t in block.split(",") if t.strip()]
    for i, t in enumerate(tokens):
        if t == "-framework" and i + 1 < len(tokens):
            need = f"Frameworks/{tokens[i + 1]}.framework"
        elif t.startswith("-l"):
            need = f"lib/lib{t[2:]}.dylib"
        elif t.startswith("$(AVM_SYSROOT)/"):
            need = t[len("$(AVM_SYSROOT)/"):]
        else:
            continue
        if need not in seen:
            seen.add(need)
            print(need)
PY
)" || fail "Could not read the libraries the Xcode project links."
[ -n "$LINKED" ] || fail "Found no linked libraries in the Xcode project; its format may have changed."
while IFS= read -r need; do
    [ -e "$OUT/$need" ] || problem "$need (linked by AVM.xcodeproj)"
done <<< "$LINKED"

# xorriso new enough for Windows' boot loader.
XV="$("$OUT/bin/xorriso" -version 2>/dev/null | sed -nE 's/^(GNU )?xorriso ([0-9]+\.[0-9]+\.[0-9]+(\.pl[0-9]+)?).*/\2/p' | sed -n 1p)"
[ "$XV" = "1.5.8.pl02" ] || problem "xorriso version (got ${XV:-nothing}, expected 1.5.8.pl02)"

# The deadlock fix made it into the osxaudio plugin AVM links: the
# render-notify path is gone and the silence path is there.
OSX_A="$OUT/lib/gstreamer-1.0/libgstosxaudio.a"
if [ -f "$OSX_A" ]; then
    SYMS="$(nm "$OSX_A" 2>/dev/null)"
    case "$SYMS" in *gst_core_audio_render_notify*) problem "osxaudio deadlock fix (render notify still present)" ;; esac
    case "$SYMS" in *gst_audio_format_info_fill_silence*) ;; *) problem "osxaudio deadlock fix (silence path absent)" ;; esac
fi

# Nothing may point into Homebrew: it isn't on testers' Macs.
brew_refs=0
while IFS= read -r f; do
    case "$(file -b "$f")" in *Mach-O*) ;; *) continue ;; esac
    # Captured first: grep -q in a pipe under pipefail could make a match
    # read as clean.
    links="$(otool -L "$f" 2>/dev/null | tail -n +2)"
    if [[ "$links" == *"$(brew --prefix)"* ]]; then
        echo "   Links Homebrew: ${f#"$OUT"/}"
        brew_refs=$((brew_refs + 1))
    fi
done < <(find "$OUT/bin" "$OUT/lib" "$OUT/Frameworks" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
[ "$brew_refs" = "0" ] || problem "$brew_refs binaries link Homebrew libraries"
# The list read whole first (2026-10-28, fourth audit): grep -q stops at
# its first match, and under pipefail QEMU dying of SIGPIPE read as a
# missing device.
devices=$("$OUT/bin/qemu-system-aarch64" -device help 2>/dev/null || true)
grep -q '"usb-camera"' <<<"$devices" \
    || problem "QEMU has no usb-camera device (Tools/sysroot-patches/qemu-10.0.12-utm+usb-camera.patch)"
grep -q '"usb-hid-bridge"' <<<"$devices" \
    || problem "QEMU has no usb-hid-bridge device (Tools/sysroot-patches/qemu-10.0.12-utm+usb-hid-bridge.patch)"
grep -q '"virtio-gpu-gl-pci"' <<<"$devices" \
    || problem "QEMU has no virtio-gpu-gl-pci: it was built without OpenGL or virglrenderer"
for lib in libEGL.dylib libGLESv2.dylib libepoxy.0.dylib libvirglrenderer.1.dylib; do
    [ -f "$OUT/lib/$lib" ] || problem "$lib is missing: Linux 3D acceleration needs it"
done

[ "$problems" = "0" ] || fail "$problems problems with the sysroot (listed above)."
info "Every framework and library AVM links is present."
info "QEMU $("$OUT/bin/qemu-system-aarch64" --version 2>/dev/null | sed -n 1p | sed -E 's/.*version ([^ ]+).*/\1/'), xorriso $XV, osxaudio deadlock fix in place, no Homebrew links."

# MARK: - Done

trap - EXIT
echo
echo "== Done. Sysroot:"
echo "   $OUT"
if [ "$OUT" != "$HOME/Developer/sysroot-macos-arm64/sysroot-macOS-arm64" ]; then
    echo "   Build AVM with: Tools/build-installer.sh --sysroot \"$OUT\""
else
    echo "   This is AVM's default AVM_SYSROOT, so Xcode and Tools/build-installer.sh find it as is."
fi
speak "AVM sysroot is ready."
