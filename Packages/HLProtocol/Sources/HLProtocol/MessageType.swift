/// `type` của envelope (0.7.1): tập đã chốt cộng `session`, `camera` và `web` (P6).
public enum MessageType: String, Codable, CaseIterable, Sendable {
    case clipboard
    case sms
    case callEvent = "call_event"
    case callAudio = "call_audio"
    case pair
    case ack
    case ping
    case capability
    case session
    case camera
    case web
}
