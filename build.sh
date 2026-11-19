#!/bin/zsh
# Builds build/WinterPurrch.app (ad hoc signed). With --install, copies it to /Applications and restarts it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
bin="$(swift build -c release --show-bin-path)"

app=build/WinterPurrch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/WinterPurrch" "$app/Contents/MacOS/WinterPurrch"
cp Resources/Info.plist "$app/Contents/"
for lproj in Resources/*.lproj; do
    mkdir -p "$app/Contents/Resources/$(basename "$lproj")"
    plutil -convert binary1 -o "$app/Contents/Resources/$(basename "$lproj")/Localizable.strings" "$lproj/Localizable.strings"
done
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x WinterPurrch 2>/dev/null || true
    rm -rf /Applications/WinterPurrch.app
    ditto "$app" /Applications/WinterPurrch.app
    open /Applications/WinterPurrch.app
    echo "Installed /Applications/WinterPurrch.app"
fi
