#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
set -e

if [[ $(uname) != Darwin ]]; then
  echo "build_mac_app.sh needs macOS (sips, iconutil, codesign)"
  exit 1
fi

# Info.plist wants a numeric version: the latest tag without its "v"
version=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
version=${version:-0.0.0}
app="build/Byte.app"

scripts/build.sh release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp build/byte "$app/Contents/MacOS/byte"
cp -r data "$app/Contents/Resources/data"
ln -s ../Resources/data "$app/Contents/MacOS/data"

# icon: every size iconutil wants, from the 512px logo
iconset=$(mktemp -d)/byte.iconset
mkdir "$iconset"
for s in 16 32 128 256; do
  sips -z $s $s resources/images/byte-logo-512.png \
    --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) resources/images/byte-logo-512.png \
    --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
cp resources/images/byte-logo-512.png "$iconset/icon_512x512.png"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/byte.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Byte</string>
  <key>CFBundleDisplayName</key><string>Byte</string>
  <key>CFBundleIdentifier</key><string>com.alexledezma04.byte</string>
  <key>CFBundleExecutable</key><string>byte</string>
  <key>CFBundleIconFile</key><string>byte</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$app"

rm -f build/byte-macos.zip
ditto -c -k --keepParent "$app" build/byte-macos.zip
echo "packed: build/byte-macos.zip ($(du -h build/byte-macos.zip | cut -f1))"
