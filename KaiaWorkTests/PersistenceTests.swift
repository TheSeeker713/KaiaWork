import SwiftData
import XCTest
@testable import KaiaWork

@MainActor
final class PersistenceTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("KaiaWorkTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func location(_ name: String = "KaiaWork") -> StoreLocation {
        StoreLocation(directory: root.appendingPathComponent(name, isDirectory: true))
    }

    private func container(from outcome: StoreOpenOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> (ModelContainer, RecoveryReport?) {
        switch outcome {
        case .opened(let container, let report): return (container, report)
        case .failed(let failure):
            XCTFail("Store did not open: \(failure.message)", file: file, line: line)
            throw failure
        }
    }

    func testStoreOpensAndKeepsDataAcrossReopen() throws {
        let place = location()
        do {
            let (container, report) = try container(from: StoreOpener.open(location: place, retryDelay: 0))
            XCTAssertNil(report)
            container.mainContext.insert(JobRecord(title: "Thesis", lane: .school))
            try container.mainContext.save()
        }
        XCTAssertTrue(fm.fileExists(atPath: place.storeURL.path))
        let (again, report) = try container(from: StoreOpener.open(location: place, retryDelay: 0))
        XCTAssertNil(report)
        let jobs = try again.mainContext.fetch(FetchDescriptor<JobRecord>())
        XCTAssertEqual(jobs.map(\.title), ["Thesis"])
    }

    func testCorruptStoreIsBackedUpAndFreshStoreCreated() throws {
        let place = location()
        try fm.createDirectory(at: place.directory, withIntermediateDirectories: true)
        let garbage = Data("this is not a database".utf8) + Data(repeating: 0x41, count: 8192)
        try garbage.write(to: place.storeURL)

        let (container, report) = try container(from: StoreOpener.open(location: place, retryDelay: 0))
        let backup = try XCTUnwrap(report?.backupFolder)
        XCTAssertTrue(backup.path.hasPrefix(place.recoveredDirectory.path))
        let saved = try Data(contentsOf: backup.appendingPathComponent("KaiaWork.store"))
        XCTAssertEqual(saved, garbage, "the bad file must be kept, not deleted")

        container.mainContext.insert(TodoRecord(title: "Fresh start", lane: .paid))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TodoRecord>()).count, 1)
    }

    func testEarlierStoreIsCopiedAndOriginalLeftAlone() throws {
        let legacy = StoreLocation(directory: root.appendingPathComponent("Legacy", isDirectory: true))
        do {
            let (container, _) = try container(from: StoreOpener.open(location: legacy, retryDelay: 0))
            container.mainContext.insert(JobRecord(title: "Old data", lane: .paid))
            try container.mainContext.save()
        }
        let place = location()
        let (container, report) = try container(from: StoreOpener.open(location: place, legacyURL: legacy.storeURL, retryDelay: 0))
        XCTAssertNil(report)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<JobRecord>()).map(\.title), ["Old data"])
        XCTAssertTrue(fm.fileExists(atPath: legacy.storeURL.path))
    }

    func testRollingBackupIsOncePerDayAndKeepsSeven() throws {
        let place = location()
        _ = try container(from: StoreOpener.open(location: place, retryDelay: 0))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        XCTAssertNotNil(StoreBackups.rolling(location: place, now: start))
        XCTAssertNil(StoreBackups.rolling(location: place, now: start.addingTimeInterval(60)), "second backup the same day")
        for n in 1...9 {
            XCTAssertNotNil(StoreBackups.rolling(location: place, now: start.addingTimeInterval(Double(n) * day)))
        }
        let kept = StoreBackups.folders(in: place.backupsDirectory)
        XCTAssertEqual(kept.count, 7)
        XCTAssertTrue(fm.fileExists(atPath: kept[0].appendingPathComponent("KaiaWork.store").path))
    }

    func testCountedTimeExcludesBreaks() {
        let session = SessionRecord(lane: .school, task: nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        session.startedAt = start
        session.breaks = [
            TimeSpan(start: start.addingTimeInterval(600), end: start.addingTimeInterval(900)),
            TimeSpan(start: start.addingTimeInterval(1_500), end: nil),
        ]
        // 30 minutes elapsed, a closed 5 minute break, and an open break that began at 25 minutes
        XCTAssertEqual(session.counted(to: start.addingTimeInterval(1_800)), 1_800 - 300 - 300, accuracy: 0.001)
        session.clockOut(at: start.addingTimeInterval(2_400))
        XCTAssertNotNil(session.breaks.last?.end, "clocking out closes an open break")
        XCTAssertEqual(session.counted(to: start.addingTimeInterval(9_999)), 2_400 - 300 - 900, accuracy: 0.001)
    }
}
