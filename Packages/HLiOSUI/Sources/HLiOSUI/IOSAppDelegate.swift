#if os(iOS)
import HLAppCore
import HLCallNotifications
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
        let model = IOSAppModel(settings: settings, secrets: KeychainSecretStore(accessGroup: appGroup), device: device,
                                pairStoreURL: PairedDeviceStore.defaultURL(bundleIdentifier: bundle),
                                smsDatabaseURL: SmsDatabase.defaultURL(bundleIdentifier: bundle),
                                pasteboard: IOSPasteboard(settings: settings), notifications: UserNotificationsIOS(),
                                callNotifications: UserNotificationCallsIOS(), pushProvider: provider, pushTopic: bundle,
                                makeRelay: { identity in
                                    RelayConfiguration.fromBundle().map {
                                        RelayServices.live(configuration: $0, identity: identity)
                                    }
                                })
        // VoiceOver reads "Incoming call from …" when the banner comes up (CALL-01 special requirements).
        model.calls.announce = { UIAccessibility.post(notification: .announcement, argument: $0) }
        return model
    }
}

/// The application delegate: launch (SET-03 step 2), the APNs token (CONN-04 API 1), the SMS and call notification
/// categories and their actions — "Reply" and a missed call's "Message" run in a background task of about 20 s (SMS-04
/// API 5), "Decline" within 15 s (CALL-02 API 6) — and the scene phase.
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
        center.setNotificationCategories(SmsNotificationBuilder.categories()
            .union(CallNotificationBuilder.mobileCategories()))
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

    /// While the app is open it shows messages itself: no banner for HandLive's own notifications. An incoming call
    /// becomes the in-app banner; a missed call stays in Notification Center only (CALL-01 API 6 logic 3).
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        return await presentation(info: CallNotificationInfo(userInfo), push: PushAlertFields(userInfo: userInfo))
    }

    private func presentation(info: CallNotificationInfo?, push: PushAlertFields?) -> UNNotificationPresentationOptions {
        model.foregroundPresentation(info: info, push: push) ?? []
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let text = (response as? UNTextInputNotificationResponse)?.userText
        if let call = CallNotificationResponse(actionIdentifier: response.actionIdentifier, userInfo: userInfo,
                                               userText: text) {
            await handle(call)
        } else if let sms = SmsNotificationResponse(actionIdentifier: response.actionIdentifier, userInfo: userInfo,
                                                    userText: text) {
            await handle(sms)
        }
    }

    /// The system may suspend the app as soon as the delegate returns: each action runs in a background task.
    private func handle(_ response: SmsNotificationResponse) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "HandLive reply")
        await model.handleSmsNotification(response)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    private func handle(_ response: CallNotificationResponse) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "HandLive call")
        await model.handleCallNotification(response)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}
#endif
