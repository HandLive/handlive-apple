#if os(iOS)
import HLAppCore
import HLCrypto
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLTransport
import SwiftUI
import UIKit
import UserNotifications

extension IOSAppModel {
    /// The model of the running app: settings in the App Group suite, keys in the Keychain group shared with the
    /// Notification Service Extension, the SMS database in the app's own container (never opened by the extension).
    public static func live() -> IOSAppModel {
        let settings = AppSettings(defaults: UserDefaults(suiteName: appGroup) ?? .standard)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let device = LocalDevice.current(name: UIDevice.current.name, platform: pad ? .ipados : .ios)
        let bundle = Bundle.main.bundleIdentifier ?? "app.handlive.ios"
        #if DEBUG
        let provider = RelayPushTokenRequest.Provider.apnsSandbox
        #else
        let provider = RelayPushTokenRequest.Provider.apns
        #endif
        return IOSAppModel(settings: settings, secrets: KeychainSecretStore(accessGroup: appGroup), device: device,
                           pairStoreURL: PairedDeviceStore.defaultURL(bundleIdentifier: bundle),
                           smsDatabaseURL: SmsDatabase.defaultURL(bundleIdentifier: bundle),
                           pasteboard: IOSPasteboard(settings: settings), notifications: UserNotificationsIOS(),
                           pushProvider: provider, pushTopic: bundle,
                           makeRelay: { identity in
                               RelayConfiguration.fromBundle().map { RelayServices.live(configuration: $0, identity: identity) }
                           })
    }
}

/// The application delegate: launch (SET-03 step 2), the APNs token (CONN-04 API 1), the SMS notification categories
/// and their actions — "Reply" runs in a background task of about 20 s (SMS-04 API 5) — and the scene phase.
@MainActor
public final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    public let model = IOSAppModel.live()

    override public init() {
        super.init()
    }

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(SmsNotificationBuilder.categories())
        model.launch()
        if model.setupCompleted { application.registerForRemoteNotifications() } // every launch (CONN-04 API 1)
        return true
    }

    /// SET-03 step 13: after setup, the APNs token.
    public func registerForPush() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    public func application(_ application: UIApplication,
                            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.pushTokenReceived(deviceToken)
    }

    public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token: SMS and calls arrive only while the app is open; the next launch asks again.
    }

    /// The foreground connection follows the scene (CONN-02 E3).
    public func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: model.sceneBecameActive()
        case .background: model.sceneEnteredBackground()
        default: break
        }
    }

    /// While the app is open it shows messages itself: no banner for HandLive's own notifications.
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        []
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let sms = SmsNotificationResponse(actionIdentifier: response.actionIdentifier,
                                          userInfo: response.notification.request.content.userInfo,
                                          userText: (response as? UNTextInputNotificationResponse)?.userText)
        guard let sms else { return }
        await handle(sms)
    }

    private func handle(_ response: SmsNotificationResponse) async {
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "HandLive reply")
        await model.handleSmsNotification(response)
        if task != .invalid { application.endBackgroundTask(task) }
    }
}
#endif
