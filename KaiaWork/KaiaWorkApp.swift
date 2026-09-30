import SwiftData
import SwiftUI

@main
struct KaiaWorkApp: App {
    var body: some Scene {
        WindowGroup {
            DeskRoot()
        }
        .modelContainer(DeskStore.container)
        #if os(macOS)
        MenuBarExtra("Kaia", systemImage: "timer") {
            MenuCapsule()
                .modelContainer(DeskStore.container)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

enum DeskStore {
    static let usedMemoryOnly: Bool = {
        _ = container
        return memoryFallback
    }()

    private static var memoryFallback = false

    static let container: ModelContainer = {
        let schema = Schema([
            JobRecord.self,
            TaskRecord.self,
            TodoRecord.self,
            SessionRecord.self,
            NoteRecord.self,
        ])
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration("KaiaWork"))
        } catch {
            memoryFallback = true
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Kaia could not open a database: \(error.localizedDescription)")
            }
        }
    }()
}
