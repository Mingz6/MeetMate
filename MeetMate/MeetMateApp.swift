import SwiftUI
import SwiftData

@main
struct MeetMateApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            if DemoMode.isActive {
                DemoMeetingView()
            } else {
                MainView()
            }
            #else
            RecordView()
            #endif
        }
        .modelContainer(for: [Meeting.self, TranscriptSegment.self], inMemory: DemoMode.isActive)

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
