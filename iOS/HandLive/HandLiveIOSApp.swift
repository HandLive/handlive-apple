import HLiOSUI
import SwiftUI

/// HandLive for iPhone and iPad: the tabs of `HLiOSUI` over the model the application delegate owns.
@main
struct HandLiveIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSRootView(model: delegate.model) { delegate.registerForPush() }
        }
        .onChange(of: scenePhase) { phase in
            delegate.scenePhaseChanged(phase)
        }
    }
}
