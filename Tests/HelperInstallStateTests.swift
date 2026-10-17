import Foundation

@main enum HelperInstallStateTests {
    static func main() {
        // Root-owned, not group/world-writable, socket present: trusted.
        precondition(HelperInstallState.isTrusted(ownerUID: 0, posixPermissions: 0o755, socketExists: true))
        // Not root-owned: never trusted regardless of permissions/socket.
        precondition(!HelperInstallState.isTrusted(ownerUID: 501, posixPermissions: 0o755, socketExists: true))
        // Group/world-writable: never trusted even if root-owned.
        precondition(!HelperInstallState.isTrusted(ownerUID: 0, posixPermissions: 0o777, socketExists: true))
        // No socket yet (daemon not running): not trusted.
        precondition(!HelperInstallState.isTrusted(ownerUID: 0, posixPermissions: 0o755, socketExists: false))
        // Missing attributes entirely (helper not installed): not trusted.
        precondition(!HelperInstallState.isTrusted(ownerUID: nil, posixPermissions: nil, socketExists: false))

        // The embedded daemon plists must stay byte-identical to the packaged ones.
        for (label, helper) in [("io.github.berkinefeavci.cellkeep.powermode", "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode"),
                                ("io.github.berkinefeavci.cellkeep.led", "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led")] {
            let packaged = try! String(contentsOfFile: "Packaging/\(label).plist", encoding: .utf8)
            let embedded = HelperInstallState.launchDaemonPlistLines(label: label, helperPath: helper).joined(separator: "\n") + "\n"
            precondition(embedded == packaged, "embedded plist drifted from Packaging/\(label).plist")
            let write = HelperInstallState.writeLaunchDaemonPlistCommand(label: label, helperPath: helper)
            precondition(!write.contains("\n") && write.contains("/usr/sbin/chown root:wheel"))
        }

        // Team IDs: exactly ten uppercase letters/digits; anything else is never interpolated.
        precondition(HelperInstallState.isValidTeamIdentifier("ABCDE12345"))
        precondition(!HelperInstallState.isValidTeamIdentifier("abcde12345"))
        precondition(!HelperInstallState.isValidTeamIdentifier("ABCDE1234"))
        precondition(!HelperInstallState.isValidTeamIdentifier("ABCDE1234'"))
        let pinned = HelperInstallState.signatureCheckCommand(installedPath: "/x/helper", teamIdentifier: "ABCDE12345")
        precondition(pinned.contains("leaf[subject.OU] = \"ABCDE12345\"") && pinned.contains("/bin/rm -f '/x/helper'"))
        let adHoc = HelperInstallState.signatureCheckCommand(installedPath: "/x/helper", teamIdentifier: nil)
        precondition(!adHoc.contains(" -R ") && adHoc.hasPrefix("(/usr/bin/codesign --verify --strict '/x/helper'"))
        let injected = HelperInstallState.signatureCheckCommand(installedPath: "/x/helper", teamIdentifier: "A'; rm -rf /")
        precondition(!injected.contains("rm -rf"))
        precondition(HelperInstallState.shellQuoted("a'b") == "'a'\\''b'")

        // One shared admin runner: the AppleScript is fixed, the command travels as data after "--".
        let hostile = "/bin/echo \"x\" 'y' \\ $(id) -rf"
        let arguments = AdminAuthorization.arguments(forCommand: hostile)
        precondition(arguments.suffix(2) == ["--", hostile], "command is an argument, never part of the script")
        precondition(!arguments.dropLast(2).contains { $0.contains("echo") }, "script text never contains the command")
        precondition(arguments.dropLast(2).filter { $0 == "-e" }.count == AdminAuthorization.scriptLines.count)
        precondition(AdminAuthorization.scriptLines.contains("do shell script (item 1 of argv) with administrator privileges"))
        precondition(AdminAuthorization.failure(forOutput: "7:30: execution error: User canceled. (-128)\n") == .cancelled)
        precondition(AdminAuthorization.failure(forOutput: "8:40: Benutzer hat abgebrochen. (-128)") == .cancelled)
        precondition(AdminAuthorization.failure(forOutput: " install: x: Permission denied (1)\n") == .failed("install: x: Permission denied (1)"))
        precondition(AdminAuthorization.failure(forOutput: "") == .failed(""))

        // The shared install command quotes every variable part and keeps the order copy → verify → authorize → load.
        let install = HelperInstallState.installCommand(label: "io.example.helper", helperPath: "/Library/PrivilegedHelperTools/io.example.helper",
                                                        bundledHelperPath: "/Apps/it's here/Helper", teamIdentifier: "ABCDE12345", uid: 501)
        precondition(install.contains("'/Apps/it'\\''s here/Helper'") && install.contains("--authorize-uid 501"))
        precondition(install.range(of: "codesign --verify")!.lowerBound < install.range(of: "--authorize-uid")!.lowerBound)
        precondition(install.range(of: "--authorize-uid")!.lowerBound < install.range(of: "launchctl bootstrap")!.lowerBound)
        precondition(install.contains("install -o root -g wheel -m 755") && !install.contains("\n"))
        let legacy = HelperInstallState.legacyCleanupCommand(daemonLabel: "local.old", binaryPath: "/Library/PrivilegedHelperTools/old tool")
        precondition(legacy.contains("'/Library/PrivilegedHelperTools/old tool'") && legacy.hasSuffix(" && "))
        precondition(HelperInstallState.installCommand(label: "a", helperPath: "/h", bundledHelperPath: "/b", teamIdentifier: nil,
                                                       uid: 1, legacyCleanup: legacy).hasPrefix(legacy))

        // A helper's `--version` (a process launch) is read once per file identity, never cached when it fails.
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeep-helper-\(UUID().uuidString)")
        try! Data("one".utf8).write(to: helper)
        defer { try? FileManager.default.removeItem(at: helper) }
        var reads = 0
        precondition(HelperInstallState.cachedVersion(atPath: helper.path, read: { reads += 1; return 3 }) == 3)
        precondition(HelperInstallState.cachedVersion(atPath: helper.path, read: { reads += 1; return 9 }) == 3 && reads == 1)
        try! Data("a different binary".utf8).write(to: helper)
        precondition(HelperInstallState.cachedVersion(atPath: helper.path, read: { reads += 1; return 4 }) == 4 && reads == 2)
        precondition(HelperInstallState.cachedVersion(atPath: helper.path + ".missing", read: { reads += 1; return 1 }) == nil && reads == 2)
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeep-helper-\(UUID().uuidString)")
        try! Data("x".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        precondition(HelperInstallState.cachedVersion(atPath: broken.path, read: { reads += 1; return nil }) == nil)
        precondition(HelperInstallState.cachedVersion(atPath: broken.path, read: { reads += 1; return 2 }) == 2, "a failed read is retried")
        print("Helper install state: ownership/permission/socket trust, plist and signature assertions passed.")
    }
}
