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

//  Copyright © 2023 - 2024 Apple Inc. All rights reserved.

internal import enum CloudBoardAsyncXPC.XPCDisconnectable
import CloudBoardCommon
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os

enum CloudBoardAppWorkloadError: ReportableError {
    case tornDownBeforeRunning
    case unexpectedTerminationError(Error)
    case illegalStateAfterClientIsRunning(String)
    case illegalStateAfterClientIsConnected(String)
    case illegalStateAfterClientTerminationFailed(String)
    case illegalStateWhenReceivingWorkerResponse(String)
    case cloudAppUnavailable(String)
    case monitoringCompletedEarly(Error?)
    case monitoringCompletedMoreThanOnce
    case jobNeverRan

    var publicDescription: String {
        let errorType = switch self {
        case .tornDownBeforeRunning: "tornDownBeforeRunning"
        case .unexpectedTerminationError(let error): "unexpectedTerminationError(\(String(reportable: error)))"
        case .illegalStateAfterClientIsRunning(let state): "illegalStateAfterClientIsRunning(\(state))"
        case .illegalStateAfterClientIsConnected(let state): "illegalStateAfterClientIsConnected(\(state))"
        case .illegalStateAfterClientTerminationFailed(let state): "illegalStateAfterClientTerminationFailed(\(state))"
        case .illegalStateWhenReceivingWorkerResponse(let state): "illegalStateWhenReceivingWorkerResponse(\(state))"
        case .cloudAppUnavailable(let state): "cloudAppUnavailable(\(state))"
        case .monitoringCompletedEarly(let error):
            if let error {
                "monitoringCompletedEarly(\(String(reportable: error)))"
            } else {
                "monitoringCompletedEarly"
            }
        case .monitoringCompletedMoreThanOnce: "monitoringCompletedMoreThanOnce"
        case .jobNeverRan: "jobNeverRan"
        }
        return "appWorkload.\(errorType)"
    }
}

/// Models CloudBoardJobHelper side of the API with the CloudApp workload.
///
/// Manages the state of the CloudApp process, including launching, warming it up and tearing it down,
/// monitors the state of the process, buffers any messages to the process as required,
/// and provides an interface to make calls to the workload as well as a `responseStream`.
package protocol CloudAppWorkloadProtocol: Actor {
    func run() async throws
    var remotePID: Int? { get }
    var abandoned: Bool { get async }

    nonisolated var responseStream: AsyncThrowingStream<CloudBoardJobHelperCore.CloudAppResponse, any Error> { get }

    func warmup(_ warmupData: WarmupData) async throws
    func provideInput(_ data: Data?, isFinal: Bool) async throws
    func endOfInput(error: Error?) async throws
    func parameters(_ parametersData: ParametersData) async throws
    func workerFound(workerID: UUID, releaseDigest: String, spanID: String?) async throws
    func workerResponseMessage(workerID: UUID, data: Data?, isFinal: Bool) async throws
    func workerResponseSummary(workerID: UUID, succeeded: Bool) async throws
    func teardown() async throws
    func abandon() async throws
}

actor CloudAppWorkload: CloudAppWorkloadProtocol {
    private var stateMachine: CloudBoardAppStateMachine

    private let job: any LaunchdJobInstanceInitiatorProtocol
    // Provides access to request secrets such as the DEK need to derive new secrets from client-provided key material
    private let requestSecrets: RequestSecrets

    private let log: Logger
    private(set) var remotePID: Int?
    private var requestID: String?
    private var spanID: String?
    private let metrics: MetricsSystem
    public var abandoned: Bool {
        get async {
            return await self.stateMachine.abandoned
        }
    }

    private nonisolated let (cloudAppResponseStream, cloudAppResponseContinuation) = AsyncThrowingStream<
        CloudBoardJobHelperCore.CloudAppResponse,
        any Error
    >.makeStream()

    init(
        definition: any LaunchdJobDefinitionProtocol,
        xpcClientFactory: any CloudAppXPCClientFactoryProtocol,
        requestSecrets: RequestSecrets,
        ensembleKeyDistributor: EnsembleKeyDistributorProtocol,
        log: Logger,
        metrics: any MetricsSystem,
        jobUUID: UUID,
        spanID: String?
    ) throws {
        self.log = log

        // Create a new job instance
        self.job = definition.createInstance(uuid: jobUUID)
        self.requestSecrets = requestSecrets
        self.stateMachine = CloudBoardAppStateMachine(
            xpcClientFactory: xpcClientFactory,
            job: self.job,
            requestSecrets: requestSecrets,
            ensembleKeyDistributor: ensembleKeyDistributor,
            log: log,
            spanID: spanID
        )
        self.metrics = metrics
        self.spanID = spanID
    }

    func run() async throws {
        await self.stateMachine.start()
        CloudBoardAppWorkloadCheckpoint(
            jobID: self.job.uuid,
            requestID: self.requestID,
            remotePID: self.remotePID,
            spanID: self.spanID,
            message: "Running job",
            state: nil
        ).log(to: self.log, level: .default)
        var lastKnownJobState: LaunchdJobEvents.State? = nil
        defer {
            CloudBoardAppWorkloadCheckpoint(
                jobID: self.job.uuid,
                requestID: self.requestID,
                remotePID: self.remotePID,
                spanID: self.spanID,
                message: "Job finished",
                state: lastKnownJobState
            ).log(to: self.log, level: .default)
        }
        do {
            for try await state in self.job.startAndWatch() {
                lastKnownJobState = state
                CloudBoardAppWorkloadCheckpoint(
                    jobID: self.job.uuid,
                    requestID: self.requestID,
                    remotePID: self.remotePID,
                    spanID: self.spanID,
                    message: "Job state changed",
                    state: state
                ).log(to: self.log, level: .info)
                switch state {
                case .initialized, .created, .starting, .terminating:
                    // Nothing to do
                    ()
                case .running(let pid):
                    self.remotePID = pid
                    try await self.stateMachine.clientIsRunning(pid: pid, responseHandler: self)
                case .terminated(let terminationCondition):
                    terminationCondition.emitMetrics(
                        metricsSystem: self.metrics,
                        counterFactory: Metrics.Workload.CloudAppExitCounter.Factory()
                    )

                    let statusCode: Int? = if case .exited(let status) = terminationCondition {
                        switch status {
                        case .osStatus(_, let code):
                            code
                        case .wait4Status(let code):
                            code
                        case .unknown:
                            nil
                        @unknown default:
                            nil
                        }
                    } else {
                        nil
                    }
                    await self.stateMachine.clientTerminated(statusCode: statusCode)
                    self.cloudAppResponseContinuation.yield(.appTermination(.init(statusCode: statusCode)))
                case .neverRan:
                    await self.stateMachine.clientTerminated(statusCode: nil)
                    self.cloudAppResponseContinuation.yield(.appTermination(.init(statusCode: nil)))
                @unknown default:
                    // Nothing to do
                    ()
                }
            }
        } catch {
            CloudBoardAppWorkloadCheckpoint(
                jobID: self.job.uuid,
                requestID: self.requestID,
                remotePID: self.remotePID,
                spanID: self.spanID,
                message: "Error while monitoring CloudApp, no longer monitoring",
                state: lastKnownJobState,
                error: error
            ).log(to: self.log, level: .error)
            self.cloudAppResponseContinuation.finish(throwing: error)
            try await self.stateMachine.monitoringCompleted(error: error)
            throw error
        }
        do {
            try await self.stateMachine.monitoringCompleted()
            self.cloudAppResponseContinuation.finish()
        } catch {
            self.cloudAppResponseContinuation.finish(throwing: error)
        }
    }

    public nonisolated var responseStream: AsyncThrowingStream<CloudBoardJobHelperCore.CloudAppResponse, any Error> {
        self.cloudAppResponseStream
    }

    public func provideInput(_ data: Data?, isFinal: Bool) async throws {
        try await self.stateMachine.provideInput(data, isFinal: isFinal)
    }

    /// Signal the end of input
    /// - Parameter error: error in case the input stream failed instead of finishing cleanly
    public func endOfInput(error: Error? = nil) async throws {
        if let error {
            // Should only teardown the cloudApp after the error is propagated back
            // Else there would be a race between the app terminating and finishing
            // the continuation, before retuning the error
            self.cloudAppResponseContinuation.finish(throwing: error)
            try await self.abandon()
        } else {
            try await self.stateMachine.endOfInput()
        }
    }

    public func warmup(_ warmupData: WarmupData) async throws {
        try await self.stateMachine.warmup(warmupData)
    }

    public func parameters(_ parametersData: ParametersData) async throws {
        self.requestID = parametersData.plaintextMetadata.requestID
        try await self.stateMachine.parameters(parametersData)
    }

    public func abandon() async throws {
        try await self.stateMachine.abandon()
    }

    public func teardown() async throws {
        try await self.stateMachine.teardown()
    }

    func workerFound(workerID: UUID, releaseDigest: String, spanID: String?) async throws {
        try await self.stateMachine.workerFound(workerID: workerID, releaseDigest: releaseDigest, spanID: spanID)
    }

    func workerResponseMessage(workerID: UUID, data: Data?, isFinal: Bool) async throws {
        try await self.stateMachine.workerResponseMessage(workerID: workerID, chunk: data, isFinal: isFinal)
    }

    func workerResponseSummary(workerID: UUID, succeeded: Bool) async throws {
        try await self.stateMachine.workerResponseSummary(workerID: workerID, succeeded: succeeded)
    }
}

extension CloudAppWorkload: CloudBoardJobAPICloudAppResponseHandlerProtocol {
    nonisolated func handleResponseChunk(_ chunk: Data) {
        self.cloudAppResponseContinuation.yield(.chunk(chunk))
    }

    func handleInternalError() async throws {
        self.cloudAppResponseContinuation.yield(.internalError)
    }

    func handleEndOfResponse() async throws {
        self.cloudAppResponseContinuation.yield(.endOfResponse)
    }

    func handleEndJob() async throws {
        self.cloudAppResponseContinuation.yield(.endJob)
    }

    func handleFindWorker(_ workerConstraints: WorkerConstraints) async throws {
        self.cloudAppResponseContinuation.yield(.findWorker(
            FindWorkerQuery(
                workerID: workerConstraints.workerID,
                serviceName: workerConstraints.serviceName,
                routingParameters: workerConstraints.routingParameters,
                responseBypass: workerConstraints.responseBypass,
                forwardRequestChunks: workerConstraints.forwardRequestChunks,
                isFinal: workerConstraints.isFinal,
                spanID: workerConstraints.spanID
            )
        ))
    }

    nonisolated func handleWorkerRequestMessage(_ workerRequestMessage: WorkerRequestMessage) {
        self.cloudAppResponseContinuation.yield(.workerRequestMessage(
            workerRequestMessage.workerID,
            workerRequestMessage.message
        ))
    }

    nonisolated func handleWorkerEOF(_ workerEOF: WorkerEOF) {
        self.cloudAppResponseContinuation.yield(.workerRequestEOF(workerEOF.workerID, workerEOF.isError))
    }

    nonisolated func handleFinaliseRequestExecutionLog() {
        self.cloudAppResponseContinuation.yield(.finalizeRequestExecutionLog)
    }

    nonisolated func disconnected(error: (any Error)?) {
        // Nothing we can do here but log because we already handle cloud app termination and finish the
        // cloudAppResponseContinuation in `run`.
        CloudBoardAppWorkloadCheckpoint(
            jobID: self.job.uuid,
            requestID: nil,
            remotePID: nil,
            spanID: nil,
            message: "Cloud app disconnected",
            state: nil,
            error: error
        ).log(to: self.log, level: .default)
    }
}

extension CloudAppWorkload {
    /// Testing only: handle of the underlying Launchd job
    var _testJobInitiator: any LaunchdJobInstanceInitiatorProtocol {
        self.job
    }
}

internal protocol CloudAppXPCClientFactoryProtocol: Sendable {
    func makeCloudAppXPCClient(
        for job: LaunchdJobInstanceInitiatorProtocol,
        responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol
    ) async throws -> CloudAppXPCClient
}

struct CloudAppXPCClientFactory: CloudAppXPCClientFactoryProtocol {
    func makeCloudAppXPCClient(
        for job: LaunchdJobInstanceInitiatorProtocol,
        responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol
    ) async throws -> CloudAppXPCClient {
        let cloudAppClient = await CloudAppXPCClient.localConnectionWithUUID(
            machServiceName: job.handle.attributes.initMachServiceName,
            uuid: job.uuid,
            responseHandler: responseHandler
        )
        return cloudAppClient
    }
}

private actor CloudBoardAppStateMachine {
    // NOTE: The description of this type is publicly logged and/or included in metric dimensions and therefore MUST not
    // contain sensitive data.
    enum State: CustomStringConvertible {
        case awaitingAppConnection([(data: Data?, isFinal: Bool)], WarmupData?, ParametersData?)
        case connecting([(data: Data?, isFinal: Bool)], WarmupData?, ParametersData?)
        case connected(CloudAppXPCClient)
        case terminating
        case terminated
        case monitoringCompleted

        // NOTE: This description is publicly logged and/or included in metric dimensions and therefore MUST not contain
        // sensitive data.
        var description: String {
            switch self {
            case .awaitingAppConnection: "awaitingAppConnection"
            case .connecting: "connecting"
            case .connected: "connected"
            case .terminating: "terminating"
            case .terminated: "terminated"
            case .monitoringCompleted: "monitoringCompleted"
            }
        }
    }

    private let xpcClientFactory: any CloudAppXPCClientFactoryProtocol
    private let job: any LaunchdJobInstanceInitiatorProtocol
    private let requestSecrets: RequestSecrets
    private let ensembleKeyDistributor: EnsembleKeyDistributorProtocol
    private var remotePID: Int?
    private var requestID: String?
    private var spanID: String?

    private let log: Logger
    private var state: State = .awaitingAppConnection([], nil, nil) {
        didSet(oldState) {
            self.log.trace("""
            jobID=\(self.job.uuid, privacy: .public)
            message=\("state changed", privacy: .public)
            oldState=\(oldState, privacy: .public)
            state=\(self.state, privacy: .public)
            """)
        }
    }

    private var started: Bool = false
    private let terminationPromise = Promise<Void, Error>()
    private var terminationRequest: TerminationRequest = .none
    public var abandoned: Bool {
        self.terminationRequest == .abandon
    }

    private enum TerminationRequest {
        case none
        case terminate
        case abandon
    }

    init(
        xpcClientFactory: CloudAppXPCClientFactoryProtocol,
        job: any LaunchdJobInstanceInitiatorProtocol,
        requestSecrets: RequestSecrets,
        ensembleKeyDistributor: EnsembleKeyDistributorProtocol,
        log: Logger,
        spanID: String?
    ) {
        self.xpcClientFactory = xpcClientFactory
        self.job = job
        self.requestSecrets = requestSecrets
        self.ensembleKeyDistributor = ensembleKeyDistributor
        self.log = log
        self.spanID = spanID
    }

    deinit {
        if !started {
            terminationPromise.fail(with: CloudBoardAppWorkloadError.tornDownBeforeRunning)
        }
    }

    func start() async {
        self.started = true
    }

    func provideInput(_ data: Data?, isFinal: Bool) async throws {
        switch self.state {
        case .awaitingAppConnection(
            let bufferedInputChunks,
            let warmupData,
            let parametersData
        ):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "buffering input data while waiting for connection to CloudApp",
                state: self.state
            ).log(to: self.log, level: .debug)
            self.state = .awaitingAppConnection(
                bufferedInputChunks + [(data, isFinal)], warmupData, parametersData
            )
        case .connecting(let bufferedInputChunks, let warmupData, let parametersData):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "buffering input data while waiting for connection to CloudApp",
                state: self.state
            ).log(to: self.log, level: .debug)
            self.state = .connecting(
                bufferedInputChunks + [(data, isFinal)],
                warmupData,
                parametersData
            )
        case .connected(let client):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "sending input data to CloudApp",
                state: self.state
            ).log(to: self.log, level: .debug)
            try await client.provideInput(data, isFinal: isFinal)
        case .terminating, .terminated, .monitoringCompleted:
            if data != nil {
                let error = CloudBoardAppWorkloadError.cloudAppUnavailable("\(self.state)")
                CloudBoardAppStateMachineCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Cannot forward input to CloudApp currently terminating",
                    state: self.state,
                    error: error
                ).log(to: self.log, level: .error)
                throw error
            } else {
                CloudBoardAppStateMachineCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "CloudApp currently terminating, no need to pass empty chunk",
                    state: self.state
                ).log(to: self.log, level: .debug)
            }
        }
    }

    func endOfInput() async throws {
        switch self.state {
        case .awaitingAppConnection(
            let bufferedInputChunks,
            let warmupData,
            let parametersData
        ):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "buffering end of input notification while waiting for connection to CloudApp",
                state: self.state
            ).log(to: self.log, level: .debug)
            self.state = .awaitingAppConnection(
                bufferedInputChunks + [(nil, true)], warmupData, parametersData
            )
        case .connecting(let bufferedInputChunks, let warmupData, let parametersData):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "buffering end of input notification while waiting for connection to CloudApp",
                state: self.state
            ).log(to: self.log, level: .debug)
            self.state = .connecting(
                bufferedInputChunks + [(nil, true)],
                warmupData,
                parametersData
            )
        case .connected(let client):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "sending end of input notification to CloudApp",
                state: self.state
            ).log(to: self.log, level: .debug)
            try await client.provideInput(nil, isFinal: true)
        case .terminating, .terminated, .monitoringCompleted:
            let error = CloudBoardAppWorkloadError.cloudAppUnavailable("\(self.state)")
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Cannot forward end of input notification to CloudApp currently terminating",
                state: self.state,
                error: error
            ).log(to: self.log, level: .error)
            throw error
        }
    }

    func clientIsRunning(
        pid: Int?,
        responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol
    ) async throws {
        self.remotePID = pid
        // Notice-/default-level log to ensure that we have the cb_jobhelper associated with the current request is
        // visible in Splunk
        CloudBoardAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "cloud app is running",
            state: self.state
        ).log(to: self.log, level: .default)
        switch self.state {
        case .awaitingAppConnection(let bufferedInputData, let warmupData, let parametersData):
            self.state = .connecting(bufferedInputData, warmupData, parametersData)
            try await self.connect(responseHandler: responseHandler)
        case .connecting, .connected,
             .terminating, .terminated, .monitoringCompleted:
            let error = CloudBoardAppWorkloadError.illegalStateAfterClientIsRunning("\(self.state)")
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "state machine in unexpected state after CloudApp state reported to be \"running\"",
                state: self.state,
                error: error
            ).log(to: self.log, level: .fault)
            throw error
        }
    }

    private func connect(
        responseHandler: CloudBoardJobAPICloudAppResponseHandlerProtocol
    ) async throws {
        CloudBoardAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Connecting to CloudApp",
            state: self.state
        ).log(to: self.log, level: .info)
        let cloudAppClient = try await xpcClientFactory.makeCloudAppXPCClient(
            for: self.job,
            responseHandler: responseHandler
        )

        await cloudAppClient.configureKeyDerivationHandler { keyDerivationRequest in
            switch keyDerivationRequest {
            case .distributeEnsembleKey(let info, let distributionType):
                do {
                    return try await self.distributeEnsembleKey(info: info, distributionType: .init(distributionType))
                } catch is CancellationError {
                    throw CloudAppToJobHelperDeriveKeyError.cancelled
                } catch {
                    throw CloudAppToJobHelperDeriveKeyError.failedKeyDerivation
                }
            }
        }
        await cloudAppClient.configureSealedKeyDerivationHandler { keyDerivationRequest in
            switch keyDerivationRequest {
            case .distributeSealedEnsembleKey(let info, let distributionType):
                do {
                    let keyInfo = try await self.distributeSealedEnsembleKey(
                        info: info,
                        distributionType: .init(distributionType)
                    )
                    return CloudBoardJobAPIEnsembleKeyInfo(
                        keyID: keyInfo.keyID,
                        keyEncryptionKey: keyInfo.keyEncryptionKey.withUnsafeBytes { Data($0) }
                    )
                } catch is CancellationError {
                    throw CloudAppToJobHelperDeriveKeyError.cancelled
                } catch {
                    throw CloudAppToJobHelperDeriveKeyError.failedKeyDerivation
                }
            }
        }
        CloudBoardAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Connected to CloudApp",
            state: self.state
        ).log(to: self.log, level: .info)
        try await self.clientIsConnected(client: cloudAppClient)
    }

    func warmup(_ warmupData: WarmupData) async throws {
        switch self.state {
        case .awaitingAppConnection(let data, _, let parametersData):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received warmup message",
                state: self.state
            ).log(to: self.log, level: .default)
            self.state = .awaitingAppConnection(data, warmupData, parametersData)
        case .connecting(let data, _, let parametersData):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received warmup message",
                state: self.state
            ).log(to: self.log, level: .default)
            self.state = .connecting(data, warmupData, parametersData)
        case .terminated:
            // This is a bit of a race but it's basically fine: we received this message as
            // we were tearing down. Do nothing.
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received warmup message after cloud app terminated, message will be dropped",
                state: self.state
            ).log(to: self.log, level: .error)
        case .connected(let client):
            try await client.warmup(details: .init())
        case .terminating, .monitoringCompleted:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received warmup data while CloudApp is terminating or monitoring completed",
                state: self.state
            ).log(to: self.log, level: .fault)
        }
    }

    func parameters(_ parametersData: ParametersData) async throws {
        self.requestID = parametersData.plaintextMetadata.requestID
        switch self.state {
        case .awaitingAppConnection(let data, let warmupData, _):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received parameters message",
                state: self.state
            ).log(to: self.log, level: .default)
            self.state = .awaitingAppConnection(data, warmupData, parametersData)
        case .connecting(let data, let warmupData, _):
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received parameters message",
                state: self.state
            ).log(to: self.log, level: .default)
            self.state = .connecting(data, warmupData, parametersData)
        case .terminated:
            // This is a bit of a race but it's basically fine: we received this message as
            // we were tearing down. Do nothing.
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received parameters message after cloud app terminated, message will be dropped",
                state: self.state
            ).log(to: self.log, level: .error)
        case .connected(let client):
            try await client.receiveParameters(parametersData: parametersData)
        case .terminating, .monitoringCompleted:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received parameters data while CloudApp is terminating or monitoring completed",
                state: self.state
            ).log(to: self.log, level: .fault)
        }
    }

    // Expected to be invoked from .connectingPendingWarmupData or .connecting states
    private func clientIsConnected(client: CloudAppXPCClient) async throws {
        switch self.state {
        case .connecting:
            if self.state.warmupData != nil {
                CloudBoardAppStateMachineCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Client is connected, forwarding previously received warmup data",
                    state: self.state
                ).log(to: self.log, level: .default)
                try await client.warmup(details: .init())
            }
            if let parametersData = state.parametersData {
                try await client.receiveParameters(parametersData: parametersData)
                CloudBoardAppStateMachineCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Client is connected, forwarding previously received parameters data",
                    state: self.state
                ).log(to: self.log, level: .default)
            }
            switch self.terminationRequest {
            case .none:
                while let (data, isFinal) = state.nextBufferedChunk() {
                    CloudBoardAppStateMachineCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "forwarding buffered input chunk to CloudApp",
                        state: self.state
                    ).log(to: self.log, level: .debug)
                    try await client.provideInput(data, isFinal: isFinal)
                }

                switch self.state {
                case .connecting:
                    self.state = .connected(client)
                case .terminated, .terminating, .monitoringCompleted:
                    // We have terminated in the meantime, nothing we can do
                    ()
                case .awaitingAppConnection, .connected:
                    let error = CloudBoardAppWorkloadError.illegalStateAfterClientIsConnected("\(self.state)")
                    CloudBoardAppStateMachineCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "State machine in unexpected state after connecting to CloudApp",
                        state: self.state,
                        error: error
                    ).log(to: self.log, level: .fault)
                    throw error
                }
            case .terminate, .abandon:
                // the CloudApp was requested to terminate
                // note the bufferedInputChunks here might be stale, but we don't
                // actually use the contained data so this is fine.
                try await self.teardownConnectedClient(
                    client: client,
                    bufferedInputChunks: self.state.bufferedInputChunks
                )
            }
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            ()
        case .awaitingAppConnection, .connected:
            let error = CloudBoardAppWorkloadError.illegalStateAfterClientIsConnected("\(self.state)")
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "State machine in unexpected state after connecting to CloudApp",
                state: self.state,
                error: error
            ).log(to: self.log, level: .fault)
            throw error
        }
    }

    func workerFound(workerID: UUID, releaseDigest: String, spanID: String?) async throws {
        switch self.state {
        case .awaitingAppConnection, .connecting:
            // Can never happen as worker can only be found is only sent in response to the cloud app requesting an
            // outbound connection
            let error = CloudBoardAppWorkloadError.illegalStateWhenReceivingWorkerResponse("\(self.state)")
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: spanID),
                message: "State machine in unexpected state after connecting to CloudApp",
                state: self.state,
                error: error
            ).log(to: self.log, level: .fault)
            throw error
        case .connected(let client):
            try await client.receiveWorkerFoundEvent(workerID: workerID, releaseDigest: releaseDigest)
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            ()
        }
    }

    func workerResponseMessage(workerID: UUID, chunk: Data?, isFinal: Bool) async throws {
        switch self.state {
        case .awaitingAppConnection, .connecting:
            // Can never happen as worker attestation is only sent in response to the cloud app requesting an outbound
            // connection
            let error = CloudBoardAppWorkloadError.illegalStateWhenReceivingWorkerResponse("\(self.state)")
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "State machine in unexpected state after connecting to CloudApp",
                state: self.state,
                error: error
            ).log(to: self.log, level: .fault)
            throw error
        case .connected(let client):
            if let chunk {
                try await client.receiveWorkerMessage(workerID: workerID, .payload(chunk))
            }
            if isFinal {
                try await client.receiveWorkerEOF(workerID: workerID)
            }
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            ()
        }
    }

    func workerResponseSummary(workerID: UUID, succeeded: Bool) async throws {
        switch self.state {
        case .awaitingAppConnection, .connecting:
            // Can never happen as worker attestation is only sent in response to the cloud app requesting an outbound
            // connection
            let error = CloudBoardAppWorkloadError.illegalStateWhenReceivingWorkerResponse("\(self.state)")
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "State machine in unexpected state after connecting to CloudApp",
                state: self.state,
                error: error
            ).log(to: self.log, level: .fault)
            throw error
        case .connected(let client):
            try await client.receiveWorkerResponseSummary(workerID: workerID, succeeded: succeeded)
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            ()
        }
    }

    func abandon() async throws {
        try await self.teardown(abandon: true)
    }

    func teardown(abandon: Bool = false) async throws {
        if self.terminationRequest != .none {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Job termination already requested, waiting for termination",
                state: self.state
            ).log(to: self.log, level: .default)
        } else {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received request to teardown job",
                state: self.state
            ).log(to: self.log, level: .default)
            if abandon == true {
                self.terminationRequest = .abandon
            } else {
                self.terminationRequest = .terminate
            }
        }

        switch self.state {
        case .awaitingAppConnection, .connecting:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received request to teardown CloudApp while not yet connected, waiting for connection",
                state: self.state
            ).log(to: self.log, level: .default)
            try await self.waitForTermination()
        case .connected(let client):
            try await self.teardownConnectedClient(client: client)
            try await self.waitForTermination()
        case .terminating:
            try await self.waitForTermination()
        case .terminated, .monitoringCompleted:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Ignoring request to teardown CloudApp",
                state: self.state
            ).log(to: self.log, level: .default)
        }
    }

    private func waitForTermination() async throws {
        do {
            try await Future(self.terminationPromise).valueWithCancellation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Unexpected error while waiting for terminationPromise to be fulfiled",
                state: self.state,
                error: error
            ).log(to: self.log, level: .fault)
            throw CloudBoardAppWorkloadError.unexpectedTerminationError(error)
        }
    }

    private func teardownConnectedClient(
        client: CloudBoardJobAPIClientToServerProtocol,
        bufferedInputChunks: [(data: Data?, isFinal: Bool)] = []
    ) async throws {
        if bufferedInputChunks.count > 0 {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "CloudApp requested to terminate with buffered input chunks",
                state: self.state
            ).log(to: self.log, level: .error)
        }
        self.state = .terminating
        CloudBoardAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(),
            message: "Sending teardown request to CloudApp",
            state: self.state
        ).log(to: self.log, level: .debug)
        do {
            try await client.teardown()
        } catch {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "client.teardown() returned error",
                state: self.state,
                error: error
            ).log(to: self.log, level: .error)
        }
    }

    func clientTerminated(statusCode _: Int?) async {
        switch self.state {
        case .awaitingAppConnection(_, _, _),
             .connecting:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "CloudApp has terminated with buffered input data chunks",
                state: self.state
            ).log(to: self.log, level: .error)
            self.terminationPromise.succeed()
        case .connected, .terminating:
            self.terminationPromise.succeed()
        case .terminated:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "CloudApp reported to have terminated after monitoring stopped",
                state: self.state
            ).log(to: self.log, level: .error)
        case .monitoringCompleted:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "CloudApp reported to have terminated after monitoring stopped",
                state: self.state
            ).log(to: self.log, level: .default)
        }

        self.state = .terminated
    }

    // This routine is guaranteed to be invoked once we make it to the point
    // of calling CloudBoardAppWorkload.run(). That ensures that the terminationPromise
    // is completed.
    func monitoringCompleted(error: Error? = nil) async throws {
        defer {
            self.state = .monitoringCompleted
        }

        switch self.state {
        case .awaitingAppConnection, .connecting, .terminating:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "CloudApp monitoring stopped before receiving termination notification",
                state: self.state,
                error: error
            ).log(to: self.log, level: .error)
            self.terminationPromise.fail(with: CloudBoardAppWorkloadError.monitoringCompletedEarly(error))
            throw CloudBoardAppWorkloadError.monitoringCompletedEarly(error)
        case .connected:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "cb_jobhelper monitoring stopped before receiving termination notification",
                state: self.state
            ).log(to: self.log, level: .error)
        case .terminated:
            // terminationPromise fulfilled in clientTerminated()
            ()
        case .monitoringCompleted:
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "cb_jobhelper monitoring reported to have completed twice",
                state: self.state,
                error: CloudBoardAppWorkloadError.monitoringCompletedMoreThanOnce
            ).log(to: self.log, level: .error)
            throw CloudBoardAppWorkloadError.monitoringCompletedMoreThanOnce
        }
    }

    func distributeEnsembleKey(
        info: String,
        distributionType: CloudBoardInternalEnsembleKeyDistributionType
    ) async throws -> UUID {
        do {
            let key = try await self.requestSecrets.deriveKey(
                info: Data(("ensemblekey" + info).utf8),
                // We generate a 256-bit key as we expect it to be used for AES-256-GCM.
                outputByteCount: 256 / 8
            )
            return try await self.ensembleKeyDistributor.distributeKey(key: key, distributionType: distributionType)
        } catch {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Failed to derive and distribute ensemble key",
                state: self.state,
                error: error
            ).log(to: self.log, level: .error)
            throw error
        }
    }

    func distributeSealedEnsembleKey(
        info: String,
        distributionType: CloudBoardInternalEnsembleKeyDistributionType
    ) async throws -> CloudBoardInternalEnsembleKeyInfo {
        do {
            let key = try await self.requestSecrets.deriveKey(
                info: Data(("SealedEnsembleKey" + info).utf8),
                // We generate a 256-bit key as we expect it to be used for AES-256-GCM.
                outputByteCount: 256 / 8
            )

            let ensembleKeyBytes = key.withUnsafeBytes { Data($0) }
            let keyEncryptionKey = SymmetricKey(size: .bits256)
            let SealedEnsembleKey = try AES.GCM.seal(ensembleKeyBytes, using: keyEncryptionKey)
            let keyID = try await self.ensembleKeyDistributor.distributeSealedKey(
                key: SealedEnsembleKey,
                distributionType: distributionType
            )
            return CloudBoardInternalEnsembleKeyInfo(keyID: keyID, keyEncryptionKey: keyEncryptionKey)
        } catch {
            CloudBoardAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Failed to derive and distribute ensemble key",
                state: self.state,
                error: error
            ).log(to: self.log, level: .error)
            throw error
        }
    }
}

// Needed to safely de-queue chunks after async calls.
extension CloudBoardAppStateMachine.State {
    var bufferedInputChunks: [(data: Data?, isFinal: Bool)] {
        switch self {
        case .awaitingAppConnection(let chunks, _, _):
            return chunks
        case .connecting(let chunks, _, _):
            return chunks
        case .connected, .monitoringCompleted, .terminating, .terminated:
            return []
        }
    }

    var warmupData: WarmupData? {
        switch self {
        case .awaitingAppConnection(_, let data, _):
            return data
        case .connecting(_, let data, _):
            return data
        case .connected, .monitoringCompleted, .terminating, .terminated:
            return nil
        }
    }

    var parametersData: ParametersData? {
        switch self {
        case .awaitingAppConnection(_, _, let data):
            return data
        case .connecting(_, _, let data):
            return data
        case .connected, .monitoringCompleted, .terminating, .terminated:
            return nil
        }
    }

    mutating func nextBufferedChunk() -> (data: Data?, isFinal: Bool)? {
        switch self {
        case .connecting(var bufferedInputData, let warmupData, let payloadData):
            guard bufferedInputData.count > 0 else { return nil }
            let data = bufferedInputData.removeFirst()
            self = .connecting(bufferedInputData, warmupData, payloadData)
            return data
        case .awaitingAppConnection, .connected, .terminating, .terminated, .monitoringCompleted:
            return nil
        }
    }
}

extension CloudBoardJobAPI.ParametersData {
    package init(_ data: CloudBoardJobHelperAPI.Parameters) {
        self.init(
            parametersReceived: data.parametersReceived,
            plaintextMetadata: .init(
                data.plaintextMetadata,
                requestID: data.requestID
            ),
            requestBypassed: data.requestBypassed,
            traceContext: .init(traceID: data.traceContext.traceID, spanID: data.traceContext.spanID)
        )
    }
}

extension CloudBoardJobAPI.ParametersData.PlaintextMetadata {
    init(_ data: CloudBoardJobHelperAPI.Parameters.PlaintextMetadata, requestID: String) {
        self.init(
            bundleID: data.bundleID,
            bundleVersion: data.bundleVersion,
            featureID: data.featureID,
            clientInfo: data.clientInfo,
            workloadType: data.workloadType,
            workloadParameters: data.workloadParameters,
            requestID: requestID,
            automatedDeviceGroup: data.automatedDeviceGroup
        )
    }
}

extension CloudBoardAppStateMachine {
    private func logMetadata(spanID: String? = nil) -> CloudBoardJobHelperLogMetadata {
        return CloudBoardJobHelperLogMetadata(
            jobID: self.job.uuid,
            requestTrackingID: self.requestID,
            remotePID: self.remotePID,
            spanID: spanID
        )
    }
}

private struct CloudBoardAppStateMachineCheckpoint: RequestCheckpoint {
    var requestID: String? {
        self.logMetadata.requestTrackingID
    }

    var operationName: StaticString

    var serviceName: StaticString = "cb_jobhelper"

    var namespace: StaticString = "cloudboard"

    var error: Error?

    var logMetadata: CloudBoardJobHelperLogMetadata

    var message: StaticString

    var state: CloudBoardAppStateMachine.State

    public init(
        logMetadata: CloudBoardJobHelperLogMetadata,
        operationName: StaticString = #function,
        message: StaticString,
        state: CloudBoardAppStateMachine.State,
        error: Error? = nil
    ) {
        self.logMetadata = logMetadata
        self.operationName = operationName
        self.message = message
        self.state = state
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
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        state=\(self.state, privacy: .public)
        message=\(self.message, privacy: .public)
        """)
    }
}

struct CloudBoardAppWorkloadCheckpoint: RequestCheckpoint {
    private(set) var jobID: UUID

    private(set) var requestID: String?

    private(set) var remotePID: Int?

    var operationName: StaticString

    var serviceName: StaticString = "cb_jobhelper"

    var namespace: StaticString = "cloudboard"

    var error: Error?

    var message: StaticString

    var state: LaunchdJobEvents.State?

    var spanID: String?

    public init(
        jobID: UUID,
        requestID: String?,
        remotePID _: Int?,
        spanID: String?,
        operationName: StaticString = #function,
        message: StaticString,
        state: LaunchdJobEvents.State?,
        error: Error? = nil
    ) {
        self.jobID = jobID
        self.requestID = requestID
        self.spanID = spanID
        self.operationName = operationName
        self.state = state
        self.message = message
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
        remotePid=\(self.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        state=\(String(describing: self.state), privacy: .public)
        """)
    }
}

/// Shared type to define distribution type for DEK-derived request specific keys used within ensembles
package enum CloudBoardInternalEnsembleKeyDistributionType: String, Codable, Sendable {
    /// Makes the key only available via ensembled on the leader of an ensemble
    case local
    /// Distribute the key to follower nodes of an ensemble
    case distributed

    init(_ distributionType: CloudBoardJobAPIEnsembleKeyDistributionType) {
        self = switch distributionType {
        case .local: .local
        case .distributed: .distributed
        }
    }
}

/// Shared type to define distribution type for DEK-derived request specific keys used within ensembles
package struct CloudBoardInternalEnsembleKeyInfo: Sendable {
    /// ID of the encrypted ensemble key assigned by ensembled
    package var keyID: UUID
    /// Symmetric 256-bit key used to encrypt/decrypt
    package var keyEncryptionKey: SymmetricKey

    package init(keyID: UUID, keyEncryptionKey: SymmetricKey) {
        self.keyID = keyID
        self.keyEncryptionKey = keyEncryptionKey
    }
}
