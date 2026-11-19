#!/bin/zsh
# Builds a universal WinterPurrch.app and packs it into build/WinterPurrch-<version>.dmg,
# with a link to Applications to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
stage=build/dmg
rm -rf "$stage"
mkdir -p "$stage"
ditto build/WinterPurrch.app "$stage/WinterPurrch.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname WinterPurrch -srcfolder "$stage" -ov -format UDZO "build/WinterPurrch-$version.dmg"
rm -rf "$stage"
echo "Built build/WinterPurrch-$version.dmg"
