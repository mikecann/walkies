#if canImport(UIKit)
import Foundation
import Testing
@testable import Walkies

/// Real reads, directory creation and protected writes from the launch path. These
/// use ordinary filesystem permissions; a simulator cannot prove locked-file encryption.
@MainActor
struct FirstUnlockFileTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "FirstUnlockFiles-\(UUID())", directoryHint: .isDirectory)
    }

    @Test func aMissingProbeAndDirectoryAreCreatedByTheLockedLaunchPath() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(FirstUnlock.happened(protectedDataAvailable: false, directory: dir))
        #expect(try Data(contentsOf: dir.appending(path: "first-unlock-probe")) == Data("ok".utf8))
    }

    @Test func aReadableProbeInANonWritableDirectoryStartsWithoutReplacingIt() throws {
        let dir = directory()
        let probe = dir.appending(path: "first-unlock-probe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data("an existing probe".utf8)
        try original.write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: probe.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: probe.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(!FileManager.default.isWritableFile(atPath: dir.path))
        #expect(FirstUnlock.happened(protectedDataAvailable: false, directory: dir))
        #expect(try Data(contentsOf: probe) == original)
    }

    @Test func anUnreadableDirectoryCannotBeReadOrRecreatedAndStartupWaits() throws {
        let dir = directory()
        let probe = dir.appending(path: "first-unlock-probe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data("keep this probe".utf8)
        try original.write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect((try? Data(contentsOf: probe)) == nil)
        #expect(!FirstUnlock.happened(protectedDataAvailable: false, directory: dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(try Data(contentsOf: probe) == original)
        #expect(FirstUnlock.happened(protectedDataAvailable: false, directory: dir))
    }

    @Test func aProbeUnderARegularFileFailsBothReadAndCreate() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("this path is a file".utf8)
        try original.write(to: dir)
        #expect(!FirstUnlock.happened(protectedDataAvailable: false, directory: dir))
        #expect(try Data(contentsOf: dir) == original)
    }

    @Test func currentlyAvailableProtectedDataBypassesAnUnusableProbePath() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("leave this file alone".utf8)
        try original.write(to: dir)
        #expect(FirstUnlock.happened(protectedDataAvailable: true, directory: dir))
        #expect(try Data(contentsOf: dir) == original)
    }
}
#endif
