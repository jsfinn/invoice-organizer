#!/usr/bin/env bash

set -euo pipefail

PROJECT="InvoiceOrganizer.xcodeproj"
PROJECT_SPEC="project.yml"
PROJECT_FILE="InvoiceOrganizer.xcodeproj/project.pbxproj"
SCHEME="InvoiceOrganizer"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build"
APP_NAME="Invoice Organizer"
DMG_VOLUME_NAME="Invoice Organizer"
OUTPUT_BASENAME="InvoiceOrganizer"

DIST_DIR="dist"
STAGING_DIR="dmg-root"

read_marketing_version() {
  python3 - "$PROJECT_SPEC" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
match = re.search(r'(^\s*MARKETING_VERSION:\s*)(\d+\.\d+\.\d+)\s*$', text, re.MULTILINE)
if match is None:
    raise SystemExit("Could not read MARKETING_VERSION from project.yml")

print(match.group(2))
PY
}

bump_revision() {
  python3 - "$1" <<'PY'
import sys

parts = sys.argv[1].split(".")
if len(parts) != 3 or not all(part.isdigit() for part in parts):
    raise SystemExit("MARKETING_VERSION must use m.m.r format")

major, minor, revision = map(int, parts)
print(f"{major}.{minor}.{revision + 1}")
PY
}

persist_marketing_version() {
  python3 - "$1" "$PROJECT_SPEC" "$PROJECT_FILE" <<'PY'
from pathlib import Path
import re
import sys

version = sys.argv[1]
paths = [Path(path) for path in sys.argv[2:]]
patterns = [
    re.compile(r'(^\s*MARKETING_VERSION:\s*)\d+\.\d+\.\d+(\s*)$', re.MULTILINE),
    re.compile(r'(^\s*MARKETING_VERSION = )\d+\.\d+\.\d+(;\s*)$', re.MULTILINE),
]

for path in paths:
    text = path.read_text()
    updated = text
    replacements = 0

    for pattern in patterns:
        updated, count = pattern.subn(rf'\g<1>{version}\g<2>', updated)
        replacements += count

    if replacements == 0:
        raise SystemExit(f"Could not update MARKETING_VERSION in {path}")

    path.write_text(updated)
PY
}

CURRENT_VERSION="$(read_marketing_version)"
VERSION="${VERSION:-$(bump_revision "$CURRENT_VERSION")}"
PERSIST_VERSION="${PERSIST_VERSION:-1}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${OUTPUT_BASENAME}-${VERSION}.dmg"

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  MARKETING_VERSION="${VERSION}" \
  build

rm -rf "${DIST_DIR}" "${STAGING_DIR}"
mkdir -p "${DIST_DIR}" "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "${DMG_VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

if [[ "${PERSIST_VERSION}" == "1" ]]; then
  persist_marketing_version "${VERSION}"
fi

echo "Created ${DMG_PATH}"
