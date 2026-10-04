import Foundation

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
        print("Update installer: URL, checksum, SHA-256 and swap-script assertions passed.")
    }
}
