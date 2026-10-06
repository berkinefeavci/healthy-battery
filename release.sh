#!/bin/bash
# Cellkeep release packaging: check -> build -> (re-)sign -> dmg -> notarize -> staple.
#
# Env:
#   CELLKEEP_SIGN_IDENTITY   Signing identity (name or hash). If unset, the first
#                            "Developer ID Application:" identity from
#                            `security find-identity -v -p codesigning` is used.
#                            If none exists, falls back to ad-hoc ("-") signing
#                            and notarization is skipped.
#   CELLKEEP_NOTARY_PROFILE  `xcrun notarytool` keychain profile name.
#                            Default: cellkeep-notary. Only used when signing
#                            with a real Developer ID identity.
set -euo pipefail
cd "$(dirname "$0")"

app_path=.build/Cellkeep.app
dist_dir=dist
mkdir -p "$dist_dir"

echo "==> check.sh"
./check.sh

echo "==> build.sh"
./build.sh

test -d "$app_path"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"

# ---------------------------------------------------------------------------
# 1. Signing identity
# ---------------------------------------------------------------------------
identity="${CELLKEEP_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n1)"
fi

have_dev_id=true
if [[ -z "$identity" ]]; then
  have_dev_id=false
  identity="-"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "!! No 'Developer ID Application:' identity found. Falling back to  !!" >&2
  echo "!! ad-hoc signing (-). The app will NOT pass Gatekeeper on other   !!" >&2
  echo "!! Macs, and notarization is skipped entirely.                    !!" >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
fi
echo "==> signing identity: $identity"

# ---------------------------------------------------------------------------
# 2. Entitlements decision
# ---------------------------------------------------------------------------
# Cellkeep talks to the private PowerUI.framework (dlopen from
# /System/Library/PrivateFrameworks) from both the main app and the helper
# executables (Tools/PowerLimitProbe.m, Sources/PowerUIBridge/PowerUIBridge.m).
# Hardened Runtime's library validation (the default when no
# com.apple.security.cs.disable-library-validation entitlement is present)
# blocks loading code NOT signed by the same Team ID as the running binary --
# EXCEPT code signed by Apple itself. PowerUI.framework ships inside the
# dyld shared cache as part of the OS and is Apple-signed, so it loads fine
# under the default Hardened Runtime with no extra entitlement. We deliberately
# do NOT add com.apple.security.cs.disable-library-validation: it would only
# be needed to load third-party or unsigned code, which is not the case here,
# and adding it unnecessarily widens what the process is allowed to load.
#
# If a real need for entitlements ever appears (e.g. a sandboxed helper needing
# specific temporary-exception keys), drop a Packaging/Cellkeep.entitlements
# file next to Info.plist and it will be picked up automatically below.
entitlements_file="Packaging/Cellkeep.entitlements"
entitlements_args=()
if [[ -f "$entitlements_file" ]]; then
  entitlements_args=(--entitlements "$entitlements_file")
  echo "==> using entitlements: $entitlements_file"
else
  echo "==> no entitlements file needed (see comment in release.sh: PowerUI is Apple-signed)"
fi

# ---------------------------------------------------------------------------
# 3. (Re-)sign: helpers first (inside-out), then the app
# ---------------------------------------------------------------------------
# --timestamp needs a trusted timestamp from Apple's server, which only works
# for a real Developer ID certificate; it errors out on ad-hoc ("-") signing.
# --options runtime (Hardened Runtime) is also only meaningful with a real
# identity (notarization requires it), so both are conditional on having one.
sign_opts=(--force)
if $have_dev_id; then
  sign_opts+=(--options runtime --timestamp ${entitlements_args[@]+"${entitlements_args[@]}"})
fi

helper_names=(CellkeepLEDHelper CellkeepPowerModeHelper CellkeepNativeChargeHelper CellkeepChargeInhibitHelper)
for helper in "${helper_names[@]}"; do
  helper_path="$app_path/Contents/Resources/$helper"
  test -f "$helper_path"
  echo "==> signing $helper"
  codesign "${sign_opts[@]}" --sign "$identity" "$helper_path"
done

echo "==> signing $app_path"
codesign "${sign_opts[@]}" --sign "$identity" "$app_path"

echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict "$app_path"

# ---------------------------------------------------------------------------
# 4. Notarize the app itself (before it gets packaged into the DMG), so it can
#    be stapled prior to packaging, as well as the final DMG.
# ---------------------------------------------------------------------------
notary_profile="${CELLKEEP_NOTARY_PROFILE:-cellkeep-notary}"
did_notarize=false
if $have_dev_id; then
  if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    did_notarize=true
  else
    echo "==> notarization skipped: keychain profile '$notary_profile' not found."
    echo "    To set it up (you will be prompted for an app-specific password"
    echo "    from account.apple.com):"
    echo "      xcrun notarytool store-credentials $notary_profile --apple-id <email> --team-id A7V9NP35W2"
  fi
fi

if $did_notarize; then
  app_zip="$dist_dir/Cellkeep-${version}-app.zip"
  echo "==> notarizing app"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$app_zip"
  xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
  rm -f "$app_zip"
  echo "==> stapling app"
  xcrun stapler staple "$app_path"
fi

# ---------------------------------------------------------------------------
# 5. Two DMGs: new name for new installs; old asset and app names for 1.2.1 updaters.
# ---------------------------------------------------------------------------
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

for package_name in Healthy-Battery Cellkeep; do
  if [[ "$package_name" == Healthy-Battery ]]; then
    bundle_name="Healthy Battery.app"
    volume_name="Healthy Battery"
  else
    bundle_name="Cellkeep.app"
    volume_name="Cellkeep"
  fi
  rm -rf "$stage_dir"/*
  cp -R "$app_path" "$stage_dir/$bundle_name"
  ln -s /Applications "$stage_dir/Applications"
  dmg_name="${package_name}-${version}.dmg"
  dmg_path="$dist_dir/$dmg_name"
  rm -f "$dmg_path"
  hdiutil create -volname "$volume_name" -srcfolder "$stage_dir" -format UDZO -ov "$dmg_path"
  codesign --force --sign "$identity" "$dmg_path"
  if $did_notarize; then
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
  fi
  (cd "$dist_dir" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")
  mount_dir="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg_path" >/dev/null
  if [[ ! -d "$mount_dir/$bundle_name" ]]; then
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
    rmdir "$mount_dir" 2>/dev/null || true
    echo "ERROR: $dmg_path does not contain $bundle_name" >&2
    exit 1
  fi
  hdiutil detach "$mount_dir" >/dev/null
  rmdir "$mount_dir" 2>/dev/null || true
  echo "==> done: $dmg_path"
done
if $did_notarize; then
  spctl -a -vvv -t exec "$app_path"
fi
