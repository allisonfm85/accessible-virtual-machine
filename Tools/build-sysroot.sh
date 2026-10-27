#!/bin/bash
# build-sysroot.sh
# AVM — Accessible Virtual Machine
#
# Builds, from source, the sysroot AVM's build phase stages QEMU, SPICE,
# GStreamer and the install tools from (the AVM_SYSROOT build setting).
#
#   Tools/build-sysroot.sh            build into the default AVM_SYSROOT
#   Tools/build-sysroot.sh --help     every option
#
# WHAT IT BUILDS
#   1. UTM's macOS arm64 dependency build (scripts/build_dependencies.sh),
#      at the pinned UTM commit below, with two changes:
#        - The GPU stack is left out: ANGLE, libepoxy, the Vulkan loader,
#          virglrenderer, Mesa, MoltenVK, LLVM and the D3D drivers. AVM
#          gives the guest plain virtio-gpu-pci with no OpenGL, and links
#          none of these libraries, so they would only cost hours.
#        - AVM's patches in Tools/sysroot-patches are applied after UTM's
#          own patch for the same package: the GStreamer osxaudio
#          deadlock fix, a QEMU build fix so UTM's Metal display code
#          is compiled only when OpenGL is, QEMU's coreaudio playback and
#          microphone, and usb-camera (the Mac's camera as a USB webcam).
#          Each patch's header says what it does and where it comes from.
#   2. The install-pipeline tools UTM doesn't build: xorriso 1.5.8.pl02
#      (the README's minimum), wimlib-imagex and mtools. They link only
#      macOS's own libraries, as the build phase expects.
#   3. A check of the result against what AVM actually uses: every
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
  --no-speech     Don't speak the result at the end.
  -h, --help      This help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)        OUT="$2"; shift 2 ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        --tools-only) SKIP_UTM=1; shift ;;
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

# GPU sources.
for line in [
    'clone $WEBKIT_REPO $WEBKIT_COMMIT "$WEBKIT_SUBDIRS"\n',
    "clone $EPOXY_REPO $EPOXY_COMMIT\n",
    "clone $VULKAN_LOADER_REPO $VULKAN_LOADER_COMMIT\n",
    "clone $VIRGLRENDERER_REPO $VIRGLRENDERER_COMMIT\n",
    "clone $HYPERVISOR_REPO $HYPERVISOR_COMMIT\n",
    "clone $MESA_REPO $MESA_COMMIT\n",
    "clone $MOLTENVK_REPO $MOLTENVK_COMMIT\n",
    "clone_moltenvk_dependences $MOLTENVK_REPO\n",
    "download $LLVM15_SRC\n",
    "clone $DXMT_REPO $DXMT_COMMIT\n",
    "clone $D3DMETAL_REPO $D3DMETAL_COMMIT\n",
]:
    drop("    " + line, "GPU download")

# GPU builds inside build_qemu_dependencies, up to the iOS-only hypervisor.
start = s.find("    # GPU support\n")
end = s.find("    # Hypervisor for iOS\n")
if start < 0 or end < start:
    sys.exit("UTM's build_qemu_dependencies no longer has its GPU support block.")
s = s[:start] + s[end:]

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
    info "GPU stack left out (ANGLE, epoxy, Vulkan, virglrenderer, Mesa, MoltenVK, LLVM, D3D)"

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
else
    step "Skipping the UTM build (--tools-only)"
    [ -x "$OUT/host/bin/pkg-config" ] || fail "There is no earlier UTM build in $OUT to add the tools to." "Run without --tools-only first."
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

# MARK: - 5. Check against AVM

step "Checking the sysroot against what AVM uses"

problems=0
problem() { echo "   MISSING OR WRONG: $1"; problems=$((problems + 1)); }

# What the build phase stages.
for f in bin/qemu-system-aarch64 bin/qemu-img bin/swtpm lib/libswtpm_libtpms.0.dylib bin/xorriso bin/wimlib-imagex bin/mtools \
         bin/mformat bin/mcopy bin/mdir lib/libwim.15.dylib \
         share/qemu/edk2-aarch64-code.fd share/qemu/edk2-arm-vars.fd share/qemu/vgabios-ramfb.bin share/qemu/efi-virtio.rom \
         include/libusb-1.0/libusb.h lib/libusb-1.0.0.dylib lib/libusbredirhost.1.dylib lib/libusbredirparser.1.dylib; do
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
"$OUT/bin/qemu-system-aarch64" -device help 2>/dev/null | grep -q '"usb-camera"' \
    || problem "QEMU has no usb-camera device (Tools/sysroot-patches/qemu-10.0.12-utm+usb-camera.patch)"

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
