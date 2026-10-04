# Privacy

Healthy Battery is a local-only macOS app. Short version: nothing about you or your Mac leaves it.

- **No network access by default.** Healthy Battery makes no network requests out of the box — no telemetry, no crash reporting, no ads.
- **Daily release check (can be turned off).** Unless you turn off "Günde bir yeni sürüm denetle" in Settings → About, Healthy Battery sends one plain HTTPS GET to `api.github.com/repos/berkinefeavci/healthy-battery/releases/latest` at most once a day while it is running; "Şimdi denetle" sends the same request on demand. A choice made in an earlier version to keep the check off is kept. It sends no identifier, settings, battery data or anything else; GitHub sees only what any web request shows (your IP address and a generic macOS user agent). A newer version is shown in the panel and in About and, if macOS notifications are allowed and "Yeni sürüm çıkınca bildirim göster" is on, announced once per version with a local notification; no push server, device token or subscription is involved. Only when you press "Update" does Healthy Battery download that release's DMG and its `.sha256` from `github.com/berkinefeavci/healthy-battery/releases`; it installs it only if the checksum matches, the app inside is signed with the same Developer ID Team as the running copy, Gatekeeper accepts it as notarized, and its version and bundle identifier are the expected ones. Otherwise nothing is installed and the release page link is offered instead.
- **No analytics, no accounts.** There is no sign-in, no user identifier, no usage tracking of any kind.
- **No data collection by the developer.** The developer never receives any information from your installation.
- **Local storage only.** Preferences, charge history, and schedules are stored in standard macOS locations (`UserDefaults`, local application-support files) on your Mac only.
- **Diagnostics are opt-in and local.** The in-app "export diagnostics" feature writes a plain-text report to a file you choose, via a standard macOS save panel. It is never uploaded anywhere automatically; you decide who sees it.
- **No serial numbers or personal identifiers are read or stored.** Where Healthy Battery reads hardware/device metadata (e.g. a connected iPhone's class over USB), it deliberately avoids reading or recording per-device serial numbers.

If this ever changes, it will be called out here and in the changelog before it ships.
