import Foundation

/// One-time migration of user state from the previous "ChargeMate" identity into "Healthy Battery":
/// UserDefaults and the Application Support data folder (history, schedule, journal, policy
/// files). Pure and testable — every read/write is injected, nothing here touches the real
/// file system or `UserDefaults` directly. `IdentityMigration.run(...)` performs the copy;
/// `IdentityMigration.production()` builds the real injected environment for app launch.
enum IdentityMigration {
    static let oldDefaultsDomain = "local.chargemate.app"
    static let migratedMarkerKey = "identityMigrationV1Completed"

    struct OldDefaultsReading {
        /// Everything stored under the old bundle id's defaults domain.
        var dictionaryRepresentation: () -> [String: Any]
    }

    struct NewDefaultsStore {
        var object: (String) -> Any?
        var set: (Any, String) -> Void
        var hasMigrated: () -> Bool
        var markMigrated: () -> Void
    }

    struct FileSystem {
        var fileExists: (String) -> Bool
        var contentsOfDirectory: (String) -> [String]
        var createDirectoryIfNeeded: (String) -> Void
        /// Copies a single file; never called if the destination already exists.
        var copyItem: (String, String) -> Void
    }

    /// Runs the migration; no-ops immediately if the new domain already has the marker.
    /// Never overwrites an existing new-domain default or an existing new-domain file.
    /// A missing old data folder is fine — the file step is simply skipped.
    static func run(oldDefaults: OldDefaultsReading, newDefaults: NewDefaultsStore,
                     oldSupportDirectory: String, newSupportDirectory: String,
                     fileSystem: FileSystem) {
        guard !newDefaults.hasMigrated() else { return }

        for (key, value) in oldDefaults.dictionaryRepresentation() {
            guard newDefaults.object(key) == nil else { continue }
            newDefaults.set(value, key)
        }

        if fileSystem.fileExists(oldSupportDirectory) {
            fileSystem.createDirectoryIfNeeded(newSupportDirectory)
            for name in fileSystem.contentsOfDirectory(oldSupportDirectory) {
                let source = oldSupportDirectory + "/" + name
                let destination = newSupportDirectory + "/" + name
                guard !fileSystem.fileExists(destination) else { continue }
                fileSystem.copyItem(source, destination)
            }
        }

        newDefaults.markMigrated()
    }

    /// The real, side-effecting environment used at app launch.
    static func production(oldSupportDirectory: URL, newSupportDirectory: URL) -> (
        oldDefaults: OldDefaultsReading, newDefaults: NewDefaultsStore,
        oldSupportDirectory: String, newSupportDirectory: String, fileSystem: FileSystem
    ) {
        let oldUserDefaults = UserDefaults(suiteName: oldDefaultsDomain) ?? .standard
        let newUserDefaults = UserDefaults.standard
        let fm = FileManager.default
        return (
            oldDefaults: OldDefaultsReading(dictionaryRepresentation: { oldUserDefaults.dictionaryRepresentation() }),
            newDefaults: NewDefaultsStore(
                object: { newUserDefaults.object(forKey: $0) },
                set: { newUserDefaults.set($0, forKey: $1) },
                hasMigrated: { newUserDefaults.bool(forKey: migratedMarkerKey) },
                markMigrated: { newUserDefaults.set(true, forKey: migratedMarkerKey) }),
            oldSupportDirectory: oldSupportDirectory.path,
            newSupportDirectory: newSupportDirectory.path,
            fileSystem: FileSystem(
                fileExists: { fm.fileExists(atPath: $0) },
                contentsOfDirectory: { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] },
                createDirectoryIfNeeded: { try? fm.createDirectory(atPath: $0, withIntermediateDirectories: true) },
                copyItem: { try? fm.copyItem(atPath: $0, toPath: $1) })
        )
    }

    /// Runs the real migration once, at app launch.
    static func runIfNeeded(oldSupportDirectory: URL, newSupportDirectory: URL) {
        let env = production(oldSupportDirectory: oldSupportDirectory, newSupportDirectory: newSupportDirectory)
        run(oldDefaults: env.oldDefaults, newDefaults: env.newDefaults,
            oldSupportDirectory: env.oldSupportDirectory, newSupportDirectory: env.newSupportDirectory,
            fileSystem: env.fileSystem)
    }
}
