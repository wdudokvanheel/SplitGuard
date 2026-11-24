// SPDX-License-Identifier: MIT

import Dispatch
import dnssd
import Foundation

public struct DNSLookupResponse: Equatable, Hashable, Sendable {
    public let responseCode: DNSResponseCode
    public let records: [DNSResourceRecord]

    public init(responseCode: DNSResponseCode, records: [DNSResourceRecord]) {
        self.responseCode = responseCode
        self.records = records
    }
}

public protocol PhysicalResolver: Sendable {
    func resolve(
        name: String,
        recordType: UInt16,
        recordClass: UInt16,
        interfaceIndex: UInt32?,
        completion: @escaping @Sendable (Result<DNSLookupResponse, Error>) -> Void
    )
}

public enum DNSSDResolverError: Error, Equatable, Sendable {
    case timeout
    case serviceError(Int32)
}

/// Resolves DNS records via `DNSServiceQueryRecord` scoped to the physical network interface
/// so excluded lookups use the underlying Wi-Fi/cellular resolver instead of the tunnel DNS.
public final class DNSSDResolver: PhysicalResolver, @unchecked Sendable {
    private final class QueryState {
        let token: UInt
        let completion: @Sendable (Result<DNSLookupResponse, Error>) -> Void
        var serviceRef: DNSServiceRef?
        var timer: DispatchSourceTimer?
        var records: [DNSResourceRecord] = []
        var finished = false

        init(token: UInt, completion: @escaping @Sendable (Result<DNSLookupResponse, Error>) -> Void) {
            self.token = token
            self.completion = completion
        }
    }

    private final class QueryRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextToken: UInt = 1
        private var activeQueries: [UInt: QueryState] = [:]

        func allocateToken() -> UInt {
            lock.withLock {
                let current = nextToken
                nextToken &+= 1
                if nextToken == 0 { nextToken = 1 }
                return current
            }
        }

        func store(_ state: QueryState, for token: UInt) {
            lock.withLock { activeQueries[token] = state }
        }

        func lookup(for token: UInt) -> QueryState? {
            lock.withLock { activeQueries[token] }
        }

        func remove(for token: UInt) -> QueryState? {
            lock.withLock { activeQueries.removeValue(forKey: token) }
        }
    }

    private static let registry = QueryRegistry()

    private let queue = DispatchQueue(label: "SplitGuard.DNSSDResolver.queue")
    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 5.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func resolve(
        name: String,
        recordType: UInt16,
        recordClass: UInt16,
        interfaceIndex: UInt32?,
        completion: @escaping @Sendable (Result<DNSLookupResponse, Error>) -> Void
    ) {
        queue.async {
            let token = Self.registry.allocateToken()
            let state = QueryState(token: token, completion: completion)
            Self.registry.store(state, for: token)

            var serviceRef: DNSServiceRef?
            let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
            let iface = interfaceIndex ?? UInt32(kDNSServiceInterfaceIndexAny)

            let context = UnsafeMutableRawPointer(bitPattern: token)
            let queryError = DNSServiceQueryRecord(
                &serviceRef,
                flags,
                iface,
                name,
                recordType,
                recordClass,
                Self.queryCallback,
                context
            )

            guard queryError == kDNSServiceErr_NoError, let serviceRef else {
                _ = Self.registry.remove(for: token)
                completion(.failure(DNSSDResolverError.serviceError(queryError)))
                return
            }

            state.serviceRef = serviceRef

            let queueError = DNSServiceSetDispatchQueue(serviceRef, self.queue)
            guard queueError == kDNSServiceErr_NoError else {
                _ = Self.registry.remove(for: token)
                DNSServiceRefDeallocate(serviceRef)
                completion(.failure(DNSSDResolverError.serviceError(queueError)))
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.timeoutSeconds)
            timer.setEventHandler {
                Self.finish(token: token, result: .failure(DNSSDResolverError.timeout))
            }
            state.timer = timer
            timer.activate()
        }
    }

    private static let queryCallback: DNSServiceQueryRecordReply = {
        _, flags, _, errorCode, fullname, rrtype, rrclass, rdlen, rdata, ttl, context in
        guard let context else { return }
        let token = UInt(bitPattern: context)
        guard let state = registry.lookup(for: token), !state.finished else { return }

        if errorCode == kDNSServiceErr_NoSuchName {
            finish(token: token, result: .success(DNSLookupResponse(responseCode: .nameError, records: [])))
            return
        }

        if errorCode == kDNSServiceErr_NoSuchRecord {
            finish(token: token, result: .success(DNSLookupResponse(responseCode: .noError, records: state.records)))
            return
        }

        guard errorCode == kDNSServiceErr_NoError else {
            finish(token: token, result: .failure(DNSSDResolverError.serviceError(errorCode)))
            return
        }

        let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
        if isAdd, rdlen > 0, let rdata, let fullname {
            let recordName = String(cString: fullname)
            let recordData = Data(bytes: rdata, count: Int(rdlen))
            state.records.append(DNSResourceRecord(
                name: recordName,
                type: rrtype,
                recordClass: rrclass,
                ttl: ttl,
                rdata: recordData
            ))
        }

        let moreComing = (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) != 0
        if !moreComing {
            finish(token: token, result: .success(DNSLookupResponse(responseCode: .noError, records: state.records)))
        }
    }

    private static func finish(token: UInt, result: Result<DNSLookupResponse, Error>) {
        guard let state = registry.remove(for: token), !state.finished else { return }
        state.finished = true
        state.timer?.cancel()
        state.timer = nil
        if let serviceRef = state.serviceRef {
            state.serviceRef = nil
            DNSServiceRefDeallocate(serviceRef)
        }
        state.completion(result)
    }
}
