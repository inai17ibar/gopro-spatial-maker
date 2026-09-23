import SwiftUI

@main
struct GoProSpatialMakerApp: App {
    @StateObject private var project = ProjectState()

    var body: some Scene {
        WindowGroup("GoPro Spatial Maker") {
            ContentView()
                .environmentObject(project)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}
