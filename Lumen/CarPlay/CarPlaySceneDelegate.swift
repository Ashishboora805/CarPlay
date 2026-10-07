import CarPlay
import UIKit

/// CarPlay scene entry point (declared in Info.plist and returned by AppDelegate).
/// The app is a CarPlay *Audio* app: templates only, no custom views, no video.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let environment = AppEnvironment.shared
        environment.bootstrap()
        let coordinator = CarPlayCoordinator(
            interfaceController: interfaceController,
            channels: environment.channels,
            library: environment.library,
            player: environment.player,
            epg: environment.epg,
            settings: environment.settings,
            images: environment.images
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        coordinator?.stop()
        coordinator = nil
        // Playback intentionally continues on the phone/speaker after disconnecting, matching
        // the behavior of other audio apps; the user can stop it from Control Center.
    }
}
