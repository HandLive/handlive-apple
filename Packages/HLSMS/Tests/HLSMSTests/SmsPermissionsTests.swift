import Foundation
import Testing
@testable import HLSMS

/// `permissions_missing` names that matter for SMS (0.7.2; SMS-01 E2, E3; SMS-04 E3; PAIR-02 field 9).
@Suite("SMS permissions of the phone")
struct SmsPermissionsTests {
    @Test("READ_SMS and SEND_SMS in short or full form are SMS permissions; contacts and others are not")
    func classify() {
        #expect(SmsPermissions.isSms("READ_SMS") && SmsPermissions.isSms("android.permission.SEND_SMS"))
        #expect(!SmsPermissions.isSms("READ_CONTACTS") && !SmsPermissions.isSms("READ_CALL_LOG"))
        #expect(!SmsPermissions.isSms("android.permission.READ_SMS_EXTRA"))
        #expect(SmsPermissions.smsMissing(in: ["READ_CALL_LOG", "SEND_SMS"]))
        #expect(!SmsPermissions.smsMissing(in: ["READ_CONTACTS"]))
        #expect(SmsPermissions.contactsMissing(in: ["android.permission.READ_CONTACTS"]))
        #expect(!SmsPermissions.contactsMissing(in: ["READ_SMS"]))
    }
}
