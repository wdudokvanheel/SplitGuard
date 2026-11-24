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
    case missingInterface
    case timeout
    case serviceError(Int32)
}

/// Resolves DNS records via `DNSServiceQueryRecord` scoped to the physical network interface
/// so excluded lookups use the underlying Wi-Fi/cellular resolver instead of the tunnel DNS.
public final class DNSSDResolver: PhysicalResolver, @unchecked Sendable {
    struct QueryResults {
        private static let cnameType = UInt16(kDNSServiceType_CNAME)
        private static let anyRecordClass: UInt16 = 255

        private let recordType: UInt16
        private let recordClass: UInt16
        private var records: [DNSResourceRecord] = []

        init(recordType: UInt16, recordClass: UInt16) {
            self.recordType = recordType
            self.recordClass = recordClass
        }

        mutating func receive(
            flags: DNSServiceFlags,
            errorCode: DNSServiceErrorType,
            record: DNSResourceRecord?
        ) -> Result<DNSLookupResponse, Error>? {
            switch Int(errorCode) {
            case kDNSServiceErr_NoSuchName:
                let aliases = records.filter { $0.type == Self.cnameType }
                return .success(DNSLookupResponse(responseCode: .nameError, records: aliases))
            case kDNSServiceErr_NoSuchRecord:
                let aliases = records.filter { $0.type == Self.cnameType }
                return .success(DNSLookupResponse(responseCode: .noError, records: aliases))
            case kDNSServiceErr_NoError:
                break
            default:
                return .failure(DNSSDResolverError.serviceError(errorCode))
            }

            if let record,
               record.recordClass == recordClass || recordClass == Self.anyRecordClass,
               matchesRequestedType(record) || record.type == Self.cnameType {
                if (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0 {
                    records.append(record)
                } else {
                    records.removeAll {
                        $0.name == record.name && $0.type == record.type
                            && $0.recordClass == record.recordClass && $0.rdata == record.rdata
                    }
                }
            }

            // MoreComing tracks queued callbacks. An alias may arrive in a batch of its own.
            let moreComing = (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) != 0
            guard !moreComing, records.contains(where: matchesRequestedType) else { return nil }
            return .success(DNSLookupResponse(responseCode: .noError, records: records))
        }

        private func matchesRequestedType(_ record: DNSResourceRecord) -> Bool {
            record.type == recordType || recordType == UInt16(kDNSServiceType_ANY)
        }
    }

    private final class QueryState {
        let token: UInt
        let completion: @Sendable (Result<DNSLookupResponse, Error>) -> Void
        var serviceRef: DNSServiceRef?
        var timer: DispatchSourceTimer?
        var results: QueryResults
        var finished = false

        init(
            token: UInt,
            recordType: UInt16,
            recordClass: UInt16,
            completion: @escaping @Sendable (Result<DNSLookupResponse, Error>) -> Void
        ) {
            self.token = token
            self.results = QueryResults(recordType: recordType, recordClass: recordClass)
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
            guard let interfaceIndex, interfaceIndex != kDNSServiceInterfaceIndexAny else {
                completion(.failure(DNSSDResolverError.missingInterface))
                return
            }

            let token = Self.registry.allocateToken()
            let state = QueryState(token: token, recordType: recordType, recordClass: recordClass, completion: completion)
            Self.registry.store(state, for: token)

            var serviceRef: DNSServiceRef?
            let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)

            let context = UnsafeMutableRawPointer(bitPattern: token)
            let queryError = DNSServiceQueryRecord(
                &serviceRef,
                flags,
                interfaceIndex,
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

        var record: DNSResourceRecord?
        if errorCode == kDNSServiceErr_NoError, rdlen > 0, let rdata, let fullname {
            let recordName = String(cString: fullname)
            let recordData = Data(bytes: rdata, count: Int(rdlen))
            record = DNSResourceRecord(
                name: recordName,
                type: rrtype,
                recordClass: rrclass,
                ttl: ttl,
                rdata: recordData
            )
        }

        if let result = state.results.receive(flags: flags, errorCode: errorCode, record: record) {
            finish(token: token, result: result)
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
