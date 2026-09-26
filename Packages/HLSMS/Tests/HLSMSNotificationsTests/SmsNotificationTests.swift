import Foundation
import HLLocalization
import HLProtocol
import Testing
import UserNotifications
@testable import HLSMSNotifications

/// SMS-02 API 4, SMS-05 API 2 and CONN-04 step 9b: notification content, categories, removal, the extension's decoding.
@Suite("SMS notifications")
struct SmsNotificationTests {
    static let pairId = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f2a3b4c5d"

    static func new(addresses: [String] = ["+84900000123"], name: String? = "Nguyễn Văn A") -> SmsNewData {
        SmsNewData(message: SmsMessageData(messageKey: "sms:12847", threadId: 42, address: addresses[0],
                                           body: "Nhớ mang theo tài liệu", box: .inbox, ts: 1_727_150_060_456,
                                           read: false, subId: 2),
                   thread: SmsThreadData(threadId: 42, addresses: addresses, displayName: name,
                                         snippet: "Nhớ mang theo tài liệu", lastTs: 1_727_150_060_456, unreadCount: 2))
    }

    @Test("Title, subtitle, body, grouping, category and userInfo of an SMS")
    func content() throws {
        let content = SmsNotificationBuilder.content(for: Self.new(), pairId: Self.pairId, simLabel: "SIM 2",
                                                     showPreview: true)
        #expect(content.title == "Nguyễn Văn A" && content.subtitle == "SIM 2" && content.body == "Nhớ mang theo tài liệu")
        #expect(content.threadIdentifier == "sms:\(Self.pairId):42" && content.categoryIdentifier == "HL_SMS")
        let info = try #require(SmsNotificationInfo(content.userInfo))
        #expect(info.pairId == Self.pairId && info.threadId == 42 && info.messageKey == "sms:12847")
        #expect(info.ts == 1_727_150_060_456 && info.address == "+84900000123" && info.subId == 2)
        #expect(SmsNotificationKeys.identifier(pairId: Self.pairId, messageKey: "sms:12847")
                == "sms:\(Self.pairId):sms:12847")
    }

    @Test("Previews off: the generic body; no name: the number in national format; groups get HL_SMS_GROUP")
    func hiddenAndGroups() {
        let hidden = SmsNotificationBuilder.content(for: Self.new(name: nil), pairId: Self.pairId, simLabel: nil,
                                                    showPreview: false)
        #expect(hidden.body == L10n.Sms.notificationHiddenBody && hidden.title == "090 000 0123" && hidden.subtitle.isEmpty)
        let group = SmsNotificationBuilder.content(for: Self.new(addresses: ["+84900000123", "+84900000456"], name: nil),
                                                   pairId: Self.pairId, simLabel: nil, showPreview: true)
        #expect(group.categoryIdentifier == "HL_SMS_GROUP" && group.title == "090 000 0123, 090 000 0456")
    }

    @Test("Categories: Reply with a text field and Mark as Read; groups only Mark as Read")
    func categories() throws {
        let categories = SmsNotificationBuilder.categories()
        let single = try #require(categories.first { $0.identifier == "HL_SMS" })
        #expect(single.actions.map(\.identifier) == ["HL_SMS_REPLY", "HL_SMS_MARK_READ"])
        #expect(single.actions.first is UNTextInputNotificationAction)
        #expect(!single.actions.contains { $0.options.contains(.foreground) })
        let group = try #require(categories.first { $0.identifier == "HL_SMS_GROUP" })
        #expect(group.actions.map(\.identifier) == ["HL_SMS_MARK_READ"])
    }

    @Test("Removal by userInfo: one conversation, up to read_up_to_ts; generic ones after a sync")
    func removal() {
        let delivered = [
            DeliveredNotification(identifier: "a", userInfo: ["pair_id": Self.pairId, "thread_id": 42, "ts": 100]),
            DeliveredNotification(identifier: "b", userInfo: ["pair_id": Self.pairId, "thread_id": 42, "ts": 200]),
            DeliveredNotification(identifier: "c", userInfo: ["pair_id": Self.pairId, "thread_id": 7, "ts": 100]),
            DeliveredNotification(identifier: "d", userInfo: ["p": Self.pairId, "hl": "x"]),
        ]
        #expect(SmsNotificationFilter.identifiers(in: delivered, pairId: Self.pairId, threadId: 42, upToTs: 150) == ["a"])
        #expect(SmsNotificationFilter.identifiers(in: delivered, pairId: Self.pairId, threadId: 42, upToTs: nil) == ["a", "b"])
        let generic = SmsNotificationFilter.genericIdentifiers(in: delivered)
        #expect(generic == ["d"])
    }

    @Test("Responses: Reply with its text, Mark as Read, a tap; other actions and foreign notifications are not ours")
    func responses() {
        let userInfo: [AnyHashable: Any] = [SmsNotificationKeys.pairId: "p", SmsNotificationKeys.threadId: NSNumber(value: 7)]
        let info = SmsNotificationInfo(userInfo)
        #expect(info != nil)
        guard let info else { return }
        #expect(SmsNotificationResponse(actionIdentifier: SmsNotificationKeys.replyAction, userInfo: userInfo, userText: "Ok")
            == .reply(info, text: "Ok"))
        #expect(SmsNotificationResponse(actionIdentifier: SmsNotificationKeys.replyAction, userInfo: userInfo,
                                        userText: nil) == nil)
        #expect(SmsNotificationResponse(actionIdentifier: SmsNotificationKeys.markReadAction, userInfo: userInfo,
                                        userText: nil) == .markRead(info))
        #expect(SmsNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo,
                                        userText: nil) == .open(info))
        #expect(SmsNotificationResponse(actionIdentifier: "HL_CLIP_SEND_AGAIN", userInfo: userInfo, userText: nil) == nil)
        #expect(SmsNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["p": "x"],
                                        userText: nil) == nil)
    }

    @Test("Numbers and initials for display")
    func names() throws {
        #expect(PhoneNumberDisplay.format("+84900000123") == "090 000 0123")
        #expect(PhoneNumberDisplay.format("+842438123456") == "024 3812 3456")
        #expect(PhoneNumberDisplay.format("+14155550100") == "+14155550100")
        #expect(PhoneNumberDisplay.format("VIETTEL") == "VIETTEL")
        #expect(InitialsAvatar.initials(of: "Nguyễn Văn An") == "NA" && InitialsAvatar.initials(of: "lan") == "L")
        #expect(InitialsAvatar.initials(of: "0900") == nil && InitialsAvatar.initials(of: nil) == nil)
        let png = try #require(InitialsAvatar.pngData(for: "Nguyễn Văn An", side: 64))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}
