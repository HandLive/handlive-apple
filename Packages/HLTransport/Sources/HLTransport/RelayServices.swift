import Foundation

/// What the connection manager needs from the relay (CONN-03, CONN-04 wake): its REST API and a way to open the
/// relay WebSocket. Tests put fakes behind both.
public struct RelayServices: Sendable {
    public let api: any RelayAPI
    public let sockets: any RelaySocketOpening

    public init(api: any RelayAPI, sockets: any RelaySocketOpening) {
        self.api = api
        self.sockets = sockets
    }

    /// The real relay of a build with `{RELAY_HOST}` configured.
    public static func live(configuration: RelayConfiguration, identity: RelayIdentity) -> RelayServices {
        RelayServices(api: RelayAPIClient(configuration: configuration, identity: identity),
                      sockets: RelaySocketConnector(configuration: configuration))
    }
}
