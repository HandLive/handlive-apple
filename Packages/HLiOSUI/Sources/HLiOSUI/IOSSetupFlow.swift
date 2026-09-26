import Foundation
import HLAppCore
import HLTransport

/// First run on iPhone and iPad (SET-03): welcome, the notification primer, the local network primer, the platform
/// limits; each system dialog comes after its explanation screen with a single "Continue" (field 14), and a refusal
/// shows the way back in Settings (E3, E4). Finishing writes `setup.completed_at`, registers for push and leads to
/// pairing (step 13).
@MainActor
public final class IOSSetupFlow: ObservableObject {
    public enum Step: Equatable, Sendable {
        case welcome
        case notifications
        case notificationsDenied
        case localNetwork
        case localNetworkDenied
        case limits
    }

    @Published public private(set) var step = Step.welcome
    /// A system dialog is being answered: "Continue" waits.
    @Published public private(set) var checking = false

    let model: IOSAppModel
    let probeLocalNetwork: @Sendable () async -> DiscoveryState
    let registerForPush: @MainActor () -> Void

    public init(model: IOSAppModel, probeLocalNetwork: @escaping @Sendable () async -> DiscoveryState = LocalNetworkProbe.run,
                registerForPush: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.probeLocalNetwork = probeLocalNetwork
        self.registerForPush = registerForPush
    }

    /// "Get Started" (step 3 → 7).
    public func start() {
        step = .notifications
    }

    /// Steps 7–8: ask once; a refusal shows the guide (E3).
    public func continueFromNotifications() async {
        checking = true
        defer { checking = false }
        var permission = await model.notifications.permission()
        if permission == .notDetermined { permission = await model.notifications.requestPermission() }
        model.notificationPermission = permission
        step = permission == .denied ? .notificationsDenied : .localNetwork
    }

    public func afterNotificationsGuide() {
        step = .localNetwork
    }

    /// Steps 9–10: the first Bonjour browse makes iOS ask; a denial shows the guide (E4).
    public func continueFromLocalNetwork() async {
        checking = true
        defer { checking = false }
        let state = await probeLocalNetwork()
        step = state == .localNetworkDenied ? .localNetworkDenied : .limits
    }

    public func afterLocalNetworkGuide() {
        step = .limits
    }

    /// Steps 11–13: the limits were read; `setup.completed_at`, the push registration, then pairing.
    public func finish() {
        model.completeSetup()
        registerForPush()
    }
}
