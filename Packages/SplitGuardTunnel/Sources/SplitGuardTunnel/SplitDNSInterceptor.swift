// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

/// Packet hook that intercepts outbound UDP/53 queries for excluded split-DNS names,
/// resolves them via `PhysicalResolver` on the physical network interface, and injects
/// synthesized UDP DNS replies back into the tunnel interface.
public final class SplitDNSInterceptor: PacketHook, @unchecked Sendable {
    private struct LookupKey: Hashable {
        let name: String
        let type: UInt16
        let recordClass: UInt16
    }

    private struct PendingWaiter {
        let datagram: UDPDatagram
        let query: DNSQuery
    }

    public static let defaultMaxPendingLookups = 64
    private static let maxPendingWaiters = 256
    private static let maxWaitersPerLookup = 16

    private let configuration: SplitDNSConfiguration
    private let dnsServers: [IPAddress]
    private let resolver: any PhysicalResolver
    private let interfaceIndexProvider: @Sendable () -> UInt32?
    private let deliverToTunnel: @Sendable (Data) throws -> Void
    private let logHandler: @Sendable (TunnelLogLevel, String) -> Void
    private let maxPendingLookups: Int

    private let lock = NSLock()
    private var pending: [LookupKey: [PendingWaiter]] = [:]
    private var pendingWaiterCount = 0

    public init(
        configuration: SplitDNSConfiguration,
        dnsServers: [IPAddress],
        resolver: any PhysicalResolver,
        interfaceIndexProvider: @escaping @Sendable () -> UInt32?,
        deliverToTunnel: @escaping @Sendable (Data) throws -> Void,
        logHandler: @escaping @Sendable (TunnelLogLevel, String) -> Void = { _, _ in },
        maxPendingLookups: Int = SplitDNSInterceptor.defaultMaxPendingLookups
    ) {
        self.configuration = configuration
        self.dnsServers = dnsServers
        self.resolver = resolver
        self.interfaceIndexProvider = interfaceIndexProvider
        self.deliverToTunnel = deliverToTunnel
        self.logHandler = logHandler
        self.maxPendingLookups = max(1, maxPendingLookups)
    }

    public func outbound(_ packet: Data) -> PacketVerdict {
        guard let datagram = UDPDatagram.parse(packet),
              let query = DNSMessage.parseQuery(datagram.payload) else {
            return .pass
        }

        let decision = configuration.routeDecision(for: query.name, dnsServers: dnsServers)
        guard case .normalDNS(reason: .excluded) = decision else {
            return .pass
        }

        let key = LookupKey(name: query.name, type: query.type, recordClass: query.recordClass)
        let waiter = PendingWaiter(datagram: datagram, query: query)

        enum Admission {
            case startLookup
            case joinedExisting
            case atCapacity
        }

        let admission: Admission = lock.withLock {
            let existingWaiterCount = pending[key]?.count ?? 0
            guard pendingWaiterCount < Self.maxPendingWaiters,
                  existingWaiterCount < Self.maxWaitersPerLookup,
                  existingWaiterCount > 0 || pending.count < maxPendingLookups else {
                return .atCapacity
            }

            pending[key, default: []].append(waiter)
            pendingWaiterCount += 1
            return existingWaiterCount == 0 ? .startLookup : .joinedExisting
        }

        switch admission {
        case .joinedExisting:
            return .consume

        case .atCapacity:
            sendReply(for: waiter, responseCode: .serverFailure, records: [])
            return .consume

        case .startLookup:
            let interfaceIndex = interfaceIndexProvider()
            resolver.resolve(
                name: query.name,
                recordType: query.type,
                recordClass: query.recordClass,
                interfaceIndex: interfaceIndex
            ) { [weak self] result in
                self?.completeLookup(for: key, result: result)
            }
            return .consume
        }
    }

    public func inbound(_ packet: Data) {}

    private func completeLookup(for key: LookupKey, result: Result<DNSLookupResponse, Error>) {
        let waiters = lock.withLock {
            let waiters = pending.removeValue(forKey: key) ?? []
            pendingWaiterCount -= waiters.count
            return waiters
        }
        guard !waiters.isEmpty else { return }

        let responseCode: DNSResponseCode
        let records: [DNSResourceRecord]
        switch result {
        case .success(let response):
            responseCode = response.responseCode
            records = response.records
        case .failure(let error):
            logHandler(.verbose, "Split DNS exclusion lookup failed for \(key.name) (type \(key.type)): \(error)")
            responseCode = .serverFailure
            records = []
        }

        for waiter in waiters {
            sendReply(for: waiter, responseCode: responseCode, records: records)
        }
    }

    private func sendReply(
        for waiter: PendingWaiter,
        responseCode: DNSResponseCode,
        records: [DNSResourceRecord]
    ) {
        let dnsPayload = DNSMessage.buildResponse(
            for: waiter.query,
            responseCode: responseCode,
            answers: records
        )
        guard let replyPacket = waiter.datagram.makeReply(payload: dnsPayload) else { return }
        do {
            try deliverToTunnel(replyPacket)
        } catch {
            logHandler(.verbose, "Failed to deliver split DNS reply for \(waiter.query.name): \(error)")
        }
    }
}
