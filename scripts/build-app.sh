#!/usr/bin/env bash
# Verpakt de release-binary PitchlabSpeechApp tot een macOS-appbundel
# .build/PitchlabSpeech.app. Command Line Tools only, geen Xcode.
#
# De bundel krijgt een Info.plist met:
#   LSUIElement = true                 -> geen Dock-icoon, alleen een statusitem.
#   NSMicrophoneUsageDescription       -> permissie-tekst voor de microfoon (R7).
#   NSAppleEventsUsageDescription      -> Accessibility/toetsaanslagen (R9).
#   CFBundleIconFile/CFBundleIconName  -> AppIcon.icns in Contents/Resources (PL-730).
# en wordt ad-hoc gesigneerd met codesign (identiteit "-"), zodat de TCC-permissies
# aan een stabiele bundel-identiteit hangen. Geen Developer ID nodig voor lokaal
# gebruik; notariseren is buiten scope.
#
# Het app-icoon wordt bij elke build vers uit scripts/appicon/icon-1024.png afgeleid
# met sips + iconutil (beide zitten in Command Line Tools). De bron is een tijdelijk
# ontwerp; scripts/make-appicon.py maakt hem opnieuw. Een LSUIElement-app heeft geen
# Dock-icoon, dus dit icoon zie je vooral in Systeeminstellingen en permissie-dialogen.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PitchlabSpeech"
BUNDLE_ID="nl.pitchlab.speech"
EXECUTABLE="PitchlabSpeechApp"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
ICON_SOURCE="scripts/appicon/icon-1024.png"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXECUTABLE}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "FOUT: binary niet gevonden op ${BIN_PATH}" >&2
    exit 1
fi

echo "==> bundel opnieuw opbouwen in ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# De binary heet in de bundel gewoon PitchlabSpeech (CFBundleExecutable).
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# AppIcon.icns vers uit de bron bakken: iconset met alle vereiste maten via sips,
# dan iconutil. Zo staat er altijd een geldig icoon in de bundel (test-gate).
if [[ ! -f "${ICON_SOURCE}" ]]; then
    echo "FOUT: icoonbron niet gevonden op ${ICON_SOURCE}" >&2
    exit 1
fi
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET}"
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    px="${pair%% *}"; label="${pair##* }"
    sips -z "${px}" "${px}" "${ICON_SOURCE}" --out "${ICONSET}/icon_${label}.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "$(dirname "${ICONSET}")"

# Versie uit de laatste tag als die er is, anwaartsom 0.0.0.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
VERSION="${VERSION#v}"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>pitchlab-speech</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>pitchlab-speech gebruikt de microfoon om je spraak lokaal naar tekst om te zetten.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>pitchlab-speech voegt de herkende tekst in bij de cursor van het actieve venster.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"
codesign --verify --verbose=2 "${APP_DIR}"

echo "==> klaar: ${APP_DIR}"
