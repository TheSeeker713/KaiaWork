import Foundation
import SwiftData

enum Lane: String, Codable, CaseIterable, Identifiable {
    case school, paid, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .school: "School"
        case .paid: "Paid"
        case .other: "Other"
        }
    }
}

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case now, next, later, done
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TimeSpan: Codable, Hashable {
    var start: Date
    var end: Date?
}

struct ContextMark: Codable, Hashable {
    var app: String
    var at: Date
}

struct LinkRef: Codable, Hashable {
    var kind: String
    var id: UUID
    var listID: String { "\(kind):\(id.uuidString)" }
}

enum DeskJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decode<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@Model
final class JobRecord {
    var id: UUID
    var title: String
    var laneRaw: String
    var detail: String
    var createdAt: Date
    var archived: Bool

    init(title: String, lane: Lane, detail: String = "") {
        id = UUID()
        self.title = title
        laneRaw = lane.rawValue
        self.detail = detail
        createdAt = .now
        archived = false
    }

    var lane: Lane {
        get { Lane(rawValue: laneRaw) ?? .school }
        set { laneRaw = newValue.rawValue }
    }
}

@Model
final class TaskRecord {
    var id: UUID
    var title: String
    var laneRaw: String
    var jobID: UUID?
    var statusRaw: String
    var firstStep: String
    var estimateMin: Int?
    var createdAt: Date

    init(title: String, lane: Lane) {
        id = UUID()
        self.title = title
        laneRaw = lane.rawValue
        jobID = nil
        statusRaw = TaskStatus.now.rawValue
        firstStep = ""
        estimateMin = nil
        createdAt = .now
    }

    var lane: Lane {
        get { Lane(rawValue: laneRaw) ?? .school }
        set { laneRaw = newValue.rawValue }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .now }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class TodoRecord {
    var id: UUID
    var title: String
    var done: Bool
    var laneRaw: String
    var createdAt: Date

    init(title: String, lane: Lane) {
        id = UUID()
        self.title = title
        done = false
        laneRaw = lane.rawValue
        createdAt = .now
    }

    var lane: Lane {
        get { Lane(rawValue: laneRaw) ?? .school }
        set { laneRaw = newValue.rawValue }
    }
}

@Model
final class SessionRecord {
    var id: UUID
    var laneRaw: String
    var taskID: UUID?
    var jobID: UUID?
    var startedAt: Date
    var endedAt: Date?
    var breaksJSON: String
    var contextJSON: String
    var summary: String

    init(lane: Lane, task: TaskRecord?) {
        id = UUID()
        laneRaw = lane.rawValue
        taskID = task?.id
        jobID = task?.jobID
        startedAt = .now
        endedAt = nil
        breaksJSON = "[]"
        contextJSON = "[]"
        summary = ""
    }

    var lane: Lane {
        get { Lane(rawValue: laneRaw) ?? .school }
        set { laneRaw = newValue.rawValue }
    }

    var breaks: [TimeSpan] {
        get { DeskJSON.decode(breaksJSON, as: [TimeSpan].self) ?? [] }
        set { breaksJSON = DeskJSON.encode(newValue) }
    }

    var context: [ContextMark] {
        get { DeskJSON.decode(contextJSON, as: [ContextMark].self) ?? [] }
        set { contextJSON = DeskJSON.encode(newValue) }
    }

    var isOpen: Bool { endedAt == nil }

    func counted(to now: Date) -> TimeInterval {
        let end = endedAt ?? now
        var total = end.timeIntervalSince(startedAt)
        for span in breaks {
            let a = max(span.start, startedAt)
            let b = min(span.end ?? end, end)
            if b > a { total -= b.timeIntervalSince(a) }
        }
        return max(0, total)
    }
}

@Model
final class NoteRecord {
    var id: UUID
    var title: String
    var body: String
    var kind: String
    var linksJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(kind: String) {
        id = UUID()
        title = ""
        body = ""
        self.kind = kind
        linksJSON = "[]"
        createdAt = .now
        updatedAt = .now
    }

    var links: [LinkRef] {
        get { DeskJSON.decode(linksJSON, as: [LinkRef].self) ?? [] }
        set { linksJSON = DeskJSON.encode(newValue) }
    }
}
