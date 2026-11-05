import Foundation
import OSLog
import Observation
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let storeLog = Logger(subsystem: "com.myceliainteractive.KaiaWork", category: "store")

// MARK: - Schema

/// Version 1 of the desk. When a model changes, freeze the V1 model classes
/// inside this enum, add a KaiaSchemaV2 with the new ones, and add a stage to
/// KaiaMigrationPlan. Never edit a shipped version in place.
enum KaiaSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [JobRecord.self, TaskRecord.self, TodoRecord.self, SessionRecord.self, NoteRecord.self]
    }
}

enum KaiaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [KaiaSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Where the store lives

struct StoreLocation {
    var directory: URL

    var storeURL: URL { directory.appendingPathComponent("KaiaWork.store") }
    var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    var recoveredDirectory: URL { directory.appendingPathComponent("Recovered", isDirectory: true) }

    /// Application Support/KaiaWork. Under XCTest the hosted app uses a throwaway folder
    /// so a test run never touches real data.
    static func standard() -> StoreLocation {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaiaWorkHostedTests-\(UUID().uuidString)", isDirectory: true)
            return StoreLocation(directory: temp)
        }
        return StoreLocation(directory: URL.applicationSupportDirectory.appending(path: "KaiaWork", directoryHint: .isDirectory))
    }

    /// Where builds 0.00.01 to 0.00.03 kept the data (SwiftData's default for a named store).
    static func legacyStoreURL() -> URL {
        ModelConfiguration("KaiaWork").url
    }

    static func files(for storeURL: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
    }
}

struct RecoveryReport: Equatable {
    var backupFolder: URL

    var message: String {
        "Kaia couldn't read its saved data. The old files were not deleted. They were moved to a backup folder, and a fresh desk was started.\n\nBackup folder:\n\(backupFolder.path)"
    }
}

struct StoreFailure: Error {
    var message: String
    var folder: URL?
}

enum StoreOpenOutcome {
    case opened(ModelContainer, RecoveryReport?)
    case failed(StoreFailure)
}

// MARK: - Opening, recovering, backing up

enum StoreOpener {
    static func makeContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: Schema(versionedSchema: KaiaSchemaV1.self), url: url, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Schema(versionedSchema: KaiaSchemaV1.self),
            migrationPlan: KaiaMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func open(
        location: StoreLocation,
        legacyURL: URL? = nil,
        fileManager fm: FileManager = .default,
        now: Date = .now,
        attempts: Int = 3,
        retryDelay: TimeInterval = 0.25
    ) -> StoreOpenOutcome {
        do {
            try fm.createDirectory(at: location.directory, withIntermediateDirectories: true)
        } catch {
            storeLog.error("Could not create \(location.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(StoreFailure(message: "Kaia couldn't create its data folder. Your data has not been changed.", folder: location.directory))
        }

        let url = location.storeURL

        if !fm.fileExists(atPath: url.path), let legacyURL, fm.fileExists(atPath: legacyURL.path) {
            do {
                try importLegacy(from: legacyURL, into: location, fileManager: fm)
                storeLog.notice("Copied earlier store into \(url.path, privacy: .public)")
            } catch {
                storeLog.error("Legacy import failed: \(error.localizedDescription, privacy: .public)")
                return .failed(StoreFailure(
                    message: "Kaia found your earlier data but couldn't copy it into its new folder. The earlier data has not been touched.",
                    folder: legacyURL.deletingLastPathComponent()
                ))
            }
        }

        // Safe copy of what is on disk before anything opens or migrates it.
        StoreBackups.rolling(location: location, now: now, fileManager: fm)

        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            do {
                return .opened(try makeContainer(at: url), nil)
            } catch {
                lastError = error
                storeLog.error("Open attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < attempts { Thread.sleep(forTimeInterval: retryDelay) }
            }
        }

        let existing = StoreLocation.files(for: url).filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            return .failed(StoreFailure(
                message: "Kaia couldn't create its data store (\(lastError?.localizedDescription ?? "unknown error")). Nothing was changed.",
                folder: location.directory
            ))
        }

        let backup: URL
        do {
            backup = try moveAside(existing, into: location, now: now, fileManager: fm)
        } catch let failure as StoreFailure {
            return .failed(failure)
        } catch {
            return .failed(StoreFailure(message: "Kaia couldn't back up its unreadable data, so it left the files where they are.", folder: location.directory))
        }
        storeLog.error("Moved unreadable store to \(backup.path, privacy: .public)")

        do {
            return .opened(try makeContainer(at: url), RecoveryReport(backupFolder: backup))
        } catch {
            storeLog.error("Fresh store failed: \(error.localizedDescription, privacy: .public)")
            return .failed(StoreFailure(
                message: "Kaia backed up the unreadable data to \(backup.path) but couldn't create a fresh store (\(error.localizedDescription)).",
                folder: backup
            ))
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// Moves the store files into Recovered/<timestamp>/. Never deletes. If a move fails,
    /// whatever was already moved goes back so no stray -wal ends up beside a new store.
    private static func moveAside(_ files: [URL], into location: StoreLocation, now: Date, fileManager fm: FileManager) throws -> URL {
        var folder = location.recoveredDirectory.appendingPathComponent(timestamp(now), isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: folder.path) {
            folder = location.recoveredDirectory.appendingPathComponent("\(timestamp(now))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for file in files {
                let destination = folder.appendingPathComponent(file.lastPathComponent)
                try fm.moveItem(at: file, to: destination)
                moved.append((file, destination))
            }
        } catch {
            for item in moved.reversed() { try? fm.moveItem(at: item.to, to: item.from) }
            throw StoreFailure(message: "Kaia couldn't move its unreadable data to a backup folder, so it left everything where it is. (\(error.localizedDescription))", folder: location.directory)
        }
        return folder
    }

    /// Copies the earlier store (and its -wal and -shm, as one set) into place.
    /// The original is left untouched.
    private static func importLegacy(from legacyURL: URL, into location: StoreLocation, fileManager fm: FileManager) throws {
        let staging = location.directory.appendingPathComponent("Importing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let sources = StoreLocation.files(for: legacyURL).filter { fm.fileExists(atPath: $0.path) }
        var staged: [(copy: URL, destination: URL)] = []
        for source in sources {
            let copy = staging.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: copy)
            let suffix = String(source.path.dropFirst(legacyURL.path.count))
            staged.append((copy, URL(fileURLWithPath: location.storeURL.path + suffix)))
        }
        for item in staged {
            try fm.moveItem(at: item.copy, to: item.destination)
        }
        try? fm.removeItem(at: staging)
    }
}

enum StoreBackups {
    static let keep = 7

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// One copy a day in Backups/<yyyy-MM-dd-HHmmss>/, newest 7 kept. Failures are logged and never block opening.
    @discardableResult
    static func rolling(location: StoreLocation, now: Date = .now, keep: Int = StoreBackups.keep, fileManager fm: FileManager = .default) -> URL? {
        guard fm.fileExists(atPath: location.storeURL.path) else { return nil }
        let day = formatter("yyyy-MM-dd").string(from: now)
        let existing = folders(in: location.backupsDirectory, fileManager: fm)
        if existing.contains(where: { $0.lastPathComponent.hasPrefix(day) }) { return nil }

        let folder = location.backupsDirectory.appendingPathComponent(formatter("yyyy-MM-dd-HHmmss").string(from: now), isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in StoreLocation.files(for: location.storeURL) where fm.fileExists(atPath: file.path) {
                try fm.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
        } catch {
            storeLog.error("Backup failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: folder)
            return nil
        }

        let all = folders(in: location.backupsDirectory, fileManager: fm)
        if all.count > keep {
            for old in all.prefix(all.count - keep) { try? fm.removeItem(at: old) }
        }
        return folder
    }

    /// Oldest first (names sort by time).
    static func folders(in directory: URL, fileManager fm: FileManager = .default) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - The store the app uses

@MainActor
@Observable
final class DeskStore {
    enum State {
        case ready(ModelContainer)
        case failed(StoreFailure)
    }

    static let shared = DeskStore(location: .standard(), legacyURL: StoreLocation.legacyStoreURL())

    private(set) var state: State
    var recoveryNotice: RecoveryReport?
    private(set) var saveProblem: String?
    let location: StoreLocation
    private let legacyURL: URL?

    init(location: StoreLocation, legacyURL: URL?) {
        self.location = location
        self.legacyURL = legacyURL
        switch StoreOpener.open(location: location, legacyURL: legacyURL) {
        case .opened(let container, let report):
            state = .ready(container)
            recoveryNotice = report
        case .failed(let failure):
            state = .failed(failure)
        }
        watchLifecycle()
    }

    func retry() {
        guard case .failed = state else { return }
        switch StoreOpener.open(location: location, legacyURL: legacyURL) {
        case .opened(let container, let report):
            state = .ready(container)
            recoveryNotice = report
        case .failed(let failure):
            state = .failed(failure)
        }
    }

    /// The one place the app saves. Logs, retries once, and raises a quiet notice if it still fails.
    /// Unsaved edits stay in the context, so the next save (or Try again) picks them up.
    func save(_ context: ModelContext, reason: String = "edit") {
        guard context.hasChanges else {
            if saveProblem != nil { saveProblem = nil }
            return
        }
        do {
            try context.save()
            saveProblem = nil
            return
        } catch {
            storeLog.error("Save failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        do {
            try context.save()
            saveProblem = nil
        } catch {
            storeLog.error("Save retry failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            saveProblem = "Kaia couldn't save your last change. It is still on screen, and Kaia will keep trying."
        }
    }

    func saveNow(reason: String) {
        if case .ready(let container) = state { save(container.mainContext, reason: reason) }
    }

    private func watchLifecycle() {
        #if os(macOS)
        let names: [Notification.Name] = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
        #else
        let names: [Notification.Name] = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #endif
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.saveNow(reason: note.name.rawValue) }
            }
        }
    }

    func revealFolder(_ url: URL?) {
        #if os(macOS)
        let target = url ?? location.directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
        #endif
    }
}

// MARK: - Screens

struct RootGate: View {
    var store: DeskStore

    var body: some View {
        Group {
            switch store.state {
            case .ready(let container):
                DeskRoot()
                    .modelContainer(container)
            case .failed(let failure):
                StoreErrorView(failure: failure, onRetry: { store.retry() }, onReveal: { store.revealFolder(failure.folder) })
            }
        }
        .alert("Your desk was restored", isPresented: Binding(
            get: { store.recoveryNotice != nil },
            set: { if !$0 { store.recoveryNotice = nil } }
        )) {
            #if os(macOS)
            Button("Show backup in Finder") { store.revealFolder(store.recoveryNotice?.backupFolder) }
            #endif
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.recoveryNotice?.message ?? "")
        }
    }
}

struct MenuGate: View {
    var store: DeskStore

    var body: some View {
        switch store.state {
        case .ready(let container):
            MenuCapsule()
                .modelContainer(container)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("Kaia can't open its data").font(.headline)
                Text("Open the Kaia window for details.").foregroundStyle(.secondary)
                #if os(macOS)
                Button("Show Kaia") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
                #endif
            }
            .padding()
            .frame(width: 220)
        }
    }
}

struct StoreErrorView: View {
    var failure: StoreFailure
    var onRetry: () -> Void
    var onReveal: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Kaia can't open your desk").font(.custom("Georgia", size: 28)).fontWeight(.semibold)
            Text(failure.message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let folder = failure.folder {
                Text(folder.path).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Nothing is being edited in memory, so nothing can be lost. Your data files are safe on disk.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack {
                Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                #if os(macOS)
                Button("Reveal in Finder", action: onReveal)
                #endif
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.937, green: 0.910, blue: 0.863))
    }
}
