import Foundation
import Security

@main enum UpdateInstallerTests {
    static func main() {
        // Download URLs: only this repo's release assets, only plain versions and DMG files.
        precondition(UpdatePackage.downloadURL(version: "1.1.4", file: "Healthy-Battery-1.1.4.dmg")?.absoluteString
                     == "https://github.com/berkinefeavci/healthy-battery/releases/download/v1.1.4/Healthy-Battery-1.1.4.dmg")
        precondition(UpdatePackage.downloadURL(version: "1.1.4", file: "Healthy-Battery-1.1.4.dmg.sha256") != nil)
        precondition(UpdatePackage.downloadURL(version: "1.1.4-beta", file: "Healthy-Battery-1.1.4-beta.dmg") == nil)
        precondition(UpdatePackage.downloadURL(version: "1.1.4", file: "Other.dmg") == nil)
        precondition(UpdatePackage.downloadURL(version: "1.1.4", file: "Healthy-Battery-1.1.4.dmg/../x") == nil)
        precondition(UpdatePackage.downloadURL(version: "../1", file: "Healthy-Battery-../1.dmg") == nil)

        // Checksum file parsing.
        let hash = String(repeating: "ab", count: 32)
        precondition(UpdatePackage.expectedChecksum(in: "\(hash)  Cellkeep-1.1.4.dmg\n", for: "Cellkeep-1.1.4.dmg") == hash)
        precondition(UpdatePackage.expectedChecksum(in: "\(hash.uppercased()) *Cellkeep-1.1.4.dmg", for: "Cellkeep-1.1.4.dmg") == hash)
        precondition(UpdatePackage.expectedChecksum(in: "\(hash)  Cellkeep-1.1.3.dmg", for: "Cellkeep-1.1.4.dmg") == nil)
        precondition(UpdatePackage.expectedChecksum(in: "abc  Cellkeep-1.1.4.dmg", for: "Cellkeep-1.1.4.dmg") == nil)
        precondition(UpdatePackage.expectedChecksum(in: "", for: "Cellkeep-1.1.4.dmg") == nil)

        // SHA-256 of a known file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeep-sha-\(UUID().uuidString)")
        try! Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        precondition(try! UpdatePackage.sha256Hex(of: file)
                     == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // The swap script takes paths only as positional arguments and restores on failure.
        precondition(UpdatePackage.swapScript.contains("pid=\"$1\"; staged=\"$2\"; target=\"$3\""))
        precondition(UpdatePackage.swapScript.contains("mv \"$backup\" \"$target\""))
        // Redirects: GitHub's own hosts over https only.
        func allowed(_ text: String) -> Bool { UpdatePackage.isAllowedDownloadLocation(URL(string: text)!) }
        precondition(allowed("https://github.com/berkinefeavci/healthy-battery/releases/download/v1.1.4/x.dmg"))
        precondition(allowed("https://objects.githubusercontent.com/github-production-release-asset/1"))
        precondition(allowed("https://release-assets.githubusercontent.com/x"))
        precondition(!allowed("http://github.com/x") && !allowed("https://evil.example/x"))
        precondition(!allowed("https://github.com.evil.example/x") && !allowed("https://evilgithubusercontent.com/x"))
        precondition(!allowed("https://githubusercontent.com.evil.example/x") && !allowed("ftp://github.com/x"))

        // The downloaded app must satisfy an explicit Developer ID requirement of the running app's team.
        let requirement = UpdatePackage.developerIDRequirement(teamIdentifier: "A7V9NP35W2", bundleIdentifier: "io.github.berkinefeavci.cellkeep")!
        precondition(requirement.contains("leaf[subject.OU] = \"A7V9NP35W2\"") && requirement.contains("identifier \"io.github.berkinefeavci.cellkeep\""))
        precondition(requirement.contains("1.2.840.113635.100.6.2.6") && requirement.contains("1.2.840.113635.100.6.1.13"))
        var compiled: SecRequirement?
        precondition(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess && compiled != nil,
                     "the requirement text must be valid code-signing syntax")
        precondition(UpdatePackage.developerIDRequirement(teamIdentifier: "a7v9np35w2", bundleIdentifier: "io.github.berkinefeavci.cellkeep") == nil)
        precondition(UpdatePackage.developerIDRequirement(teamIdentifier: "A7V9NP35W2\" or anchor apple", bundleIdentifier: "x.y") == nil)
        precondition(UpdatePackage.developerIDRequirement(teamIdentifier: "A7V9NP35W2", bundleIdentifier: nil) == nil)
        precondition(UpdatePackage.developerIDRequirement(teamIdentifier: "A7V9NP35W2", bundleIdentifier: "a\" or identifier \"b") == nil)
        // No requirement (unsigned running app) never verifies anything, and a plain folder is not a signed bundle.
        precondition(UpdateInstaller.signingTeam(of: FileManager.default.temporaryDirectory, requirement: nil) == nil)
        precondition(UpdateInstaller.signingTeam(of: FileManager.default.temporaryDirectory, requirement: requirement) == nil)
        print("Update installer: URL, checksum, SHA-256 and swap-script assertions passed.")
    }
}
