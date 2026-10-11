# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private vulnerability reporting instead: go to this repository's **Security** tab → **Report a vulnerability**. This opens a private draft advisory that only maintainers can see until it's resolved.

If that's unavailable to you, open a normal issue asking for a private contact, without describing the vulnerability, and a maintainer will follow up.

Please include:

- Mac model and macOS version.
- Healthy Battery version (Settings → About).
- Steps to reproduce, and what you'd expect to happen instead.

## Privileged helper surface

Healthy Battery (previously Cellkeep; the helper names keep that identity so existing installs keep working) installs up to three small, root-owned helpers, each only when you use the feature that needs it. These are the parts of the app worth extra scrutiny, so here is exactly what they do:

| Helper (`/Library/PrivilegedHelperTools/…`) | Used for | What it accepts |
| --- | --- | --- |
| `io.github.berkinefeavci.cellkeep.powermode` | Power-mode switching | `M B\|C\|A 0\|1\|2` over a Unix domain socket; runs `pmset -b\|-c\|-a powermode 0\|1\|2` and nothing else |
| `io.github.berkinefeavci.cellkeep.led` | MagSafe LED control | `PING`, `P <mode> <start> <end>` and `W 0\|1\|3\|4` over a Unix domain socket; writes one known SMC key (`ACLC`) with four fixed values |
| `io.github.berkinefeavci.cellkeep.chargeinhibit` | Adapter mode (experimental, off by default) | `R`, `C`, `S 0\|1 0\|1`, `H` over a Unix domain socket; writes only the allowlisted charge-inhibit/adapter SMC keys with two fixed byte patterns, verifies every write by reading it back, and puts everything back after 60 seconds without a heartbeat, on unplug, on sleep and below 10% |

- Every helper accepts a **fixed, allowlisted set of commands**. There is no general shell execution, no arbitrary file path, and no arguments beyond the fixed set; an unknown or malformed request is refused. Values are range-checked (modes 0–2, minutes 0–1439, and so on) before anything runs.
- **No password is stored or transmitted** by Healthy Battery or its helpers. The one-time administrator approval macOS asks for on first install is handled entirely by the OS (`osascript … with administrator privileges`). The AppleScript is fixed and the install command is handed to it as an argument, never spliced into the script text; Healthy Battery never sees or keeps the credential.
- **Who may call a helper.** The socket is local (`/var/run`, no network listener anywhere in the app). A helper first checks that the connecting user is the one registered at install time (not another user on a shared Mac). A Developer ID helper then also requires the caller to be Healthy Battery itself: bundle identifier `io.github.berkinefeavci.cellkeep`, signed by the same Team ID as the helper, verified from the caller's audit token. If a Developer ID helper cannot read its own signature it refuses everyone. A locally built, ad-hoc signed helper has no Team ID to pin, so there the user-ID check is the only one: any process of that user could send the same fixed commands.
- **Install-time checks.** The helper is copied from the app bundle to its root-owned path and its code signature is verified *on that root-owned copy* before it is ever run; a failed check deletes it and aborts the install. A Developer ID release requires the helper to carry the app's own Team ID. An ad-hoc (locally built) app has no Team ID to pin, so there the check only proves the signature is intact — it cannot tell a re-signed replacement from the original. The LaunchDaemon plist is written from a copy built into the app, not read from the bundle. Helpers, plists and their state folders are root-owned and not writable by anyone else, and the daemons run only from `/Library/PrivilegedHelperTools`.
- Helpers write to specific, known targets only (a single SMC key for the LED, two allowlisted SMC channels for adapter mode, `pmset` power-profile arguments for power mode). They do not touch the file system beyond their own plist/state files, and they do not read or transmit personal data.
- **Updates.** The in-app updater downloads only `https://github.com/berkinefeavci/healthy-battery/releases/download/…` (redirects are followed only to GitHub's own hosts over https), checks the published SHA-256, then requires the app inside the DMG to be signed with a Developer ID certificate of the running app's team and bundle identifier, and accepted by Gatekeeper (notarized), before it replaces anything.

If you find a way to get a helper to run something outside its fixed allowlist, or to make it answer a caller that is not Healthy Battery, that's exactly the kind of report we want — please report it privately as above.
