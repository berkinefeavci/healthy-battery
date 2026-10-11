import Foundation
import Security

/// Pure ownership/permission/socket trust check shared by every privileged root helper
/// (LED control, power-mode control). Kept separate from `FileManager` so the rule itself —
/// root-owned, not group/world-writable, and its control socket present — is unit-testable
/// without touching real system paths.
enum HelperInstallState {
    static func isTrusted(ownerUID: Int?, posixPermissions: Int?, socketExists: Bool) -> Bool {
        guard let ownerUID, ownerUID == 0,
              let posixPermissions, posixPermissions & 0o022 == 0 else { return false }
        return socketExists
    }

    /// Root shell step run after a helper binary is copied to its root-owned path and before it is
    /// ever executed. The app bundle is user-writable, so its bundled helper could have been swapped;
    /// checking the root-owned copy leaves no window to swap it again. A Developer ID build pins the
    /// helper to the app's own Team ID. An ad-hoc (local/dev) build has no identity to pin, so it
    /// can only require an intact signature — that does not stop a re-signed replacement.
    static func signatureCheckCommand(installedPath: String, teamIdentifier: String?) -> String {
        let path = shellQuoted(installedPath)
        var verify = "/usr/bin/codesign --verify --strict"
        if let teamIdentifier, isValidTeamIdentifier(teamIdentifier) {
            verify += " -R " + shellQuoted("=anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
        }
        return "(\(verify) \(path) || { /bin/rm -f \(path); false; })"
    }

    static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Same content as `Packaging/<label>.plist`. The daemon plist is written from here instead of
    /// being copied out of the user-writable app bundle, where a swapped plist could point launchd
    /// at any program and run it as root.
    static func launchDaemonPlistLines(label: String, helperPath: String) -> [String] {
        [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\"><dict>",
            "<key>Label</key><string>\(label)</string>",
            "<key>ProgramArguments</key><array><string>\(helperPath)</string><string>--daemon</string></array>",
            "<key>RunAtLoad</key><true/>",
            "<key>KeepAlive</key><true/>",
            "<key>ThrottleInterval</key><integer>10</integer>",
            "<key>ProcessType</key><string>Background</string>",
            "</dict></plist>",
        ]
    }

    /// Root shell step that (re)writes `/Library/LaunchDaemons/<label>.plist`. Each line is its own
    /// single-quoted argument, so the command carries no literal newlines through AppleScript.
    static func writeLaunchDaemonPlistCommand(label: String, helperPath: String) -> String {
        let destination = shellQuoted("/Library/LaunchDaemons/\(label).plist")
        let lines = launchDaemonPlistLines(label: label, helperPath: helperPath).map(shellQuoted).joined(separator: " ")
        return "/bin/rm -f \(destination) && (umask 022; /usr/bin/printf '%s\\n' \(lines) > \(destination)) && " +
            "/usr/sbin/chown root:wheel \(destination) && /bin/chmod 644 \(destination)"
    }

    /// Root shell step that removes a helper installed under the previous "ChargeMate" identity.
    static func legacyCleanupCommand(daemonLabel: String, binaryPath: String) -> String {
        "(/bin/launchctl bootout system/\(daemonLabel) 2>/dev/null || true) && " +
            "/bin/rm -f \(shellQuoted(binaryPath)) \(shellQuoted("/Library/LaunchDaemons/\(daemonLabel).plist")) && "
    }

    /// The one admin shell command that installs a root helper: copy → verify the root-owned copy's signature
    /// → write the daemon plist → authorize this user → (re)load. Every variable part is quoted for the shell.
    /// `legacyCleanup` (see `legacyCleanupCommand`) runs first when an older identity left a helper behind.
    static func installCommand(label: String, helperPath: String, bundledHelperPath: String,
                               teamIdentifier: String?, uid: uid_t, legacyCleanup: String = "") -> String {
        legacyCleanup +
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools && " +
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuoted(bundledHelperPath)) \(shellQuoted(helperPath)) && " +
            signatureCheckCommand(installedPath: helperPath, teamIdentifier: teamIdentifier) + " && " +
            writeLaunchDaemonPlistCommand(label: label, helperPath: helperPath) + " && " +
            "\(shellQuoted(helperPath)) --authorize-uid \(uid) && " +
            "(/bin/launchctl bootout system/\(label) 2>/dev/null || true) && " +
            "/bin/launchctl bootstrap system /Library/LaunchDaemons/\(label).plist"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Result of `helperVersion` lookups, keyed by file identity. A helper binary only changes when it is
    /// installed again, so asking it `--version` (a process launch) on every check is wasted work.
    private static var versionCache: [String: (stamp: String, version: Int?)] = [:]
    private static let versionCacheLock = NSLock()

    /// `read` (normally: run `<helper> --version`) is only called when the file at `path` is new or changed
    /// (inode, size, modification time). A missing file or a failed read is never cached.
    static func cachedVersion(atPath path: String, read: () -> Int?) -> Int? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let stamp = "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        versionCacheLock.lock()
        if let hit = versionCache[path], hit.stamp == stamp { versionCacheLock.unlock(); return hit.version }
        versionCacheLock.unlock()
        let version = read()
        if version != nil {
            versionCacheLock.lock()
            versionCache[path] = (stamp, version)
            versionCacheLock.unlock()
        }
        return version
    }

    /// Runs `<path> --version` and parses the number it prints.
    static func readVersion(ofHelperAt path: String) -> Int? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Team ID of the running app's signature, or nil for ad-hoc/unsigned builds.
    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Runs one shell command with administrator privileges through `osascript`. The AppleScript is fixed and
/// the command is handed over as data (`item 1 of argv`), never spliced into the script text, so no path,
/// label or quote inside the command can break out of an AppleScript string. The command itself must still
/// quote every variable part for the shell (`HelperInstallState.shellQuoted`).
enum AdminAuthorization {
    enum Failure: Error, Equatable {
        /// The user dismissed the password prompt. Nothing ran; this is not a hardware or install failure.
        case cancelled
        case failed(String)
    }

    static let scriptLines = [
        "on run argv",
        "do shell script (item 1 of argv) with administrator privileges",
        "end run",
    ]

    /// `--` ends osascript's own option parsing, so a command can never be read as a flag.
    static func arguments(forCommand command: String) -> [String] {
        scriptLines.flatMap { ["-e", $0] } + ["--", command]
    }

    /// AppleScript reports a dismissed prompt as error -128, whatever the system language.
    static func failure(forOutput output: String) -> Failure {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.contains("(-128)") ? .cancelled : .failed(detail)
    }

    static func run(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments(forCommand: command)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure(forOutput: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
