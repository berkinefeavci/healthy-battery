# Releasing

Releases are built, signed, notarized and published by `.github/workflows/release.yml`. It runs
only when started by hand, on the maintainer's Mac through a self-hosted GitHub Actions runner.
That Mac provides Xcode 27, the Developer ID certificate and the `cellkeep-notary` keychain
profile, so no signing secret is stored in GitHub.

## One-time setup on the Mac

1. The Mac already builds releases locally: `./release.sh` produces a notarized DMG (Developer ID
   identity in the login keychain, `xcrun notarytool store-credentials cellkeep-notary …` done).
2. GitHub → repository **Settings → Actions → Runners → New self-hosted runner** → macOS, ARM64.
   Run the shown download and `./config.sh …` commands in a folder such as `~/actions-runner`.
   When `config.sh` asks for extra labels, enter `cellkeep-release`.
3. Keep it running while logged in: `./svc.sh install && ./svc.sh start` (a LaunchAgent in the
   user session, so it can use the login keychain). The first signing may show a keychain prompt
   for `codesign`; choose **Always Allow**.
4. **Settings → Actions → General → Fork pull request workflows from outside collaborators**:
   choose **Require approval for all external contributors**. The release workflow never runs for
   pull requests, but this keeps any workflow from a fork off the self-hosted runner until you
   approve it.

## Each release

1. Merge a PR that bumps `CFBundleShortVersionString` / `CFBundleVersion` in
   `Packaging/Info.plist` and adds a `## <version>` section to `CHANGELOG.md`.
2. **Actions → Release → Run workflow** on `main` (the Mac must be awake and online).
3. The workflow refuses to publish if the tag already exists, the changelog section is missing,
   or the DMG is not Developer ID signed and notarized. On success it creates `v<version>` with the
   changelog section as notes and attaches both `Healthy-Battery-<version>.dmg` and legacy `Cellkeep-<version>.dmg`, each with a `.sha256`.
4. Update the Homebrew cask with that DMG (`Tools/update-cask.sh`, see `Packaging/homebrew`).
