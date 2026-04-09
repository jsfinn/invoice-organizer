#!/usr/bin/env bash
#
# Signs a DMG with Sparkle's EdDSA key and updates (or creates) appcast.xml.
#
# Usage:
#   ./update-appcast.sh <dmg-path> <version> <build-number> <download-url>
#
# Environment:
#   SIGN_UPDATE  - path to Sparkle's sign_update binary (default: auto-detected from .build/)
#   SPARKLE_KEY  - EdDSA private key for CI (if set, piped to sign_update via --ed-key-file -)
#

set -euo pipefail

DMG_PATH="${1:?Usage: update-appcast.sh <dmg-path> <version> <build-number> <download-url>}"
VERSION="${2:?Missing version}"
BUILD_NUMBER="${3:?Missing build number}"
DOWNLOAD_URL="${4:?Missing download URL}"

APPCAST_FILE="appcast.xml"
if [[ -z "${SIGN_UPDATE:-}" ]]; then
  SIGN_UPDATE="$(find .build/artifacts build/SourcePackages/artifacts -name sign_update -type f 2>/dev/null | head -1)"
fi

if [[ -z "${SIGN_UPDATE}" ]]; then
  echo "Could not find sign_update. Set SIGN_UPDATE or run 'swift package resolve' first." >&2
  exit 1
fi

if [[ -n "${SPARKLE_KEY:-}" ]]; then
  SIGN_OUTPUT="$(echo "${SPARKLE_KEY}" | "${SIGN_UPDATE}" --ed-key-file - "${DMG_PATH}")"
else
  SIGN_OUTPUT="$("${SIGN_UPDATE}" "${DMG_PATH}")"
fi

ED_SIGNATURE="$(echo "${SIGN_OUTPUT}" | python3 -c "import re,sys; m=re.search(r'sparkle:edSignature=\"([^\"]+)\"', sys.stdin.read()); print(m.group(1))")"
LENGTH="$(echo "${SIGN_OUTPUT}" | python3 -c "import re,sys; m=re.search(r'length=\"([^\"]+)\"', sys.stdin.read()); print(m.group(1))")"

PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

python3 - "${APPCAST_FILE}" "${VERSION}" "${BUILD_NUMBER}" "${DOWNLOAD_URL}" "${ED_SIGNATURE}" "${LENGTH}" "${PUB_DATE}" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

appcast_path = Path(sys.argv[1])
version = sys.argv[2]
build_number = sys.argv[3]
download_url = sys.argv[4]
ed_signature = sys.argv[5]
length = sys.argv[6]
pub_date = sys.argv[7]

if appcast_path.exists():
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    tree = ET.ElementTree(root)
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Invoice Organizer"

for item in channel.findall("item"):
    item_version = item.find(f"{{{SPARKLE_NS}}}shortVersionString")
    if item_version is not None and item_version.text == version:
        channel.remove(item)
        break

item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build_number
ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, "enclosure", {
    "url": download_url,
    "type": "application/octet-stream",
    f"{{{SPARKLE_NS}}}edSignature": ed_signature,
    "length": length,
})

ET.indent(tree, space="  ")
tree.write(appcast_path, xml_declaration=True, encoding="unicode")
appcast_path.write_text(appcast_path.read_text() + "\n")

print(f"Updated {appcast_path} with v{version} (build {build_number})")
PY
