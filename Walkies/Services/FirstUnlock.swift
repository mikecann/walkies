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
        happened(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                 directory: URL.applicationSupportDirectory)
    }

    /// The same file operations used at launch, with a disposable directory in tests.
    /// Simulator permission failures exercise the I/O path, not iOS's encryption state.
    static func happened(protectedDataAvailable: Bool, directory: URL) -> Bool {
        let probe = directory.appending(path: "first-unlock-probe")
        return happened(protectedDataAvailable: protectedDataAvailable,
                        readProbe: { (try? Data(contentsOf: probe)) != nil },
                        makeProbe: {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("ok".utf8).write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch {
                return false
            }
        })
    }
    #endif
}
