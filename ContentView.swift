import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { LabDashboardView() }
                .tabItem { Label("Lab", systemImage: "flask") }
            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            NavigationStack { UsageView() }
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            NavigationStack { ExperimentView() }
                .tabItem { Label("Experiments", systemImage: "testtube.2") }
            NavigationStack { ImageTestView() }
                .tabItem { Label("Image Test", systemImage: "photo.badge.magnifyingglass") }
        }
        .tint(.indigo)
    }
}
