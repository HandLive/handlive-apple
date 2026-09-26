import Foundation
import HLAppCore
import HLProtocol
import HLTransport

/// First run on the Mac (SET-03), one screen at a time; every step skips itself once reached (step 1 note).
@MainActor
public final class OnboardingFlow: ObservableObject {
    public enum Step: Equatable, Sendable {
        case welcome
        case applications
        case notifications
        case notificationsDenied
        case localNetwork
        case localNetworkDenied
        case pasteGuide
        case pairing
        case paired(deviceName: String)
    }

    @Published public private(set) var step: Step
    /// SET-03 fields 3 and 16, both preset on.
    @Published public var openAtLogin = true
    @Published public var showInMenuBar = true
    /// SET-03 E2: the app could not move itself.
    @Published public private(set) var moveFailed = false
    @Published public private(set) var checking = false

    let model: AppModel
    let localNetworkProbe: @Sendable () async -> DiscoveryState

    public init(model: AppModel, startAtPairing: Bool = false,
                localNetworkProbe: @escaping @Sendable () async -> DiscoveryState = LocalNetworkProbe.run) {
        self.model = model
        self.localNetworkProbe = localNetworkProbe
        step = startAtPairing ? .pairing : .welcome
    }

    /// "Get Started" (step 3 → 4).
    public func start() {
        step = ApplicationLocation.current == .applications ? afterApplications() : .applications
    }

    /// "Move" (step 5, API 2): on success the app relaunches from /Applications.
    public func moveToApplications() {
        if !ApplicationLocation.moveToApplications() { moveFailed = true }
    }

    /// "Not Now" or "Continue" after a failed move.
    public func skipApplications() {
        step = afterApplications()
    }

    /// Step 6: login item and menu bar icon as chosen, then the notification primer (or its skip).
    private func afterApplications() -> Step {
        model.setOpenAtLogin(openAtLogin)
        model.setShowInMenuBar(showInMenuBar)
        return .notifications
    }

    /// Notification primer "Continue" (steps 7–8): ask once; a refusal shows the guide (E3).
    public func requestNotifications() async {
        checking = true
        defer { checking = false }
        var permission = await NotificationPermission.current()
        if permission == .notDetermined { permission = await NotificationPermission.request() }
        step = permission == .denied ? .notificationsDenied : afterNotifications()
    }

    public func afterNotificationsGuide() {
        step = afterNotifications()
    }

    /// macOS 15+ asks for local network access at the first browse (step 9); macOS 13–14 skip it.
    private func afterNotifications() -> Step {
        if #available(macOS 15, *) { return .localNetwork }
        return afterLocalNetwork()
    }

    /// Local network primer "Continue" (steps 9–10): browse once so the system asks; a denial shows the guide (E4).
    public func requestLocalNetwork() async {
        checking = true
        defer { checking = false }
        let state = await localNetworkProbe()
        step = state == .localNetworkDenied ? .localNetworkDenied : afterLocalNetwork()
    }

    public func afterLocalNetworkGuide() {
        step = afterLocalNetwork()
    }

    /// Step 11: the paste guide only when macOS 15.4+ asks or refuses (C10, E6).
    private func afterLocalNetwork() -> Step {
        PasteAccess.current.needsGuide ? .pasteGuide : finishSetup()
    }

    public func afterPasteGuide() {
        step = finishSetup()
    }

    /// Step 13: `setup.completed_at`, then pairing (PAIR-01 step 1), unless a phone is already paired.
    private func finishSetup() -> Step {
        model.completeSetup()
        if let device = model.pairedDevice { return .paired(deviceName: device.peerName) }
        return .pairing
    }

    /// Pairing finished (PAIR-01 step 12).
    public func paired(with name: String) {
        step = .paired(deviceName: name)
    }
}
