import SwiftUI
import SwiftData

@main
struct PCCTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [PCCRequestLog.self, PCCQuotaObservation.self])
    }
}
