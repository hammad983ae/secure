import AgentHubCore
import Foundation
import Network

/// A small HTTP server for the phone page and its JSON API, on the local network.
final class RemoteServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    struct InvalidPort: LocalizedError {
        var errorDescription: String? { "The port must be between 1024 and 65535." }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "AgentHub.remote")
    private let handler: Handler

    init(port: Int, handler: @escaping Handler) throws {
        guard (1024...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw InvalidPort() }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: endpointPort)
        self.handler = handler
    }

    /// Starts listening; `onState` gets nil when ready or an error message.
    func start(onState: @escaping @Sendable (String?) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(nil)
            case let .failed(error): onState(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop connections that never finish sending a request.
        queue.asyncAfter(deadline: .now() + 20) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case let .complete(request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    Self.send(response, on: connection)
                }
            case .invalid:
                Self.send(.error(400, "Bad request"), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// IPv4 addresses of this Mac on Wi-Fi and Ethernet, for the pairing link.
    static func localAddresses() -> [String] {
        var addresses: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"),
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
        return addresses
    }
}
