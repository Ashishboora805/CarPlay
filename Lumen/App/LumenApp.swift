import SwiftUI
import UIKit

@main
struct LumenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.settings)
                .environment(environment.router)
                .environment(environment.library)
                .environment(environment.channels)
                .environment(environment.epg)
                .environment(environment.player)
                .environment(environment.browser)
                .environment(environment.youtube)
                .environment(environment.network)
                .modelContainer(environment.modelContainer)
        }
        .onChange(of: scenePhase) { _, phase in
            // Foregrounding refreshes only stale sources/guides; fresh caches are left alone.
            if phase == .active {
                Task { await environment.channels.refreshAll(force: false) }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppEnvironment.shared.bootstrap()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        // SwiftUI provides the window scene delegate for the WindowGroup.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
