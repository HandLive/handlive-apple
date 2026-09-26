import Foundation
import HLLocalization
import HLProtocol
import Intents
import UserNotifications

/// SMS notifications (SMS-02 API 4) for the Mac, the iPhone/iPad app and the Notification Service Extension: the same
/// title, body, grouping, category and `userInfo` everywhere, turned into a communication notification with the
/// sender as an `INSendMessageIntent`.
public enum SmsNotificationBuilder {
    /// Title (field 1), subtitle (field 3), body (field 2, "New SMS message" when previews are off), thread and category.
    public static func content(for new: SmsNewData, pairId: String, simLabel: String?,
                               showPreview: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = SmsNames.title(of: new.thread)
        content.subtitle = simLabel ?? ""
        content.body = showPreview ? new.message.body : L10n.Sms.notificationHiddenBody
        content.threadIdentifier = SmsNotificationKeys.threadIdentifier(pairId: pairId, threadId: new.thread.threadId)
        content.categoryIdentifier = new.thread.addresses.count > 1 ? SmsNotificationKeys.groupCategory
            : SmsNotificationKeys.category
        content.userInfo = SmsNotificationKeys.userInfo(pairId: pairId, message: new.message)
        content.sound = .default
        return content
    }

    /// The communication-notification form (the sender's name and avatar, Focus filtering by sender). Falls back to the
    /// plain content when the system refuses the intent (no Communication Notifications capability).
    public static func communication(_ content: UNMutableNotificationContent, new: SmsNewData,
                                     showPreview: Bool) -> UNNotificationContent {
        let title = SmsNames.title(of: new.thread)
        let avatar = InitialsAvatar.pngData(for: new.thread.displayName).map { INImage(imageData: $0) }
        let sender = INPerson(personHandle: INPersonHandle(value: new.message.address, type: .phoneNumber),
                              nameComponents: nil, displayName: title, image: avatar, contactIdentifier: nil,
                              customIdentifier: new.message.address)
        let isGroup = new.thread.addresses.count > 1
        let recipients = isGroup ? new.thread.addresses.map {
            INPerson(personHandle: INPersonHandle(value: $0, type: .phoneNumber), nameComponents: nil,
                     displayName: PhoneNumberDisplay.format($0), image: nil, contactIdentifier: nil, customIdentifier: $0)
        } : nil
        let intent = INSendMessageIntent(recipients: recipients, outgoingMessageType: .outgoingMessageText,
                                         content: showPreview ? new.message.body : nil,
                                         speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: title) : nil,
                                         conversationIdentifier: content.threadIdentifier, serviceName: nil,
                                         sender: sender, attachments: nil)
        #if os(iOS)
        if isGroup, let avatar { intent.setImage(avatar, forParameterNamed: \.speakableGroupName) }
        #endif
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return (try? content.updating(from: intent)) ?? content
    }

    /// The request for a message of an app process (the extension's request keeps its system identifier).
    public static func request(for new: SmsNewData, pairId: String, simLabel: String?,
                               showPreview: Bool) -> UNNotificationRequest {
        let base = content(for: new, pairId: pairId, simLabel: simLabel, showPreview: showPreview)
        return UNNotificationRequest(
            identifier: SmsNotificationKeys.identifier(pairId: pairId, messageKey: new.message.messageKey),
            content: communication(base, new: new, showPreview: showPreview), trigger: nil)
    }

    /// `HL_SMS` with "Reply" (text field, "Send") and "Mark as Read"; `HL_SMS_GROUP` with "Mark as Read" only. The
    /// placeholder replaces the body when the user hides previews in the system settings.
    public static func categories() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: SmsNotificationKeys.replyAction, title: L10n.Sms.reply, options: [],
            icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: L10n.Sms.send, textInputPlaceholder: L10n.Sms.composePlaceholder)
        let markRead = UNNotificationAction(identifier: SmsNotificationKeys.markReadAction, title: L10n.Sms.markAsRead,
                                            options: [], icon: UNNotificationActionIcon(systemImageName: "envelope.open"))
        let placeholder = L10n.Sms.notificationHiddenBody
        return [
            UNNotificationCategory(identifier: SmsNotificationKeys.category, actions: [reply, markRead],
                                   intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: placeholder, options: []),
            UNNotificationCategory(identifier: SmsNotificationKeys.groupCategory, actions: [markRead],
                                   intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: placeholder, options: []),
        ]
    }
}
