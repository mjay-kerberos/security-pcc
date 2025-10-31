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
//  DaemonHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 20/01/2025.
//

internal import CryptoKit
private import EnsembleWardenCommon
private import EnsembleWardenServer
private import EnsembleWardenXPCAPI
package import Foundation
package import IOSurface
internal import os
private import Synchronization
@preconcurrency private import XPC


/// DaemonHandler receives plaintext ioSurfaces, encrypts them and then publishes them over XPC.
///
/// DaemonHandler itself conforms to ``EnsembleWardenServerHandler``, our type for
/// defining a destination for fetching and publishing ioSurfaces. The ``DaemonHandler`` is
/// our own, internal type that we use to receive ioSurfaces, encrypt them, and then write them out
/// to whichever *other* ``EnsembleWardenServerHandler`` is configured to read them.
///
/// Overall flow will look like:
///
/// Application -> EnsembleWardenFramework -> DaemonHandler (EnsembleWardenDaemon) -> EnsembleWardenServer (DownstreamApplication)
package final class DaemonHandler<
    Provider: KeyProvider & Sendable
>: Sendable {

    private enum State: Sendable {
        case keyNotYetReceived
        case keyReceived(SymmetricKey)
        case connectedToDownstream(SymmetricKey, XPCSession)
    }

    private let downstreamXPCService: String
    /// Source for us to get a key to encrypt the KV-caches.
    private let keyProvider: Provider
    /// Continuation that we yield to when we want the daemon to tear itself down
    private let shutdownInitiateContinuation: AsyncStream<Void>.Continuation
    internal let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "DaemonHandler")
    private let state: Mutex<State> = .init(.keyNotYetReceived)
    private let signposter: OSSignposter

    package init(downstreamXPCService: String, keyProvider: Provider, shutdownInitiateContinuation: AsyncStream<Void>.Continuation) {
        self.downstreamXPCService = downstreamXPCService
        self.keyProvider = keyProvider
        self.shutdownInitiateContinuation = shutdownInitiateContinuation
        self.signposter = OSSignposter(logger: self.logger)
    }
    
    private func unwrap(keyWithID keyID: UUID, keyEncryptionKey: SymmetricKey?, requestID: UUID, spanID: UInt64) throws -> SymmetricKey {
        let key: SymmetricKey
        if let keyEncryptionKey {
            let wrappedKey = try self.keyProvider.fetch(wrappedKey: keyID, requestID: requestID, spanID: spanID)
            logger.log("""
                Unwrapping keyEncryptionKey. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            // Unwrap the key
            let serialisedKey = try AES.GCM.open(wrappedKey, using: keyEncryptionKey)
            key = SymmetricKey(data: serialisedKey)
        } else {
            key = try self.keyProvider.fetch(key: keyID)
        }
        return key
    }
    
    private func sendToKVCacheTransfer(downstreamRequest:EnsembleWardenDaemonXPC.Request, requestID: UUID, spanID: UInt64) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                logger.log("""
                    Sending encrypted surface to tie-kvcache-transfer. \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID.hexEncoded, privacy: .public)
                    """)
                let downstreamSession = try self.getDownstreamXPCSession(requestID: requestID, spanID: spanID)
                try downstreamSession.send(downstreamRequest) { response in
                    do {
                        _ = try response.get()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    self.logger.log("""
                        Finished sending encrypted surface to tie-kvcache-transfer. \
                        request_id=\(requestID, privacy: .public) \
                        span_id=\(spanID.hexEncoded, privacy: .public)
                        """)
                    continuation.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func getDownstreamXPCSession(requestID: UUID?, spanID: UInt64?) throws -> XPCSession {
        try self.state.withLock { state in
            switch state {
            case .keyNotYetReceived:
                if let requestID, let spanID {
                    logger.error("""
                                Tried to connect to downstream before receiving a key. \
                                request_id=\(requestID, privacy: .public) \
                                span_id=\(spanID.hexEncoded, privacy: .public)
                                """)
                } else {
                    logger.error("Tried to connect to downstream before receiving a key.")
                }
                throw EnsembleWardenDError.keyNotYetReceived
            case .keyReceived(let key):
                let session = try XPCSession(machService: downstreamXPCService)
                state = .connectedToDownstream(key, session)
                return session
            case .connectedToDownstream(_, let session):
                return session
            }
        }
    }

    internal func getKey(requestID: UUID, spanID: UInt64) throws -> SymmetricKey {
        try self.state.withLock { state in
            switch state {
            case .keyNotYetReceived:
                logger.error("""
                             Tried to get key before receiving it. \
                             request_id=\(requestID, privacy: .public) \
                             span_id=\(spanID.hexEncoded, privacy: .public)
                             """)
                throw EnsembleWardenDError.keyNotYetReceived
            case .keyReceived(let key):
                return key
            case .connectedToDownstream(let key, _):
                return key
            }
        }
    }
}

extension DaemonHandler: EnsembleWardenServerHandler {

    func start(keyEncryptionKey: SymmetricKey?, keyID: UUID, requestID: UUID, spanID: UInt64) {
        let requestSummary = EnsembleWardenRequestSummary(requestID: requestID)
        let tracingContext = DefaultTracer(
            name: "start-daemon",
            requestID: requestID,
            parentSpanID: spanID
        )
        let spanID = tracingContext.spanID
        try! self.state.withLock { state in
            let startInterval = self.signposter.beginInterval("EW.startInterval.signpost")
            defer {
                self.signposter.endInterval("EW.startInterval.signpost", startInterval)
            }
            do {
                switch state {
                case .keyNotYetReceived:
                    logger.log("""
                             Fetching key from keyID. \
                             request_id=\(requestID, privacy: .public) \
                             span_id=\(spanID.hexEncoded, privacy: .public)
                             """)
                    let key: SymmetricKey
                    // If we get a keyEncryptionKey then we need to fetch the *wrapped* key from ensembled.
                    // And then unwrap that key using the keyEncryptionKey.
                    key = try unwrap(keyWithID: keyID, keyEncryptionKey: keyEncryptionKey, requestID: requestID, spanID: spanID)
                    state = .keyReceived(key)
                default:
                    // We don't expect to call start if we're in any other state.
                    logger.error("""
                                start(keyID:,requestID:,spanID:) called but we already have a key. Each ensemblewardend should only have 1 key. \
                                request_id=\(requestID, privacy: .public) \
                                span_id=\(spanID.hexEncoded, privacy: .public)
                                """)
                    throw EnsembleWardenDError.startCalledTwice
                }
                requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenStart)
            } catch {
                requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenStart, error: error)
                throw error
            }
        }
    }

    /// Encrypts ioSurfaces using a key from ensembled and publishes the resulting ciphertext.
    /// - Parameters:
    ///   - serializedXPCRequest: The serialized XPC request that contains the ioSurface
    ///   - privateData: The data to encrypt and then publish.
    package func onPublish(serializedXPCRequest: Data, privateData decryptedSurfaces: [IOSurface],
                           requestID: UUID, spanID: UUID) async throws {
        try await self.onPublish(serializedXPCRequest: serializedXPCRequest, privateData: decryptedSurfaces,
                                 requestID: requestID, spanID: UInt64(uuid: spanID))
    }

    package func onPublish(serializedXPCRequest: Data, privateData decryptedSurfaces: [IOSurface],
                           requestID: UUID, spanID: UInt64) async throws {
        let requestSummary = EnsembleWardenRequestSummary(requestID: requestID)
        let tracingContext = DefaultTracer(
            name: "onPublish-daemon",
            requestID: requestID,
            parentSpanID: spanID
        )
        let spanID = tracingContext.spanID
        do {
            requestSummary.logCheckpoint(tracingName: .EnsembleWardenEncryptionStart, tracingContext: tracingContext)
            let encryptedSurfaces = try self.encrypt(decryptedSurfaces: decryptedSurfaces, requestID: requestID, spanID: spanID)
            requestSummary.logCheckpoint(tracingName: .EnsembleWardenEncryptionEnd, tracingContext: tracingContext)
            let downstreamRequest = EnsembleWardenDaemonXPC.Request.publish(.init(
                serializedXPCRequest: serializedXPCRequest,
                ioSurfaces: encryptedSurfaces,
                requestID: requestID,
                spanID: spanID))
            let publishInterval = self.signposter.beginInterval("EW.publish_to_kvcache_transfer.signpost")
            defer {
                self.signposter.endInterval("EW.publish_to_kvcache_transfer.signpost", publishInterval)
            }
            requestSummary.logCheckpoint(tracingName: .EnsembleWardenXPCMessageToKVCacheSendStart, tracingContext: tracingContext)
            try await sendToKVCacheTransfer(downstreamRequest: downstreamRequest, requestID: requestID, spanID: spanID)
            requestSummary.logCheckpoint(tracingName: .EnsembleWardenXPCMessageToKVCacheSendCompleted, tracingContext: tracingContext)
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenPublishDaemon)
        } catch {
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenPublishDaemon, error: error)
            throw error
        }
    }
    
    /// Fetches ioSurfaces from the downstream EnsembleWardenServer, decrypts them, and then returns the plaintext.
    /// - Parameter serializedXPCRequest: The serialized XPC request that contains the ioSurface...
    package func onFetch(serializedXPCRequest: Data, requestID: UUID, spanID: UUID) async throws -> [IOSurface] {
        try await self.onFetch(serializedXPCRequest: serializedXPCRequest, requestID: requestID,
                               spanID: UInt64(uuid: spanID))
    }

    package func onFetch(serializedXPCRequest: Data, requestID: UUID, spanID: UInt64) async throws -> [IOSurface] {
        let tracingContext = DefaultTracer(
            name: "onFetch-daemon",
            requestID: requestID,
            parentSpanID: spanID
        )
        let requestSummary = EnsembleWardenRequestSummary(requestID: requestID)
        let spanID = tracingContext.spanID
        let downstreamRequest = EnsembleWardenDaemonXPC.Request.fetch(
            .init(
                serializedXPCRequest: serializedXPCRequest,
                requestID: requestID,
                spanID: spanID
            )
        )
        let fetchInterval = self.signposter.beginInterval("EW.fetch_from_kvcache.signpost")
        defer {
            self.signposter.endInterval("EW.fetch_from_kvcache.signpost", fetchInterval)
        }
        do {
            let encryptedSurfaces = try await withCheckedThrowingContinuation { continuation in
                do {
                    let downstreamSession = try self.getDownstreamXPCSession(requestID: requestID, spanID: spanID)
                    try downstreamSession.send(downstreamRequest) { response in
                        do {
                            let success = try response.get()
                            let decodedResponse = try success.decode(as: EnsembleWardenDaemonXPC.Response.self)
                            switch decodedResponse {
                            case .success(let ioSurfaces): continuation.resume(returning: ioSurfaces)
                            case .error(let error): continuation.resume(throwing: error)
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            requestSummary.logCheckpoint(tracingName: .EnsembleWardenDecryptionStart, tracingContext: tracingContext)
            let final = try self.decrypt(encryptedSurfaces: encryptedSurfaces, requestID: requestID, spanID: spanID)
            requestSummary.logCheckpoint(tracingName: .EnsembleWardenDecryptionEnd, tracingContext: tracingContext)
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenOnFetchDaemon)
            return final
        } catch {
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenOnFetchDaemon, error: error)
            throw error
        }
    }

    private func shutdownSessionAndInitiateShutdown() {
        self.state.withLock { state in
            switch state {
            case .connectedToDownstream(_, let session): session.cancel(reason: "Finished")
            default: break
            }
        }
        self.shutdownInitiateContinuation.yield()
    }

    package func onFinish() async throws {
        self.shutdownSessionAndInitiateShutdown()
    }

    package func onCancellation() throws {
        self.shutdownSessionAndInitiateShutdown()
    }
}
