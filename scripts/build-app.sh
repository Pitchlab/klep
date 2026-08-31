#!/usr/bin/env bash
# Verpakt de release-binary PitchlabSpeechApp tot een macOS-appbundel
# .build/PitchlabSpeech.app. Command Line Tools only, geen Xcode.
#
# De bundel krijgt een Info.plist met:
#   LSUIElement = true                 -> geen Dock-icoon, alleen een statusitem.
#   NSMicrophoneUsageDescription       -> permissie-tekst voor de microfoon (R7).
#   NSAppleEventsUsageDescription      -> Accessibility/toetsaanslagen (R9).
# en wordt ad-hoc gesigneerd met codesign (identiteit "-"), zodat de TCC-permissies
# aan een stabiele bundel-identiteit hangen. Geen Developer ID nodig voor lokaal
# gebruik; notariseren is buiten scope.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PitchlabSpeech"
BUNDLE_ID="nl.pitchlab.speech"
EXECUTABLE="PitchlabSpeechApp"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXECUTABLE}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "FOUT: binary niet gevonden op ${BIN_PATH}" >&2
    exit 1
fi

echo "==> bundel opnieuw opbouwen in ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

# De binary heet in de bundel gewoon PitchlabSpeech (CFBundleExecutable).
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

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
