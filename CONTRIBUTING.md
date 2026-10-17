# Contributing

Thanks for considering a contribution to Healthy Battery (previously Cellkeep; internal names such as `Cellkeep.app`, helper labels and data folders keep that identity on purpose).

## Build and test

Requires Xcode 27, Apple Silicon Mac.

```sh
./check.sh   # pure-logic test suite, no hardware writes
./build.sh   # produces .build/Cellkeep.app
```

Read `check.sh` and `build.sh` before running them — they're plain shell scripts, not a black box.

## Translations

Healthy Battery ships in English, Turkish, German, French and Spanish. Turkish is the source language: user-facing text in the code is Turkish (`Text("…")`, `String(localized: "…")`), and each `Localization/<lang>.lproj/Localizable.strings` maps that Turkish key to its translation.

When you add or change a user-facing string, `./build.sh` will fail and list it as `MISSING` for every language. Add the key to each `Localizable.strings` (Turkish maps the key to itself). Keep format specifiers such as `%@`, `%lld` and `%%` exactly as in the key. Identifiers — enum raw values, `UserDefaults` keys, process names, SF Symbol names — must stay unwrapped.

## Rules

- **No hardware-writing tests in CI.** Anything that would write to the battery controller, SMC, `pmset`, or a privileged helper must be a pure-logic or fake-backend test that runs offline. Real hardware writes are only ever exercised manually, locally, by someone with the physical Mac in front of them.
- **No fabricated measurements.** If a value can't be read, the code shows "—" or an explicit "unavailable" state — never an estimate, interpolation, or placeholder presented as a real reading. This applies to UI, tests, and PR descriptions alike: don't claim a measurement or hardware behavior you haven't actually observed.
- Keep changes scoped and explain in the PR description what you tested and how (including what you could *not* test, e.g. "no physical MagSafe cable available").
- Match existing code style; there's no separate linter config to satisfy beyond `check.sh` passing.
