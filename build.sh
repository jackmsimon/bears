#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
app="$root/dist/Bears.app"
contents="$app/Contents"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

xcrun swiftc \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework Carbon \
  -framework ServiceManagement \
  -framework WebKit \
  "$root/Sources/Bears/main.swift" \
  -o "$contents/MacOS/Bears"

cp "$root/Resources/Info.plist" "$contents/Info.plist"
codesign --force --sign - "$app"

print "$app"
