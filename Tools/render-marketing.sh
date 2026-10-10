#!/bin/bash
# Renders the app's real SwiftUI views offscreen with curated demo data into marketing PNGs (3x,
# transparent outside each component's own shape, English localization).
#   Tools/render-marketing.sh [output-dir]
# Writes nothing outside the output dir and .build/marketing. No hardware access: the native backend
# is a read-only fake, HOME is a temp sandbox, defaults live in a private bundle-id domain.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
cd "$(dirname "$0")/.."
out="${1:-/Users/berkinefeavci/Depo/30-39_Aktif_Isler/healthy-battery-marketing/assets/ui/}"
work=.build/marketing
app="$work/MarketingRender.app"
rm -rf "$app"
mkdir -p "$work" "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun clang -fobjc-arc -c Sources/PowerUIBridge/PowerUIBridge.m -I Sources/PowerUIBridge/include -o "$work/PowerUIBridge.o"
sources=()
while IFS= read -r f; do sources+=("$f"); done < <(ls Sources/ChargeMate/*.swift | grep -v '/App.swift$')
xcrun swiftc -O -I Sources/PowerUIBridge/include "${sources[@]}" Tests/MarketingRender.swift \
  "$work/PowerUIBridge.o" -o "$app/Contents/MacOS/MarketingRender"

# Bundle.main must resolve en.lproj, so the renderer runs inside a minimal app bundle.
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>MarketingRender</string>
<key>CFBundleIdentifier</key><string>local.marketing.render</string>
<key>CFBundleName</key><string>Healthy Battery</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
for lproj in Localization/*.lproj; do cp -R "$lproj" "$app/Contents/Resources/"; done
codesign --force --sign - "$app" >/dev/null

# App icon compiled from Packaging/AppIcon.icon exactly like build.sh does (no full app build needed).
rm -rf "$work/icon"; mkdir -p "$work/icon"
xcrun actool "$PWD/Sources/ChargeMate/Resources/Assets.xcassets" "$PWD/Packaging/AppIcon.icon" \
  --compile "$PWD/$work/icon" --output-format human-readable-text --notices --warnings \
  --output-partial-info-plist "$PWD/$work/icon/p.plist" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 13.0 --target-device mac >/dev/null || true
icon="$PWD/$work/icon/AppIcon.icns"
[ -s .build/Cellkeep.app/Contents/Resources/AppIcon.icns ] && icon="$PWD/.build/Cellkeep.app/Contents/Resources/AppIcon.icns"

home="$(mktemp -d "${TMPDIR:-/tmp}/hb-marketing-home.XXXXXX")"
trap 'rm -rf "$home"' EXIT
mkdir -p "$out"
HOME="$home" CFFIXED_USER_HOME="$home" "$app/Contents/MacOS/MarketingRender" "$out" "$icon" \
  -AppleLanguages "(en)" -AppleLocale en_US
