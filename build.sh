#!/bin/zsh
# Builds a universal (Intel + Apple Silicon) Vigil.app into ./build
set -e
cd "${0:A:h}"
APP=build/Vigil.app
rm -rf build && mkdir -p build $APP/Contents/MacOS $APP/Contents/Resources
for arch in x86_64 arm64; do
  swiftc -O -target $arch-apple-macos12.0 -o build/Vigil-$arch Sources/*.swift -framework AppKit -framework IOKit
done
lipo -create build/Vigil-x86_64 build/Vigil-arm64 -output $APP/Contents/MacOS/Vigil
rm build/Vigil-x86_64 build/Vigil-arm64
cp Info.plist $APP/Contents/
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/
codesign --force --sign - $APP
echo "Built $APP ($(lipo -archs $APP/Contents/MacOS/Vigil))"
