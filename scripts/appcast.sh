#!/usr/bin/env bash
# Writes a single-item Sparkle appcast for one release to stdout.
#   scripts/appcast.sh <version> <zip-path> '<sparkle:edSignature="…" length="…">'
# The third argument is sign_update's output for the zip. The feed is served from the latest
# GitHub Release (releases/latest/download/appcast.xml), so it only ever needs the newest item.
set -euo pipefail
VERSION="$1"; ZIP="$2"; SIGNATURE_ATTRS="$3"
REPO="${REPO:-KudcraftsHQ/ntfy-bar}"
case "$SIGNATURE_ATTRS" in
  *'sparkle:edSignature="'*'length="'*) ;;
  *) echo "appcast.sh: unexpected signature attributes: $SIGNATURE_ATTRS" >&2; exit 1 ;;
esac
NAME="$(basename "$ZIP")"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ntfy-bar</title>
    <link>https://github.com/${REPO}</link>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/${REPO}/releases/tag/v${VERSION}</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/${REPO}/releases/download/v${VERSION}/${NAME}" type="application/octet-stream" ${SIGNATURE_ATTRS} />
    </item>
  </channel>
</rss>
XML
