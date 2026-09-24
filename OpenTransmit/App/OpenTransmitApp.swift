import SwiftUI

@main struct OpenTransmitApp: App {
    @State private var library = LibraryStore()
    @State private var transfers: TransferStore
    @StateObject private var updates: AppUpdateStore

    init() {
        let transfers = TransferStore()
        _transfers = State(initialValue: transfers)
        _updates = StateObject(wrappedValue: AppUpdateStore(transfers: transfers))
    }

    var body: some Scene {
        Window("OpenTransmit", id: "main") {
            ContentView(library: library, transfers: transfers, updates: updates)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}
