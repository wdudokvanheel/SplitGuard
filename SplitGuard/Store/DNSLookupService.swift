import Darwin
import Foundation

struct DNSLookupResult: Equatable, Sendable {
    let hostname: String
    let addresses: [String]
    let durationMilliseconds: Int
    let errorMessage: String?

    var succeeded: Bool {
        errorMessage == nil && !addresses.isEmpty
    }
}

enum DNSLookupService {
    static func resolve(hostname rawHostname: String) async -> DNSLookupResult {
        let hostname = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            return DNSLookupResult(
                hostname: hostname,
                addresses: [],
                durationMilliseconds: 0,
                errorMessage: "Enter a hostname to test."
            )
        }

        return await Task.detached(priority: .userInitiated) {
            resolveSync(hostname: hostname)
        }.value
    }

    private static func resolveSync(hostname: String) -> DNSLookupResult {
        let start = DispatchTime.now().uptimeNanoseconds

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &resultPointer)
        defer {
            if let resultPointer {
                freeaddrinfo(resultPointer)
            }
        }

        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

        guard status == 0 else {
            let reason = gai_strerror(status).map { String(cString: $0) } ?? "Resolution failed"
            return DNSLookupResult(
                hostname: hostname,
                addresses: [],
                durationMilliseconds: elapsedMs,
                errorMessage: reason
            )
        }

        let addresses = extractAddresses(from: resultPointer)
        if addresses.isEmpty {
            return DNSLookupResult(
                hostname: hostname,
                addresses: [],
                durationMilliseconds: elapsedMs,
                errorMessage: "No IP addresses returned."
            )
        }

        return DNSLookupResult(
            hostname: hostname,
            addresses: addresses,
            durationMilliseconds: elapsedMs,
            errorMessage: nil
        )
    }

    private static func extractAddresses(from pointer: UnsafeMutablePointer<addrinfo>?) -> [String] {
        var addresses: [String] = []
        var seen = Set<String>()
        var cursor = pointer

        while let info = cursor?.pointee {
            if let sockaddr = info.ai_addr {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    sockaddr,
                    info.ai_addrlen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    let ipString = String(cString: hostBuffer)
                    if !ipString.isEmpty && !seen.contains(ipString) {
                        seen.insert(ipString)
                        addresses.append(ipString)
                    }
                }
            }
            cursor = info.ai_next
        }
        return addresses
    }
}
