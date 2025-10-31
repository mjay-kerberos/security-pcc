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

//  Copyright © 2023 Apple Inc. All rights reserved.

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardController
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import CryptoKit
import Foundation
import InternalGRPC
import InternalSwiftProtobuf
import NIOCore
import NIOHPACK
import os
import ServiceContextModule
import Tracing

final class CloudBoardProvider: Com_Apple_Cloudboard_Api_V1_CloudBoardAsyncProvider, Sendable {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardProvider"
    )

    enum Error: Swift.Error {
        case receivedMultipleFinalChunks
        case receivedMultipleDecryptionKeys
        case incomingConnectionClosedEarly
        case receivedRequestAfterRequestStreamTerminated
        case alreadyWaitingForIdle
    }

    static let rpcIDHeaderName = "apple-rpc-uuid"

    let sessionStore: SessionStore

    let isProxy: Bool
    let enforceRequestBypass: Bool
    let jobHelperClientProvider: CloudBoardJobHelperClientProvider
    let jobHelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider
    let trustedProxyParametersToFirstRewrapDurationMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement?> =
        .init(initialState: nil)

    /// Mapping for remote PCC worker nodes to communicate back to the initiating app.
    let pccWorkerToInitiatorMapping: PccWorkerToInitiatorMapping = .init()

    let healthMonitor: ServiceHealthMonitor
    let attestationProvider: AttestationProvider
    let loadState: OSAllocatedUnfairLock<LoadState> = .init(initialState: .init(
        concurrentRequestCount: 0,
        maxConcurrentRequests: 0,
        paused: false
    ))
    // exposed purely for unit test checking of the state
    internal var loadStateSnapshot: LoadState {
        self.loadState.withLock { $0 }
    }

    let loadConfiguration: CloudBoardDConfiguration.LoadConfiguration
    private let hotProperties: HotPropertiesController?
    let metrics: any MetricsSystem
    let tracer: RequestSummaryTracer

    private let (_concurrentRequestCountStream, concurrentRequestCountContinuation) = AsyncStream
        .makeStream(of: Int.self)
    var concurrentRequestCountStream: AsyncStream<Int> {
        self._concurrentRequestCountStream
    }

    private let drainState = OSAllocatedUnfairLock(initialState: DrainState())
    public var activeRequestsBeforeDrain: Int {
        self.drainState.withLock { $0.activeRequestsBeforeDrain }
    }

    struct DrainState {
        var activeRequests: Int
        var activeRequestsBeforeDrain: Int
        var draining: Bool
        var drainCompleteContinuation: CheckedContinuation<Void, Never>?

        init() {
            self.activeRequests = 0
            self.activeRequestsBeforeDrain = 0
            self.draining = false
            self.drainCompleteContinuation = nil
        }

        mutating func requestStarted() throws {
            if self.draining {
                CloudBoardProvider.logger.warning("Received invokeWorkload gRPC message; but draining")
                throw GRPCTransformableError.drainingRequests
            }
            self.activeRequests += 1
        }

        mutating func requestFinished() {
            self.activeRequests -= 1

            if self.draining, self.activeRequests == 0 {
                CloudBoardProvider.logger
                    .debug("CloudBoardProvider drain has reached 0 active requests")
                if let continuation = self.drainCompleteContinuation {
                    self.drainCompleteContinuation = nil
                    continuation.resume()
                } else {
                    assertionFailure("Missing drain complete continuation")
                }
            }
        }

        mutating func drain() {
            self.draining = true
            self.activeRequestsBeforeDrain = self.activeRequests
        }
    }

    init(
        isProxy: Bool,
        enforceRequestBypass: Bool = false,
        jobHelperClientProvider: CloudBoardJobHelperClientProvider,
        jobHelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider,
        healthMonitor: ServiceHealthMonitor,
        metrics: any MetricsSystem,
        tracer: RequestSummaryTracer,
        attestationProvider: AttestationProvider,
        loadConfiguration: CloudBoardDConfiguration.LoadConfiguration,
        hotProperties: HotPropertiesController?,
        sessionStore: SessionStore
    ) {
        self.isProxy = isProxy
        self.enforceRequestBypass = enforceRequestBypass
        self.jobHelperClientProvider = jobHelperClientProvider
        self.jobHelperResponseDelegateProvider = jobHelperResponseDelegateProvider
        self.healthMonitor = healthMonitor
        self.attestationProvider = attestationProvider
        self.metrics = metrics
        self.tracer = tracer
        self.loadConfiguration = loadConfiguration
        self.hotProperties = hotProperties
        self.sessionStore = sessionStore
    }

    func run() async {
        // We start our own watch of the service health here in order to manage
        // max concurrent requests.
        for await update in self.healthMonitor.watch() {
            let maxConcurrentRequests: Int = switch update {
            case .initializing, .unhealthy:
                0
            case .healthy(let state):
                state?.maxBatchSize ?? 0
            }

            self.loadState.withLock {
                $0.maxConcurrentRequests = maxConcurrentRequests
                if maxConcurrentRequests > 0 {
                    $0.paused = false
                    $0.pauseReason = nil
                }
            }
        }
    }

    func invokeWorkload(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest>,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        var serviceContext = ServiceContext.topLevel
        self.tracer.extract(context.request.headers, into: &serviceContext, using: HPACKHeadersExtractor())

        let invokeWorkloadSpanID = TraceContextCache.singletonCache.generateNewSpanID()
        try await self.tracer.withSpan(OperationNames.invokeWorkload, context: serviceContext) { span in
            let requestDurationMeasurementIncludingJobHelperExit = ContinuousTimeMeasurement.start()
            span.attributes.requestSummary.invocationAttributes.invocationRequestHeaders = context.request
                .headers
            span.attributes.requestSummary.invocationAttributes.spanID = invokeWorkloadSpanID
            try await withTaskCancellationHandler {
                try await self.policeDraining {
                    try await self.enforceConcurrentWorkloadLimit { onClient in
                        do {
                            // If we for any reason can't find a better value, let's use 30s.
                            let idleTimeoutDuration = await Duration.milliseconds(
                                self.hotProperties?.currentValue?.idleTimeoutMilliseconds ?? 30 * 1000
                            )

                            try await InvokeWorkloadRequestStreamHandler(
                                requestStream: requestStream,
                                responseWriter: responseStream,
                                jobHelperResponseDelegateProvider: self.jobHelperResponseDelegateProvider,
                                jobHelperClientProvider: self.jobHelperClientProvider,
                                sessionStore: self.sessionStore,
                                pccWorkerToInitiatorMapping: self.pccWorkerToInitiatorMapping,
                                attestationProvider: self.attestationProvider,
                                isProxy: self.isProxy,
                                enforceRequestBypass: self.enforceRequestBypass,
                                idleTimeoutDuration: idleTimeoutDuration,
                                maxCumulativeRequestBytes: self.currentMaxCumulativeRequestBytes(),
                                pushFailureReportsToROPES: self.hotProperties?.currentValue?
                                    .pushFailureReportsToROPES ?? false,
                                metrics: self.metrics,
                                tracer: self.tracer,
                                workloadInvocationSpanID: invokeWorkloadSpanID,
                                trustedProxyParametersToFirstRewrapDurationMeasurement: self
                                    .trustedProxyParametersToFirstRewrapDurationMeasurement,
                                requestSummarySpan: span
                            ).handle(notifyOfClientCreation: onClient)
                        } catch is CancellationError {
                            span.attributes.requestSummary.invocationAttributes.connectionCancelled = true
                            var error: Swift.Error = CancellationError()
                            let durationMicrosIncludingJobHelperExit = requestDurationMeasurementIncludingJobHelperExit
                                .duration

                            // If the top-level task is cancelled we were cancelled by grpc-swift due to the
                            // connection/stream having been cancelled. In this case CancellationErrors are expected
                            // and we should classify them accordingly
                            if Task.isCancelled {
                                error = GRPCTransformableError.connectionCancelled
                            }
                            self.metrics.emit(Metrics.CloudBoardProvider.RequestTimeWithJobHelperExitHistogram(
                                duration: durationMicrosIncludingJobHelperExit,
                                failureReason: error
                            ))
                            span.durationMicrosIncludingJobHelperExit = durationMicrosIncludingJobHelperExit
                                .microsecondsClamped
                            throw error
                        }
                    }
                }
            } onCancel: {
                Self.logger.log("\(Self.logMetadata(), privacy: .public) Connection cancelled")
                span.attributes.requestSummary.invocationAttributes.connectionCancelled = true
            }
            let parentSpanID = TraceContextCache.singletonCache.getSpanID(
                forKeyWithID: serviceContext.rpcID.uuidString,
                forKeyWithSpanIdentifier: SpanIdentifier.parameters
            )
            let durationMicrosIncludingJobHelperExit = requestDurationMeasurementIncludingJobHelperExit
                .duration
            span.attributes.requestSummary.invocationAttributes.parentSpanID = parentSpanID
            span.durationMicrosIncludingJobHelperExit = durationMicrosIncludingJobHelperExit.microsecondsClamped
            self.metrics
                .emit(
                    Metrics.CloudBoardProvider
                        .RequestTimeWithJobHelperExitHistogram(
                            duration: durationMicrosIncludingJobHelperExit
                        )
                )
        }
    }

    /// This maintains the needed invariants for loadState.concurrentRequestCount
    /// It is deliberately pessimisitc, it increments as soon as possble, and decrements only when it is sure the helper
    /// has terminated, to achieve the latter it has to resort to starting a detached task when cancellations occur
    fileprivate func enforceConcurrentWorkloadLimit(
        executeWorkload: ((CloudBoardJobHelperInstanceProtocol) -> Void) async throws -> Void
    ) async throws {
        try self.loadState.withLock { loadState in
            let maxConcurrentRequests = loadState.maxConcurrentRequests
            if loadState.concurrentRequestCount >= maxConcurrentRequests {
                self.metrics.emit(Metrics.CloudBoardProvider.MaxConcurrentRequestCountExceededTotal(action: .increment))

                if self.loadConfiguration.enforceConcurrentRequestLimit {
                    self.metrics.emit(
                        Metrics.CloudBoardProvider.MaxConcurrentRequestCountRejectedTotal(action: .increment)
                    )
                    Self.logger.warning(
                        "\(Self.logMetadata(), privacy: .public) incoming workload rejected because it would exceed the number of max concurrent request count of \(maxConcurrentRequests, privacy: .public)"
                    )
                    if maxConcurrentRequests != 0 {
                        throw GRPCTransformableError.maxConcurrentRequestsExceeded
                    } else if loadState.paused {
                        // Workload controller is busy
                        throw GRPCTransformableError.workloadBusy(loadState.pauseReason)
                    } else {
                        // Oh shoot we're unhealthy!
                        throw GRPCTransformableError.workloadUnhealthy
                    }
                } else {
                    Self.logger.warning(
                        "\(Self.logMetadata(), privacy: .public) incoming workload request exceeds the number of max concurrent request count of \(maxConcurrentRequests, privacy: .public) but accepted as enforcement is disabled"
                    )
                }
            }
            loadState.concurrentRequestCount += 1
            if self.loadConfiguration.overrideCloudAppConcurrentRequests {
                self.healthMonitor.overrideCurrentRequestCount(count: loadState.concurrentRequestCount)
            }
            self.metrics.emit(Metrics.CloudBoardProvider.ConcurrentRequests(value: loadState.concurrentRequestCount))
            self.concurrentRequestCountContinuation.yield(loadState.concurrentRequestCount)
        }

        // avoid lock ordering, never hold this at the same time as self.loadState
        let jobHelperInstance = OSAllocatedUnfairLock<CloudBoardJobHelperInstanceProtocol?>(initialState: nil)
        func notifyOfClientCreation(helper: CloudBoardJobHelperInstanceProtocol) {
            jobHelperInstance.withLock { $0 = helper }
        }

        // Safe to call from multiple concurrency domains, but must only be called once
        func onJobConsideredFinished() {
            self.loadState.withLock { loadState in
                loadState.concurrentRequestCount -= 1
                if self.loadConfiguration.overrideCloudAppConcurrentRequests {
                    self.healthMonitor.overrideCurrentRequestCount(count: loadState.concurrentRequestCount)
                }
                self.metrics.emit(
                    Metrics.CloudBoardProvider.ConcurrentRequests(value: loadState.concurrentRequestCount)
                )
                self.concurrentRequestCountContinuation.yield(loadState.concurrentRequestCount)

                if let continuation = loadState.idleContinuation {
                    if loadState.concurrentRequestCount == 0 {
                        loadState.idleContinuation = nil
                        continuation.finish()
                    }
                }
            }
        }

        do {
            try await executeWorkload(notifyOfClientCreation)
            await self.waitForExit(jobHelperInstance.withLock { $0 })
            // This must be last call, or part of non throwing final section
            onJobConsideredFinished()
        } catch {
            // nothing we can do, let defer tidy up with a detached task (if it needs to)
            if let jobHelperInstance = jobHelperInstance.withLock({ $0 }) {
                Self.logger.info(
                    "\(Self.logMetadata(), privacy: .public) Spawning detached task to monitor job helpers before releasing workload count"
                )
                Task.detached {
                    await self.waitForExit(jobHelperInstance)
                    onJobConsideredFinished()
                    Self.logger.info("\(Self.logMetadata(), privacy: .public) released workload count")
                }

            } else {
                onJobConsideredFinished()
            }
            throw error
        }
    }

    // Technically this will tolerate any wait calls throwing and consider that 'good enough'
    private func waitForExit(_ jobHelperInstance: CloudBoardJobHelperInstanceProtocol?) async {
        // we want to be silent in the happy path
        guard let jobHelperInstance else {
            return
        }

        Self.logger.debug("\(Self.logMetadata(), privacy: .public) Waiting for job helper to exit")
        do {
            try await jobHelperInstance.waitForExit(returnIfNotUsed: true)
        } catch {
            // There's not much we can do here (apart from log), either we consider the job completed,
            // and consider finished, or we blow up spectacularly to cause a restart of some form.
            // Just pretending the job is running constantly is a bad state to be in (even if it is)
            // because nothing is definitely going to take action to clean that state up.
            // since there are other protections against concurrent jobs, and the time it will spend in
            // this state is likely small we consider it done
            Self.logger.error("""
            \(Self.logMetadata(), privacy: .public) \
            Unexpected error while waiting for job helper to exit: \
            \(String(unredacted: error), privacy: .public)
            """)
        }
    }

    public func pause(_ reason: String?) async throws {
        let (idleStream, idleContinuation) =
            AsyncStream.makeStream(of: Void.self)

        try self.loadState.withLock { loadState in
            guard loadState.idleContinuation == nil else {
                throw CloudBoardProvider.Error.alreadyWaitingForIdle
            }
            loadState.maxConcurrentRequests = 0
            loadState.paused = true
            loadState.pauseReason = reason
            if loadState.concurrentRequestCount == 0 {
                idleContinuation.finish()
                return
            }
            loadState.idleContinuation = idleContinuation
        }

        for await _ in idleStream {
            return
        }
    }

    fileprivate func policeDraining(
        executeWorkload: () async throws -> Void
    ) async throws {
        // Check for ongoing draining
        try self.drainState.withLock { drainState in
            // Throws if draining is in progress
            try drainState.requestStarted()
        }
        defer {
            self.drainState.withLock { drainState in
                drainState.requestFinished()
            }
        }

        try await executeWorkload()
    }

    private func currentMaxCumulativeRequestBytes() async -> Int {
        let defaultValue = self.loadConfiguration.maxCumulativeRequestBytes

        guard let hotProperties = self.hotProperties else {
            return defaultValue
        }

        guard let currentConfigValue = await hotProperties.currentValue else {
            return defaultValue
        }

        return currentConfigValue.maxCumulativeRequestBytes ?? defaultValue
    }

    func watchLoadLevel(
        request _: Com_Apple_Cloudboard_Api_V1_LoadRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_LoadResponse>,
        context _: GRPCAsyncServerCallContext
    ) async throws {
        try await withErrorLogging(operation: "watchLoadLevel", sensitiveError: false) {
            Self.logger.info("received watch load level request")

            for await status in self.healthMonitor.watch() {
                Self.logger.info("new load status: \(status, privacy: .public)")

                switch status {
                case .healthy(let healthy):
                    if let healthy {
                        try await responseStream.send(.init(healthy))
                    } else {
                        fallthrough
                    }
                case .initializing, .unhealthy:
                    // Unhealthy means load level of 0.
                    try await responseStream.send(.with {
                        $0.currentBatchSize = 0
                        $0.maxBatchSize = 0
                        $0.optimalBatchSize = 0
                    })
                    // Deliberately don't reset the workload: if the same workload comes back, we don't need
                    // to send this value again.
                }
            }
        }
    }

    func fetchAttestation(
        request _: Com_Apple_Cloudboard_Api_V1_FetchAttestationRequest,
        context: InternalGRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Cloudboard_Api_V1_FetchAttestationResponse {
        var serviceContext = ServiceContext.topLevel
        self.tracer.extract(context.request.headers, into: &serviceContext, using: HPACKHeadersExtractor())
        let context = serviceContext
        Self.logger.log("message=\"received fetch attestation request\"\nrpcID=\(context.rpcID)")
        return try await withErrorLogging(operation: "fetchAttestation", sensitiveError: false) {
            let requestSummary = FetchAttestationRequestSummary(rpcID: context.rpcID)
            return try await requestSummary.loggingRequestSummaryModifying(logger: Self.logger) { summary in
                let attestationSet = try await self.attestationProvider.currentAttestationSet()
                summary.populateAttestationSet(attestationSet: attestationSet)
                if attestationSet.currentAttestation.expiry.timeIntervalSince(Date.now) <= 0 {
                    Self.logger.error(
                        "fetchAttestation failed with error: \(AttestationError.attestationExpired, privacy: .public)"
                    )
                    throw AttestationError.attestationExpired
                }
                return .with {
                    $0.attestation = .with {
                        $0.attestationBundle = attestationSet.currentAttestation.attestationBundle
                        $0.keyID = attestationSet.currentAttestation.keyID

                        // Unused field. Cleanup when removing `fetchAttestation`
                        $0.nextRefreshTime = .init(date: .distantFuture)

                        $0.expiresAfter = .init(date: attestationSet.currentAttestation.expiry)
                    }
                    $0.unpublishedAttestation = attestationSet.unpublishedAttestations.map { key in
                        .with {
                            $0.keyID = key.keyID
                            $0.expiresAfter = .init(date: key.expiry)
                        }
                    }
                }
            }
        }
    }

    func watchAttestation(
        request _: Com_Apple_Cloudboard_Api_V1_WatchAttestationRequest,
        responseStream: InternalGRPC
            .GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_WatchAttestationResponse>,
        context _: InternalGRPC.GRPCAsyncServerCallContext
    ) async throws {
        @Sendable func updateAttestationMetaData(
            _ meta: inout Com_Apple_Cloudboard_Api_V1_WatchAttestationResponse.AttestationMetadata,
            _ attestation: AttestationSet.Attestation
        ) {
            meta.keyID = attestation.keyID
            meta.supportedRelease = attestation.proxiedReleaseDigests
                .map { release in
                    .with {
                        $0.digest = release
                    }
                }
            meta.expiresAfter = .init(date: attestation.expiry)
        }

        try await withErrorLogging(operation: "watchAttestation", sensitiveError: false) {
            Self.logger.info("Received watch attestation request")

            for await attestationSet in await self.attestationProvider.registerForUpdates() {
                try await responseStream.send(.with {
                    $0.attestionSet = .with {
                        $0.activeAttestation = .with {
                            $0.attestationBundle = attestationSet.currentAttestation.attestationBundle
                            $0.attestationMetadata = .with {
                                updateAttestationMetaData(&$0, attestationSet.currentAttestation)
                            }
                        }
                        $0.unpublishedAttestations = attestationSet.unpublishedAttestations.compactMap { attestation in
                            if !attestation.availableOnNodeOnly {
                                .with {
                                    updateAttestationMetaData(&$0, attestation)
                                }
                            } else { nil }
                        }
                    }
                })
            }
        }
    }

    func drain() async {
        await withCheckedContinuation { drainCompleteContinuation in
            self.drainState.withLock { drainState in
                precondition(!drainState.draining, "CloudBoardProvider received request to drain during ongoing drain")

                drainState.drain()
                if drainState.activeRequests == 0 {
                    drainCompleteContinuation.resume()
                } else {
                    drainState.drainCompleteContinuation = drainCompleteContinuation
                }
            }
        }
    }
}

struct LoadState {
    var concurrentRequestCount: Int
    var maxConcurrentRequests: Int
    var paused: Bool
    var pauseReason: String?
    var idleContinuation: AsyncStream<Void>.Continuation?
}

extension CloudBoardDaemonToJobHelperMessage {
    init?(from cloudBoardRequest: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest) {
        switch cloudBoardRequest.type {
        case .parameters(let parameters):
            // validation was handled elsewhere, we just fail to parse
            let responseBypassMode = try? ResponseBypassMode(from: parameters)
            guard let responseBypassMode else {
                return nil
            }
            self = .parameters(.init(
                requestID: parameters.requestID,
                oneTimeToken: parameters.oneTimeToken,
                encryptedKey: .init(
                    keyID: parameters.decryptionKey.keyID,
                    key: parameters.decryptionKey.encryptedPayload
                ),
                parametersReceived: .now,
                plaintextMetadata: .init(tenantInfo: parameters.tenantInfo, workload: parameters.workload),
                responseBypassMode: responseBypassMode,
                requestBypassed: parameters.requestBypassed,
                requestedNack: parameters.requestNack,
                traceContext: .init(
                    traceID: parameters.traceContext.traceID,
                    spanID: TraceContextCache.singletonCache
                        .getSpanID(
                            forKeyWithID: parameters.requestID,
                            forKeyWithSpanIdentifier: SpanIdentifier.invokeWorkload
                        ) ?? ""
                )
            ))
        case .requestChunk(let requestChunk):
            self = .requestChunk(requestChunk.encryptedPayload, isFinal: requestChunk.isFinal)
        case .none, .setup, .terminate:
            return nil
        }
    }
}

class InvokeWorkloadRequestStreamHandler {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        // Keeping this at CloudBoardProvider deliberately for now, the handler class is
        // private to `CloudBoardProvider`
        category: "CloudBoardProvider"
    )
    private static let signposter: OSSignposter = .init(logger: logger)
    private static let requestBypassEnforceableWorkloads: Set<String> = ["tie-cloudboard-apple-com"]

    fileprivate enum WorkloadTaskResult {
        case jobHelperExited
        case receiveInputCompleted
        case responseOutputCompleted
    }

    /// Stream of inbound requests coming in
    private let requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest>
    /// Stream of outbound responses going out
    private let responseWriter: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>

    private let jobHelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider
    private let jobHelperClientProvider: CloudBoardJobHelperClientProvider

    /// Session store for detecting replay attacks. Shared across all streams
    private let sessionStore: SessionStore

    /// Mapping for remote PCC worker nodes to communicate back to the initiating app.
    ///
    /// We receive jobHelper requests for a worker and establish the mapping
    private let pccWorkerToInitiatorMapping: PccWorkerToInitiatorMapping

    /// Manually managing `ServiceContext` to propagate metadata extracted in request message handler to
    /// response handler logs
    private let serviceContext: OSAllocatedUnfairLock<ServiceContext>

    private let attestationProvider: AttestationProvider

    // MARK: handler configuration

    private let isProxy: Bool
    private let enforceRequestBypass: Bool
    private let idleTimeoutDuration: Duration
    private let maxCumulativeRequestBytes: Int
    private let pushFailureReportsToROPES: Bool
    private let invokeWorkloadSpanID: String

    let metrics: any MetricsSystem
    let tracer: RequestSummaryTracer

    let parametersToEndResponseSpan: OSAllocatedUnfairLock<Span?> = .init(initialState: nil)
    let parametersToEndResponseSignpost: OSAllocatedUnfairLock<OSSignpostIntervalState?> = .init(initialState: nil)
    let finalRequestChunkToEndResponseSpan: OSAllocatedUnfairLock<Span?> = .init(initialState: nil)
    let finalRequestChunkToEndResponseSignpost: OSAllocatedUnfairLock<OSSignpostIntervalState?> =
        .init(initialState: nil)

    // which key the parameters indicate was used for this request
    let keyID: OSAllocatedUnfairLock<Data> = .init(initialState: .init())

    let trustedProxyParametersToFirstRewrapDurationMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement?>
    let requestSummarySpan: RequestSummaryTracer.Span

    init(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest>,
        responseWriter: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>,
        jobHelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider,
        jobHelperClientProvider: CloudBoardJobHelperClientProvider,
        sessionStore: SessionStore,
        pccWorkerToInitiatorMapping: PccWorkerToInitiatorMapping,
        attestationProvider: AttestationProvider,
        isProxy: Bool,
        enforceRequestBypass: Bool,
        idleTimeoutDuration: Duration,
        maxCumulativeRequestBytes: Int,
        pushFailureReportsToROPES: Bool,
        metrics: any MetricsSystem,
        tracer: RequestSummaryTracer,
        workloadInvocationSpanID: String,
        trustedProxyParametersToFirstRewrapDurationMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement?>,
        requestSummarySpan: RequestSummaryTracer.Span
    ) {
        self.requestStream = requestStream
        self.responseWriter = responseWriter
        self.jobHelperResponseDelegateProvider = jobHelperResponseDelegateProvider
        self.jobHelperClientProvider = jobHelperClientProvider
        self.sessionStore = sessionStore
        self.pccWorkerToInitiatorMapping = pccWorkerToInitiatorMapping
        self.attestationProvider = attestationProvider
        self.isProxy = isProxy
        self.enforceRequestBypass = enforceRequestBypass
        self.idleTimeoutDuration = idleTimeoutDuration
        self.maxCumulativeRequestBytes = maxCumulativeRequestBytes
        self.pushFailureReportsToROPES = pushFailureReportsToROPES
        self.metrics = metrics
        self.tracer = tracer
        self.invokeWorkloadSpanID = workloadInvocationSpanID
        self.serviceContext = .init(initialState: ServiceContext.current ?? .topLevel)
        self.trustedProxyParametersToFirstRewrapDurationMeasurement =
            trustedProxyParametersToFirstRewrapDurationMeasurement
        self.requestSummarySpan = requestSummarySpan
    }

    func handle(
        notifyOfClientCreation: (CloudBoardJobHelperInstanceProtocol) -> Void
    ) async throws {
        try await withErrorLogging(
            operation: "_invokeWorkload",
            diagnosticKeys: CloudBoardDaemonDiagnosticKeys([.rpcID]),
            sensitiveError: false
        ) {
            CloudBoardProviderCheckpoint(
                logMetadata: Self.logMetadata(spanID: self.invokeWorkloadSpanID),
                operationName: "cloudboard_invoke_workload_request_received",
                message: "invokeWorkload() received workload invocation request"
            ).log(to: Self.logger)

            let (jobHelperResponseStream, jobHelperResponseContinuation) = AsyncStream<JobHelperInvokeWorkloadResponse>
                .makeStream()

            let delegate = await self.jobHelperResponseDelegateProvider
                .makeDelegate(invokeWorkloadResponseContinuation: jobHelperResponseContinuation)
            let idleTimeout = await self.idleTimeout(
                timeout: self.idleTimeoutDuration, taskName: "invokeWorkload",
                taskID: ServiceContext.current?.rpcID.uuidString ?? ""
            )
            try await self.jobHelperClientProvider.withClient(delegate: delegate) { jobHelperClient in
                // Once we have taken ownership of a client we must ensure the accounting system knows
                // we own it before we do anything else
                notifyOfClientCreation(jobHelperClient)
                try await withThrowingTaskGroup(of: WorkloadTaskResult.self) { group in
                    group.addTaskWithLogging(
                        operation: "_invokeWorkload.idleTimeout",
                        diagnosticKeys: CloudBoardDaemonDiagnosticKeys([.rpcID]),
                        sensitiveError: false
                    ) {
                        do {
                            try await idleTimeout.run()
                        } catch let error as IdleTimeoutError {
                            CloudBoardProviderCheckpoint(
                                logMetadata: Self.logMetadata(spanID: self.invokeWorkloadSpanID),
                                operationName: "cloudboard_invoke_workload_idle_timeout_error",
                                message: "preparing idle timeout",
                                error: error
                            ).log(to: Self.logger, level: .error)
                            throw GRPCTransformableError(idleTimeoutError: error)
                        }
                    }

                    group.addTaskWithLogging(
                        operation: "_invokeWorkload.requestStream",
                        diagnosticKeys: CloudBoardDaemonDiagnosticKeys([.rpcID]),
                        sensitiveError: false
                    ) {
                        do {
                            try await self.processInvokeWorkloadRequests(
                                requestStream: self.requestStream,
                                responseStream: self.responseWriter,
                                jobHelperClient: jobHelperClient,
                                idleTimeout: idleTimeout,
                                invokeWorkloadSpanID: self.invokeWorkloadSpanID
                            )
                            return .receiveInputCompleted
                        } catch let error as InvokeWorkloadStreamState.Error {
                            throw GRPCTransformableError(error)
                        }
                    }

                    group.addTaskWithLogging(
                        operation: "_invokeWorkload.jobHelperClient",
                        diagnosticKeys: CloudBoardDaemonDiagnosticKeys([.rpcID]),
                        sensitiveError: false
                    ) {
                        try await jobHelperClient.waitForExit(returnIfNotUsed: false)
                        // Now that we no longer have a cb_jobhelper instance, ensure
                        // the output stream is finished.
                        jobHelperResponseContinuation.finish()
                        return .jobHelperExited
                    }

                    group.addTaskWithLogging(
                        operation: "_invokeWorkload.jobHelperResponseStream",
                        diagnosticKeys: CloudBoardDaemonDiagnosticKeys([.rpcID]),
                        sensitiveError: false
                    ) {
                        try await self.processJobHelperResponses(
                            jobHelperResponseStream: jobHelperResponseStream,
                            idleTimeout: idleTimeout,
                            jobHelperClient: jobHelperClient,
                            delegate: delegate,
                            invokeWorkloadSpanID: self.invokeWorkloadSpanID
                        )
                        // Not including cb_jobhelper exit time in the request duration calculation.
                        self.requestSummarySpan.setManualEndTime(DefaultTracerClock.now)

                        return .responseOutputCompleted
                    }

                    // Once the associated cb_jobhelper exits and we finish sending
                    // any response data, we can cancel any remaining tasks.
                    enum CompletionStatus {
                        case awaitingCompletion
                        case awaitingResponseStreamCompletion
                        case awaitingJobHelperCompletion
                        case completed
                    }
                    var status: CompletionStatus = .awaitingCompletion
                    taskResultLoop: for try await result in group {
                        if group.isCancelled {
                            break
                        }
                        switch result {
                        case .jobHelperExited:
                            if status == .awaitingJobHelperCompletion {
                                status = .completed
                            } else {
                                status = .awaitingResponseStreamCompletion
                            }
                        case .responseOutputCompleted:
                            if status == .awaitingResponseStreamCompletion {
                                status = .completed
                            } else {
                                status = .awaitingJobHelperCompletion
                            }
                        case .receiveInputCompleted:
                            // Nothing to do, job helper is expected to terminate on its own at this point
                            ()
                        }
                        if case .completed = status {
                            CloudBoardProviderCheckpoint(
                                logMetadata: Self.logMetadata(spanID: self.invokeWorkloadSpanID),
                                operationName: "cb_jobhelper_completed",
                                message: "cb_jobhelper exited + output completed, cancelling remaining work in invokeWorkload"
                            ).log(to: Self.logger)
                            group.cancelAll()
                            break taskResultLoop
                        }
                    }
                }
            }
        }
    }

    private func processJobHelperResponses(
        jobHelperResponseStream: consuming AsyncStream<JobHelperInvokeWorkloadResponse>,
        idleTimeout: IdleTimeout<ContinuousClock>,
        jobHelperClient: CloudBoardJobHelperInstanceProtocol,
        delegate: JobHelperResponseDelegateProtocol,
        invokeWorkloadSpanID: String
    ) async throws {
        let workloadResponseSpanID = TraceContextCache.singletonCache.generateNewSpanID()
        self.serviceContext.withLock { $0.spanID = workloadResponseSpanID }
        self.serviceContext.withLock { $0.parentSpanID = invokeWorkloadSpanID }
        try await self.tracer.withSpan(
            OperationNames.invokeWorkloadResponse,
            context: self.serviceContext.withLock { $0 }
        ) { span in
            var requestedWorkerIDs: Set<UUID> = .init()
            defer {
                // this should get closed on sending last response chunk, but that isn't the case when an error
                // happens, so we close it here anyway
                self.finalRequestChunkToEndResponseSpan.withLock { span in
                    span?.end()
                    span = nil
                }
                self.finalRequestChunkToEndResponseSignpost.withLock { signpost in
                    if let signpost {
                        Self.signposter.endInterval(
                            "CB.finalRequestChunkToEndResponseSignpost",
                            signpost
                        )
                    }
                    signpost = nil
                }

                self.parametersToEndResponseSpan.withLock { span in
                    span?.end()
                    span = nil
                }

                self.parametersToEndResponseSignpost.withLock { signpost in
                    if let signpost {
                        Self.signposter.endInterval(
                            "CB.parametersToEndResponseSignpost",
                            signpost
                        )
                    }
                    signpost = nil
                }
                for requestedWorkerID in requestedWorkerIDs {
                    self.pccWorkerToInitiatorMapping.unlink(workerID: requestedWorkerID)
                }
            }
            span.attributes.requestSummary.responseChunkAttributes.spanID = workloadResponseSpanID
            span.attributes.requestSummary.responseChunkAttributes.parentSpanID = invokeWorkloadSpanID
            for await jobHelperResponse in jobHelperResponseStream {
                try await ServiceContext.withValue(self.serviceContext.withLock { $0 }) { // update the current context
                    Self.logger.debug(
                        "\(Self.logMetadata(), privacy: .public) received response from cb_jobhelper"
                    )
                    idleTimeout.registerActivity()

                    switch jobHelperResponse {
                    case .responseChunk(let responseChunk):
                        span.attributes.requestSummary.responseChunkAttributes
                            .chunksCount = (
                                span.attributes.requestSummary.responseChunkAttributes
                                    .chunksCount ?? 0
                            ) + 1
                        span.attributes.requestSummary.responseChunkAttributes
                            .isFinal = (
                                span.attributes.requestSummary.responseChunkAttributes
                                    .isFinal ?? false
                            ) || responseChunk.isFinal
                        // Send our response piece.
                        try await self.responseWriter.send(.with {
                            $0.responseChunk = .with {
                                $0.encryptedPayload = responseChunk.encryptedPayload
                                $0.isFinal = responseChunk.isFinal
                            }
                        })
                        if responseChunk.isFinal {
                            CloudBoardProviderCheckpoint(
                                logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                                operationName: "sentResponseChunkFinal",
                                message: "Sent final response chunk"
                            ).log(
                                to: Self.logger,
                                level: .default
                            )
                            self.finalRequestChunkToEndResponseSpan.withLock { span in
                                span?.end()
                                span = nil
                            }
                            self.finalRequestChunkToEndResponseSignpost.withLock { signpost in
                                if let signpost {
                                    Self.signposter.endInterval(
                                        "CB.finalRequestChunkToEndResponseSignpost",
                                        signpost
                                    )
                                }
                                signpost = nil
                            }

                            self.parametersToEndResponseSpan.withLock { span in
                                span?.end()
                                span = nil
                            }

                            self.parametersToEndResponseSignpost.withLock { signpost in
                                if let signpost {
                                    Self.signposter.endInterval(
                                        "CB.parametersToEndResponseSignpost",
                                        signpost
                                    )
                                }
                                signpost = nil
                            }
                        }
                        Self.logger.debug("\(Self.logMetadata(), privacy: .public) sent grpc response")
                    case .findWorker(let query):
                        let findWorkerDurationMeasurement =
                            OSAllocatedUnfairLock<ContinuousTimeMeasurement>(
                                initialState: ContinuousTimeMeasurement
                                    .start()
                            )
                        // By the time we get a findWorker call we must know the key used
                        // It may not have been validated as the *correct* one yet, but that's not a problem
                        // because we just want to filter things here, we validate later
                        let ourTransitiveTrust = try await self.attestationProvider.findProxiedReleaseDigests(
                            keyID: self.keyID.withLock { $0 }
                        )
                        var routingParameters = query.routingParameters
                        if !ourTransitiveTrust.isEmpty {
                            // If the proxy app specified it we do NOT change it's decision
                            // We do log to make sure it's clear it's happening though
                            if let preSpecified = routingParameters["releaseDigest"] {
                                if preSpecified.count == 0 {
                                    Self.logger
                                        .error(
                                            "cloud app overrode the transitively trusted set of release digests to empty"
                                        )
                                } else if Set(preSpecified).isSubset(of: ourTransitiveTrust) {
                                    if preSpecified.count == ourTransitiveTrust.count {
                                        Self.logger
                                            .debug(
                                                "cloud app respecified the transitively trusted set of release digests"
                                            )
                                    } else {
                                        Self.logger
                                            .log("cloud app restricted the transitively trusted set of release digests")
                                    }
                                } else {
                                    /// If we are performing validation then these requests may fail later
                                    /// if they end up used. This is deemed acceptable so people can test
                                    /// failure modes or force behaviours in ephemeral
                                    Self.logger
                                        .error(
                                            "cloud app overrode the transitively trusted set of release digests with ones we don't trust"
                                        )
                                }
                            } else {
                                routingParameters["releaseDigest"] = ourTransitiveTrust
                            }
                        }
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: query.spanID),
                            operationName: "requesting_worker",
                            message: "Requesting worker"
                        ).log(
                            workerID: query.workerID,
                            service: query.serviceName,
                            routingParameters: routingParameters,
                            to: Self.logger,
                            level: .info
                        )
                        self.pccWorkerToInitiatorMapping.link(
                            workerID: query.workerID,
                            jobHelperClient: jobHelperClient,
                            jobHelperResponseDelegate: delegate,
                            findWorkerDurationMeasurement: findWorkerDurationMeasurement
                        )
                        requestedWorkerIDs.insert(query.workerID)

                        let responseBypassMode = ResponseBypassMode(requested: query.responseBypass)
                        let protoBypass = switch responseBypassMode {
                        case .none:
                            Com_Apple_Cloudboard_Api_V1_ResponseBypassMode.none
                        case .matchRequestCiphersuiteSharedAeadState:
                            Com_Apple_Cloudboard_Api_V1_ResponseBypassMode
                                .matchRequestCiphersuiteSharedAeadState
                        }
                        try await self.responseWriter.send(.with {
                            $0.invokeProxyInitiate = .with {
                                $0.taskID = query.workerID.uuidString
                                $0.workload = .with {
                                    $0.type = query.serviceName
                                    $0.param = .init(routingParameters)
                                }
                                $0.traceContext.traceID = ServiceContext.current?.requestID ?? ""
                                $0.traceContext.spanID = query.spanID
                                $0.responseBypassMode = protoBypass
                                if query.forwardRequestChunks {
                                    $0.forwardBypassedRequestChunks = true
                                }
                            }
                        })
                    case .failureReport(let failureReason):
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                            operationName: "cb_jobhelper_failure_response",
                            message: "received error response from cb_jobhelper with FailureReason"
                        ).log(failureReason: failureReason, to: Self.logger)
                        if self.pushFailureReportsToROPES {
                            throw GRPCTransformableError(failureReason: failureReason)
                        }
                    case .workerError(let uuid):
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                            operationName: "cb_jobhelper_worker_error",
                            message: "received worker error from cb_jobhelper"
                        ).log(
                            workerID: uuid,
                            to: Self.logger,
                            level: .default
                        )
                        try await self.responseWriter.send(.with {
                            $0.proxyWorkerError = .with {
                                $0.taskID = uuid.uuidString
                            }
                        })
                    }
                }
            }
        }
    }

    private func processInvokeWorkloadRequests(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest>,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>,
        jobHelperClient: CloudBoardJobHelperInstanceProtocol,
        idleTimeout: IdleTimeout<ContinuousClock>,
        invokeWorkloadSpanID: String
    ) async throws {
        var cumulativeRequestBytesLimiter = CumulativeRequestBytesLimiter()
        var stateMachine = InvokeWorkloadRequestStateMachine()
        var state = InvokeWorkloadStreamState(isProxy: self.isProxy)

        let context: ServiceContext
        var updatedContextWithTraceContext = ServiceContext.current ?? .topLevel
        let workloadRequestSpanID = TraceContextCache.singletonCache.generateNewSpanID()
        updatedContextWithTraceContext.spanID = workloadRequestSpanID
        updatedContextWithTraceContext.parentSpanID = invokeWorkloadSpanID
        context = updatedContextWithTraceContext
        self.serviceContext.withLock { $0 = context }

        var requestChunksReceived = 0
        for try await request in requestStream {
            idleTimeout.registerActivity()
            try state.receiveMessage(request)

            // This is quite hacky, but we only get request ID with the parameters message, however once we have
            // received it, we would like to always carry it with our context.
            let context: ServiceContext
            if let requestID = extractRequestID(from: request) {
                var updatedContext = ServiceContext.current ?? .topLevel
                updatedContext.requestID = requestID
                context = updatedContext
                self.serviceContext.withLock { $0 = context }
            } else {
                context = self.serviceContext.withLock { $0 } // take the previously stored context
            }

            try await self.tracer.withSpan(OperationNames.invokeWorkloadRequest, context: context) { span in
                try cumulativeRequestBytesLimiter.enforceLimit(
                    self.maxCumulativeRequestBytes,
                    on: request,
                    metrics: self.metrics
                )
                span.attributes.requestSummary.workloadRequestAttributes.spanID = workloadRequestSpanID
                span.attributes.requestSummary.workloadRequestAttributes.parentSpanID = invokeWorkloadSpanID
                switch request.type {
                case .setup:
                    CloudBoardProviderCheckpoint(
                        logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                        operationName: "awaiting_warmup_complete_before_workload_setup_request",
                        message: "received workload setup request, awaiting warmup complete before continuing"
                    ).log(to: Self.logger)
                    span.attributes.requestSummary.workloadRequestAttributes.receivedSetup = true
                    let waitForWarmupCompleteTimeMeasurement = ContinuousTimeMeasurement.start()
                    do {
                        try await jobHelperClient.waitForWarmupComplete()
                        self.metrics.emit(
                            Metrics.CloudBoardProvider.WaitForWarmupCompleteTimeHistogram(
                                duration: waitForWarmupCompleteTimeMeasurement.duration
                            )
                        )
                    } catch {
                        self.metrics.emit(
                            Metrics.CloudBoardProvider.FailedWaitForWarmupCompleteTimeHistogram(
                                duration: waitForWarmupCompleteTimeMeasurement.duration
                            )
                        )
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                            operationName: "wait_for_warmup_complete_returned_error",
                            message: "waitForWarmupComplete returned error",
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }
                    CloudBoardProviderCheckpoint(
                        logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                        operationName: "warmup_completed",
                        message: "warmup completed, sending acknowledgement"
                    ).log(to: Self.logger)
                    idleTimeout.registerActivity()

                    try await responseStream.send(.with {
                        $0.setupAck = .with {
                            $0.supportTerminate = true
                            $0.supportNack = self.isProxy ? true : false
                            $0.supportAuthTokenWithRequestBypass = self.isProxy ? true : false
                        }
                    })
                case .parameters:
                    self.trustedProxyParametersToFirstRewrapDurationMeasurement
                        .withLock { $0 = ContinuousTimeMeasurement.start() }
                    let parentSpanID = request.parameters.traceContext.spanID
                    let requestID = request.parameters.requestID
                    let rpcID = self.serviceContext.withLock { $0.rpcID.uuidString }

                    // This spanID is needed to associate the cloudboardd spans(invokeWorkload + invokeProxyDialBack
                    // spans) with appropriate parent spans
                    TraceContextCache.singletonCache.setSpanID(
                        parentSpanID,
                        forKeyWithID: requestID,
                        forKeyWithSpanIdentifier: SpanIdentifier.parameters
                    )
                    TraceContextCache.singletonCache.setSpanID(
                        parentSpanID,
                        forKeyWithID: rpcID,
                        forKeyWithSpanIdentifier: SpanIdentifier.parameters
                    )

                    // This spanID is needed to associate the cb_jobhelper span to cloudboardd parent span
                    TraceContextCache.singletonCache.setSpanID(
                        invokeWorkloadSpanID,
                        forKeyWithID: requestID,
                        forKeyWithSpanIdentifier: SpanIdentifier.invokeWorkload
                    )
                    self.parametersToEndResponseSignpost.withLock {
                        $0 = Self.signposter.beginInterval("CB.parametersToEndResponseSignpost")
                    }
                    self.parametersToEndResponseSpan.withLock {
                        $0 = self.tracer.startSpan(OperationNames.invokeWorkloadParametersToResponseEnd)
                    }
                    CloudBoardProviderCheckpoint(
                        logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                        operationName: "workload_parameter_request_received",
                        message: "received workload parameters request"
                    ).log(to: Self.logger)

                    if request.parameters.hasRequestNack && request.parameters.requestNack {
                        span.attributes.requestSummary.workloadRequestAttributes.isNack = true
                    }
                    span.attributes.requestSummary.workloadRequestAttributes.receivedParameters = true
                    span.attributes.requestSummary.workloadRequestAttributes.bundleID = request.parameters
                        .tenantInfo
                        .bundleID
                    span.attributes.requestSummary.workloadRequestAttributes.featureID = request.parameters
                        .tenantInfo
                        .featureID
                    span.attributes.requestSummary.workloadRequestAttributes.workload = request.parameters.workload
                        .type
                    span.attributes.requestSummary.workloadRequestAttributes.automatedDeviceGroup =
                        request.parameters.tenantInfo.automatedDeviceGroup

                    // Check for replay and reject request if the decryption key has been seen before
                    do {
                        // This is not validated until the jobhelper unwraps the DEK,
                        // but it's fine to use for assumptions that will be irrelevant if the later
                        // validation fails and terminates the entire request
                        let keyID = request.parameters.decryptionKey.keyID
                        self.keyID.withLock { $0 = keyID }
                        // The encryptedPayload provides a means to perform anti replay as all the bytes
                        // within this (including the header) form part of the input to the downstream
                        // HPKE functionality, so there is no scope for  this (say by editing the
                        // keyId in the header) and getting a functional response.
                        try await self.sessionStore.addSession(
                            encryptedPayload: request.parameters.decryptionKey.encryptedPayload, keyID: keyID
                        )
                    } catch {
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                            operationName: "decryption_key_addition_to_session_store_failed",
                            message: "Failed to add decryption key to session store",
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }
                    let responseBypass: ResponseBypassMode
                    do {
                        responseBypass = try ResponseBypassMode(from: request.parameters)
                    } catch GRPCTransformableError.bypassVersionInvalid(value: let value) {
                        Self.logger.error(
                            "received request parameters indicating responseBypassMode of \(value, privacy: .public)"
                        )
                        throw GRPCTransformableError.bypassVersionInvalid(value: value)
                    }
                    if self.isProxy, responseBypass != .none {
                        let error = GRPCTransformableError.providedBypassSettingsToProxy
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                            operationName: "response_bypass_received_at_proxy",
                            message: "Proxy instance received response bypass instructions",
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }

                    // requestBypassed indicates to a proxy node that the encrypted application payload bypasses it,
                    // not that the worker is getting the original request. The worker should not care whether this
                    // happened or not so is not informed about it.
                    guard self.isProxy || !request.parameters.requestBypassed else {
                        let error = GRPCTransformableError.protocolError(
                            InvokeWorkloadStreamState.Error.receivedRequestBypassNotification
                        )
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                            operationName: "request_bypassed_received_at_worker",
                            message: "Worker instance received requestBypassed notification",
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }

                    if !request.parameters.requestBypassed,
                       self.enforceRequestBypass,
                       Self.requestBypassEnforceableWorkloads.contains(request.parameters.workload.type) {
                        let error = GRPCTransformableError.requestBypassEnforced
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(),
                            operationName: "expected_request_bypassed_not_set",
                            message: "Request bypassed is expected but not set",
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }
                case .requestChunk(let chunk):
                    requestChunksReceived += 1
                    let message: StaticString = if chunk.isFinal {
                        "workload_request_final_chunk_received"
                    } else {
                        "workload_request_chunk_received"
                    }
                    if chunk.isFinal {
                        self.finalRequestChunkToEndResponseSpan.withLock {
                            $0 = self.tracer.startSpan(OperationNames.invokeWorkloadRequestFinalToResponseEnd)
                        }
                        self.finalRequestChunkToEndResponseSignpost.withLock {
                            $0 = Self.signposter.beginInterval("CB.finalRequestChunkToEndResponseSignpost")
                        }
                    }
                    CloudBoardProviderCheckpoint(
                        logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                        operationName: message,
                        message: message
                    ).log(to: Self.logger)
                    span.attributes.requestSummary.workloadRequestAttributes.chunkSize = chunk.encryptedPayload
                        .count
                    span.attributes.requestSummary.workloadRequestAttributes.isFinal = chunk.isFinal

                    // ROPES sends a single request chunk containing the auth token to the proxy when request bypass
                    // is used. We enforce in cb_jobhelper that this is the only request chunk we process
                    if self.enforceRequestBypass, requestChunksReceived > 1 {
                        let error = GRPCTransformableError.providedRequestWhenBypassExpected
                        CloudBoardProviderCheckpoint(
                            logMetadata: Self.logMetadata(),
                            operationName: "erroneous_request_payload_received_on_bypass",
                            message: "Received more than one request chunk when proxy should be bypassed",
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }
                case .terminate(let message):
                    span.attributes.requestSummary.workloadRequestAttributes.ropesTerminationCode = message.code
                        .rawValue
                    span.attributes.requestSummary.workloadRequestAttributes.ropesTerminationReason = message.reason
                    CloudBoardProviderCheckpoint(
                        logMetadata: Self.logMetadata(spanID: invokeWorkloadSpanID),
                        operationName: "termination_from_ropes",
                        message: "Received termination notification from ROPES"
                    ).log(
                        terminationCode: message.code.rawValue,
                        terminationReason: message.reason,
                        to: Self.logger
                    )
                case .none:
                    break
                }
                try await self.invokeJobHelperRequest(
                    for: request,
                    stateMachine: &stateMachine,
                    jobHelperClient: jobHelperClient
                )
            }
        }

        try state.receiveEOF()
    }

    private func invokeJobHelperRequest(
        for request: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest,
        stateMachine: inout InvokeWorkloadRequestStateMachine,
        jobHelperClient: CloudBoardJobHelperInstanceProtocol
    ) async throws {
        switch request.type {
        case .setup, .terminate:
            // Nothing to forward
            return
        default:
            if let jobHelperRequest = CloudBoardDaemonToJobHelperMessage(from: request) {
                try stateMachine.receive(jobHelperRequest)
                try await jobHelperClient.invokeWorkloadRequest(jobHelperRequest)
            } else {
                CloudBoardProviderCheckpoint(
                    logMetadata: Self.logMetadata(spanID: self.invokeWorkloadSpanID),
                    operationName: "cloudboard_received_invalid_request_message",
                    message: "received invalid InvokeWorkloadRequest message on request stream, ignoring"
                ).log(to: Self.logger, level: .error)
            }
        }
    }

    internal static func logMetadata(spanID: String? = nil) -> CloudBoardDaemonLogMetadata {
        return CloudBoardProvider.logMetadata(spanID: spanID)
    }

    private func idleTimeout(
        timeout duration: Duration,
        taskName: String,
        taskID: String
    ) async -> IdleTimeout<ContinuousClock> {
        CloudBoardProviderCheckpoint(
            logMetadata: Self.logMetadata(spanID: self.invokeWorkloadSpanID),
            operationName: "preparing_idle_timeout",
            message: "preparing idle timeout"
        ).log(timeoutDuration: duration, to: Self.logger)
        return IdleTimeout(timeout: duration, taskName: taskName, taskID: taskID)
    }
}

/// State machine to keep track of invoke workload request state. Needed to determine when a request stream ends early,
/// i.e. before we have received a final chunk and a decryption key.
struct InvokeWorkloadRequestStateMachine {
    enum State {
        case awaitingFinalChunkAndDecryptionKey
        case awaitingFinalChunk
        case awaitingDecryptionKey
        case receivedFinalChunkAndDecryptionKey
        case terminated
    }

    private var state: State

    init() {
        self.state = .awaitingFinalChunkAndDecryptionKey
    }

    mutating func receive(_ request: CloudBoardDaemonToJobHelperMessage) throws {
        if case .requestChunk(_, let isFinal) = request, isFinal {
            switch self.state {
            case .awaitingFinalChunkAndDecryptionKey:
                self.state = .awaitingDecryptionKey
            case .awaitingFinalChunk:
                self.state = .receivedFinalChunkAndDecryptionKey
            case .awaitingDecryptionKey, .receivedFinalChunkAndDecryptionKey:
                throw CloudBoardProvider.Error.receivedMultipleFinalChunks
            case .terminated:
                CloudBoardProvider.logger.fault("Unexpectedly received request after request stream has terminated")
                throw CloudBoardProvider.Error.receivedRequestAfterRequestStreamTerminated
            }
        } else if case .parameters = request {
            switch self.state {
            case .awaitingFinalChunkAndDecryptionKey:
                self.state = .awaitingFinalChunk
            case .awaitingDecryptionKey:
                self.state = .receivedFinalChunkAndDecryptionKey
            case .awaitingFinalChunk, .receivedFinalChunkAndDecryptionKey:
                throw CloudBoardProvider.Error.receivedMultipleDecryptionKeys
            case .terminated:
                CloudBoardProvider.logger.fault("Unexpectedly received request after request stream has terminated")
                throw CloudBoardProvider.Error.receivedRequestAfterRequestStreamTerminated
            }
        }
    }

    mutating func streamEnded() throws {
        defer {
            self.state = .terminated
        }
        guard case .receivedFinalChunkAndDecryptionKey = self.state else {
            throw CloudBoardProvider.Error.incomingConnectionClosedEarly
        }
    }
}

extension Com_Apple_Cloudboard_Api_V1_LoadResponse {
    init(_ status: ServiceHealthMonitor.Status.Healthy) {
        self = .with {
            $0.currentBatchSize = UInt32(status.currentBatchSize)
            $0.maxBatchSize = UInt32(status.maxBatchSize)
            $0.optimalBatchSize = UInt32(status.optimalBatchSize)
        }
    }
}

extension [Proto_Ropes_Common_Workload.Parameter] {
    init(_ tags: [String: [String]]) {
        self = tags.map { key, values in
            .with {
                $0.key = key
                $0.value = values
            }
        }
    }
}

func extractRequestID(
    from request: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest
) -> String? {
    switch request.type {
    case .parameters(let parameters):
        return parameters.requestID
    default:
        return nil
    }
}

extension CloudBoardProvider {
    internal static func logMetadata(spanID: String? = nil) -> CloudBoardDaemonLogMetadata {
        return CloudBoardDaemonLogMetadata(
            rpcID: ServiceContext.current?.rpcID ?? .zero,
            requestTrackingID: ServiceContext.current?.requestID ?? "",
            spanID: spanID ?? ""
        )
    }
}

extension Parameters.PlaintextMetadata {
    init(
        tenantInfo: Proto_Ropes_Common_TenantInfo,
        workload: Proto_Ropes_Common_Workload
    ) {
        self.init(
            bundleID: tenantInfo.bundleID,
            bundleVersion: tenantInfo.bundleVersion,
            featureID: tenantInfo.featureID,
            clientInfo: tenantInfo.clientInfo,
            workloadType: workload.type,
            workloadParameters: Dictionary(parameters: workload.param),
            automatedDeviceGroup: tenantInfo.automatedDeviceGroup
        )
    }
}

extension [String: [String]] {
    init(parameters: [Proto_Ropes_Common_Workload.Parameter]) {
        self = [:]

        for parameter in parameters {
            self[parameter.key, default: []].append(contentsOf: parameter.value)
        }
    }
}

/// NOTE: CloudBoardDCore is considered safe for logging the entire error description, so the detailed error
/// is always logged as public in`CloudBoardProviderCheckpoint`.
struct CloudBoardProviderCheckpoint: RequestCheckpoint {
    var requestID: String? {
        self.logMetadata.requestTrackingID
    }

    var operationName: StaticString

    var serviceName: StaticString = "cloudboardd"

    var namespace: StaticString = "cloudboard"

    var error: Error?

    var logMetadata: CloudBoardDaemonLogMetadata

    var message: StaticString

    public init(
        logMetadata: CloudBoardDaemonLogMetadata,
        operationName: StaticString,
        message: StaticString,
        error: Error? = nil
    ) {
        self.logMetadata = logMetadata
        self.operationName = operationName
        self.message = message
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        rpcId=\(self.logMetadata.rpcID?.uuidString ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        """)
    }

    public func log(failureReason: FailureReason, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        rpcId=\(self.logMetadata.rpcID?.uuidString ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        failureReason=\(failureReason, privacy: .public)
        """)
    }

    public func log(timeoutDuration: Duration, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        rpcId=\(self.logMetadata.rpcID?.uuidString ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        timeoutDuration=\(timeoutDuration, privacy: .public)
        """)
    }

    public func log(terminationCode: Int, terminationReason: String, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(String(describing: self.logMetadata.remotePID), privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        rpcId=\(self.logMetadata.rpcID?.uuidString ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        terminationCode=\(terminationCode, privacy: .public),
        terminationReason=\(terminationReason, privacy: .public)
        """)
    }

    public func log(
        workerID: UUID,
        service: String,
        routingParameters: [String: [String]],
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(String(describing: self.logMetadata.remotePID), privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        rpcId=\(self.logMetadata.rpcID?.uuidString ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.uuid=\(workerID, privacy: .public),
        worker.service=\(service, privacy: .public),
        worker.routingParameters=\(routingParameters, privacy: .public)
        """)
    }

    public func log(
        workerID: UUID?,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(String(describing: self.logMetadata.remotePID), privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        rpcId=\(self.logMetadata.rpcID?.uuidString ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.uuid=\(workerID?.uuidString ?? "", privacy: .public)
        """)
    }
}

struct FetchAttestationRequestSummary: RequestSummary {
    let requestID: String? = nil // No request IDs for fetch attestation requests
    let automatedDeviceGroup: String? = nil // No automated device gorup for fetch attestation requests

    var startTimeNanos: Int64?
    var endTimeNanos: Int64?

    let operationName = "FetchAttestation"
    let type = "RequestSummary"
    var serviceName = "cloudboardd"
    var namespace = "cloudboard"

    let rpcID: UUID
    var attestationSet: AttestationSet?
    var error: Error?

    init(rpcID: UUID) {
        self.rpcID = rpcID
    }

    mutating func populateAttestationSet(attestationSet: AttestationSet) {
        self.attestationSet = attestationSet
    }

    func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        rpcId=\(self.rpcID, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { "\(String(reportable: $0))" } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        attestationSet=\(self.attestationSet.map { "\($0)" } ?? "", privacy: .public)
        """)
    }
}

extension ResponseBypassMode {
    init(from parameters: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Parameters) throws {
        // so old it doesn't know about it
        guard parameters.hasTrustedProxyMetadata else {
            self = .none
            return
        }
        // new but not specified at all
        guard parameters.trustedProxyMetadata.hasResponseBypassMode else {
            self = .none
            return
        }
        switch parameters.trustedProxyMetadata.responseBypassMode {
        case .none:
            self = .none
        case .matchRequestCiphersuiteSharedAeadState:
            self = .matchRequestCiphersuiteSharedAeadState
        case .UNRECOGNIZED(let value):
            // we don't know what this version is, so we fail safe
            throw GRPCTransformableError.bypassVersionInvalid(value: value)
        }
    }
}

/// Provides a mapping for remote PCC worker nodes to communicate back to the initiating app.
///
/// An initiating Cloud App (represented by `cb_jobhelper` instance) first requests a worker node
/// with a requested worker ID, at which point we establish a mapping here between the Cloud App and
/// any responses fo that worker ID.
final class PccWorkerToInitiatorMapping: Sendable {
    typealias PCCWorkerInitiator = (
        CloudBoardJobHelperInstanceProtocol,
        JobHelperResponseDelegateProtocol,
        OSAllocatedUnfairLock<ContinuousTimeMeasurement>
    )
    private let pccWorkerDelegates: OSAllocatedUnfairLock<[UUID: PCCWorkerInitiator]> = .init(initialState: [:])

    /// Link the workerID with the `CloudBoardJobHelperInstanceProtocol` and `JobHelperResponseDelegateProtocol`
    func link(
        workerID: UUID,
        jobHelperClient: CloudBoardJobHelperInstanceProtocol,
        jobHelperResponseDelegate: JobHelperResponseDelegateProtocol,
        findWorkerDurationMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement>
    ) {
        self.pccWorkerDelegates.withLock { $0[workerID] = (
            jobHelperClient,
            jobHelperResponseDelegate,
            findWorkerDurationMeasurement
        ) }
    }

    /// Returns the instance of `CloudBoardJobHelperInstanceProtocol` and
    /// `JobHelperResponseDelegateProtocol` that requested this worker.
    func getInitiator(workerID: UUID) -> PCCWorkerInitiator? {
        self.pccWorkerDelegates.withLock { $0[workerID] }
    }

    /// Removes the link
    func unlink(workerID: UUID) {
        self.pccWorkerDelegates.withLock { _ = $0.removeValue(forKey: workerID) }
    }

    func isEmpty() -> Bool {
        self.pccWorkerDelegates.withLock { $0.isEmpty }
    }
}
