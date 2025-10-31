// Copyright © 2025 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//
//  mDNSResponderQueries.swift
//  SecurityMonitorLite
//
import Foundation
import Synchronization

final class MDNSResponderQueries: OSLogStreamer.PredicatePlugin {
    let parser = Mutex<Parser>(Parser())
    func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any SMLUEFEvent)? {
        parser.withLock {
            $0.parse(fromOSLogEvent)
        }
    }

    static let predicate: String = "((process == \"mDNSResponder\" AND subsystem == \"com.apple.mDNSResponder\" AND category == \"Default\") AND (eventMessage CONTAINS[cd] \"DNSServiceQueryRecord\"))"
    func getPredicate() -> String {
        return Self.predicate
    }

    func logMessageMatch(_ event: OSLogStreamer.OSLogEvent) -> Bool {
        return event.process == "mDNSResponder" && event.subsystem == "com.apple.mDNSResponder" && (event.composedMessage.contains("DNSServiceQueryRecord START") || event.composedMessage.contains("DNSServiceQueryRecord result"))
    }

    internal init() { }

    static let lookupMap = ThreadSafeExpiringLookupMap<String, Event>(.seconds(120))
    static let tldExtractCache = Mutex<LRUCache<String, String>>(LRUCache(totalCount: 256))

    static func subdomainFromQuery(_ query: String) -> String {
        let (wasCached, cached) = tldExtractCache.withLock { cache in
            if let cached = cache[query] {
                 return (true, cached)
            }
            return (false, "")
        }
        if wasCached {
            return cached
        }
        let resolved = {
            let lookup = (query.hasSuffix(".") ? String(query.dropLast(1)) : query)
            if let droppedTld = lookup.removingTLD() {
                var parts = droppedTld.split(separator: ".")
                _ = parts.removeLast()
                guard !parts.isEmpty else {
                    return ""
                }
                let subdomain = parts.joined(separator: ".")
                return subdomain
            }
            return ""
        }()
        tldExtractCache.withLock { cache in
            cache[query] = resolved
        }
        return resolved
    }

    struct Parser: OSLogStreamer.EventParser {
        let rrule = /\[(?<queryid>R\d+)(-.+?)?\] DNSServiceQueryRecord (?<rowtype>START|result) -- (qname: (?<qname>.+?)(, +))?(event: (?<event>.+?)(, +))?(expired: (?<expired>.+?)(, +))?(qtype: (?<qtype>.+?)(, +))?(flags: (?<flags>.+?)(, +))?((ifindex|interface index): (?<interface>.+?)(, +))?(client pid: (?<pid>\d+) \((?<processname>.+?)\)(, +|$))?(name hash: (?<namehash>.+?)(, +|$))?(type: (?<rtype>.+?)(, +))?(rdata: (?<rdata>.+?)($))?/

        func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any SMLUEFEvent)? {
            var e = Event()
            if let result = try? rrule.firstMatch(in: fromOSLogEvent.composedMessage) {
                e.rowtype = String(result.rowtype) == "START" ? Event.QueryType.start.rawValue : Event.QueryType.result.rawValue
                e.timestamp = fromOSLogEvent.timestamp
                e.queryID = String(result.queryid)
                e.interfaceIndex = Int(String(result.interface ?? "0")) ?? 0
                e.namehash = String(result.namehash ?? "na")

                if e.rowtype == Event.QueryType.start.rawValue {
                    e.process = String(result.processname ?? "na")
                    e.processID = Int(String(result.pid ?? "0")) ?? 0
                    e.qname = String(result.qname ?? "na")
                    e.qtype = String(result.qtype ?? "na")
                    e.qnameSE = e.qname.entropy()
                    e.subqname = MDNSResponderQueries.subdomainFromQuery(e.qname)
                    e.subqnameSE = e.subqname.entropy()
                    e.flags = String(result.flags ?? "na")
                    MDNSResponderQueries.lookupMap[e.queryID] = e
                } else if e.rowtype == Event.QueryType.result.rawValue {
                    e.rdata = String(result.rdata ?? "na")
                    e.qtype = String(result.rtype ?? "na")
                    if let queryStart = MDNSResponderQueries.lookupMap[e.queryID] {
                        e.process = queryStart.process
                        e.processID = queryStart.processID
                        e.qname = queryStart.qname
                        e.flags = queryStart.flags
                        e.qnameSE = queryStart.qnameSE
                        e.subqname = queryStart.subqname
                        e.subqnameSE = queryStart.subqnameSE
                    }
                }
                return e
            } else {
                return nil
            }
        }

    }
    struct Event: SMLUEFEvent {
        enum QueryType: String, Codable, CaseIterable {
            case start
            case result
        }
        var fields: [String: any Sendable] = [:]
        var tags = Set<String>()

        let archetype: SMLUEFArchetype = .system
        let subtype: String = "DNSServiceQueryRecord"

        // Stored as a string so we can reflect on it
        var rowtype = QueryType.start.rawValue
        var timestamp = Date()
        var queryID = ""
        var process = ""
        var processID = 0
        var qname = ""
        var qtype = ""
        var flags = ""
        var interfaceIndex: Int = 0
        var namehash = ""
        var rdata = ""
        var qnameSE: Double = 0
        var subqname = ""
        var subqnameSE: Double = 0
    }
}
