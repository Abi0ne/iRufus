import Foundation
import IrufusCore

/// Persistent preferences (UserDefaults).
struct AppSettings: Equatable {
    var showUSBHardDrives = false
    var showDiskImages = false
    var verifyAfterWrite = true
    var binaryUnits = false
    var defaultHashes: Set<HashAlgorithm> = [.sha256]
    var excludedDevices: [String: String] = [:] // identityKey → display name
    var checkForUpdates = true
    var installUpdatesAutomatically = true

    private enum Key {
        static let usbHDD = "showUSBHardDrives"
        static let images = "showDiskImages"
        static let verify = "verifyAfterWrite"
        static let binary = "binaryUnits"
        static let hashes = "defaultHashes"
        static let excluded = "excludedDevices"
        static let checkUpdates = "checkForUpdates"
        static let installUpdates = "installUpdatesAutomatically"
    }

    static func load(_ d: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings()
        s.showUSBHardDrives = d.bool(forKey: Key.usbHDD)
        s.showDiskImages = d.bool(forKey: Key.images)
        s.verifyAfterWrite = d.object(forKey: Key.verify) as? Bool ?? true
        s.binaryUnits = d.bool(forKey: Key.binary)
        if let h = d.stringArray(forKey: Key.hashes) {
            let set = Set(h.compactMap(HashAlgorithm.init(rawValue:)))
            s.defaultHashes = set.isEmpty ? [.sha256] : set
        }
        s.excludedDevices = d.dictionary(forKey: Key.excluded) as? [String: String] ?? [:]
        s.checkForUpdates = d.object(forKey: Key.checkUpdates) as? Bool ?? true
        s.installUpdatesAutomatically = d.object(forKey: Key.installUpdates) as? Bool ?? true
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(showUSBHardDrives, forKey: Key.usbHDD)
        d.set(showDiskImages, forKey: Key.images)
        d.set(verifyAfterWrite, forKey: Key.verify)
        d.set(binaryUnits, forKey: Key.binary)
        d.set(defaultHashes.map(\.rawValue).sorted(), forKey: Key.hashes)
        d.set(excludedDevices, forKey: Key.excluded)
        d.set(checkForUpdates, forKey: Key.checkUpdates)
        d.set(installUpdatesAutomatically, forKey: Key.installUpdates)
    }
}
