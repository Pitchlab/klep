#!/usr/bin/env bash
# Verpakt de release-binary PitchlabSpeechApp tot een macOS-appbundel
# .build/PitchlabSpeech.app. Command Line Tools only, geen Xcode.
#
# De bundel krijgt een Info.plist met:
#   LSUIElement = true                 -> geen Dock-icoon, alleen een statusitem.
#   NSMicrophoneUsageDescription       -> permissie-tekst voor de microfoon (R7).
#   NSAppleEventsUsageDescription      -> Accessibility/toetsaanslagen (R9).
# en wordt gesigneerd met een stabiele self-signed identiteit uit de keychain
# (standaard "PitchLab Local Code Signing", override met PITCHLAB_SIGN_IDENTITY).
# macOS TCC koppelt Microfoon, Toegankelijkheid en Invoerbewaking aan de designated
# requirement van de code. Met een vaste identiteit is die `identifier <bundle-id>
# and certificate root = H"<cert>"` — gelijk over builds, dus de toestemming
# overleeft een herbouw. Ontbreekt die identiteit, dan valt het script terug op
# ad-hoc (identiteit "-"); dan is de requirement de exacte CDHash die per build
# verandert en trekt macOS de toestemming bij elke herbouw in. Developer ID en
# notariseren zijn buiten scope.

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

# --- Signeren met een stabiele identiteit zodat TCC-toestemming een herbouw overleeft ---
SIGN_IDENTITY="${PITCHLAB_SIGN_IDENTITY:-PitchLab Local Code Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${SIGN_IDENTITY}"; then
    echo "==> codesign met stabiele identiteit: ${SIGN_IDENTITY}"
    codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP_DIR}"
    STABLE_SIGN=1
else
    echo "!! stabiele identiteit '${SIGN_IDENTITY}' niet in de keychain — val terug op ad-hoc." >&2
    echo "!! Ad-hoc geeft per build een nieuwe CDHash-requirement: macOS trekt Microfoon," >&2
    echo "!! Toegankelijkheid en Invoerbewaking bij elke herbouw in. Maak de identiteit aan" >&2
    echo "!! (zie README, sectie Installeren) om dat te voorkomen." >&2
    codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"
    STABLE_SIGN=0
fi
codesign --verify --verbose=2 "${APP_DIR}"

# --- Melden of de code-identiteit veranderd is t.o.v. de vorige build ---
# De CDHash weerspiegelt de code-inhoud en verandert dus bij elke wijziging, ook bij
# stabiel signeren. Wat TCC bepaalt is de designated requirement (DR): blijft die
# gelijk, dan blijft de toestemming geldig ondanks een nieuwe CDHash. We melden beide.
STATE_DIR="${BUILD_DIR}/.app-signature"
mkdir -p "${STATE_DIR}"
CDHASH_FILE="${STATE_DIR}/cdhash"
DR_FILE="${STATE_DIR}/requirement"

NEW_CDHASH="$(codesign -dvvv "${APP_DIR}" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
NEW_DR="$(codesign -d -r- "${APP_DIR}" 2>&1 | sed -n 's/^designated => //p')"
PREV_CDHASH=""; [[ -f "${CDHASH_FILE}" ]] && PREV_CDHASH="$(cat "${CDHASH_FILE}")"
PREV_DR="";     [[ -f "${DR_FILE}"     ]] && PREV_DR="$(cat "${DR_FILE}")"

echo
echo "==> CDHash: ${NEW_CDHASH}"
if [[ -z "${PREV_CDHASH}" ]]; then
    echo "==> Eerste build die de signature bijhoudt — niets om mee te vergelijken."
elif [[ "${NEW_CDHASH}" == "${PREV_CDHASH}" ]]; then
    echo "==> CDHash ongewijzigd t.o.v. vorige build."
else
    echo "!! CDHash veranderd t.o.v. vorige build: ${PREV_CDHASH} -> ${NEW_CDHASH}"
    if [[ -n "${PREV_DR}" && "${NEW_DR}" == "${PREV_DR}" ]]; then
        echo "!! Signeer-identiteit ongewijzigd — TCC-toestemming (Microfoon/Toegankelijkheid/Invoerbewaking) blijft geldig, niets opnieuw geven."
    elif [[ "${STABLE_SIGN}" == "1" ]]; then
        echo "!! Signeer-identiteit gewijzigd — geef Microfoon, Toegankelijkheid en Invoerbewaking opnieuw."
    else
        echo "!! Ad-hoc gesigneerd — macOS ziet dit als een nieuwe app: geef Microfoon, Toegankelijkheid en Invoerbewaking opnieuw."
    fi
fi
printf '%s' "${NEW_CDHASH}" > "${CDHASH_FILE}"
printf '%s' "${NEW_DR}"     > "${DR_FILE}"

echo "==> klaar: ${APP_DIR}"
