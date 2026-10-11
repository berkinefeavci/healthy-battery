# Homebrew casks

Users install and update Healthy Battery with (this is the command in the main README):

```sh
brew install --cask berkinefeavci/healthy-battery/healthy-battery
brew upgrade --cask healthy-battery
```

Two taps serve the same GitHub releases:

| Tap repository | Cask | DMG | App |
| --- | --- | --- | --- |
| `berkinefeavci/homebrew-healthy-battery` (current) | `healthy-battery` | `Healthy-Battery-<version>.dmg` | `Healthy Battery.app` |
| `berkinefeavci/homebrew-cellkeep` (legacy, for installs made under the old name) | `cellkeep` | `Cellkeep-<version>.dmg` | `Cellkeep.app` |

`cellkeep.rb` in this folder is the source of the legacy cask. The current cask is the same file with the
cask token, DMG name and app name above; keep its `zap` list identical to `cellkeep.rb` (it must name all
three helpers: `powermode`, `led` and `chargeinhibit`, and their state folders).

## One-time setup (maintainer)

Homebrew installs third-party casks from a "tap", a public repository named `homebrew-<name>`. Both
repositories above already exist; put each cask in `Casks/<token>.rb`.

## Each release

1. Build and upload the release as usual (`./release.sh`, then attach `Healthy-Battery-<version>.dmg`
   and `Cellkeep-<version>.dmg`).
2. Update the legacy cask with the exact DMG you uploaded (the version and SHA-256 must match the
   release; do not edit them by hand):
   ```sh
   Tools/update-cask.sh <version> path/to/Cellkeep-<version>.dmg
   ```
   For the current cask set `version` and the `Healthy-Battery-<version>.dmg` SHA-256
   (`shasum -a 256 <dmg>`) in the tap's `Casks/healthy-battery.rb`.
3. Copy the updated casks to their taps' `Casks/` folders and push.
4. Optionally check them: `brew audit --cask --strict berkinefeavci/healthy-battery/healthy-battery` and
   `brew install --cask berkinefeavci/healthy-battery/healthy-battery` on a clean Mac.

`brew upgrade` runs the old version's `uninstall` step, so that step only quits the app; the root
helpers and their launch daemons stay installed across upgrades. `brew uninstall --zap --cask healthy-battery`
also removes the helpers, launch daemons, data and preferences, as does Settings → General →
Healthy Battery'i kaldır. The macOS charge limit itself is a system setting and is left as it was.
