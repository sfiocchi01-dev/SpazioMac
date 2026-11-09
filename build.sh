#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product SpazioMac
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/SpazioMac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SpazioMac" "$APP/Contents/MacOS/SpazioMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift Resources/MakeIcon.swift "$PWD/.build/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# iCloud/Finder may attach metadata to generated files; strip only this built bundle.
xattr -cr "$APP"
codesign --force --sign - --identifier local.spaziomac.app "$APP"
codesign --verify --strict "$APP"
echo "Creata: $APP"
if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/SpazioMac.app"
    mkdir -p "$HOME/Applications"
    if [[ -e "$DEST" ]]; then
        echo "Esiste già $DEST: nessuna sovrascrittura. Il nuovo pacchetto è in dist/." >&2
        exit 1
    fi
    ditto "$APP" "$DEST"
    echo "Installata: $DEST"
fi
