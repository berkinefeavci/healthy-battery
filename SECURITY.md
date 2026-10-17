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

Healthy Battery installs one or more small, root-owned helper tools/daemons when you use certain features (power-mode switching, MagSafe LED control). These are the parts of the app worth extra scrutiny, so here is exactly what they do:

- Each helper accepts a **fixed, allowlisted set of commands** over a local, root-owned Unix domain socket or a one-shot privileged process invocation — for example `M B|C|A 0|1|2` for power-mode profile writes, or a single-byte enum write for the MagSafe LED key. There is no general shell execution, no arbitrary file path, and no arguments beyond the fixed set.
- **No password is stored or transmitted** by Healthy Battery or its helpers. The one-time administrator approval macOS asks for on first install is handled entirely by the OS (`osascript ... with administrator privileges`); Healthy Battery never sees or keeps the credential.
- Helpers only accept commands from the local, registered user (UID) that installed them — not from other users on a shared Mac, and not over the network. There is no network listener anywhere in Healthy Battery.
  The check is by user ID only, not by code signature: any process running as that same user can send the same fixed commands (change the power mode or the LED).
- **Install-time checks.** The helper is copied from the app bundle to its root-owned path and its code signature is verified *on that root-owned copy* before it is ever run; a failed check deletes it and aborts the install. A Developer ID release requires the helper to carry the app's own Team ID. An ad-hoc (locally built) app has no Team ID to pin, so there the check only proves the signature is intact — it cannot tell a re-signed replacement from the original. The LaunchDaemon plist is written from a copy built into the app, not read from the bundle.
- Helpers write to specific, known targets only (a single SMC key for the LED, `pmset` power-profile arguments for power mode). They do not touch the file system beyond their own plist/log files, and they do not read or transmit personal data.

If you find a way to get a helper to run something outside its fixed allowlist, that's exactly the kind of report we want — please report it privately as above.
