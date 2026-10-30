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
# The branch whose appcast.xml installed copies read (SUFeedURL in
# AVM/Info.plist). The release is tagged there and the feed entry is
# pushed there; publishing from any other branch would offer nobody the
# update (2026-10-26).
FEED_BRANCH="${AVM_FEED_BRANCH:-main}"
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

BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
[ "$BRANCH" = "$FEED_BRANCH" ] || fail "This checkout is on $BRANCH, but the app reads its updates from $FEED_BRANCH." "Merge the release into $FEED_BRANCH, switch to it (git switch $FEED_BRANCH), and run this again."
git -C "$REPO_ROOT" fetch -q origin "$FEED_BRANCH" || fail "Couldn't reach GitHub to check $FEED_BRANCH."
[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(git -C "$REPO_ROOT" rev-parse "origin/$FEED_BRANCH")" ] || fail "This $FEED_BRANCH isn't the same as GitHub's." "Run git pull (or push), then run this again."

ITEM="$OUT_DIR/appcast-item.xml"
[ -f "$ITEM" ] || fail "There is no build to publish in $OUT_DIR." "Run Tools/build-installer.sh first."
VERSION="$(sed -nE 's#.*<sparkle:shortVersionString>(.*)</sparkle:shortVersionString>.*#\1#p' "$ITEM" | sed -n 1p)"
DMG="$OUT_DIR/AVM-$VERSION.dmg"
ZIP="$OUT_DIR/AVM-$VERSION.zip"
[ -f "$DMG" ] && [ -f "$ZIP" ] || fail "AVM-$VERSION.dmg or .zip is missing from $OUT_DIR." "Run Tools/build-installer.sh again."
grep -q "edSignature" "$ITEM" || fail "The update feed entry has no signature." "Run Tools/build-installer.sh again and allow keychain access."
# Notarized, and built from what's being tagged (2026-10-26, code audit): a
# --skip-notarize build was otherwise publishable, and Gatekeeper then
# blocked it for every new user; and a build made on another branch was
# tagged at main's tip.
xcrun stapler validate "$DMG" >/dev/null 2>&1 || fail "AVM-$VERSION.dmg isn't notarized." "Run Tools/build-installer.sh without --skip-notarize."
BUILT="$(cat "$OUT_DIR/built-commit.txt" 2>/dev/null || true)"
[ -n "$BUILT" ] && [ "$BUILT" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ] || fail "The build in $OUT_DIR wasn't made from this commit of $FEED_BRANCH." "Run Tools/build-installer.sh again here, on $FEED_BRANCH."
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$REPO_ROOT/appcast.xml"; then
    fail "appcast.xml already lists version $VERSION." "Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION, then build again."
fi
# Sparkle compares build numbers (2026-10-28, fourth audit): one not above
# every build already in the feed offers the update to no one.
NEW_BUILD="$(sed -nE 's|.*<sparkle:version>([0-9]+)</sparkle:version>.*|\1|p' "$ITEM" | head -1)"
TOP_BUILD="$(sed -nE 's|.*<sparkle:version>([0-9]+)</sparkle:version>.*|\1|p' "$REPO_ROOT/appcast.xml" | sort -n | tail -1)"
[ -n "$NEW_BUILD" ] || fail "The update feed entry has no build number." "Run Tools/build-installer.sh again."
if [ -n "$TOP_BUILD" ] && [ "$NEW_BUILD" -le "$TOP_BUILD" ]; then
    fail "Build $NEW_BUILD isn't above build $TOP_BUILD, already in appcast.xml, so no installed copy would be offered it." "Raise CURRENT_PROJECT_VERSION, then build again."
fi
# Nothing else staged rides along in the feed's commit (fourth audit).
git -C "$REPO_ROOT" diff --cached --quiet || fail "Something is already staged in git." "Commit or unstage it first (git status)."
# Nor an edit of the feed not yet committed (2026-10-29, sixth audit): the
# commit below takes appcast.xml as it is, and every installed copy reads it.
git -C "$REPO_ROOT" diff --quiet -- appcast.xml || fail "appcast.xml has changes that aren't committed." "Commit or undo them first (git diff appcast.xml)."
# A tag already on GitHub names this build's commit (2026-10-29, sixth
# audit): a tag kept from a deleted release made the new release name an
# older commit than the one its files were built from.
# A failure to reach GitHub is said (2026-10-29, seventh audit): under set -e
# it ended the script with git's own words.
REMOTE_TAG="$(git -C "$REPO_ROOT" ls-remote -q --tags origin "refs/tags/v$VERSION^{}" | cut -f1)" || fail "Couldn't read GitHub's tags." "Check the connection, then run this again."
if [ -z "$REMOTE_TAG" ]; then
    REMOTE_TAG="$(git -C "$REPO_ROOT" ls-remote -q --tags origin "refs/tags/v$VERSION" | cut -f1)" || fail "Couldn't read GitHub's tags." "Check the connection, then run this again."
fi
if [ -n "$REMOTE_TAG" ] && [ "$REMOTE_TAG" != "$BUILT" ]; then
    fail "GitHub's tag v$VERSION names commit ${REMOTE_TAG:0:7}, not ${BUILT:0:7}, which this build was made from." "Delete the old tag (git push origin :refs/tags/v$VERSION) if it's from an abandoned release, or raise the version."
fi
# A release that already exists, with this version not yet in the feed, is
# carried on with rather than refused (2026-10-26, code audit): a run that
# stopped after making the release (a failed push, or the --draft flow)
# could never be finished. Its files are replaced with this build's.
EXISTING=0
if gh release view "v$VERSION" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    EXISTING=1
    echo "GitHub already has a release v$VERSION; this run finishes it: its files are replaced, then the feed is updated."
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
if [ "$EXISTING" = "1" ]; then
    gh release upload "v$VERSION" "$DMG" "$ZIP" --repo "$REPO_SLUG" --clobber || fail "gh could not replace the release's files."
    if [ "$DRAFT" = "0" ]; then
        gh release edit "v$VERSION" --repo "$REPO_SLUG" --draft=false >/dev/null || fail "gh could not publish the draft release."
    fi
    echo "Release v$VERSION updated."
else
    # The built commit itself, not the branch (sixth audit): a push to the
    # branch while this waited for "yes" tagged a newer commit.
    # What's new, as AVM's What's New window says it (2026-10-30,
    # release-notes.md from build-installer.sh), then how to install.
    NOTES="AVM $VERSION. Install from the DMG; existing installs update from inside AVM."
    [ -s "$OUT_DIR/release-notes.md" ] && NOTES="$(cat "$OUT_DIR/release-notes.md")"$'\n\n'"$NOTES"
    gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$REPO_SLUG" --target "$BUILT" \
        --title "AVM $VERSION" --notes "$NOTES" \
        ${DRAFT_FLAG[@]+"${DRAFT_FLAG[@]}"} || fail "gh could not create the release."
    echo "Created release v$VERSION."
fi

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
# After the release is public, a failure says so (2026-10-28, fourth audit):
# set -e ended the script with only git's own error.
git -C "$REPO_ROOT" commit -q -m "Appcast: add v$VERSION entry" -- appcast.xml \
    || fail "The release v$VERSION is public, but the feed entry couldn't be committed." "Commit appcast.xml yourself and push it, so installed copies are offered $VERSION."
git -C "$REPO_ROOT" push -q \
    || fail "The release v$VERSION is public, but the feed couldn't be pushed." "Run git push yourself (pull first if main moved), so installed copies are offered $VERSION."
echo "Update feed updated and pushed. Installed copies of AVM will be offered $VERSION."
command -v say >/dev/null && say "AVM $VERSION is published." || true
