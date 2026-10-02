import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLLocalization
import HLSMS
import HLSMSUI

extension AppModel {
    /// Calls on the Mac (CALL-01…04): the call log shares the encrypted database with SMS; a quick reply and the
    /// "Message" action go out through the SMS engine (CALL-02 API 5, CALL-04 API 4).
    func startCalls() {
        calls.sendSms = { [weak self] number, subId, text in
            _ = try? await self?.smsEngine?.send(text: text, toNumber: number, subId: subId)
        }
        calls.smsCanSend = { [weak self] in self?.smsEngine?.canSend ?? false }
        calls.capabilityChanged = { [weak self] in self?.scheduleCapabilityUpdate() }
        calls.showCallList = { [weak self] in self?.showCalls() }
        alerts.onCallResponse = { [weak self] response in self?.calls.handleNotification(response) }
        calls.start(database: database)
        calls.setPair(pairedDevice)
    }

    /// The Messages window on its Calls item (CALL-04 field 10: a tap on a missed-call notification).
    public func showCalls() {
        messages?.selection = MessagesModel.callsItem
        openMessagesWindow()
    }

    /// Why calls do not work with the phone while they are on here (PAIR-02 field 8), or `nil`.
    public var callsFeatureReason: String? {
        guard let device = pairedDevice else { return nil }
        guard calls.callsEnabled else { return L10n.Pairing.reasonOffOnDevice(deviceName: self.device.name) }
        guard let capability = device.peerCapability else { return nil }
        if capability.features.call?.enabled != true { return L10n.Pairing.reasonOffOnDevice(deviceName: device.peerName) }
        if CallPermissions.missing(CallPermissions.phoneState, in: capability.permissionsMissing ?? []) {
            return L10n.Pairing.reasonMissingPermission
        }
        return nil
    }

    /// Why calls from other apps do not reach this Mac while they are on here (CALL-05), or `nil`: the phone lacks
    /// Notification access, or turned them off. Cellular calls are unaffected, so nothing is said while calls are off.
    public var appCallsFeatureReason: String? {
        guard let device = pairedDevice, calls.callsEnabled, calls.callAppCalls,
              let capability = device.peerCapability, capability.features.call?.enabled == true,
              capability.features.call?.appCalls == false else { return nil }
        if CallPermissions.missing(CallPermissions.notificationListener, in: capability.permissionsMissing ?? []) {
            return L10n.Pairing.reasonMissingPermission
        }
        return L10n.Pairing.reasonOffOnDevice(deviceName: device.peerName)
    }
}
