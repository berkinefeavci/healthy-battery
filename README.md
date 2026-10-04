# Healthy Battery

🇹🇷 [Türkçe README](README.tr.md)

**Free, open-source battery care for Apple Silicon MacBooks.** Set macOS's 80–100% charge limit, see live power flow, and watch your battery's health over months — from a small menu-bar app with no subscription, no account and no telemetry.

<p align="center">
  <a href="../../releases/latest"><img alt="Download the latest release" src="https://img.shields.io/github/v/release/berkinefeavci/healthy-battery?label=Download&style=for-the-badge"></a>
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-black?style=for-the-badge&logo=apple">
  <img alt="MIT license" src="https://img.shields.io/github/license/berkinefeavci/healthy-battery?style=for-the-badge">
</p>

- **Charge limit** 80–100% and one-click **Top Up** to 100% for a trip.
- **Live power flow**: adapter, battery, CPU, display — measured, never guessed.
- **Long-term health**: daily summaries for up to 400 days, CSV export.
- **Signed and notarized** by Apple, **open source** (MIT), data stays on your Mac ([PRIVACY.md](PRIVACY.md)).
- English, Türkçe, Deutsch, Français, Español.

## Screenshots

<p align="center"><img src="docs/screenshots/demo.gif" alt="Healthy Battery menu bar panel with live power flow from the adapter to the processor, display and other" width="400"></p>

<table>
<tr><td width="50%"><img src="docs/screenshots/panel-light.png" alt="Menu bar panel: 80% charge limit, Top Up, live power flow and power modes" width="100%"></td><td width="50%"><img src="docs/screenshots/dashboard-light.png" alt="Dashboard: battery history charts, charging state and long-term health trend" width="100%"></td></tr>
<tr><td width="50%"><img src="docs/screenshots/energy-light.png" alt="Energy Usage: apps ranked by macOS energy impact, connected devices and power flow" width="100%"></td><td width="50%"><img src="docs/screenshots/magsafe-light.png" alt="MagSafe Light: let macOS manage it, always off, or off during a time range" width="100%"></td></tr>
</table>

> Healthy Battery was previously named Cellkeep and ChargeMate. Existing app data, helper IDs and the Homebrew cask token retain Cellkeep for compatibility.

## Features

- **Charge limit, 80–100%.** Healthy Battery drives macOS's own native charge-limit control (the same mechanism macOS itself uses) to hold your battery at a target between 80% and 100% in 5% steps. Applying a limit is a real read/write round trip with an independent read-back check — see [Limitations](#how-it-works-and-limitations) for what that does and does not prove.
- **Top Up.** Temporarily charge to 100% for a trip, then Healthy Battery restores your usual limit afterward.
- **Live power flow.** A diagram of adapter, battery, CPU, display, and "other" power, in watts. CPU and display watts are read from Apple's SMC sensors; the total system draw comes from the battery controller. Nothing here is estimated or invented — if a value can't be measured, it shows as "—" instead of a guess.
- **Connected device power.** When exactly one USB device is drawing power on exactly one active port, Healthy Battery shows its wattage (read-only, from the battery controller's port telemetry). With more than one device or port, it shows "—" rather than a guess.
- **History charts.** 1 hour / 6 hour / 24 hour views of charge level, power draw, and battery health. The recorded readings can be exported as CSV from Settings → About.
- **Long-term health and habits.** A daily summary is kept for up to 400 days: a battery-health trend chart and, for the last 7 and 30 days, average charge, time spent at 90% or above, cycles added, health change and peak temperature. Exportable as CSV.
- **Battery health.** A maximum-capacity chart, smoothed to hourly medians so day-to-day sensor noise doesn't look like a real health swing.
- **Power modes per source.** Automatic / High Power (Turbo) / Low Power (Battery Saver), tracked separately for "on battery" and "on adapter," backed by macOS's own `pmset` power profiles through a narrowly scoped, allowlisted helper.
- **Sleep behavior.** Optional: while charging below your target with the adapter connected, Healthy Battery holds a public macOS idle-sleep assertion so your Mac keeps charging instead of going to sleep. It has an 8-hour safety cutoff and never touches lid-close or screen sleep. It does not pause charging by itself during sleep — see Limitations.
- **MagSafe LED control.** Manual System / Green / Orange / Off control, plus an always-off or scheduled-hours policy, via a signed, narrowly scoped privileged helper that only writes one known SMC key.
- **Schedules.** Recurring or one-off actions (apply a limit, switch power mode, and more) with a filterable execution history.
- **Apple Shortcuts actions.** Eight App Intents to read battery percentage, temperature, and status, and to apply a limit, start/cancel Top Up, switch power mode, or set the MagSafe LED.
- **High-energy apps, with Quit.** The energy list groups helper processes under their owning app, shows a real icon, and lets you quit an app straight from the list.
- **Updates from inside the app.** Healthy Battery asks GitHub for the latest release number at most once a day and shows one notification when a new version is out; both can be turned off in Settings → About. Press **Update** and it downloads that release, checks its checksum, Developer ID signature and Apple notarization, then replaces itself and relaunches. Nothing is sent; see [PRIVACY.md](PRIVACY.md).
- **Conflict guard.** When another charge-limit tool is running or installed (AlDente, Battery Toolkit, BatFi, batt, battery, bclm), Healthy Battery keeps monitoring but locks its own limit writes, so two apps never fight over the same setting.
- **Global shortcut (optional).** Off by default. Pick ⌃⌥⌘B or ⌃⌥⌘C in Settings → General to open or close the panel from anywhere; it needs no Accessibility permission and sees only that key combination.
- **Languages.** English, Türkçe, Deutsch, Français and Español; Healthy Battery follows your macOS language and falls back to English.
- **Customizable panel.** Long-press a card (or right-click → Edit cards) to reorder, add or remove cards, switch square/wide, and choose which rows the battery-info card shows.

### Planned; needs hardware verification

These are shown in the UI as locked and marked **"Yakında"** (Coming soon). They are **not working features** — do not expect them to do anything yet:

- **Discharge / auto-discharge** — no verified way to force the battery to discharge on this hardware.
- **Sailing** (oscillate within a range) — needs a working pause/resume primitive that hasn't been found.
- **Heat protection** — needs the same pause/resume primitive plus fresh temperature data.
- **Calibration** — a long-running, restorable discharge/recharge cycle; not implemented.

## Requirements

- **Apple Silicon (arm64) only.**
- Tested on **macOS 27**, on a single Mac model. Other macOS versions and other Mac models are **untested** — they may work, may not build, or may silently misbehave. Please file an issue with your Mac model and macOS version if you try one.

## Install

1. Download the latest `.dmg` from [Releases](../../releases). Release builds are signed with Developer ID and notarized by Apple.
2. Open it and drag `Healthy Battery.app` to Applications.
3. A build you made yourself with `./build.sh` is only ad-hoc signed; macOS will warn about it on first launch — open System Settings → Privacy & Security and allow it.
4. The first time you use a feature that needs a privileged helper (power-mode switching or MagSafe LED control), macOS will ask for administrator approval once for that helper. No password is stored by Healthy Battery.

### With Homebrew

The [Healthy Battery Homebrew tap](https://github.com/berkinefeavci/homebrew-healthy-battery) is available:

```sh
brew install --cask berkinefeavci/healthy-battery/healthy-battery
```

## Build from source

Requires Xcode 27.

```sh
./check.sh
./build.sh
```

`check.sh` runs the pure-logic test suite. `build.sh` produces `.build/Cellkeep.app`.

## Uninstall

In-app (recommended): Settings → General → **"Healthy Battery'i kaldır"** (Remove Healthy Battery). After one administrator prompt it removes the helpers and launch daemons, unregisters the login item, can reset the macOS charge limit to 100% (on by default) and can delete Healthy Battery's data (off by default). Then drag `Healthy Battery.app` or an older `Cellkeep.app` to the Trash.

Manual alternative:

1. Quit Healthy Battery and turn off "Start at login" in Settings first.
2. Move `Healthy Battery.app` or an older `Cellkeep.app` from `/Applications` to the Trash.
3. Remove the privileged helpers, if installed:
   ```sh
   sudo launchctl bootout system/io.github.berkinefeavci.cellkeep.powermode 2>/dev/null
   sudo launchctl bootout system/io.github.berkinefeavci.cellkeep.led 2>/dev/null
   sudo rm -f /Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.powermode.plist
   sudo rm -f /Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.led.plist
   sudo rm -f /Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode
   sudo rm -f /Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led
   ```
4. If you uninstall manually, your macOS charge limit stays as it was: it is a macOS setting. Change it in System Settings → Battery if you want to.

## How it works, and limitations

Healthy Battery reads and writes through Apple's private `PowerUI` framework (the same subsystem macOS's own Battery settings use) and reads a small number of documented, read-only SMC keys. This is not a public, stable API: **a macOS update can break it without warning**, and Healthy Battery has no way to detect that in advance.

The most important limitation: **applying a charge limit is a verified configuration write with an independent read-back — it is not proof that physical charge current actually stops at that percentage.** Healthy Battery has confirmed that macOS accepts and reports back the requested limit; it has not run a controlled physical experiment (battery held above the target, charger connected, competing controllers closed) to confirm the current is actually cut. Treat the limit as "macOS says it's set," not as a guarantee.

Everywhere else, the same rule applies: if a number can't be measured, Healthy Battery shows "—" instead of inventing one. No measurement is fabricated or interpolated for display.

## Privacy

Healthy Battery runs entirely on your Mac. There is no telemetry, no analytics, and no account. The daily release check is on unless you turn it off; see [PRIVACY.md](PRIVACY.md). Diagnostics you export are saved to a local file you choose and are never sent anywhere automatically.

See [PRIVACY.md](PRIVACY.md).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for build/test commands and the rules around hardware-writing code.

If Healthy Battery is useful to you: <!-- TODO: Buy Me a Coffee link --> ☕

## Security

Found a vulnerability? Please see [SECURITY.md](SECURITY.md) — do not open a public issue.

## License

MIT — see [LICENSE](LICENSE).
