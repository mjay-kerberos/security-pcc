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

// Copyright © 2025 Apple, Inc. All rights reserved.

import Testing
@_spi(HTTP) @_spi(CTypeConversion) @_spi(NWConnection) @_spi(nw_http_encoding_type_t) import Network
import Network_Private
import Synchronization
import System

@Suite(.serialized)
struct HTTPServerTests {
    @Test
    func testConnection() async throws {
        try await HTTPServer.withTestServer(accessing: "/") { server, clientConnection in
            let serverAddress: any IPAddress = switch server.host {
            case .ipv4(let ip): ip
            case .ipv6(let ip): ip
            default:
                fatalError()
            }
            #expect(serverAddress.isLoopback)

            guard case .hostPort(host: _, port: let port) = clientConnection.endpoint else {
                fatalError()
            }
            
            let request = nw_http_request_create_from_url(nw_http_request_method_get, "http://[::1]:\(port)/test")
            let metadata = nw_http_create_metadata_for_request(request)
            let nwContext = nw_content_context_create("send")
            nw_content_context_set_metadata_for_protocol(nwContext, metadata)
            let context = Network.NWConnection.ContentContext(nw: nwContext)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                clientConnection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }))
            }
        }
    }
    
    @Test
    func testServesContent() async throws {
        try await withTemporaryDirectory(prefix: "VRE-\(#function)") { temporaryDirectory in
            let fileContents = "Hello World"
            let createdFile = FileManager.default.createFile(atPath: temporaryDirectory.appending("Test.txt").string, contents: fileContents.data(using: .utf8))
            #expect(createdFile)
            
            try await HTTPServer.withTestServer(accessing: temporaryDirectory) { server, connection in
                guard case .hostPort(host: _, port: let port) = connection.endpoint else {
                    fatalError()
                }
                
                let receiptPath = URL(fileURLWithPath: temporaryDirectory.appending("Received.txt").string)
                try await connection.performDownload("http://[::1]:\(port)/Test.txt", to: receiptPath, within: .seconds(2))
                
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: receiptPath.path(percentEncoded: false), isDirectory: &isDirectory)
                #expect(exists)
                #expect(!isDirectory.boolValue)
                let contents = try! Data(contentsOf: receiptPath)
                #expect(String(decoding: contents, as: UTF8.self) == fileContents)
            }
        }
    }

    @Test
    func testServesPercentEncodedContent() async throws {
        try await withTemporaryDirectory(prefix: "VRE-\(#function)") { temporaryDirectory in
            let fileName = "Hello Leúte.txt"
            let fileContents = "Hello World"
            let createdFile = FileManager.default.createFile(atPath: temporaryDirectory.appending(fileName).string, contents: fileContents.data(using: .utf8))
            #expect(createdFile)

            try await HTTPServer.withTestServer(accessing: temporaryDirectory) { server, connection in
                guard case .hostPort(host: _, port: let port) = connection.endpoint else {
                    fatalError()
                }

                let receiptPath = URL(fileURLWithPath: temporaryDirectory.appending("Received.txt").string)
                let encodedFileName = try #require(fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
                try await connection.performDownload("http://[::1]:\(port)/\(encodedFileName)", to: receiptPath, within: .seconds(2))

                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: receiptPath.path(percentEncoded: false), isDirectory: &isDirectory)
                #expect(exists)
                #expect(!isDirectory.boolValue)
                let contents = try! Data(contentsOf: receiptPath)
                #expect(String(decoding: contents, as: UTF8.self) == fileContents)
            }
        }
    }

    @Test
    func testRejectsServingSymbolicLinks() async throws {
        try await withTemporaryDirectory(prefix: "VRE-\(#function)") { temporaryDirectory in
            let fileContents = "Hello World"
            let createdFile = FileManager.default.createFile(
                atPath: temporaryDirectory.appending("Test.txt").string,
                contents: fileContents.data(using: .utf8))
            #expect(createdFile)
            try FileManager.default.createSymbolicLink(
                atPath: temporaryDirectory.appending("Symlink.txt").string,
                withDestinationPath: temporaryDirectory.appending("Test.txt").string)
            
            try await HTTPServer.withTestServer(accessing: temporaryDirectory) { server, connection in
                guard case .hostPort(host: _, port: let port) = connection.endpoint else {
                    fatalError()
                }
                
                let content = try await connection.performGETRequest("http://[::1]:\(port)/Symlink.txt", within: .seconds(2))
                #expect(String(decoding: content, as: UTF8.self) == "IOError (other): not a file")
            }
        }
    }
    
    @Test
    func testRejectsJailbreaks() async throws {
        try await HTTPServer.withTestServer(accessing: "/") { server, _ in
            try await withThrowingDiscardingTaskGroup { group in
                let attempts = [
                    "../",
                    "..",
                    "he..llo",
                    "/../",
                    "......",
                ]
                for attemptPath in attempts {
                    group.addTask {
                        let connection = server.connection()
                        defer { connection.cancel() }
                        
                        guard case .hostPort(host: _, port: let port) = connection.endpoint else {
                            fatalError()
                        }
                        
                        connection.start(queue: .global())
                        
                        let content = try await connection.performGETRequest("http://[::1]:\(port)/" + attemptPath, within: .seconds(2))
                        #expect(String(decoding: content, as: UTF8.self) == "Forbidden")
                    }
                }
            }
        }
    }
}

struct HTTPServerConfigurationTests {
    private static func withRoundTrippedPlistValue<T: Codable>(
        of type: T.Type,
        from fixture: [String: Any],
        perform action: (T) async throws -> Void
    ) async throws {
        // Try plist -> T
        let plistData = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: .zero)
        let decoder = PropertyListDecoder()
        let config = try decoder.decode(T.self, from: plistData)
        try await action(config)

        // Try T -> plist -> T
        let encoder = PropertyListEncoder()
        let encodedData = try encoder.encode(config)
        let roundTrippedConfig = try decoder.decode(T.self, from: encodedData)
        try await action(roundTrippedConfig)
    }

    @Test
    func testSimpleVirtualService() async throws {
        let fixture: [String: Any] = [
            "httpService": [
                "enabled": true
            ],
            "name": "vre",
            "releaseAssets": [],
            "releaseID": "test",
        ]
        try await Self.withRoundTrippedPlistValue(of: VREInstanceConfiguration.self, from: fixture) { config in
            let httpService = try #require(config.httpService)
            guard case .virtual(let virtualConfig) = httpService else {
                fatalError("Did not decode a virtual service configuration?")
            }
            #expect(virtualConfig.mode == .nat)
            #expect(virtualConfig.port == nil)
        }
    }

    @Test
    func testServiceNotEnabled() async throws {
        let fixture: [String: Any] = [
            "httpService": [
                "enabled": false
            ],
            "name": "vre",
            "releaseAssets": [],
            "releaseID": "test",
        ]
        try await Self.withRoundTrippedPlistValue(of: VREInstanceConfiguration.self, from: fixture) { config in
            #expect(config.httpService == nil)
        }
    }

    @Test
    func testServiceWithIPv4Address() async throws {
        let host = try #require(IPv4Address("192.168.0.1"))
        let fixture: [String: Any] = [
            "httpService": [
                "enabled": true,
                "address": String(describing: host),
            ],
            "name": "vre",
            "releaseAssets": [],
            "releaseID": "test",
        ]
        try await Self.withRoundTrippedPlistValue(of: VREInstanceConfiguration.self, from: fixture) { config in
            let httpService = try #require(config.httpService)
            guard case .network(let networkConfig) = httpService else {
                fatalError("Did not decode a network service configuration?")
            }

            #expect(networkConfig.host == .ipv4(host))
            #expect(networkConfig.port == nil)
        }
    }

    @Test
    func testServiceWithIPv6Address() async throws {
        let host = try #require(IPv6Address("2620:149:af0::10"))
        let fixture: [String: Any] = [
            "httpService": [
                "enabled": true,
                "address": String(describing: host),
            ],
            "name": "vre",
            "releaseAssets": [],
            "releaseID": "test",
        ]
        try await Self.withRoundTrippedPlistValue(of: VREInstanceConfiguration.self, from: fixture) { config in
            let httpService = try #require(config.httpService)
            guard case .network(let networkConfig) = httpService else {
                fatalError("Did not decode a network service configuration?")
            }


            #expect(networkConfig.host == .ipv6(host))
            #expect(networkConfig.port == nil)
        }
    }

    @Test
    func testServiceWithIPAddressAndPort() async throws {
        let host = try #require(IPv6Address("2620:149:af0::10"))
        let fixture: [String: Any] = [
            "httpService": [
                "enabled": true,
                "address": String(describing: host),
                "port": 1234,
            ],
            "name": "vre",
            "releaseAssets": [],
            "releaseID": "test",
        ]
        try await Self.withRoundTrippedPlistValue(of: VREInstanceConfiguration.self, from: fixture) { config in
            let httpService = try #require(config.httpService)
            guard case .network(let networkConfig) = httpService else {
                fatalError("Did not decode a network service configuration?")
            }

            #expect(networkConfig.host == .ipv6(host))
            #expect(networkConfig.port == 1234)
        }
    }
}

extension NWConnection {
    func performGETRequest(_ url: String, within timeout: Duration) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let request = nw_http_request_create_from_url(nw_http_request_method_get, url)
            let metadata = nw_http_create_metadata_for_request(request)
            let nwContext = nw_content_context_create("send")
            nw_content_context_set_metadata_for_protocol(nwContext, metadata)
            let context = Network.NWConnection.ContentContext(nw: nwContext)
            
            self.batch {
                self.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
                    self.receiveMessage { content, contentContext, isComplete, error in
                        if let error {
                            return continuation.resume(throwing: error)
                        } else {
                            return continuation.resume(returning: content ?? Data())
                        }
                    }
                }))
            }
        }
    }
    
    func performDownload(_ url: String, to localFile: URL, within timeout: Duration) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let request = nw_http_request_create_from_url(nw_http_request_method_get, url)
            let metadata = nw_http_create_metadata_for_request(request)
            let nwContext = nw_content_context_create("send")
            nw_content_context_set_metadata_for_protocol(nwContext, metadata)
            let context = Network.NWConnection.ContentContext(nw: nwContext)
            
            self.batch {
                self.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
                    self.receiveFile(at: localFile) { totalBytesReceived, contentContext, isComplete, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return false
                        } else if isComplete {
                            continuation.resume(returning: ())
                            return true
                        } else {
                            return true
                        }
                    }
                }))
            }
        }
    }
}

extension HTTPServer {
    static func withTestServer<T>(
        accessing accessPath: FilePath,
        perform action: (HTTPServer, NWConnection) async throws -> T
    ) async throws -> T {
        let server = try await HTTPServer.start(.test, accessPath: accessPath)
        defer { try! server.shutdown() }
        
        let connection = server.connection()
        connection.start(queue: .global())
        defer { connection.cancel() }
        
        return try await action(server, connection)
    }
    
    func connection() -> NWConnection {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        nw_parameters_set_reuse_local_address(parameters.nw, true)
        
        nw_parameters_set_server_mode(parameters.nw, false)
        let client_protocol_stack = nw_parameters_copy_default_protocol_stack(parameters.nw)
        let client_http_options = nw_http_messaging_create_options()
        nw_protocol_stack_prepend_application_protocol(client_protocol_stack, client_http_options)
        
        return NWConnection(
            to: .loopback,
            using: parameters)
    }
}

public func withTemporaryDirectory<Result>(
    prefix: String = "TemporaryDirectory" ,
    _ body: @escaping (FilePath) async throws -> Result
) async throws -> Result {
    let templatePath = FilePath("/tmp").appending(prefix + ".XXXXXX")
    var template = [UInt8](templatePath.string.utf8).map({ Int8($0) }) + [Int8(0)]
    if mkdtemp(&template) == nil {
        throw Errno(rawValue: errno)
    }
    
    defer { _ = try? FileManager.default.removeItem(atPath: templatePath.string) }
    return try await body(FilePath(platformString: template))
}

extension NWEndpoint {
    static let loopback: Self = NWEndpoint.hostPort(host: "127.0.0.1", port: .http)
}

extension HTTPServer.Configuration {
    static let test: Self = .network(.init(host: .ipv4(IPv4Address("127.0.0.1")!), port: 80))
}
