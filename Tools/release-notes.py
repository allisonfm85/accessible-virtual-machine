#!/usr/bin/env python3
# release-notes.py
# AVM — Accessible Virtual Machine
#
# One version's release notes, as written for AVM's What's New window
# (ReleaseNotes.all in app/AVMUpdater.swift), for the places a release
# shows them too (2026-10-30): the GitHub release page (markdown) and
# Sparkle's update dialog (HTML, the feed item's description). One text,
# written once, in plain words for VoiceOver.
#
#   Tools/release-notes.py VERSION [--html]
#
# Prints nothing and exits 1 when the version has no notes.

import html
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "app" / "AVMUpdater.swift"


def changes(version):
    text = SOURCE.read_text(encoding="utf-8")
    start = text.find(f'ReleaseNote(version: "{version}", changes: [')
    if start < 0:
        return []
    end = text.find("]),", start)
    body = text[text.index("[", start) + 1:end]
    return [s.replace('\\"', '"').replace("\\\\", "\\") for s in re.findall(r'"((?:[^"\\]|\\.)*)"', body)]


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: release-notes.py VERSION [--html]")
    lines = changes(sys.argv[1])
    if not lines:
        sys.exit(1)
    if "--html" in sys.argv[2:]:
        print("<ul>" + "".join(f"<li>{html.escape(line)}</li>" for line in lines) + "</ul>")
    else:
        print("\n".join(f"- {line}" for line in lines))


if __name__ == "__main__":
    main()
