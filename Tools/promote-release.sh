#!/bin/bash
# promote-release.sh
# AVM — Accessible Virtual Machine
#
# Offers an early release to everyone (2026-11-02): takes its early mark out of
# appcast.xml, and makes it GitHub's latest release, which the website links to.
#
#   Tools/promote-release.sh <version>
#
# On main, level with GitHub, as publish-release.sh is.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="${AVM_REPO:-allisonfm85/accessible-virtual-machine}"
VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "Usage: $0 <version>"; exit 64; }
[ "$(git -C "$REPO_ROOT" branch --show-current)" = main ] || { echo "FAILED: this checkout isn't on main."; exit 1; }
git -C "$REPO_ROOT" fetch -q origin main
[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(git -C "$REPO_ROOT" rev-parse origin/main)" ] || { echo "FAILED: main isn't level with GitHub."; exit 1; }
python3 - "$REPO_ROOT/appcast.xml" "$VERSION" <<'PY'
import re, sys
path, version = sys.argv[1:3]
text = open(path).read()
mark = re.compile(r"[ \t]*<sparkle:channel>early</sparkle:channel>\n([ \t]*)<sparkle:shortVersionString>" + re.escape(version) + "<")
new, count = mark.subn(lambda m: m.group(1) + "<sparkle:shortVersionString>" + version + "<", text)
if count != 1:
    sys.exit(f"FAILED: {version} isn't marked early in appcast.xml.")
open(path, "w").write(new)
PY
xmllint --noout "$REPO_ROOT/appcast.xml"
gh release edit "v$VERSION" --repo "$REPO_SLUG" --prerelease=false --latest >/dev/null
git -C "$REPO_ROOT" commit -q -m "Appcast: v$VERSION for everyone" -- appcast.xml
git -C "$REPO_ROOT" push -q
echo "Installed copies of AVM will be offered $VERSION."
