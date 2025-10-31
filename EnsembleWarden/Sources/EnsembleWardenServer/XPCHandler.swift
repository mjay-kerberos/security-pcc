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
//  DaemonXPCHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 13/12/2024.
//

private import CryptoKit
private import EnsembleWardenCommon
internal import EnsembleWardenXPCAPI
private import IOSurface
private import os
@_spiOnly import Security_Private.SecTaskPriv
@_spi(Private) @preconcurrency private import XPC

/// Handling of XPC message types
///
/// Takes XPC messages and calls the user's handlers with their nice Swift APIs.
package struct XPCHandler<UserHandler: EnsembleWardenServerHandler & Sendable>: XPCPeerHandler, Sendable {
    /// Entitlement that the caller must have been compiled with to auths them.
    private var entitlement: String
    private let handler: UserHandler
    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "XPCHandler")

    package init(ensembleWardenHandler: UserHandler, entitlement: String) {
        self.handler = ensembleWardenHandler
        self.entitlement = entitlement
    }

    private func handle(startMessage: EnsembleWardenDaemonXPC.Start) async throws -> EnsembleWardenDaemonXPC.Start.Response {
        handler.start(keyEncryptionKey: startMessage.keyEncryptionKey,
                      keyID: startMessage.keyID,
                      requestID: startMessage.requestID,
                      spanID: startMessage.spanID)
        return .init()
    }

    private func handle(publishMessage: EnsembleWardenDaemonXPC.Publish) async throws -> EnsembleWardenDaemonXPC.Publish.Response {
        try await handler.onPublish(serializedXPCRequest: publishMessage.serializedXPCRequest,
                                    privateData: publishMessage.ioSurfaces,
                                    requestID: publishMessage.requestID,
                                    spanID: .init(uint: publishMessage.spanID))
        return .init()
    }

    private func handle(finishMessage: EnsembleWardenDaemonXPC.Finish) async throws -> EnsembleWardenDaemonXPC.Finish.Response {
        try await handler.onFinish()
        return .init()
    }

    private func handle(fetchMessage: EnsembleWardenDaemonXPC.Fetch) async throws -> EnsembleWardenDaemonXPC.Fetch.Response {
        let ioSurfaces = try await handler.onFetch(serializedXPCRequest: fetchMessage.serializedXPCRequest,
                                                   requestID: fetchMessage.requestID,
                                                   spanID: .init(uint: fetchMessage.spanID))
        return ioSurfaces
    }

    private func handle(message: EnsembleWardenDaemonXPC.Request) async throws -> [IOSurface] {
        switch message {
        case .empty: return []
        case .start(let startMessage):
            _ = try await Metrics.reportingXPCMetrics(operationName: "start") {
                try await handle(startMessage: startMessage)
            }
            return []
        case .publish(let publishMessage):
            _ = try await Metrics.reportingXPCMetrics(operationName: "publish") {
                try await handle(publishMessage: publishMessage)
            }
            return []
        case .fetch(let fetchMessage):
            return try await Metrics.reportingXPCMetrics(operationName: "fetch") {
                return try await handle(fetchMessage: fetchMessage)
            }
        case .finish(let finishMessage):
            _ = try await Metrics.reportingXPCMetrics(operationName: "finish") {
                try await handle(finishMessage: finishMessage)
            }
            return []
        }
    }

    package func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        self.logger.log("Handling incoming request")
        let auditToken = message.auditToken
        guard let secTask = SecTaskCreateWithAuditToken(nil, auditToken) else {
            logger.error("Unable to create secTask from auditToken")
            return EnsembleWardenDaemonXPC.Response.error(.invalidEntitlements)
        }

        var error: Unmanaged<CFError>?
        let entitlementValue = SecTaskCopyValueForEntitlement(secTask, self.entitlement as CFString, &error)

        if let error {
            // Error being logged here comes from the XPC world (even though not an XPC API) so is safe to log.
            logger.error("Error checking entitlement. error=\(error.takeRetainedValue(), privacy: .public)")
            return EnsembleWardenDaemonXPC.Response.error(.unexpectedFailure)
        } else if entitlementValue == nil {
            logger.error("Missing entitlement")
            return EnsembleWardenDaemonXPC.Response.error(.invalidEntitlements)
        }

        if message.isSync {
            do {
                let decodedMessage = try message.decode(as: EnsembleWardenDaemonXPC.Request.self)
                switch decodedMessage {
                case .empty:
                    logger.log("Daemon prewarmed")
                    return EnsembleWardenDaemonXPC.Response.success([])
                case .start(let startMessage):
                    handler.start(keyEncryptionKey: startMessage.keyEncryptionKey,
                                  keyID: startMessage.keyID,
                                  requestID: startMessage.requestID,
                                  spanID: startMessage.spanID)
                    return EnsembleWardenDaemonXPC.Response.success([])
                default:
                    logger.error("Received sync request with async message type.")
                    throw EnsembleWardenError.invalidSyncRequest
                }
            } catch {
                logger.error("Error decoding message. error=\(String(reportable: error), privacy: .public)")
                return EnsembleWardenDaemonXPC.Response.error(.unexpectedFailure)
            }
        } else {
            Task(priority: .userInitiated) {
                let response: EnsembleWardenDaemonXPC.Response
                do {
                    self.logger.log("Decoding message")
                    let decodedMessage = try message.decode(as: EnsembleWardenDaemonXPC.Request.self)
                    response = .success(try await handle(message: decodedMessage))
                    logger.log("Successfully handled XPC message")
                } catch let error as EnsembleWardenDaemonXPC.EnsembleWardenXPCError {
                    logger.error("Error handling XPC message. error=\(String(reportable: error), privacy: .public)")
                    response = .error(error)
                } catch {
                    logger.error("Unexpected error handling XPC message. error=\(String(reportable: error), privacy: .public)")
                    response = .error(EnsembleWardenDaemonXPC.EnsembleWardenXPCError.unexpectedFailure)
                }
                logger.log("Sending XPC response")
                message.reply(response)
            }
            return nil
        }
    }

    package func handleCancellation(error: XPCRichError) {
        logger.log("XPC cancellation. error=\(error, privacy: .public)")
        do {
            try handler.onCancellation()
        } catch {
            logger.error("Error handling cancellation. error=\(String(reportable: error))")
        }
    }
}
