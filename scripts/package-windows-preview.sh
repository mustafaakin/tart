#!/bin/sh

# Builds an unofficial preview tarball for testers: a release build of tart.app, signed ad-hoc with
# only the virtualization entitlement (no bridged networking), plus the license.
# usage: ./scripts/package-windows-preview.sh 0.1.0-windows-preview
#
# Testers who download it with a browser must run "xattr -dr com.apple.quarantine tart.app" first,
# since the build isn't notarized.

set -e

VERSION="${1:?usage: $0 <version>}"
OUT="$PWD/dist/windows-preview"

# set-version.sh edits these in place, so put them back however the build ends
trap 'git checkout -- Sources/tart/CI/CI.swift Resources/Info.plist' EXIT
VERSION="$VERSION" .ci/set-version.sh

swift build -c release --product tart

rm -Rf "$OUT"
mkdir -p "$OUT/tart.app/Contents/MacOS" "$OUT/tart.app/Contents/Resources"
cp .build/release/tart "$OUT/tart.app/Contents/MacOS/tart"
cp Resources/Info.plist "$OUT/tart.app/Contents/Info.plist"
cp "Resources/actool/UPW Tart.icns" Resources/actool/Assets.car "$OUT/tart.app/Contents/Resources/"
cp LICENSE "$OUT/"

cat > "$OUT/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.virtualization</key>
	<true/>
</dict>
</plist>
EOF
codesign --sign - --entitlements "$OUT/entitlements.plist" --force "$OUT/tart.app"
rm "$OUT/entitlements.plist"

tar -czf "$OUT/tart-windows-preview.tar.gz" -C "$OUT" tart.app LICENSE
"$OUT/tart.app/Contents/MacOS/tart" --version
shasum -a 256 "$OUT/tart-windows-preview.tar.gz"
