#!/bin/bash
# publish-release.sh
# AVM — Accessible Virtual Machine
#
# Publishes the release Tools/build-installer.sh made (2026-10-26): a
# GitHub release v<version> in this repository with the DMG and the Sparkle zip,
# then the update feed entry added to appcast.xml, committed and pushed,
# so installed copies of AVM are offered the update. Asks before it
# publishes anything.
#
#   Tools/publish-release.sh            publish build/installer's release
#   Tools/publish-release.sh --draft    make a draft GitHub release instead,
#                                       and leave appcast.xml alone
#
# Needs the GitHub CLI (gh), signed in with access to this repository.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="${AVM_REPO:-allisonfm85/accessible-virtual-machine}"
OUT_DIR="$REPO_ROOT/build/installer"
DRAFT=0
[ "${1:-}" = "--draft" ] && DRAFT=1

fail() {
    echo "FAILED: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    command -v say >/dev/null && say "Publishing failed." || true
    exit 1
}

command -v gh >/dev/null || fail "The GitHub CLI (gh) is not installed." "brew install gh, then gh auth login."
gh auth status >/dev/null 2>&1 || fail "gh is not signed in to GitHub." "Run gh auth login."

ITEM="$OUT_DIR/appcast-item.xml"
[ -f "$ITEM" ] || fail "There is no build to publish in $OUT_DIR." "Run Tools/build-installer.sh first."
VERSION="$(sed -nE 's#.*<sparkle:shortVersionString>(.*)</sparkle:shortVersionString>.*#\1#p' "$ITEM" | sed -n 1p)"
DMG="$OUT_DIR/AVM-$VERSION.dmg"
ZIP="$OUT_DIR/AVM-$VERSION.zip"
[ -f "$DMG" ] && [ -f "$ZIP" ] || fail "AVM-$VERSION.dmg or .zip is missing from $OUT_DIR." "Run Tools/build-installer.sh again."
grep -q "edSignature" "$ITEM" || fail "The update feed entry has no signature." "Run Tools/build-installer.sh again and allow keychain access."
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$REPO_ROOT/appcast.xml"; then
    fail "appcast.xml already lists version $VERSION." "Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION, then build again."
fi
if gh release view "v$VERSION" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    fail "GitHub already has a release v$VERSION." "Raise the version, then build again."
fi

echo "About to publish AVM $VERSION to https://github.com/$REPO_SLUG"
echo "  $(basename "$DMG"), $(du -h "$DMG" | cut -f1)"
echo "  $(basename "$ZIP"), $(du -h "$ZIP" | cut -f1)"
[ "$DRAFT" = "1" ] && echo "  as a DRAFT release; appcast.xml is not changed"
printf "Publish? Type yes to continue: "
read -r answer
[ "$answer" = "yes" ] || { echo "Nothing was published."; exit 0; }

DRAFT_FLAG=()
[ "$DRAFT" = "1" ] && DRAFT_FLAG=(--draft)
gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$REPO_SLUG" \
    --title "AVM $VERSION" --notes "AVM $VERSION. Install from the DMG; existing installs update from inside AVM." \
    "${DRAFT_FLAG[@]}" || fail "gh could not create the release."
echo "Created release v$VERSION."

if [ "$DRAFT" = "1" ]; then
    echo "Draft release made. Publish it on GitHub, then run this script again without --draft to update the feed."
    exit 0
fi

# Newest first: the entry goes right after the feed's comment block.
python3 - "$REPO_ROOT/appcast.xml" "$ITEM" <<'PY'
import sys
feed, item = sys.argv[1], open(sys.argv[2]).read()
text = open(feed).read()
anchor = "<language>en</language>\n"
i = text.find("-->", text.find(anchor))
at = text.find("\n", i) + 1 if i != -1 else text.find(anchor) + len(anchor)
open(feed, "w").write(text[:at] + item + text[at:])
PY
xmllint --noout "$REPO_ROOT/appcast.xml" || fail "appcast.xml is no longer valid XML; nothing was pushed." "Check the file, then commit and push it yourself."
git -C "$REPO_ROOT" add appcast.xml
git -C "$REPO_ROOT" commit -q -m "Appcast: add v$VERSION entry"
git -C "$REPO_ROOT" push -q
echo "Update feed updated and pushed. Installed copies of AVM will be offered $VERSION."
command -v say >/dev/null && say "AVM $VERSION is published." || true
