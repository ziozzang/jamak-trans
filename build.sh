#!/bin/zsh
# Builds build/JamakTrans.app (universal arm64 + x86_64, ad-hoc signed).
# Uses swiftc directly so it works with the Command Line Tools alone (no Xcode needed).
#   ./build.sh            release build, version from ./VERSION
#   ./build.sh debug
#   VERSION=1.2.3 ./build.sh
set -euo pipefail
cd "${0:A:h}"

VERSION=${VERSION:-$(<VERSION)}
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "invalid VERSION: $VERSION" >&2; exit 1; }
APP="build/JamakTrans.app"
SOURCES=(Sources/SRTTranslator/*.swift)
MIN_OS=26.0
OPT=(-O -whole-module-optimization)
[[ ${1:-release} == debug ]] && OPT=(-Onone -g)

mkdir -p build/obj
for arch in arm64 x86_64; do
  echo "▸ Compiling $arch"
  swiftc -swift-version 5 -parse-as-library $OPT \
    -target $arch-apple-macos$MIN_OS \
    $SOURCES -o build/obj/JamakTrans-$arch
done

echo "▸ Bundling $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create build/obj/JamakTrans-arm64 build/obj/JamakTrans-x86_64 -output "$APP/Contents/MacOS/JamakTrans"
cp Resources/Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
fi

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
echo "✓ $APP ($VERSION)"
