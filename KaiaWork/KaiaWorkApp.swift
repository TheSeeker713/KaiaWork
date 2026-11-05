import SwiftData
import SwiftUI

@main
struct KaiaWorkApp: App {
    private let store = DeskStore.shared

    var body: some Scene {
        WindowGroup {
            RootGate(store: store)
        }
        #if os(macOS)
        MenuBarExtra("Kaia", systemImage: "timer") {
            MenuGate(store: store)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
