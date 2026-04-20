import SwiftUI
import SwiftData

@main
struct MeetMateApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MainView()
            #else
            RecordView()
            #endif
        }
        .modelContainer(for: [Meeting.self, TranscriptSegment.self])

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
