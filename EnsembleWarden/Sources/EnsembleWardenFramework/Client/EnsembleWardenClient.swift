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
//  EnsembleWardenClient.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 11/11/2024.
//

private import AppServerSupport.OSLaunchdJob
public import CryptoKit
private import EnsembleWardenCommon
private import EnsembleWardenXPCAPI
public import Foundation
public import InternalSwiftProtobuf
public import IOSurface
internal import os
private import Synchronization
private import System
@_spi(SessionConnectionCompatibility) @preconcurrency private import XPC
private import XPCOverlay
import XPCPrivate


/// EnsembleWardenClient allows transfering of sensitive assets between nodes in an ensemble,
/// ensuring that they are encrypted to a key scoped to the ensemble.
///
/// To use `EnsembleWardenClient`, adopters should have pre-established a key across
/// an ensemble, known as `keyID`.
///
/// The usual flow for using an ``EnsembleWardenClient`` is:
/// 1. `let client = EnsembleWardenClient(requestID:)` to generate a client that will be used for a single request.
/// 2. `client.prewarm()` to start a fresh ensemblewardend process. The process takes ~40ms to start, so
/// adopters may wish to call this early on.
/// 3. `client.supply(keyID:)` when they have established a key between FT and ET ensembles.
/// 4. `client.publish()`/`client.fetch()` to do the actual fetching/publishing.
public final class EnsembleWardenClient: Sendable {

    /// This must match the "_managedBy" key in the launchd plist of ensemblewardend.
    private let managedByLabel = "com.apple.cloudos.ensemblewardenframework"

    private let xpcServiceName: String
    /// By default we use process isolation of ensemblewardend.
    ///
    /// This is built using launchd's OSLaunchdJob. However this isn't really testable.
    /// We therefore need to turn off this process isolation for our internal testing.
    private let processIsolation: Bool
    private let logger = Logger(subsystem: "com.apple.ensemblewarden", category: "EnsembleWarden")
    private let signposter: OSSignposter
    /// ensembleWardenID created for logging before requestID given.
    private let ensembleWardenID: UUID = UUID()

    private enum State: Sendable {
        /// We haven't yet connected to a daemon, so we can create a new daemon+connection.
        case notYetConnected
        ///  We have an active connection but no request ID or key ID.
        case prewarmed(XPCSession)
        /// We have an active connection to a daemon and request ID and key ID with requestID being passed through the state.
        case ready(XPCSession, UUID)
        /// We *had* a connection to a daemon but it was invalidated/interrupted.
        /// We can't create a new connection since we have a one-time access token to the key used to encrypt/decrypt the session.
        case noLongerValid
    }

    private let state: Mutex<State> = .init(.notYetConnected)

    // Deinit is a bit frowned upon, but we're just cleaning up a connection here.
    deinit {
        self.state.withLock { state in
            switch state {
            case .ready(let session, _): session.cancel(reason: "EnsembleWardenClient deinit")
            default: break
            }
        }
    }
    

    /// Initialiser for connecting to services that aren't kv-cache-transfer.
    ///
    /// Allows us to specify custom xpcServiceNames.
    package init(xpcServiceName: String, processIsolation: Bool = true, requestID: UUID) {
        self.xpcServiceName = xpcServiceName
        self.processIsolation = processIsolation
        self.signposter = OSSignposter(logger: self.logger)
    }

    /// Creates a new EnsembleWardenClient.
    public convenience init() {
        self.init(xpcServiceName: kEnsembleWardenAPIXPCLocalServiceName, processIsolation: true)
    }

    package init(xpcServiceName: String, processIsolation: Bool = true) {
        self.xpcServiceName = xpcServiceName
        self.processIsolation = processIsolation
        self.signposter = OSSignposter(logger: self.logger)
    }

    /// Starts up an instance of ensemblewardend so that the costs of process startup are paid before
    /// we hit the hot-path of requests.
    public func prewarm(spanID: UInt64) throws {
        try self.state.withLock { state in
            switch state {
            case .notYetConnected:
                let session = try doPrewarm(spanID: spanID)
                state = .prewarmed(session)
            case .prewarmed, .ready(_, _):
                logger.warning("""
                                Client prewarmed twice. \
                                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                                """)
            case .noLongerValid:
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
    }
    
    private func doPrewarm(spanID: UInt64) throws -> XPCSession {
        let prewarmInterval = self.signposter.beginInterval("EW.prewarm.signpost")
        defer {
            self.signposter.endInterval("EW.prewarm.signpost", prewarmInterval)
        }
        logger.log("""
            Prewarming ensemblewardend. \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            span_id=\(spanID.hexEncoded, privacy: .public)
            """)
        do {
            let session = try self.processIsolation ? freshProcess(spanID: spanID) : singleProcess(spanID: spanID)
            logger.log("Sending prewarm message")
            // Send an empty start message for prewarming
            try session.sendSync(EnsembleWardenDaemonXPC.Request.empty(.init()))
            logger.log("""
                Finished prewarming ensemblewardend. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            return session
        } catch {
            logger.error("""
                Error prewarming ensemblewardend. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
    }
    
    private func send(keyEncryptionKey: SymmetricKey, session: XPCSession, keyID: UUID,
                      requestID: UUID, spanID: UInt64) throws {
        logger.log("""
                Sending keyID. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
        do {
            _ = try session.sendSync(EnsembleWardenDaemonXPC.Request.start(
                .init(
                    keyEncryptionKey: keyEncryptionKey,
                    keyID: keyID,
                    requestID: requestID,
                    spanID: spanID
                )
            ))
        } catch {
            logger.error("""
                Error sending key. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
        logger.log("""
                keyID sent. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
    }

    /// Provide a single-use key access token that ensemblewardend can use to fetch a key and requestid.
    ///
    /// This is usually called once the dance with ensembled and cbjobhelper has distributed a key to the
    /// ET ensemble.
    /// - Parameters:
    ///   - keyEncryptionKey: The key used to encrypt the KV-cache encryption key.
    ///   - keyID: The key ID to use.
    ///   - requestID: The request ID that was used to request the key.
    ///   - spanID: The span ID to use for logging.
    public func supply(keyEncryptionKey: SymmetricKey, keyID: UUID, requestID: UUID, spanID: UInt64) throws {
        let tracingContext = DefaultTracer(
            name: "supply",
            requestID: requestID,
            parentSpanID: spanID
        )
        let requestSummary = EnsembleWardenRequestSummary(requestID: requestID)
        let spanID = tracingContext.spanID
        do {
            try self.state.withLock { state in
                switch state {
                case .notYetConnected:
                    let session = try doPrewarm(spanID: spanID)
                    try send(keyEncryptionKey: keyEncryptionKey, session: session, keyID: keyID,
                             requestID: requestID, spanID: spanID)
                    state = .ready(session, requestID)
                case .prewarmed(let session):
                    try send(keyEncryptionKey: keyEncryptionKey, session: session, keyID: keyID,
                             requestID: requestID, spanID: spanID)
                    state = .ready(session, requestID)
                case .ready(_, _):
                    logger.error("""
                                Supplied key_id and request_id twice. \
                                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                                request_id=\(requestID, privacy: .public) \
                                span_id=\(spanID.hexEncoded, privacy: .public)
                                """)
                    throw EnsembleWardenError.keyIDSuppliedTwice
                case .noLongerValid:
                    logger.error("""
                                Client closed and finished. \
                                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                                request_id=\(requestID, privacy: .public) \
                                span_id=\(spanID.hexEncoded, privacy: .public)
                                """)
                    throw EnsembleWardenError.invalidStateTransition
                }
            }
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenSupplyKey)
        } catch {
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenSupplyKey, error: error)
            throw error
        }
    }

    private func freshProcess(spanID: UInt64) throws -> XPCSession {
        logger.log("""
            Starting new ensemblewardend. \
            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
            span_id=\(spanID.hexEncoded, privacy: .public)
            """)
        var instanceUUID = UUID()
        let managedJobs = try OSLaunchdJob.copyJobsManaged(by: self.managedByLabel)
        // Only get the original launchd job, not all instances of this job
        let managedJobsWithoutInstances = managedJobs.filter { job in
            guard let jobInfo = job.getCurrentJobInfo() else {
                return false
            }
            return jobInfo.instance == nil
        }
        guard managedJobsWithoutInstances.count == 1, let job = managedJobsWithoutInstances.first else {
            logger.error("""
                Incorrect managed job count. \
                expected=\(1) \
                actual=\(managedJobs.count) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            throw EnsembleWardenError.launchdMisconfiguration
        }
        logger.log("""
                    Creating new process instance. \
                    process_instance_uuid=\(instanceUUID, privacy: .public) \
                    existing_managed_job_instances=\(managedJobs.count) \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                    span_id=\(spanID.hexEncoded, privacy: .public)
                    """)
        let jobInstance = try withUnsafeMutablePointer(to: &instanceUUID) { id in
            try job.createInstance(id)
        }

        logger.log("""
                    Creating process-isolated XPC connection. \
                    mach_service=\(self.xpcServiceName, privacy: .public) \
                    instance_uuid=\(instanceUUID, privacy: .public) \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                    span_id=\(spanID.hexEncoded, privacy: .public)
                    """)
        let xpcConnection = xpc_connection_create_mach_service(xpcServiceName, nil, 0)

        withUnsafeMutablePointer(to: &instanceUUID) { id in
            xpc_connection_set_oneshot_instance(xpcConnection, id)
        }
        jobInstance.monitor(on: DispatchQueue.global()) { jobInfo, err in
            self.handleJobInfoUpdate(jobInfo, errno: err, jobInstance: jobInstance)
        }

        logger.log("Creating XPC session")
        return try XPCSession(fromConnection: xpcConnection) { error in
            self.logger.log("""
                            XPC session cancelled. \
                            error=\(error, privacy: .public) \
                            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                            span_id=\(spanID.hexEncoded, privacy: .public)
                            """)
            self.state.withLock { $0 = .noLongerValid }
        }
    }

    private func handleJobInfoUpdate(_ jobInfo: OSLaunchdJobInfo?, errno: errno_t, jobInstance: OSLaunchdJob) {
        guard let jobInfo else {
            self.logger.error("""
                Unexpectedly received event with no jobInfo. \
                errno=\(errno) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
            return
        }
        switch jobInfo.state {
        case .neverRan:
            self.logger.log("""
                ensemblewardend launchd job reported neverRan. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
        case .running:
            self.logger.log("""
                ensemblewardend launchd job running. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
        case .spawnFailed:
            let errNo = Errno(rawValue: jobInfo.lastSpawnError)
            self.logger.log("""
                ensemblewardend launchd spawn failed. \
                errno=\(errNo, privacy: .public) \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
        case .exited:
            self.logger.log("""
                ensemblewardend process reported exit. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public)
                """)
            jobInstance.cancelMonitor()
        }
    }

    private func singleProcess(spanID: UInt64) throws -> XPCSession {
        logger.log("""
                    Creating XPC session. \
                    mach_service=\(self.xpcServiceName, privacy: .public) \
                    ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                    span_id=\(spanID.hexEncoded, privacy: .public)
                    """)
        return try XPCSession(machService: self.xpcServiceName) { error in
            self.logger.log("""
                            XPC session cancelled. \
                            error=\(error, privacy: .public) \
                            ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                            span_id=\(spanID.hexEncoded, privacy: .public)
                            """)
            self.state.withLock { $0 = .noLongerValid }
        }
    }
    
}

// MARK: Public API
extension EnsembleWardenClient {
    /// Ends the current EnsembleWarden session.
    public consuming func finish(spanID: UInt64=0) async throws {
        let finishInterval = self.signposter.beginInterval("EW.finish.signpost")
        defer {
            self.signposter.endInterval("EW.finish.signpost", finishInterval)
        }
        let (session, requestID): (XPCSession?, UUID?) = try self.state.withLock { state in
            switch state {
            case .notYetConnected:
                state = .noLongerValid
                return (nil, nil)
            case .prewarmed(let session):
                state = .noLongerValid
                return (session, nil)
            case .ready(let session, let requestID):
                state = .noLongerValid
                return (session, requestID)
            case .noLongerValid:
                logger.error("Client already finished")
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
        if let session {
            if let requestID {
                logger.log("""
                   Ending EnsembleWarden connection. \
                   ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                   request_id=\(requestID, privacy: .public) \
                   span_id=\(spanID.hexEncoded, privacy: .public)
                   """)
            } else {
                logger.log("""
                   Ending EnsembleWarden connection. \
                   ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                   span_id=\(spanID.hexEncoded, privacy: .public)
                   """)
            }
            session.cancel(reason: "close")
        }
    }

    /// Performs a publish operation to the ensemble warden daemon.
    /// - Parameters:
    ///   - serializedXPCRequest: The serialized XPC request to publish.
    ///   - privateData: The private data to publish.
    ///   - spanID: The span ID to use for this operation.
    public func publish(serializedXPCRequest: Data, privateData: [IOSurface], spanID: UInt64) async throws {
        let publishInterval = self.signposter.beginInterval("EW.publish.signpost")
        defer {
            self.signposter.endInterval("EW.publish.signpost", publishInterval)
        }
        let (session, requestID) = try self.state.withLock { state in
            switch state {
            case .notYetConnected, .prewarmed(_):
                throw EnsembleWardenError.keyIDNotSupplied
            case .ready(let session, let requestID):
                return (session, requestID)
            case .noLongerValid:
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
        // Need requestID to start a span so span starts here
        let requestSummary = EnsembleWardenRequestSummary(requestID: requestID)
        let tracingContext = DefaultTracer(
            name: "onPublish-framework",
            requestID: requestID,
            parentSpanID: spanID
        )
        let spanID = tracingContext.spanID
        do {
            logger.log("""
                        Publishing IOSurface to ensemblewardend. \
                        ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                        request_id=\(requestID, privacy: .public) \
                        span_id=\(spanID.hexEncoded, privacy: .public)
                        """)
            let message = EnsembleWardenDaemonXPC.Publish(
                serializedXPCRequest: serializedXPCRequest,
                ioSurfaces: privateData,
                requestID: requestID,
                spanID: spanID)
            logger.log("""
                           Created session. \
                           ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                           request_id=\(requestID, privacy: .public) \
                           span_id=\(spanID.hexEncoded, privacy: .public)
                           """)
            try await session.send(publishMessage: message, requestID: requestID, spanID: spanID)
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenPublishClient)
        } catch {
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenPublishClient, error: error)
            throw error
        }
    }

    /// Encrypts an ioSurface and makes it available to other ensembles with the relevant key material
    ///
    /// - Parameters:
    ///   - request: The request protobuf that identifies the ioSurface that we'll encrypt.
    ///   - privateData: The ioSurfaces to encrypt.
    ///   - spanID: A UUID to help with logging
    public func publish<RequestProto: Message>(request: RequestProto, privateData: [IOSurface], spanID: UInt64) async throws {
        try await self.publish(serializedXPCRequest: request.serializedData(),
                               privateData: privateData,
                               spanID: spanID)
    }

    public func fetch(serializedXPCRequest: Data, spanID: UInt64) async throws -> [IOSurface] {
        let fetchInterval = self.signposter.beginInterval("EW.fetch.signpost")
        defer {
            self.signposter.endInterval("EW.fetch.signpost", fetchInterval)
        }
        let (session, requestID) = try self.state.withLock { state in
            switch state {
            case .notYetConnected, .prewarmed(_):
                throw EnsembleWardenError.keyIDNotSupplied
            case .ready(let session, let requestID):
                return (session, requestID)
            case .noLongerValid:
                throw EnsembleWardenError.clientNoLongerActive
            }
        }
        let tracingContext = DefaultTracer(
            name: "onFetch-framework",
            requestID: requestID,
            parentSpanID: spanID
        )
        let requestSummary = EnsembleWardenRequestSummary(requestID: requestID)
        let spanID = tracingContext.spanID
        do {
            logger.log("""
                Fetching IOSurface from ensemblewardend. \
                ensemble_warden_id=\(self.ensembleWardenID, privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            let fetchMessage = EnsembleWardenDaemonXPC.Fetch(
                serializedXPCRequest: serializedXPCRequest,
                requestID: requestID,
                spanID: spanID)
            
            let valuesToSend = try await session.send(fetchMessage: fetchMessage, requestID: requestID, spanID: spanID)
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenFetchClient)
            return valuesToSend
        } catch {
            requestSummary.logSummary(tracingContext: tracingContext, tracingName: .EnsembleWardenFetchClient, error: error)
            throw error
        }
    }

    /// Fetch ioSurface and decrypt them so they can be used by the caller
    /// - Parameter request: An XPC request protobuf that identifies the ioSurfaces to be fetched.
    /// - Parameter spanID: A UUID to help with logging
    /// - Returns: Decrypted private data in IOSurfaces
    public func fetch<RequestProto: Message>(request: RequestProto, spanID: UInt64) async throws -> [IOSurface] {
        try await self.fetch(serializedXPCRequest: request.serializedData(), spanID: spanID)
    }

}
