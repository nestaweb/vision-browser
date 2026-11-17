#!/bin/bash
# Fabrique dist/Vision Browser.dmg : la fenêtre d'installation avec le fond « trace de pas » (le bonhomme va
# lui-même dans Applications), l'app à gauche et le raccourci Applications à droite.
# Usage : VisionBrowser/scripts/make-dmg.sh   (macOS peut demander d'autoriser le pilotage du Finder la première fois)
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="Vision Browser"

xcodebuild -project VisionBrowser.xcodeproj -scheme VisionBrowser -configuration Release -derivedDataPath build build -quiet
APP="build/Build/Products/Release/$APP_NAME.app"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Fond en deux résolutions réunies dans un seul fichier : net sur écran Retina.
swift scripts/make-dmg-background.swift "$WORK/background"
tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" -out "$STAGE/.background/background.tiff"

RW="$WORK/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')

# Mise en page de la fenêtre (enregistrée dans le .DS_Store du disque) : 640 × 400, icônes de 112,
# placées aux centres prévus par le fond (voir appCenter / applicationsCenter dans make-dmg-background.swift).
osascript <<OSA
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {170, 214}
        set position of item "Applications" of container window to {470, 214}
        -- Si le Finder montre les fichiers cachés, ils sortent de la zone visible de la fenêtre.
        repeat with techItem in {".background", ".fseventsd", ".Trashes"}
            if exists item techItem of container window then set position of item techItem of container window to {900, 900}
        end repeat
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA

sync
hdiutil detach -quiet "$MOUNT"
mkdir -p ../dist
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "../dist/$APP_NAME.dmg"
echo "$(cd ../dist && pwd)/$APP_NAME.dmg"
