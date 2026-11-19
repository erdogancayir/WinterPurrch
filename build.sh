#!/bin/zsh
# Builds build/WinterPurrch.app (ad hoc signed). With --install, copies it to /Applications and restarts it.
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 builds for Apple silicon and Intel at once (for releases).
flags=(-c release)
if [[ -n "${UNIVERSAL:-}" ]]; then flags+=(--arch arm64 --arch x86_64); fi
swift build "${flags[@]}"
bin="$(swift build "${flags[@]}" --show-bin-path)"

app=build/WinterPurrch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/WinterPurrch" "$app/Contents/MacOS/WinterPurrch"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
for lproj in Resources/*.lproj; do
    mkdir -p "$app/Contents/Resources/$(basename "$lproj")"
    plutil -convert binary1 -o "$app/Contents/Resources/$(basename "$lproj")/Localizable.strings" "$lproj/Localizable.strings"
done
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    # Quit it properly so it saves its snow, then make sure it is gone.
    osascript -e 'quit app "WinterPurrch"' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x WinterPurrch >/dev/null || break; sleep 0.3; done
    pkill -x WinterPurrch 2>/dev/null || true
    rm -rf /Applications/WinterPurrch.app
    ditto "$app" /Applications/WinterPurrch.app
    open /Applications/WinterPurrch.app
    echo "Installed /Applications/WinterPurrch.app"
fi
