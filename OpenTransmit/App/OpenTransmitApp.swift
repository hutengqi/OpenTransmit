import SwiftUI

@main struct OpenTransmitApp: App {
    @State private var library = LibraryStore()
    var body: some Scene {
        Window("OpenTransmit", id: "main") {
            ContentView(library: library)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1220, height: 780)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
