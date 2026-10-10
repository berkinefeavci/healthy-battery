# Changelog

## 1.4.2

- Adapter mode tests itself. Right after the charge helper is installed (or the next time the adapter is plugged in), Healthy Battery cuts the adapter for a few seconds, checks that the battery really powers the Mac, brings the adapter back, then cuts it once more without heartbeats and checks that the helper's 60-second safety timer restores it. It takes about two minutes and always ends with the adapter on. Adapter mode can be turned on only after this test passes; the result is shown in Settings → Charge Control.
- The charge helper (version 2) answers only Healthy Battery signed by the same developer. Before, any program running as your user could ask it to cut the adapter. If you installed the helper from 1.4.1, install it again from the same place.
- While Healthy Battery itself has cut the adapter, reminders no longer treat it as the cable being pulled out.

## 1.4.1

Everything since 1.2.3. Versions 1.2.4 to 1.4.0 were not published on their own.

- The panel shows the charge limit macOS is really using. If it is changed outside Healthy Battery (System Settings, a shortcut, another app), a banner says so, for example "macOS limit 80% — Healthy Battery wants 100%", with "Apply my target" and "Use the macOS value". Before, the panel kept showing the app's own target while macOS stopped at a different one.
- Settings → Charge Control: choose what happens when the limit is changed outside the app: Ask (default), Write my target back, or Adopt the macOS value.
- Top Up says which limit it goes back to when it finishes.
- Heat protection (off by default): while charging above 35 °C, the limit drops to 80% and Turbo is turned off; below 32 °C everything goes back.
- A notification when the Mac stays above 95% on power for more than 3 hours, with one click back to 80%. On by default.
- Ready by: schedule a Top Up so the battery is full at a chosen time.
- Charging habits card: time spent full, time charging while warm and average discharge depth over the last 7 days, with a short tip.
- Small reminders under the menu bar icon that disappear after 5 seconds: battery at 40% and 20%, charging while warm, plugged in while full, and a monthly calibration reminder (off by default). They never go to Notification Center. Settings → General → Reminders.
- Adapter mode (experimental, off by default): on Macs where macOS no longer lets apps pause charging, the Mac runs from the battery at the target and the adapter comes back 5 points lower, only while awake. It needs a new helper, installed once with an administrator password, which always gives power back after 60 seconds without the app, on unplug, on sleep and below 10%. It has not been tested on hardware yet.
- Fixed a crash that closed the panel on its own: the Schedule rows ran `pmset` on every redraw.
- With "Show panel at launch" on, the panel opened in the bottom-left corner. It now opens under the menu bar icon.
- English showed discharge depth as "%29" instead of "29%".
- The app icon follows the system appearance on macOS 26 and later: light, dark and tinted. Older macOS versions keep a regular icon with the same design.

## 1.2.3

- General Settings now has separate GitHub links for bug reports and feature suggestions. Diagnostic files are shared only when you attach them yourself.
- The README points to the same support channel and removes a placeholder donation link.

## 1.2.2

- The app is now called Healthy Battery. Existing settings, history, charge helpers and bundle identity stay in place.
- New GitHub downloads use `Healthy-Battery-1.2.2.dmg` with `Healthy Battery.app`. The release also includes `Cellkeep-1.2.2.dmg` with `Cellkeep.app` so installed Cellkeep 1.2.1 copies can update normally.
- Update checks and release links now use `berkinefeavci/healthy-battery`. A small `berkinefeavci/cellkeep` compatibility repository serves the 1.2.2 release expected by installed 1.2.1 copies.

## 1.2.1

- MagSafe Light: the "System" test button no longer replaces the saved light policy. Before, pressing it saved "Let the system manage it" over a chosen night window, and the page then also reset the window to 00:00–00:00, so the light stayed on at night. The button is gone; "End test" (was "Back to start") goes back to the saved policy, and the Shortcuts "System" option does the same.
- The page no longer copies 0:00 times from "System" or "Always off" into the time range; a range broken that way goes back to 22:00–08:00.
- A manual test that paused the automatic light setting is now shown on the policy card with a "Resume" button, and Cellkeep resumes it on its own when it opens.
- Policy and test messages appear only in their own card, and only failures are shown in orange. The Green and Orange test buttons show their colour.

## 1.2.0

- Cellkeep now tells you when a new version is out: one macOS notification per version. Clicking it opens Settings → About, where "Update" downloads, verifies and installs it as before, without visiting GitHub.
- The release check runs once a day and is on unless you turned it off; a choice to keep it off is kept. Both the check and the notification can be turned off in Settings → About.
- New app icon.

## 1.1.7

- Maximum capacity now matches macOS: it uses the battery's nominal capacity over its design capacity and stops at 100%, the same way System Settings shows it. Before, Cellkeep used the full charge capacity, which the battery gauge re-estimates with temperature and load, so it moved between about 97% and 101% within a day.
- That full charge figure is still shown, as "Usable capacity" (for example 8500 mAh · 99.1%), next to the design capacity.
- The capacity chart is at least five points tall (usually 95–100%) and never goes above 100%, so a one-point change no longer looks like a sudden drop. Older readings above 100% are drawn at 100%.

## 1.1.6

- MagSafe Light tests no longer get stuck. Switching from one test colour to another writes the new colour directly; before, Cellkeep first restored the old colour and then wrote the new one, two waits of about 8 seconds each, and any hiccup left the page blocked until a restore.
- "System" hands the light back to macOS instead of writing a value it then tried to read back: macOS shows its own colour in that mode, so that check could never pass.
- "Back to start" and any half-finished test re-apply the light policy chosen on the page (for example Always off), instead of forcing the colour that happened to be showing before the test.
- A test colour reports done as soon as the light reads back the new colour, instead of waiting about 8 seconds for the helper's own settle check.

## 1.1.5

- Panel edit mode no longer freezes Cellkeep. Cards used AppKit drag-and-drop, which kept the panel re-laying out every frame (100% CPU) from entering edit mode, so pressing Done hung the app. Cards are now dragged with a plain SwiftUI gesture.
- Long-press anywhere on a card to edit, including on charts (before, only the text took the press).
- Remove and resize controls are drawn above the cards instead of behind them.
- Resize from the card's bottom-right corner like a Home Screen widget: drag left for square, right for wide, or click to switch.
- Calmer wobble: on entering edit mode each card wobbles briefly and settles, each at its own tempo, instead of shaking non-stop.
- Square chart cards draw the chart edge to edge, like the wide ones; only the title and value are inset.
- Add card, Cancel and Done sit in a bar pinned to the bottom of the panel; "Add card" lists every card and chart not on the panel.

## 1.1.4

- In-app update: "Update" downloads the new release, checks its checksum, Developer ID signature and Apple notarization, then replaces Cellkeep and relaunches it. If any check fails, nothing is installed and the release page is offered.
- Panel edit mode: long-press a card (or right-click → Edit cards) to edit; the Edit button is gone. Remove and resize buttons sit on the card corners instead of covering the title, cards are dragged to reorder, and missing cards and charts are added from chips at the bottom.
- Battery info card: in edit mode, tick which rows to show (health, battery, electrical, power adapter), one by one or a whole group.
- MagSafe Light: "Apply" waits until the current light helper is installed and says how to install it, instead of hanging with an older helper.

## 1.1.3

- Menu bar panel: the locked Discharge action is a small icon, so "Limit" and "Top Up" keep their full labels in every language.
- Charge Control: the status header ("Holding the limit: 80%", "Top Up: 73% → 100%") is translated instead of staying in Turkish.
- Settings sidebar: the status badge reads "Verified" on one line instead of a cut-off "macOS limit · ver…".
- Dashboard: the cycle-count card no longer shows the raw temperature sensor id; it moved to the card's tooltip.

## 1.1.2

- English, German, French and Spanish: percentages read "62%" (or "62 %") instead of the Turkish "%62", chart ranges and durations use h/min, and the "Automations" sidebar heading is translated.

## 1.1.1

- Menu bar panel: toolbar labels stay on one line instead of wrapping mid-word; the limit reads "Sınır: %80" in Turkish, and the French and Spanish Top Up labels are shorter.
- Homebrew: upgrades keep Cellkeep's helpers; `brew uninstall --zap --cask cellkeep` removes them.

## 1.1.0

- Languages: English, German, French and Spanish, plus a language picker in Settings → General.
- Optional system-wide shortcut (⌃⌥⌘B or ⌃⌥⌘C) that opens and closes the menu bar panel.
- Long-term battery health trend, charging statistics, and CSV export of history and daily summaries.
- Detects other charge-limit tools (AlDente, Battery Toolkit, BatFi, batt, battery, bclm), not just AlDente; the MagSafe LED helper also steps aside while AlDente, Battery Toolkit, BatFi or batt is running. Existing LED helpers ask to be reinstalled once.
- Optional, off-by-default check for a newer release.
- Homebrew: `brew install --cask berkinefeavci/cellkeep/cellkeep`.

## 1.0.0 — first public release

First public release, under the name Cellkeep (previously developed internally as "ChargeMate").

- Native charge limit (80–100%, 5% steps) through macOS's own charge-control mechanism, with an independent read-back check on apply.
- Top Up: temporary charge to 100%, with automatic restore of your usual limit.
- Live power-flow diagram: adapter, battery, measured CPU/display watts, and "other," plus read-only connected-device wattage when unambiguous.
- History charts (1 h / 6 h / 24 h) for charge level, power draw, and battery health (hourly-smoothed max-capacity chart).
- Power modes (Automatic / High Power / Low Power) tracked separately per power source (battery vs. adapter).
- Optional idle-sleep prevention while charging below target, with an 8-hour safety cutoff.
- Manual and scheduled MagSafe LED control via a signed, narrowly scoped privileged helper.
- Schedules with a filterable execution history.
- Eight Apple Shortcuts actions (read battery/status, apply limit, Top Up, power mode, MagSafe LED).
- High-energy-app list with per-app Quit.
- Customizable panel with square and wide widgets.
- Discharge, Sailing, heat protection, and Calibration are visible in the UI as locked — they are not implemented; see the README for why.

## Pre-1.0 history

Built and iterated on internally over several weeks (previously named "ChargeMate") through roughly 60 incremental builds: starting from a basic native charge-limit reader, then adding live power-flow measurement, history charts, connected-device detection, power-mode-per-source switching, sleep behavior, MagSafe LED control, scheduling, Apple Shortcuts support, a customizable panel, and substantial UI refinement. Locked/unverified features (Discharge, Sailing, Heat protection, Calibration) were investigated and explicitly gated off rather than shipped as fake controls.
