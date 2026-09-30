import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DeskRoot: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @Query(sort: \TaskRecord.createdAt, order: .reverse) private var tasks: [TaskRecord]
    @Query(sort: \TodoRecord.createdAt, order: .reverse) private var todos: [TodoRecord]
    @Query(sort: \JobRecord.createdAt, order: .reverse) private var jobs: [JobRecord]
    @Query(sort: \NoteRecord.updatedAt, order: .reverse) private var notes: [NoteRecord]

    @State private var lane: Lane = .school
    @State private var tray: Tray?
    @State private var tucked = false
    @State private var pinnedTask: UUID?
    @State private var now = Date.now
    @State private var leave = false
    @State private var frontName = "Kaia"

    private var openSession: SessionRecord? { sessions.first { $0.isOpen } }
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if tucked {
                CapsuleBar(open: openSession, lane: lane, now: now, onClock: clockIn, onBreak: toggleBreak, onOut: clockOut, onUntuck: { tucked = false }, onLeave: { leave = true })
                    .padding()
            } else {
                VStack(spacing: 0) {
                    topBar
                    HStack(spacing: 0) {
                        trayList
                        focus
                        if let tray {
                            TrayHost(tray: tray, lane: lane, tasks: tasks, todos: todos, jobs: jobs, notes: notes, pinned: pinnedTask, onPin: { pinnedTask = $0 }, onClose: { self.tray = nil })
                                .frame(width: 340)
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.937, green: 0.910, blue: 0.863))
        .onReceive(timer) { date in
            now = date
            #if os(macOS)
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Kaia"
            frontName = name
            if let open = openSession, name != "Kaia", name != "KaiaWork" {
                var marks = open.context
                if marks.last?.app != name {
                    marks.append(ContextMark(app: name, at: date))
                    open.context = marks
                    try? context.save()
                }
            }
            #endif
        }
        .alert("Leave Kaia?", isPresented: $leave) {
            if openSession != nil {
                Button("Clock out and leave", role: .destructive) {
                    clockOut()
                    quit()
                }
            }
            Button(openSession == nil ? "Leave" : "Keep the clock") { quit() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text(openSession == nil ? "The desk is already saved on this device." : "Clocking out writes the sitting. Keeping the clock means time continues when you come back.")
        }
        .overlay(alignment: .top) {
            if DeskStore.usedMemoryOnly {
                Text("The database didn't open. This sitting stays in memory.")
                    .font(.footnote)
                    .padding(8)
                    .background(.yellow.opacity(0.35), in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text("Kaia").font(.custom("Georgia", size: 28)).fontWeight(.semibold)
            Text("work").foregroundStyle(.secondary)
            Spacer()
            Picker("Lane", selection: $lane) {
                ForEach(Lane.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            Text(now.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
            Button(tucked ? "Untuck" : "Tuck") { tuck() }
            Button("Leave") { leave = true }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var trayList: some View {
        VStack(spacing: 4) {
            ForEach(Tray.allCases) { item in
                Button(item.title) { tray = tray == item ? nil : item }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(tray == item ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }
        .padding(6)
        .frame(width: 108)
    }

    private var focus: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    Text(openSession == nil ? "Ready" : "Focusing")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(sittingText)
                        .font(.system(size: 56, weight: .medium, design: .serif))
                        .monospacedDigit()
                    Text((openSession?.lane ?? lane).title)
                    HStack {
                        if openSession == nil {
                            Button("Clock in") { clockIn() }.buttonStyle(.borderedProminent)
                            Button("Start 2 minutes") { clockIn() }
                        } else {
                            Button("Break") { toggleBreak() }
                            Button("Clock out") { clockOut() }
                        }
                    }
                    if let task = tasks.first(where: { $0.id == pinnedTask }) {
                        Text(task.title).font(.title3)
                        TextField("First physical move", text: Bindable(task).firstStep)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text("No task pinned. Clock in anyway.")
                            .foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                    Text("Front app: \(frontName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))

                Text("Today").font(.title2.weight(.semibold))
                let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }
                if today.isEmpty {
                    Text("No sitting yet today.").foregroundStyle(.secondary)
                }
                ForEach(today) { session in
                    VStack(alignment: .leading) {
                        Text("\(session.lane.title) · \(format(session.counted(to: now))) counted")
                        if let task = tasks.first(where: { $0.id == session.taskID }) {
                            Text(task.title).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding()
        }
    }

    private var sittingText: String {
        guard let open = openSession else { return "00:00" }
        return format(now.timeIntervalSince(open.startedAt))
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func clockIn() {
        guard openSession == nil else { return }
        let task = tasks.first { $0.id == pinnedTask }
        context.insert(SessionRecord(lane: lane, task: task))
        try? context.save()
    }

    private func toggleBreak() {
        guard let open = openSession else { return }
        var spans = open.breaks
        if let index = spans.lastIndex(where: { $0.end == nil }) {
            spans[index].end = .now
        } else {
            spans.append(TimeSpan(start: .now, end: nil))
        }
        open.breaks = spans
        try? context.save()
    }

    private func clockOut() {
        guard let open = openSession else { return }
        var spans = open.breaks
        for index in spans.indices where spans[index].end == nil {
            spans[index].end = .now
        }
        open.breaks = spans
        open.endedAt = .now
        try? context.save()
    }

    private func tuck() {
        #if os(macOS)
        tucked = true
        NSApplication.shared.keyWindow?.orderOut(nil)
        #else
        tucked = true
        #endif
    }

    private func quit() {
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #else
        tucked = false
        #endif
    }
}

struct MenuCapsule: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @State private var now = Date.now
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var open: SessionRecord? { sessions.first { $0.isOpen } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(open == nil ? "Ready" : open!.lane.title).font(.headline)
            if let open {
                Text(Duration.seconds(now.timeIntervalSince(open.startedAt)).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                    .font(.title2.monospacedDigit())
                Button("Break") { toggle(open) }
                Button("Clock out") { end(open) }
            } else {
                Button("Clock in") {
                    context.insert(SessionRecord(lane: .school, task: nil))
                    try? context.save()
                }
            }
            #if os(macOS)
            Button("Show Kaia") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            #endif
        }
        .padding()
        .frame(width: 220)
        .onReceive(timer) { now = $0 }
    }

    private func toggle(_ open: SessionRecord) {
        var spans = open.breaks
        if let index = spans.lastIndex(where: { $0.end == nil }) {
            spans[index].end = .now
        } else {
            spans.append(TimeSpan(start: .now, end: nil))
        }
        open.breaks = spans
        try? context.save()
    }

    private func end(_ open: SessionRecord) {
        open.endedAt = .now
        try? context.save()
    }
}

struct CapsuleBar: View {
    var open: SessionRecord?
    var lane: Lane
    var now: Date
    var onClock: () -> Void
    var onBreak: () -> Void
    var onOut: () -> Void
    var onUntuck: () -> Void
    var onLeave: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(open?.lane.title ?? lane.title).font(.caption)
                Text(open.map { format(now.timeIntervalSince($0.startedAt)) } ?? "00:00")
                    .font(.title.monospacedDigit())
            }
            Spacer()
            if open == nil { Button("Clock in", action: onClock) }
            else {
                Button("Break", action: onBreak)
                Button("Clock out", action: onOut)
            }
            Button("Untuck", action: onUntuck)
            Button("Leave", action: onLeave)
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    }
}

enum Tray: String, CaseIterable, Identifiable {
    case tasks, todos, jobs, notes, journal, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .todos: "Todos"
        case .jobs: "Jobs"
        case .notes: "Notes"
        case .journal: "Journal"
        case .help: "Help"
        }
    }
}

struct TrayHost: View {
    @Environment(\.modelContext) private var context
    var tray: Tray
    var lane: Lane
    var tasks: [TaskRecord]
    var todos: [TodoRecord]
    var jobs: [JobRecord]
    var notes: [NoteRecord]
    var pinned: UUID?
    var onPin: (UUID?) -> Void
    var onClose: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tray.title).font(.title2.weight(.semibold))
                Spacer()
                Button("Close", action: onClose)
            }
            switch tray {
            case .tasks:
                capture("New task") {
                    let task = TaskRecord(title: draft, lane: lane)
                    context.insert(task)
                    onPin(task.id)
                    draft = ""
                    try? context.save()
                }
                ForEach(tasks.filter { $0.lane == lane }) { task in
                    VStack(alignment: .leading) {
                        Text(task.title)
                        HStack {
                            Button(pinned == task.id ? "Pinned" : "Pin") { onPin(task.id) }
                            Button("Done") { task.status = .done; try? context.save() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            case .todos:
                capture("New todo") {
                    context.insert(TodoRecord(title: draft, lane: lane))
                    draft = ""
                    try? context.save()
                }
                ForEach(todos.filter { $0.lane == lane }) { todo in
                    Toggle(todo.title, isOn: Bindable(todo).done)
                }
            case .jobs:
                capture("New job") {
                    context.insert(JobRecord(title: draft, lane: lane))
                    draft = ""
                    try? context.save()
                }
                ForEach(jobs.filter { $0.lane == lane && !$0.archived }) { job in
                    Text(job.title)
                }
            case .notes, .journal:
                Button(tray == .journal ? "New page" : "New note") {
                    context.insert(NoteRecord(kind: tray == .journal ? "journal" : "note"))
                    try? context.save()
                }
                ForEach(notes.filter { $0.kind == (tray == .journal ? "journal" : "note") }) { note in
                    TextField("Title", text: Bindable(note).title)
                    TextField("Write", text: Bindable(note).body, axis: .vertical)
                        .lineLimit(4...10)
                }
            case .help:
                Text("Clock in before the task is clear. Color is the kind of work. On Mac, the frontmost app is logged while you are clocked in. Tuck keeps the menu-bar clock. Nothing turns red because you paused.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.white.opacity(0.72))
        .onDisappear { try? context.save() }
    }

    private func capture(_ placeholder: String, add: () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
            Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
