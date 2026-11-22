import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// `isProtectedDataAvailable` is false on every lock. Walkies' saved files and
/// Keychain item remain readable after the first unlock, so probe that protection class.
enum FirstUnlock {
    static func happened(protectedDataAvailable: Bool, readProbe: () -> Bool, makeProbe: () -> Bool) -> Bool {
        protectedDataAvailable || readProbe() || makeProbe()
    }

    #if canImport(UIKit)
    static func happened() -> Bool {
        let dir = URL.applicationSupportDirectory
        let probe = dir.appending(path: "first-unlock-probe")
        return happened(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                        readProbe: { (try? Data(contentsOf: probe)) != nil },
                        makeProbe: {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("ok".utf8).write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch {
                return false
            }
        })
    }
    #endif
}
