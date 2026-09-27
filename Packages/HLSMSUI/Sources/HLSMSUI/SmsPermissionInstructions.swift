import HLDesignSystem
import HLLocalization
import HLProtocol
import HLSMS
import SwiftUI

/// Why SMS does not work with the phone although it is on here (SET-02 field 24, PAIR-02 field 8, SMS-01 E1–E2).
public enum SmsPhoneProblem: Equatable, Sendable {
    /// SMS is off in the phone's settings: "Off on <phone>".
    case offOnPhone(name: String)
    /// `READ_SMS` or `SEND_SMS` is missing: "Missing SMS permission on the phone", with "View Instructions".
    case missingPermission

    /// The reason as Settings and the device details show it.
    public var text: String {
        switch self {
        case .offOnPhone(let name): L10n.Pairing.reasonOffOnDevice(deviceName: name)
        case .missingPermission: L10n.Pairing.reasonMissingSmsPermission
        }
    }

    /// The reason comes with "View Instructions" (SMS-01 field 7).
    public var hasInstructions: Bool { self == .missingPermission }

    /// From the phone's last capability; `nil` when SMS works with the phone, or nothing is known yet.
    public static func of(_ capability: CapabilityData?, phoneName: String) -> SmsPhoneProblem? {
        guard let capability else { return nil }
        if capability.features.sms?.enabled != true { return .offOnPhone(name: phoneName) }
        return SmsPermissions.smsMissing(in: capability.permissionsMissing ?? []) ? .missingPermission : nil
    }
}

extension View {
    /// The alert "Grant SMS Permission on Your Phone" with the steps on the phone and a single "OK" (SMS-01 field 7,
    /// opened by "View Instructions" and by a missing SMS permission in the device details, PAIR-02 field 9).
    public func smsPermissionInstructions(isPresented: Binding<Bool>) -> some View {
        alert(L10n.Sms.permissionInstructionsTitle, isPresented: isPresented) {
            Button(L10n.Common.ok) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(L10n.Sms.permissionInstructionsBody)
        }
    }
}

/// "View Instructions" next to "Missing SMS permission on the phone"; opens the SMS instructions alert.
public struct SmsInstructionsButton: View {
    @State private var showing = false

    public init() {}

    public var body: some View {
        Button(Self.title) { showing = true }
            .smsPermissionInstructions(isPresented: $showing)
    }

    /// "View Instructions…" on the Mac, where a button that opens an alert ends with "…" (03-platforms/01-macos.md);
    /// "View Instructions" on iPhone and iPad (SMS-01 field 7).
    nonisolated static var title: String {
        #if os(macOS)
        L10n.Common.viewInstructionsEllipsis
        #else
        L10n.Common.viewInstructions
        #endif
    }
}

/// The reason of an `SmsPhoneProblem` in `text-orange`, with "View Instructions" when it has instructions.
public struct SmsPhoneProblemRow: View {
    private let problem: SmsPhoneProblem

    public init(_ problem: SmsPhoneProblem) {
        self.problem = problem
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpacing.space8) {
            Label(problem.text, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Color.hl(.textOrange))
                .fixedSize(horizontal: false, vertical: true)
            if problem.hasInstructions { SmsInstructionsButton() }
        }
    }
}
