#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_path=.build/Cellkeep.app
extract_intents=false
if [[ "${1:-}" == "--local-preview-sdk" ]]; then
  # Explicit opt-in. This does not replace the full Xcode/support-matrix release gate.
  sdk_path="${2:?Usage: ./build.sh --local-preview-sdk /absolute/path/to/MacOSX26.5.sdk}"
  test "$#" = 2
  test -d "$sdk_path"
  test "$(uname -m)" = arm64
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
  printf 'Local preview: SDK=%s, developer=%s\n' "$sdk_path" "$DEVELOPER_DIR"
  # Reuse only the original asset catalog and only if every source asset is unchanged.
  # The executable is always rebuilt from ALL current production Swift sources.
  (
    cd ..
    awk '/  app\/ChargeMate.app\/Contents\/Resources\/Assets.car$/ || /  project\/Sources\/ChargeMate\/Resources\/Assets.xcassets\// { print }' SHA256SUMS | shasum -a 256 --check --status
  )
  mkdir -p .build/local-preview
  xcrun clang -isysroot "$sdk_path" -mmacosx-version-min=13.0 -fobjc-arc \
    -c Sources/PowerUIBridge/PowerUIBridge.m -I Sources/PowerUIBridge/include -o .build/local-preview/PowerUIBridge.o
  xcrun swiftc -sdk "$sdk_path" -target arm64-apple-macos13.0 -O \
    -I Sources/PowerUIBridge/include Sources/ChargeMate/*.swift \
    .build/local-preview/PowerUIBridge.o -o .build/local-preview/ChargeMate
  xcrun swiftc -sdk "$sdk_path" -target arm64-apple-macos13.0 -O \
    -I Sources/PowerUIBridge/include Sources/NativeChargeHelper/*.swift \
    .build/local-preview/PowerUIBridge.o -o .build/local-preview/ChargeMateNativeChargeHelper
  executable=.build/local-preview/ChargeMate
  native_charge_helper=.build/local-preview/ChargeMateNativeChargeHelper
  xcrun clang -isysroot "$sdk_path" -mmacosx-version-min=13.0 -O2 \
    Tools/MagSafeLEDProbe.c -framework IOKit -framework CoreFoundation \
    -o .build/local-preview/ChargeMateLEDHelper
  xcrun clang -isysroot "$sdk_path" -mmacosx-version-min=13.0 -O2 \
    Tools/PowerModeHelper.c -o .build/local-preview/ChargeMatePowerModeHelper
  xcrun clang -isysroot "$sdk_path" -mmacosx-version-min=13.0 -O2 \
    Tools/ChargeInhibitHelper.c Tools/ChargeInhibitSafety.c -framework IOKit -framework CoreFoundation -framework Security \
    -o .build/local-preview/ChargeMateChargeInhibitHelper
  charge_inhibit_helper=.build/local-preview/ChargeMateChargeInhibitHelper
  helper_binary=.build/local-preview/ChargeMateLEDHelper
  power_mode_helper=.build/local-preview/ChargeMatePowerModeHelper
  asset_catalog=../app/ChargeMate.app/Contents/Resources/Assets.car
else
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
      export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    else
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
  fi
  # The compiler also writes every localizable string key it sees (Text("…"), String(localized:), …)
  # so Tools/check-localizations.swift can verify each language covers them.
  rm -rf .build/localized-strings
  swift build -c release -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/.build/localized-strings" "$@"
  extract_intents=true
  executable=.build/release/Cellkeep
  native_charge_helper=.build/release/CellkeepNativeChargeHelper
  xcrun clang -O2 Tools/MagSafeLEDProbe.c -framework IOKit -framework CoreFoundation \
    -o .build/release/CellkeepLEDHelper
  xcrun clang -O2 Tools/PowerModeHelper.c -o .build/release/CellkeepPowerModeHelper
  xcrun clang -O2 Tools/ChargeInhibitHelper.c Tools/ChargeInhibitSafety.c -framework IOKit -framework CoreFoundation -framework Security \
    -o .build/release/CellkeepChargeInhibitHelper
  charge_inhibit_helper=.build/release/CellkeepChargeInhibitHelper
  helper_binary=.build/release/CellkeepLEDHelper
  power_mode_helper=.build/release/CellkeepPowerModeHelper
  resource_bundle=.build/release/Cellkeep_Cellkeep.bundle
  if [ -f "$resource_bundle/Contents/Resources/Assets.car" ]; then
    asset_catalog="$resource_bundle/Contents/Resources/Assets.car"
  else
    asset_catalog="$resource_bundle/Assets.car"
  fi
fi
# CI runners may carry an older Xcode whose SwiftPM lays out intermediates differently; release
# builds (Xcode 27, local) keep these steps mandatory, CI only proves compile + tests.
ci_optional() { if [ -n "${CI:-}" ]; then echo "UYARI (CI): $1 bulunamadı, atlanıyor" >&2; return 0; fi; return 1; }
if [ ! -f "$asset_catalog" ]; then ci_optional "Assets.car" || { test -f "$asset_catalog"; }; asset_catalog=""; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$executable" "$app_path/Contents/MacOS/Cellkeep"
# App icon: Packaging/AppIcon.icon (Icon Composer). actool compiles it together with the asset
# catalog into one Assets.car holding the light, dark and tinted icon, plus AppIcon.icns for
# macOS 13–15. actool resolves relative paths against its own daemon, so every path is absolute.
rm -f "$app_path/Contents/Resources/Assets.car" "$app_path/Contents/Resources/AppIcon.icns"
xcrun actool "$PWD/Sources/ChargeMate/Resources/Assets.xcassets" "$PWD/Packaging/AppIcon.icon" \
  --compile "$PWD/$app_path/Contents/Resources" \
  --output-format human-readable-text --notices --warnings \
  --output-partial-info-plist "$PWD/.build/AppIcon-info.plist" \
  --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 13.0 --target-device mac || true
if [ ! -s "$app_path/Contents/Resources/AppIcon.icns" ] || [ ! -s "$app_path/Contents/Resources/Assets.car" ]; then
  ci_optional "AppIcon (Icon Composer needs Xcode 26 or newer)" || { echo "HATA: app icon derlenemedi" >&2; exit 1; }
  rm -f "$app_path/Contents/Resources/Assets.car" "$app_path/Contents/Resources/AppIcon.icns"
  [ -n "$asset_catalog" ] && cp "$asset_catalog" "$app_path/Contents/Resources/Assets.car"
fi
cp "$helper_binary" "$app_path/Contents/Resources/CellkeepLEDHelper"
cp "$power_mode_helper" "$app_path/Contents/Resources/CellkeepPowerModeHelper"
cp "$native_charge_helper" "$app_path/Contents/Resources/CellkeepNativeChargeHelper"
cp "$charge_inhibit_helper" "$app_path/Contents/Resources/CellkeepChargeInhibitHelper"
codesign --force --sign - "$app_path/Contents/Resources/CellkeepLEDHelper"
codesign --force --sign - "$app_path/Contents/Resources/CellkeepPowerModeHelper"
codesign --force --sign - "$app_path/Contents/Resources/CellkeepNativeChargeHelper"
codesign --force --sign - "$app_path/Contents/Resources/CellkeepChargeInhibitHelper"
cp Packaging/Info.plist "$app_path/Contents/Info.plist"
# SwiftUI Text and String(localized:) look up Bundle.main, i.e. Contents/Resources/<lang>.lproj.
rm -rf "$app_path/Contents/Resources/"*.lproj
for lproj in Localization/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$app_path/Contents/Resources/"
done
if [ -d .build/localized-strings ]; then
  xcrun swift Tools/check-localizations.swift .build/localized-strings Localization ${CELLKEEP_L10N_DUMP:+--dump}
fi
if $extract_intents; then
  intent_objects=".build/out/Intermediates.noindex/Cellkeep.build/Release/Cellkeep-p.build/Objects-normal/$(uname -m)"
  intent_sources="$intent_objects/Cellkeep.SwiftFileList"
  intent_values=.build/CellkeepAppIntents.constvalues.list
  if [ ! -s "$intent_sources" ] && ci_optional "App Intents ara dosyaları"; then extract_intents=false; fi
fi
if $extract_intents; then
  test -s "$intent_sources"
  find "$intent_objects" -maxdepth 1 -type f -name '*.swiftconstvalues' -size +0 -print | sort > "$intent_values"
  test -s "$intent_values"
  "$(xcrun --find appintentsmetadataprocessor)" \
    --output "$app_path/Contents/Resources" \
    --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" \
    --module-name Cellkeep \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS \
    --deployment-target 13.0 \
    --target-triple "$(uname -m)-apple-macos13.0" \
    --source-file-list "$intent_sources" \
    --swift-const-vals-list "$intent_values" \
    --force --no-app-shortcuts-localization
  test -s "$app_path/Contents/Resources/Metadata.appintents/version.json"
  test -s "$app_path/Contents/Resources/Metadata.appintents/extract.actionsdata"
  grep -aq 'GetBatteryPercentageIntent' "$app_path/Contents/Resources/Metadata.appintents/extract.actionsdata"
  grep -aq 'SetMagSafeLightIntent' "$app_path/Contents/Resources/Metadata.appintents/extract.actionsdata"
fi
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf 'App ready: %s/%s\n' "$PWD" "$app_path"
