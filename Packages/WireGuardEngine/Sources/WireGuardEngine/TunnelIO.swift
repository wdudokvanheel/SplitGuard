// SPDX-License-Identifier: MIT

import Foundation

/// An adapter for the system's IP packet interface.
///
/// The receive closure accepts one whole IPv4 or IPv6 packet per call. Pass owned Data
/// (or a Data value whose backing storage will remain immutable while the engine retains it).
/// A false return indicates that the packet was dropped at admission. Deliver each stream
/// in read order. The engine consumes writes in order; any asynchronous writer must bound
/// its own buffering. I/O methods must not call back into device control methods.
public protocol TunnelDevice: AnyObject {
    /// Thread-safe current MTU. Use zero if padding should have no MTU cap.
    var mtu: Int { get }
    func start(receive: @escaping (Data) -> Bool) throws
    /// Cancel or detach this read registration. A later start creates a new registration.
    func stop()
    /// Release the adapter permanently.
    func close()
    /// Consume a single unpadded IP packet. Its first nibble identifies the address family.
    func write(_ packet: Data) throws
}

/// A datagram adapter. Bind returns the actual local port, including for a request of zero.
/// Bind and unbind must work repeatedly. A failed bind must release its sockets. Each receive
/// registration owns its callback for the life of that bind, even if a late call is possible
/// after unbind. Deliver packets in receive order on each socket, as owned or immutable Data.
/// Receive closures only attempt admission and may be called synchronously by an adapter.
///
/// Control and send calls are serialized by the engine. Keep send bounded in time and report
/// local send errors via throws. A successful send means the datagram was handed to the transport.
public protocol UDPTransport: AnyObject {
    func bind(port: UInt16, receive: @escaping (Data, IPEndpoint) -> Bool) throws -> UInt16
    func unbind() throws
    func send(_ datagram: Data, to destination: IPEndpoint) throws
    func setFirewallMark(_ mark: UInt32) throws
    func clearSource(for destination: IPEndpoint)
}

public extension UDPTransport {
    // Apple's reference bind has neither a firewall mark nor a cached source address.
    func setFirewallMark(_ mark: UInt32) throws {}
    func clearSource(for destination: IPEndpoint) {}
}
