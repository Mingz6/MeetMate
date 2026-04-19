import SwiftUI
import SwiftData

@main
struct MeetMateApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .modelContainer(for: [Meeting.self, TranscriptSegment.self])

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
