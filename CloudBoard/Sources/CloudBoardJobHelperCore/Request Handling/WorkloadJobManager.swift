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
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import HTTPClientStateMachine
@_spi(HPKEAlgID) import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os
import Synchronization
import Tracing

enum WorkloadJobManagerError: ReportableError {
    case unknownWorkerID
    case workerRequestAfterFinal
    case workerAttestationValidationFailed(Error)
    case missingResponseBypassContextID
    case missingResponseBypassCapability
    case findWorkerFailed(UUID, UInt32, String?)
    case workerSessionFailure(UUID, UInt32, String?)
    case receivedApplicationPayloadWithRequestBypassEnabled

    var publicDescription: String {
        switch self {
        case .unknownWorkerID: "unknownWorkerID"
        case .workerRequestAfterFinal: "workerRequestAfterFinal"
        case .workerAttestationValidationFailed(let error):
            "workerAttestationValidationFailed(\(String(reportable: error)))"
        case .missingResponseBypassContextID: "missingResponseBypassContextID"
        case .missingResponseBypassCapability: "missingResponseBypassCapability"
        case .findWorkerFailed(_, let ropesErrorCode, let ropesMessage):
            "findWorkerFailed(ropesErrorCode: \(ropesErrorCode), ropesMessage: \(ropesMessage ?? "nil"))"
        case .workerSessionFailure(_, let ropesErrorCode, let ropesMessage):
            "workerSessionFailure(ropesErrorCode: \(ropesErrorCode), ropesMessage: \(ropesMessage ?? "nil"))"
        case .receivedApplicationPayloadWithRequestBypassEnabled: "receivedApplicationPayloadWithRequestBypassEnabled"
        }
    }
}

/// Job manager responsible for the communication with privatecloudcomputed on the client and unwrapping/wrapping the
/// application request and response payloads to and from the workload respectively.
final class WorkloadJobManager: Sendable {
    private typealias PrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    private typealias PrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse

    enum OutboundMessage: Equatable, Sendable {
        case chunk(FinalizableChunk<Data>)
        case findWorker(FindWorkerQuery)
        case workerDecryptionKey(UUID, keyID: Data, Data)
        case workerRequestMessage(UUID, FinalizableChunk<Data>)
        case workerRequestEOF(UUID)
        case workerError(UUID)
        case jobHelperEOF

        static func chunk(_ chunk: Data, isFinal: Bool = false) -> Self {
            .chunk(.init(chunk: chunk, isFinal: isFinal))
        }
    }

    fileprivate static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadJobManager"
    )

    private let isProxy: Bool
    private let requestStream: AsyncStream<PipelinePayload>
    private let responseContinuation: AsyncStream<WorkloadJobManager.OutboundMessage>.Continuation
    private let cloudAppRequestContinuation: AsyncStream<PipelinePayload>.Continuation
    private let attestationValidator: any CloudBoardAttestationWorkerValidationProtocol

    private let jobUUID: UUID
    private let uuid: UUID
    private let stateMachine: Mutex<WorkloadJobStateMachine>
    private let buffer: Mutex<LengthPrefixBuffer>
    private let workload: CloudAppWorkloadProtocol

    /// There is state not known/ready until the actual request parameters come through
    /// They are all defined here so it's clear
    struct RequestInProgress {
        let requestParameters: ParametersData

        internal init(
            requestParameters: ParametersData
        ) {
            self.requestParameters = requestParameters
        }
    }

    private let _requestInProgress: Mutex<RequestInProgress?> = .init(nil)

    /// State not reasonable to use unless this is a proxy,
    final class ProxyCapability: Sendable {
        let workerSessions: Mutex<[UUID: PCCWorkerSession]> = .init([:])
        let relFinalized: Mutex<Bool> = .init(false)

        // The id of the request is operating under, this matters for transitive trust
        // not available till the parameters are decoded
        let requestAttestationKeyID = Mutex<Data?>(nil)

        internal init() {}
    }

    // non nil only if we are running in a proxy
    private let _proxyCapability: ProxyCapability?
    private var proxyCapability: ProxyCapability {
        guard let capability = self._proxyCapability else {
            fatalError("Attempt to use a codepath that requires the proxy!")
        }
        return capability
    }

    /// Unknown till we have parameters, until we know either way treat it as false regardless
    private var hasAutomatedDeviceGroup: Bool {
        !(self._requestInProgress.withLock {
            $0?.requestParameters.plaintextMetadata.automatedDeviceGroup.isEmpty ?? true
        })
    }

    /// The metrics system to use.
    private let metrics: MetricsSystem

    private let tracer: any Tracer
    private let spanID: String

    private let requestHandlingSpan: Mutex<Span?> = .init(nil)
    private let responseHandlingSpan: Mutex<Span?> = .init(nil)
    private let invokeWorkloadSpan: Mutex<Span?> = .init(nil)

    private let requestMessageCount: Mutex<Int> = .init(0)
    private let responseMessageCount: Mutex<Int> = .init(0)

    init(
        tgtValidator: TokenGrantingTokenValidatorProtocol,
        enforceTGTValidation: Bool,
        isProxy: Bool,
        requestStream: AsyncStream<PipelinePayload>,
        maxRequestMessageSize: Int,
        responseContinuation: AsyncStream<WorkloadJobManager.OutboundMessage>.Continuation,
        cloudAppRequestContinuation: AsyncStream<PipelinePayload>.Continuation,
        workload: CloudAppWorkloadProtocol,
        attestationValidator: any CloudBoardAttestationWorkerValidationProtocol,
        metrics: MetricsSystem,
        jobUUID: UUID,
        tracer: any Tracer,
        jobHelperSpanID: String
    ) {
        self.isProxy = isProxy
        self.requestStream = requestStream
        self.responseContinuation = responseContinuation
        self.cloudAppRequestContinuation = cloudAppRequestContinuation
        self.workload = workload
        self.metrics = metrics
        self.attestationValidator = attestationValidator

        self.jobUUID = jobUUID
        self.uuid = UUID()
        self.stateMachine = .init(WorkloadJobStateMachine(
            tgtValidator: tgtValidator,
            isProxy: isProxy,
            enforceTGTValidation: enforceTGTValidation,
            metrics: metrics,
            jobUUID: self.jobUUID,
            spanID: jobHelperSpanID
        ))
        self.buffer = .init(.init(maxMessageSize: maxRequestMessageSize))
        self.tracer = tracer
        self._proxyCapability = isProxy ? .init() : nil
        self.spanID = jobHelperSpanID
    }

    internal func run() async {
        defer {
            self.invokeWorkloadSpan.withLock { $0?.end() }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                defer {
                    self.cloudAppRequestContinuation.finish()
                    self.requestHandlingSpan.withLock { $0?.end() }
                }
                do {
                    for await message in self.requestStream {
                        self.requestMessageCount.withLock {
                            $0 += 1
                        }
                        try await self.receivePipelineMessage(message)
                    }
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Request stream finished"
                    ).log(to: Self.logger, level: .default)
                    try self.stateMachine.withLock { try $0.terminate() }
                } catch {
                    self.requestHandlingSpan.withLock { $0?.recordError(error) }
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Error handling request stream",
                        error: error
                    ).log(to: Self.logger, level: .error)
                    do {
                        // If input stream failed, signal end of input stream to the workload.
                        // The error is expected to be sent back in the response stream
                        try await self.workload.endOfInput(error: error)
                    } catch {}
                }
            }

            group.addTask {
                var jobHelperEOFSent = false
                defer {
                    if !jobHelperEOFSent {
                        self.responseContinuation.yield(.jobHelperEOF)
                    }
                    self.responseContinuation.finish()
                    self.responseHandlingSpan.withLock { $0?.end() }
                }
                var responseSummarySent = false
                do {
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Sending back response UUID"
                    ).log(to: Self.logger, level: .default)
                    try self.responseContinuation.yield(.chunk(.init(chunk: self.uuidChunk())))

                    // Wait for workload responses, encode them, and forward them
                    var uncleanAppTermination = false
                    for try await response in self.workload.responseStream {
                        let responseMessagesReceived = self.responseMessageCount.withLock {
                            $0 += 1
                            return $0
                        }

                        await self.getWorkloadInvokeAndHandlingSpans(
                            isRequestHandlingSpan: false,
                            isResponseHandlingSpan: true
                        )

                        switch response {
                        case .chunk(let data):
                            // downsample the checkpoints we log for response chunks
                            if responseMessagesReceived <= 2 || responseMessagesReceived % 100 == 0 {
                                await WorkloadJobManagerCheckpoint(
                                    logMetadata: self.logMetadata(spanID: self.spanID),
                                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                                    message: "Received cloud app response",
                                    operationName: "received_response_chunk"
                                ).log(to: Self.logger, level: .default)
                            }
                            var serializedResponse = try PrivateCloudComputeResponse.with {
                                $0.type = .responsePayload(data)
                            }.serializedData()
                            serializedResponse.prependLength()
                            self.responseContinuation.yield(.chunk(.init(chunk: serializedResponse)))
                        case .internalError:
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app internalError notification",
                                operationName: "received_internal_error"
                            ).log(to: Self.logger, level: .default)
                            // Something went very wrong inside the cloud app, but it still managed to tell
                            // us about it. It's likely going to crash too, but the action done here
                            // avoids the cleanup code within CloudApp (which terminates everything 'nicely')
                            // causing us to treat this request as a success at the PCC layer.
                            // The simplest way to do that is to complete the pcc layer now (if we can)
                            // The cloud app is highly unlikely to be sending anything else useful to the
                            // client now so this doesn't matter.

                            // We have to close the REL if needed first
                            if self.isProxy {
                                try await self.sendRequestExecutionLogTermination()
                            }
                            if responseSummarySent {
                                Self.logger.error("Unable to report internalError within the cloud app to the client as the response summary has already been sent")
                                // Throwing at ths point would be counter productive, we do not expect this to
                                // happen and if the client got a clean respose first it may well be fine
                            } else {
                                let responseSummaryChunk = try self.responseSummaryChunk(treatAsFailure: true)
                                self.responseContinuation.yield(.chunk(.init(
                                    chunk: responseSummaryChunk,
                                    isFinal: true
                                )))
                                self.responseContinuation.yield(.jobHelperEOF)
                                jobHelperEOFSent = true
                                responseSummarySent = true
                                self.requestHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
                                }
                            }
                        case .endOfResponse:
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app endOfResponse notification",
                                operationName: "received_end_of_response"
                            ).log(to: Self.logger, level: .default)

                            // We can only send the response summary at this point if we are either a compute node, or
                            // a proxy and have already finalized the REL
                            if (self.isProxy && self.proxyCapability.relFinalized.withLock { $0 }) || !self.isProxy {
                                if !responseSummarySent {
                                    // At this point our only indication of success/failure is the possible unclean
                                    // exit,
                                    // which may not have happened or the message for it may not have reached us yet.
                                    // For now we accept this: if the cloud app cleanly terminates the response
                                    // writer, the REL is finalized (or not relevant) and *then* crashes it's
                                    // considered a success.
                                    // If the cloud app passed .internalError to us before then we would have reported
                                    // it as a failure. A more positive indication of success can be added as
                                    // a breaking change in the future
                                    let responseSummaryChunk = try self.responseSummaryChunk(
                                        treatAsFailure: uncleanAppTermination)
                                    self.responseContinuation.yield(.chunk(.init(
                                        chunk: responseSummaryChunk,
                                        isFinal: true
                                    )))
                                    self.responseContinuation.yield(.jobHelperEOF)
                                    jobHelperEOFSent = true
                                    responseSummarySent = true
                                }
                                self.requestHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
                                }
                            }
                        case .endJob:
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app endJob notification",
                                operationName: "received_end_job"
                            ).log(to: Self.logger, level: .default)
                            // the job has ended - we don't finish the loop until we have also received app termination
                            // signal, but we can send the final response chunk back to the client if we hadn't
                            // previously sent it.

                            // First, send final REL entry if it has not previously been finalized
                            // Send final REL entry IFF we got to the point of sending the REL
                            if self.isProxy {
                                try await self.sendRequestExecutionLogTermination()
                            }
                            // See comments in .endOfResponse case
                            if !responseSummarySent {
                                let responseSummaryChunk = try self.responseSummaryChunk(
                                    treatAsFailure: uncleanAppTermination)
                                self.responseContinuation.yield(.chunk(.init(
                                    chunk: responseSummaryChunk,
                                    isFinal: true
                                )))
                                responseSummarySent = true
                                self.requestHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
                                }
                            }
                        case .appTermination(let terminationMetadata):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app termination metadata",
                                operationName: "received_app_termination"
                            ).logAppTermination(
                                terminationMetadata: terminationMetadata,
                                to: Self.logger,
                                level: .default
                            )

                            if let statusCode = terminationMetadata.statusCode, statusCode != 0 {
                                uncleanAppTermination = true
                                self.requestHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes
                                        .appTerminationStatusCode = statusCode
                                }
                            }

                            if self._proxyCapability != nil {
                                // If any worker session has still not received EOF by this time
                                // we should explicitly close it, so the worker session
                                // input stream is closed.
                                self.proxyCapability.workerSessions.withLock {
                                    [responseContinuation = self.responseContinuation] in
                                    for (workerID, workerSession) in $0 {
                                        if workerSession.finishRequestStreamAndCloseSession() {
                                            responseContinuation.yield(.workerRequestEOF(workerID))
                                        }
                                    }
                                }
                            }
                        case .findWorker(let query):
                            try await self.receiveFindWorkerQuery(query: query)
                        case .workerRequestMessage(let workerID, let payload):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received worker request message",
                                operationName: "received_worker_request"
                            ).log(workerID: workerID, to: Self.logger, level: .debug)

                            guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] }) else {
                                await WorkloadJobManagerCheckpoint(
                                    logMetadata: self.logMetadata(spanID: self.spanID),
                                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                                    message: "Received worker message for unknown worker ID. Ignoring.",
                                    operationName: "worker_message_ignored"
                                ).log(workerID: workerID, to: Self.logger, level: .error)
                                throw WorkloadJobManagerError.unknownWorkerID
                            }

                            let encapsulatedMessage = try workerSession.encapsulateMessage(payload, isFinal: false)
                            self.responseContinuation.yield(.workerRequestMessage(
                                workerID,
                                .init(chunk: encapsulatedMessage, isFinal: false)
                            ))
                        case .workerRequestEOF(let workerID, let isError):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received worker request EOF",
                                operationName: "worker_request_eof"
                            ).log(workerID: workerID, to: Self.logger, level: .debug)

                            guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] }) else {
                                await WorkloadJobManagerCheckpoint(
                                    logMetadata: self.logMetadata(spanID: self.spanID),
                                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                                    message: "Received worker request message for unknown worker ID. Ignoring.",
                                    operationName: "worker_message_ignored"
                                ).log(workerID: workerID, to: Self.logger, level: .error)
                                throw WorkloadJobManagerError.unknownWorkerID
                            }

                            // Request chunks for the worker go through the proxy if they are not forwarded by ROPES.
                            // This can happen in 2 situations:
                            // - the request chunks are from the original client, and requestBypass is not enabled
                            // - the request chunks are not from the original client
                            let requestChunksThroughProxy = !workerSession.query.forwardRequestChunks
                            // We send EOF without the final message in case of errors
                            // since ROPES will see this as a close message, which has
                            // come before a final message, and would let the worker node
                            // know that something has gone wrong, and cancelling it's request
                            if !isError, requestChunksThroughProxy {
                                let encapsulatedMessage = try workerSession.encapsulateFinalMessage()
                                self.responseContinuation.yield(.workerRequestMessage(
                                    workerID,
                                    .init(chunk: encapsulatedMessage, isFinal: true)
                                ))
                            }
                            self.responseContinuation.yield(.workerRequestEOF(workerID))
                        case .finalizeRequestExecutionLog:
                            try await self.sendRequestExecutionLogTermination()
                        }
                    }

                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Cloud app response stream finished",
                        operationName: "worker_response_stream_finished"
                    ).log(to: Self.logger, level: .default)

                    // We should have already sent the summary on receiving `endOfResponse` or `endJob` from the
                    // CloudApp when finishing cleanly, but we may not have
                    if !responseSummarySent {
                        if self.isProxy {
                            try await self.sendRequestExecutionLogTermination()
                        }
                        // See comments in .endOfResponse case
                        let responseSummaryChunk = try self.responseSummaryChunk(
                            treatAsFailure: uncleanAppTermination)
                        self.responseContinuation.yield(.chunk(.init(
                            chunk: responseSummaryChunk,
                            isFinal: true
                        )))
                        self.requestHandlingSpan.withLock { $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true }
                    }

                    let plaintextMetadata = self._requestInProgress.withLock { $0?.requestParameters.plaintextMetadata }

                    self.metrics.emit(Metrics.WorkloadManager.SuccessResponsesSentCounter(
                        action: .increment,
                        automatedDeviceGroup: !(
                            plaintextMetadata?.automatedDeviceGroup
                                .isEmpty ?? true),
                        featureId: plaintextMetadata?.featureID,
                        bundleId: plaintextMetadata?.bundleID,
                        inferenceId: plaintextMetadata?.workloadParameters[workloadParameterInferenceIDKey]?.first
                    ))
                } catch {
                    self.invokeWorkloadSpan.withLock { $0?.recordError(error) }
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Error while processing request",
                        operationName: "error_request_processing",
                        error: error
                    ).log(to: Self.logger, level: .error)
                    do {
                        // Right now our code shouldn't allow this to happen but if we ever throw after already having
                        // sent the response summary, we shouldn't sent another one.
                        if !responseSummarySent {
                            if self.isProxy {
                                try await self.sendRequestExecutionLogTermination()
                            }
                            try self.responseContinuation.yield(
                                .chunk(.init(chunk: self.errorResponseSummaryChunk(for: error), isFinal: true))
                            )
                            if let workerError = error as? WorkloadJobManagerError {
                                switch workerError {
                                case .findWorkerFailed(let workerID, _, _), .workerSessionFailure(let workerID, _, _):
                                    self.responseContinuation.yield(.workerError(workerID))
                                default: break
                                }
                            }
                        }
                    } catch {
                        await WorkloadJobManagerCheckpoint(
                            logMetadata: self.logMetadata(spanID: self.spanID),
                            requestMessageCount: self.requestMessageCount.withLock { $0 },
                            responseMessageCount: self.responseMessageCount.withLock { $0 },
                            message: "Unexpectedly failed to serialize error response. Not sending error response summary",
                            operationName: "error_error_serialization",
                            error: error
                        ).log(to: Self.logger, level: .error)
                    }
                    self.invokeWorkloadSpan.withLock { $0?.recordError(error) }
                }
            }
            await group.waitForAll()
        }
    }

    private func getWorkloadInvokeAndHandlingSpans(
        isRequestHandlingSpan: Bool,
        isResponseHandlingSpan: Bool,
        requestID: String? = nil
    ) async {
        let remotePID = await self.workload.remotePID
        let parentSpanID = TraceContextCache.singletonCache.getSpanID(
            forKeyWithID: requestID ?? "",
            forKeyWithSpanIdentifier: SpanIdentifier.invokeWorkload
        )

        let existingContext = self.invokeWorkloadSpan.withLock {
            $0 = $0 ?? self.tracer.startSpan(
                OperationNames.invokeWorkload,
                context: ServiceContext.topLevel
            )
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.spanID = self.spanID
            if parentSpanID != nil {
                $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.parentSpanID = parentSpanID
            }

            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.jobUUID = self.jobUUID.uuidString
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.remotePID = remotePID
            return $0?.context
        }

        if isRequestHandlingSpan {
            let requestMessageCount = self.requestMessageCount.withLock { $0 }
            self.requestHandlingSpan.withLock {
                $0 = $0 ?? self.tracer.startSpan(
                    OperationNames.invokeWorkloadRequest,
                    context: existingContext ?? ServiceContext.topLevel
                )
                $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.requestMessageCount = requestMessageCount
            }
        }
        if isResponseHandlingSpan {
            let responseMessageCount = self.responseMessageCount.withLock { $0 }
            self.responseHandlingSpan.withLock {
                $0 = $0 ?? self.tracer.startSpan(
                    OperationNames.invokeWorkloadResponse,
                    context: existingContext ?? ServiceContext.topLevel
                )
                $0?.attributes.requestSummary.responseChunkAttributes.responseMessagesCount = responseMessageCount
            }
        }
    }

    // Used for .nackAndExit and normal .parameters
    // nothing expensive should happen here, just assign all the state we don't know till we get them
    private func registerParametersData(parametersData: ParametersData) async {
        await self.getWorkloadInvokeAndHandlingSpans(
            isRequestHandlingSpan: true,
            isResponseHandlingSpan: false,
            requestID: parametersData.plaintextMetadata.requestID
        )
        self.requestHandlingSpan.withLock {
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedParameters = true
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.requestID = parametersData.plaintextMetadata.requestID
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.bundleID = parametersData.plaintextMetadata.bundleID
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.featureID = parametersData.plaintextMetadata.featureID
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.automatedDeviceGroup = parametersData.plaintextMetadata.automatedDeviceGroup
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.workload = parametersData.plaintextMetadata.workloadType
        }

        self._requestInProgress.withLock { $0 = RequestInProgress(requestParameters: parametersData) }
        self.stateMachine.withLock {
            $0.receiveRequestID(requestID: parametersData.plaintextMetadata.requestID)
            $0.receiveAutomatedDeviceGroup(automatedDeviceGroup: parametersData.plaintextMetadata.automatedDeviceGroup)
            $0.receiveFeatureID(featureID: parametersData.plaintextMetadata.featureID)
            $0.receiveBundleID(bundleID: parametersData.plaintextMetadata.bundleID)
            $0.receiveInferenceID(inferenceID: parametersData.plaintextMetadata.workloadParameters[workloadParameterInferenceIDKey]?.first)
        }
    }

    private func receivePipelineMessage(_ pipelineMessage: PipelinePayload) async throws {
        self.metrics.emit(Metrics.WorkloadManager.TotalRequestsReceivedCounter(
            action: .increment,
            automatedDeviceGroup: self.hasAutomatedDeviceGroup
        ))
        do {
            switch pipelineMessage {
            case .warmup(let warmupData):
                self.requestHandlingSpan.withLock { $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedSetup = true }
                self.cloudAppRequestContinuation.yield(.warmup(warmupData))
            case .nackAndExit(let parametersData):
                await self.registerParametersData(parametersData: parametersData)
                self.requestHandlingSpan.withLock { $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.isNack = true }
                // treat this like an abandon in most respects
                self.stateMachine.withLock { $0.abandon() }
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Sending NACK and exiting"
                ).log(to: Self.logger, level: .default)
                // an empty REL is what constitutes a NACK
                try await self.sendRequestExecutionLogTermination()
                self.cloudAppRequestContinuation.yield(.abandon)
            case .oneTimeToken(let token):
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock { $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedToken = true }
                try self.stateMachine.withLock { try $0.receiveOneTimeToken(token) }
            case .parameters(let parametersData):
                await self.registerParametersData(parametersData: parametersData)

                self.stateMachine.withLock { $0.receivedRequestBypassMode(bypassed: parametersData.requestBypassed) }

                self.cloudAppRequestContinuation.yield(.parameters(parametersData))
            case .chunk(let finalizableChunk):
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.isFinal = finalizableChunk.isFinal
                }

                // The ROPES test client sends 0-byte payloads as final chunks. These aren't expected to be serialized
                // PrivateCloudCompute messages but exist to finalize the request stream.
                if finalizableChunk.chunk.isEmpty, finalizableChunk.isFinal {
                    Self.logger.debug("Received final 0-byte payload, forwarding as end of input")
                    self.cloudAppRequestContinuation.yield(.endOfInput)
                } else {
                    try await self.receiveEncodedRequest(finalizableChunk)
                }
            case .endOfInput:
                // Unexpected, ``endOfInput`` is only used between ``WorkloadJobManager`` and the cloud app in response
                // to an encoded request with PrivateCloudCompute.FinalMessage.
                ()
            case .abandon:
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock { $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.abandon = true }
                self.stateMachine.withLock { $0.abandon() }
                self.cloudAppRequestContinuation.yield(.abandon)
            case .teardown:
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock { $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.teardown = true }
                self.cloudAppRequestContinuation.yield(.teardown)
            case .parametersMetaData(let keyID):
                if self.isProxy {
                    self.proxyCapability.requestAttestationKeyID.withLock { $0 = keyID }
                }
                // yielded primarily to allow tests to spot that this occured
                // it's dropped later and doesn't make it to the cloud app itself
                self.cloudAppRequestContinuation.yield(pipelineMessage)
            case .workerFound(let workerID, _, let spanID):
                // We should replace PipelinePayload with multiple types so we aren't forced to handle cases that are
                // never expected to happen. .workerFound is only used between WorkloadJobManager and the cloud app,
                // same as .endOfInput above.
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: spanID),
                    message: "Received unexpected workerFound message from cloudboardd"
                ).log(workerID: workerID, to: Self.logger, level: .error)
            case .workerAttestationAndDEK(let workerAttestationInfo, let dek):
                try await self.receiveWorkerAttestationAndDEK(info: workerAttestationInfo, dataEncryptionKey: dek)
            case .workerResponseChunk(let workerID, let chunk):
                try await self.receiveWorkerResponseChunk(workerID: workerID, chunk: chunk)
            case .workerResponseSummary(let workerID, _):
                // We never expect to receive a workerResponseSummary from CloudBoardMessenger
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Received unexpected workerResponseSummary message from cloudboardd"
                ).log(workerID: workerID, to: Self.logger, level: .error)
            case .workerResponseClose(
                let workerID,
                let grpcStatus,
                let grpcMessage,
                let ropesErrorCode,
                let ropesMessage
            ):
                try await self.receiveWorkerResponseClose(
                    workerID: workerID,
                    grpcStatus: grpcStatus,
                    grpcMessage: grpcMessage,
                    ropesErrorCode: ropesErrorCode,
                    ropesMessage: ropesMessage
                )
            case .workerResponseEOF(let workerID):
                try await self.receiveWorkerResponseEOF(workerID: workerID)
            }
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                requestMessageCount: self.requestMessageCount.withLock { $0 },
                responseMessageCount: self.responseMessageCount.withLock { $0 },
                message: "received pipeline message"
            ).logReceiveRequestPipelineMessage(pipelineMessage: pipelineMessage, to: Self.logger, level: .default)
        } catch {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                requestMessageCount: self.requestMessageCount.withLock { $0 },
                responseMessageCount: self.responseMessageCount.withLock { $0 },
                message: "received pipeline message"
            ).logReceiveRequestPipelineMessage(pipelineMessage: pipelineMessage, to: Self.logger, level: .default)
            self.requestHandlingSpan.withLock { $0?.recordError(error) }
            throw error
        }
    }

    private func receiveEncodedRequest(_ encodedRequestChunk: FinalizableChunk<Data>) async throws {
        let chunks = try self.buffer.withLock {
            try $0.append(encodedRequestChunk)
        }
        for chunk in chunks {
            switch try PrivateCloudComputeRequest(serializedBytes: chunk.chunk).type {
            case .applicationPayload(let payload):
                if try self.stateMachine.withLock({ try $0.requestBypassed }) {
                    // Abandon the workload and throw
                    self.stateMachine.withLock { $0.abandon() }
                    throw WorkloadJobManagerError.receivedApplicationPayloadWithRequestBypassEnabled
                }

                if let cloudAppRequest = stateMachine.withLock({ $0.receiveChunk(FinalizableChunk(
                    chunk: payload,
                    isFinal: chunk.isFinal
                ))}) {
                    self.cloudAppRequestContinuation.yield(.chunk(cloudAppRequest))
                }
            case .authToken(let token):
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                    message: "Received auth token"
                ).log(to: Self.logger, level: .default)

                for cloudAppRequest in try self.stateMachine.withLock({ try $0.receiveAuthToken(token) }) {
                    switch cloudAppRequest {
                    case .chunk(let chunk):
                        self.cloudAppRequestContinuation.yield(.chunk(chunk))
                    case .finalMessage:
                        self.cloudAppRequestContinuation.yield(.endOfInput)
                    }
                }
            case .finalMessage:
                // This is a message without payload allowing privatecloudcomputed to explicitly indicate the end of the
                // request stream
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                    message: "Received final message"
                ).log(to: Self.logger, level: .default)
                self.cloudAppRequestContinuation.yield(.endOfInput)
            case .none:
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                    message: "Received encoded request of unknown type, ignoring"
                ).log(to: Self.logger, level: .debug)
            }
        }
    }

    private func receiveFindWorkerQuery(query: FindWorkerQuery) async throws {
        let workerID = query.workerID
        let findWorkerDurationMeasurement = OSAllocatedUnfairLock<ContinuousTimeMeasurement>(initialState: ContinuousTimeMeasurement.start())
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: query.spanID),
            requestMessageCount: self.requestMessageCount.withLock { $0 },
            responseMessageCount: self.responseMessageCount.withLock { $0 },
            message: "Received request to find worker"
        ).log(
            workerID: workerID,
            serviceName: query.serviceName,
            routingParameters: query.routingParameters,
            to: Self.logger,
            level: .default
        )

        // Best effort attempt to fail early in case a previous session was marked as final. We additionally enforce
        // not sending the re-wrapped DEK if the REL has previously been finalized at the time we receive the worker
        // attestation from ROPES (see `sendRequestExecutionLogEntry`).
        let previousSessionWasFinal = self.proxyCapability.workerSessions.withLock {
            $0.values.contains(where: { $0.isFinal })
        }
        guard !previousSessionWasFinal else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: query.spanID),
                message: "Received request to find a worker while a previous worker request was marked as final"
            ).log(workerID: workerID, to: Self.logger, level: .error)
            throw WorkloadJobManagerError.workerRequestAfterFinal
        }

        // We must wait for the auth token to have been received before we can make an outbound request as we otherwise
        // risk for the worker attestation to come back before we receive the auth token. As both messages are handled
        // by the same AsyncStream-consuming task in WorkloadJobManager, we cannot await the auth token message while
        // handling the worker attestation as that would result in a deadlock. Therefore, we wait here instead. Note
        // that this can result in a latency hit when the client delays sending the auth token which otherwise could be
        // received and processed in parallel to finding a worker and validating its attestation.
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Waiting for auth token before progressing with worker request"
        ).log(workerID: workerID, to: Self.logger, level: .default)
        _ = try await self.stateMachine.withLock {
            try $0.awaitTokenGrantingTokenAndOTTSalt()
        }.valueWithCancellation

        let sessionExisted = self.proxyCapability.workerSessions.withLock { workerSessions in
            guard workerSessions[query.workerID] == nil else {
                return true
            }

            let workerSession = PCCWorkerSession(
                workerID: workerID,
                query: query,
                responseBypassMode: ResponseBypassMode(requested: query.responseBypass),
                isFinal: query.isFinal,
                findWorkerDurationMeasurement: findWorkerDurationMeasurement
            )
            workerSessions[workerID] = workerSession
            return false
        }

        if sessionExisted {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: query.spanID),
                requestMessageCount: self.requestMessageCount.withLock { $0 },
                responseMessageCount: self.responseMessageCount.withLock { $0 },
                message: "Worker session already exists. Ignoring."
            ).log(workerID: workerID, to: Self.logger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        } else {
            self.responseContinuation.yield(.findWorker(query))
        }
    }

    private func receiveWorkerAttestationAndDEK(
        info: WorkerAttestationInfo,
        dataEncryptionKey: SymmetricKey
    ) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: info.spanID),
            message: "Received worker attestation"
        ).log(workerID: info.workerID, to: Self.logger, level: .default)

        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[info.workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Received worker attestation for unknown worker ID"
            ).log(workerID: info.workerID, to: Self.logger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }
        // Receive client-provided DEK that needs to be re-wrapped for the worker
        try workerSession.receiveDataEncryptionKey(dataEncryptionKey)

        // Validate attestation and obtain re-wrapped encapsulated DEK to be sent to worker
        let encapsulatedWorkerDEK: Data
        let bypassCapability: ResponseBypassCapability?
        let releaseDigest: String
        do {
            let validatedWorker = try await self.attestationValidator.validateWorkerAttestation(
                // by this stage we can assert the request key must be known
                proxyAttestationKeyID: self.proxyCapability.requestAttestationKeyID.withLock { $0!},
                rawWorkerAttestationBundle: info.attestationBundle
            )

            (encapsulatedWorkerDEK, bypassCapability) = try workerSession.receiveValidatedAttestation(validatedWorker)
            releaseDigest = validatedWorker.releaseDigest
        } catch {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Worker attestation validation failed",
                error: error
            ).log(workerID: info.workerID, to: Self.logger, level: .error)
            self.stateMachine.withLock { $0.abandon() }
            throw WorkloadJobManagerError.workerAttestationValidationFailed(error)
        }

        var responseBypass: (capability: ResponseBypassCapability, contextID: UInt32)?
        if bypassCapability != nil || info.bypassContextID != nil {
            guard bypassCapability != nil else {
                throw WorkloadJobManagerError.missingResponseBypassCapability
            }
            guard info.bypassContextID != nil else {
                throw WorkloadJobManagerError.missingResponseBypassContextID
            }
            responseBypass = (capability: bypassCapability!, contextID: info.bypassContextID!)
        }

        // We should not go further than this until we have obtained and validated the TGT. As we wait for the auth
        // token to have been received and processed when we initiate the worker request it MUST be available at this
        // point.
        let (tgt, ottSalt) = try await self.stateMachine.withLock {
            try $0.awaitTokenGrantingTokenAndOTTSalt()
        }.valueWithCancellation

        // Send REL entry back to the client. This will throw if the REL has previously been finalized in which case
        // the encapsulated DEK will not be sent to ROPES.
        try await self.sendRequestExecutionLogEntry(
            attestationBundle: info.attestationBundle,
            responseBypass: responseBypass,
            isFinal: workerSession.isFinal
        )

        // Send encapsulated DEK to worker
        self.responseContinuation.yield(.workerDecryptionKey(info.workerID, keyID: info.keyID, encapsulatedWorkerDEK))

        // The cloud app can only make outbound requests after we have received the Parameters message from ROPES
        // meaning that we also know at this point whether the node is bypassed or not. If bypassed, we don't have
        // a TGT to forward and don't need to do so because it is directly sent to the worker as part of the request
        // payload from the client.
        if !workerSession.query.forwardRequestChunks {
            // Send auth token to worker
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Sending auth token to worker"
            ).log(workerID: info.workerID, to: Self.logger, level: .debug)
            let encapsulatedAuthToken = try workerSession.encapsulateAuthToken(tgt: tgt, ottSalt: ottSalt)
            self.responseContinuation.yield(.workerRequestMessage(
                info.workerID,
                .init(chunk: encapsulatedAuthToken, isFinal: false)
            ))
        }

        let findWorkerDuration = workerSession.findWorkerDurationMeasurement.withLock { $0.duration }
        self.metrics
            .emit(
                Metrics.WorkloadManager
                    .FindWorkerDuration(
                        duration: findWorkerDuration
                    )
            )

        // Inform cloud app that a worker has been found
        self.cloudAppRequestContinuation.yield(.workerFound(
            info.workerID,
            releaseDigest: releaseDigest,
            spanID: info.spanID
        ))
    }

    private func receiveWorkerResponseChunk(workerID: UUID, chunk: FinalizableChunk<Data>) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received worker response chunk"
        ).log(workerID: workerID, to: Self.logger, level: .debug)
        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received worker response chunk for unknown worker ID"
            ).log(workerID: workerID, to: Self.logger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }

        let decapsulatedMessage = try workerSession.decapsulateMessage(chunk: chunk)
        switch decapsulatedMessage.type {
        case .responseUuid:
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response UUID for worker"
            ).log(workerID: workerID, to: Self.logger, level: .debug)
        // Do nothing. The response UUID has been replaced with a client-provided request ID but needs to be
        // sent for backward compatibility with privatecloudcomputed.
        case .responsePayload(let payload):
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response payload for worker"
            ).log(workerID: workerID, to: Self.logger, level: .debug)
            self.cloudAppRequestContinuation.yield(
                .workerResponseChunk(workerID, .init(chunk: payload, isFinal: chunk.isFinal))
            )
        case .responseSummary(let summary):
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response summary for worker"
            ).log(
                workerID: workerID,
                pccResponseStatus: summary.responseStatus.rawValue,
                to: Self.logger, level: .debug
            )
            self.cloudAppRequestContinuation.yield(.workerResponseSummary(
                workerID,
                succeeded: summary.responseStatus == .ok
            ))
        default:
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received pipeline message of unknown type"
            ).log(workerID: workerID, to: Self.logger, level: .error)
        }
    }

    private func receiveWorkerResponseClose(
        workerID: UUID,
        grpcStatus: Int,
        grpcMessage: String?,
        ropesErrorCode: UInt32?,
        ropesMessage: String?
    ) async throws {
        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response close for unknown worker ID"
            ).log(workerID: workerID, to: Self.logger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }

        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received gRPC status for worker"
        ).log(
            workerID: workerID,
            grpcStatus: grpcStatus,
            grpcMessage: grpcMessage,
            ropesErrorCode: ropesErrorCode,
            ropesMessage: ropesMessage,
            to: Self.logger,
            level: .debug
        )
        if let ropesErrorCode {
            self.stateMachine.withLock { $0.abandon() }
            if !workerSession.workerFound() {
                throw WorkloadJobManagerError.findWorkerFailed(workerID, ropesErrorCode, ropesMessage)
            } else {
                throw WorkloadJobManagerError.workerSessionFailure(workerID, ropesErrorCode, ropesMessage)
            }
        } else {
            self.cloudAppRequestContinuation.yield(.workerResponseSummary(workerID, succeeded: grpcStatus == 0))
        }
    }

    private func receiveWorkerResponseEOF(workerID: UUID) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received EOF for worker"
        ).log(workerID: workerID, to: Self.logger, level: .debug)
        self.cloudAppRequestContinuation.yield(.workerResponseEOF(workerID))
    }

    private func sendRequestExecutionLogTermination() async throws {
        try await self.makeProtoAndSendRequestExecutionLogEntry(
            attestationBundle: nil,
            responseBypass: nil,
            isFinal: true
        )
    }

    private func sendRequestExecutionLogEntry(
        attestationBundle: Data,
        responseBypass: (capability: ResponseBypassCapability, contextID: UInt32)?,
        isFinal: Bool
    ) async throws {
        try await self.makeProtoAndSendRequestExecutionLogEntry(
            attestationBundle: attestationBundle,
            responseBypass: responseBypass,
            isFinal: isFinal
        )
    }

    private func makeProtoAndSendRequestExecutionLogEntry(
        attestationBundle: Data?,
        responseBypass: (capability: ResponseBypassCapability, contextID: UInt32)?,
        isFinal: Bool
    ) async throws {
        guard self.isProxy else {
            fatalError("attempt to send a REL entry when not a proxy!")
        }

        let alreadyFinalized = self.proxyCapability.relFinalized.withLock { finalized in
            let alreadyFinalized = finalized
            finalized = isFinal
            return alreadyFinalized
        }

        if alreadyFinalized {
            if attestationBundle == nil {
                // Nothing to do
                return
            } else {
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Asked to send request execution log entry after it was already finalized"
                ).log(to: Self.logger, level: .error)
                throw WorkloadJobManagerError.workerRequestAfterFinal
            }
        }

        if isFinal {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Sending final request execution log entry"
            ).log(to: Self.logger, level: .default)
        } else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Sending request execution log entry"
            ).log(to: Self.logger, level: .info)
        }

        let requestExecutionLogEntry: PrivateCloudComputeResponse = .with {
            $0.requestExecutionLogEntry = .with {
                if let attestationBundle {
                    $0.attestation = attestationBundle
                }
                if let responseBypass {
                    $0.responseContext = .with {
                        $0.aeadID = UInt32(responseBypass.capability.aead.value)
                        $0.aeadKey = responseBypass.capability.aeadKey.withUnsafeBytes { Data($0) }
                        $0.aeadNonce = responseBypass.capability.aeadNonce
                        $0.contextID = responseBypass.contextID
                    }
                }
                $0.final = isFinal
            }
        }
        var relEntry = try requestExecutionLogEntry.serializedData()
        relEntry.prependLength()
        self.responseContinuation.yield(.chunk(.init(chunk: relEntry)))
    }

    private func uuidChunk() throws -> Data {
        let uuidMessage = PrivateCloudComputeResponse.with {
            $0.type = .responseUuid(withUnsafeBytes(of: self.uuid.uuid) { Data($0) })
        }
        var serialized = try uuidMessage.serializedData()
        serialized.prependLength()
        return serialized
    }

    private func responseSummaryChunk(treatAsFailure: Bool) throws -> Data {
        let summary: PrivateCloudComputeResponse = .with {
            $0.responseSummary = .with {
                if treatAsFailure {
                    $0.responseStatus = .internalError
                    $0.postResponseActions = .with {
                        $0.requestDiagnostics = true
                    }
                } else {
                    $0.responseStatus = .ok
                }
            }
        }
        var serializedResult = try summary.serializedData()
        serializedResult.prependLength()
        return serializedResult
    }

    private func errorResponseSummaryChunk(for error: Error) throws -> Data {
        let summary = PrivateCloudComputeResponse.with {
            $0.responseSummary = .with {
                $0.responseStatus = error.responseStatus
            }
        }
        var serializedResult = try summary.serializedData()
        serializedResult.prependLength()
        return serializedResult
    }
}

enum LengthPrefixedBufferError: ReportableError {
    case exceedingMaxMessageSize(maxSize: Int, announcedSize: Int)
    case receivedAdditionalChunkAfterFinalChunk
    case finalChunkContainsIncompleteMessage

    var publicDescription: String {
        let errorType = switch self {
        case .exceedingMaxMessageSize: "exceedingMaxMessageSize"
        case .receivedAdditionalChunkAfterFinalChunk: "receivedAdditionalChunkAfterFinalChunk"
        case .finalChunkContainsIncompleteMessage: "finalChunkContainsIncompleteMessage"
        }
        return "lengthPrefixedBuffer.\(errorType)"
    }
}

struct LengthPrefixBuffer {
    enum State {
        case waitingForLengthPrefix
        case waitingForData(Int)
        case finalChunkSeen
    }

    var buffer: Data
    var state: State

    /// maximum message size in bytes that we are willing to buffer in-memory
    let maxMessageSize: Int

    init(maxMessageSize: Int) {
        self.buffer = Data()
        self.state = .waitingForLengthPrefix
        self.maxMessageSize = maxMessageSize
    }

    mutating func append(_ chunkFragment: FinalizableChunk<Data>) throws -> [FinalizableChunk<Data>] {
        self.buffer.append(chunkFragment.chunk)

        var result: [FinalizableChunk<Data>] = []
        while !self.buffer.isEmpty {
            switch self.state {
            case .waitingForLengthPrefix:
                guard let length = buffer.getLength() else {
                    if chunkFragment.isFinal {
                        throw LengthPrefixedBufferError.finalChunkContainsIncompleteMessage
                    }
                    return result
                }
                guard length <= self.maxMessageSize else {
                    throw LengthPrefixedBufferError.exceedingMaxMessageSize(
                        maxSize: self.maxMessageSize,
                        announcedSize: length
                    )
                }
                self.buffer = self.buffer.dropFirst(4)
                self.state = .waitingForData(length)

            case .waitingForData(let length):
                guard self.buffer.count >= length else {
                    if chunkFragment.isFinal {
                        throw LengthPrefixedBufferError.finalChunkContainsIncompleteMessage
                    }
                    return result
                }

                if chunkFragment.isFinal, self.buffer.count == length {
                    // this is the last chunk and we are at the last message in that chunk
                    result.append(.init(chunk: self.buffer, isFinal: true))
                    self.buffer = Data()
                    self.state = .finalChunkSeen
                } else {
                    // This might be the last chunk fragment but it contains multiple messages.
                    // This is then not yet the last message and therefore we need to set isFinal to false and
                    // parse the the next message in the following iteration
                    // It might also not be the last chunk in which case we set isFinal false too
                    result.append(.init(chunk: self.buffer.prefix(length), isFinal: false))
                    self.buffer = self.buffer.dropFirst(length)
                    self.state = .waitingForLengthPrefix
                }

            case .finalChunkSeen:
                throw LengthPrefixedBufferError.receivedAdditionalChunkAfterFinalChunk
            }
        }

        return result
    }
}

extension Data {
    fileprivate func getLength() -> Int? {
        guard self.count >= 4 else { return nil }
        // swiftformat:disable all
        return Int(
            UInt32(self[startIndex])     << 24 |
            UInt32(self[startIndex + 1]) << 16 |
            UInt32(self[startIndex + 2]) <<  8 |
            UInt32(self[startIndex + 3])
        )
    }
}

enum WorkloadJobStateMachineError: ReportableError {
    case jobAbandoned
    case terminating
    case terminated
    case requestBypassed
    case requestBypassStateUnknown
    
    var publicDescription: String {
        switch self {
        case .jobAbandoned: "WorkloadJobStateMachineError.jobAbandoned"
        case .terminating: "WorkloadJobStateMachineError.terminating"
        case .terminated: "WorkloadJobStateMachineError.terminated"
        case .requestBypassed: "WorkloadJobStateMachineError.requestBypassed"
        case .requestBypassStateUnknown: "WorkloadJobStateMachineError.requestBypassStateUnknown"
        }
    }
}

struct WorkloadJobStateMachine {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadJobStateMachine"
    )

    enum BufferedMessage<T> where T: Sendable {
        case chunk(FinalizableChunk<T>)
        case finalMessage
    }
    
    internal enum RequestBypassMode {
        case unknown
        case bypassed
        case notBypassed
    }

    internal enum State {
        case awaitingOneTimeToken(
            requestBypass: RequestBypassMode,
            bufferedMessages: [BufferedMessage<Data>],
            authTokenPromise: Promise<(Data, Data), Error>
        )
        case awaitingTokenGrantingToken(
            requestBypass: RequestBypassMode,
            bufferedMessages: [BufferedMessage<Data>],
            oneTimeToken: Data,
            authTokenPromise: Promise<(Data, Data), Error>
        )
        case validatedTokenGrantingToken(requestBypass: RequestBypassMode, tgt: Data, ottSalt: Data)
        case abandoning
        case terminated(Bool)
    }

    private let tgtValidator: TokenGrantingTokenValidatorProtocol
    private let isProxy: Bool
    private let enforceTGTValidation: Bool
    private let metrics: MetricsSystem
    private var state: State

    private var requestID: String = ""
    private var automatedDeviceGroup: String = ""
    private var featureID: String = ""
    private var bundleID: String = ""
    private var inferenceID: String? = ""
    private let jobUUID: UUID
    private let spanID: String

    public var abandoned: Bool {
        switch self.state {
        case .abandoning:
            return true
        case .terminated(let abandoned):
            return abandoned
        default:
            return false
        }
    }

    init(
        tgtValidator: TokenGrantingTokenValidatorProtocol,
        isProxy: Bool,
        enforceTGTValidation: Bool,
        metrics: MetricsSystem,
        jobUUID: UUID,
        spanID: String
    ) {
        self.tgtValidator = tgtValidator
        self.isProxy = isProxy
        self.enforceTGTValidation = enforceTGTValidation
        self.metrics = metrics
        self.state = .awaitingOneTimeToken(
            requestBypass: .unknown,
            bufferedMessages: [],
            authTokenPromise: Promise<(Data, Data), Error>()
        )
        self.jobUUID = jobUUID
        self.spanID = spanID
    }

    mutating func receiveChunk(_ chunk: FinalizableChunk<Data>) -> FinalizableChunk<Data>? {
        WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "receiveChunk"
        ).loggingStateChange(to: Self.logger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, var bufferedMessages, let authTokenPromise):
                if case .bypassed = requestBypass {
                    authTokenPromise.fail(with: WorkloadJobStateMachineError.requestBypassed)
                    preconditionFailure("Received chunk with enabled request bypass")
                }
                bufferedMessages.append(.chunk(chunk))
                self.state = .awaitingOneTimeToken(
                    requestBypass: requestBypass,
                    bufferedMessages: bufferedMessages,
                    authTokenPromise: authTokenPromise
                )
                return (nil, self.state)
            case .awaitingTokenGrantingToken(let requestBypass, var bufferedMessages, let ott, let authTokenPromise):
                if case .bypassed = requestBypass {
                    authTokenPromise.fail(with: WorkloadJobStateMachineError.requestBypassed)
                    preconditionFailure("Received chunk with enabled request bypass")
                }
                bufferedMessages.append(.chunk(chunk))
                self.state = .awaitingTokenGrantingToken(
                    requestBypass: requestBypass,
                    bufferedMessages: bufferedMessages,
                    oneTimeToken: ott,
                    authTokenPromise: authTokenPromise
                )
                return (nil, self.state)
            case .validatedTokenGrantingToken(let requestBypass, _, _):
                precondition(requestBypass == .notBypassed, "Received chunk with enabled request bypass")
                return (chunk, self.state)
            case .abandoning:
                preconditionFailure("Received chunk after instance abandoned")
            case .terminated:
                preconditionFailure("Received chunk while already terminated")
            }
        }
    }

    mutating func receiveOneTimeToken(
        _ oneTimeToken: Data
    ) throws {
        try WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "receiveOneTimeToken"
        ).loggingStateChange(to: Self.logger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, let chunks, let authTokenPromise):
                self.state = .awaitingTokenGrantingToken(
                    requestBypass: requestBypass,
                    bufferedMessages: chunks,
                    oneTimeToken: oneTimeToken,
                    authTokenPromise: authTokenPromise
                )
                return ((), self.state)
            case .awaitingTokenGrantingToken, .validatedTokenGrantingToken:
                throw TokenGrantingTokenError.receivedOneTimeTokenTwice
            case .abandoning:
                preconditionFailure("Received OTT after instance abandoned")
            case .terminated:
                preconditionFailure("Received one-time token while already terminated")
            }
        }
    }

    mutating func receiveAuthToken(
        _ authToken: Proto_PrivateCloudCompute_AuthToken
    ) throws -> [BufferedMessage<Data>] {
        try WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "receiveAuthToken"
        ).loggingStateChange(to: Self.logger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken:
                // Unexpected, we should always receive the one-time token before the token granting token
                throw TokenGrantingTokenError.missingOneTimeToken
            case .awaitingTokenGrantingToken(let requestBypass, let bufferedMessages, let ott, let authTokenPromise):
                do {
                    let tgt = authToken.tokenGrantingToken
                    let ottSalt = authToken.ottSalt
                    // ROPES sends an empty OTT to compute nodes for proxied requests. Since the proxy will not provide
                    // the DEK until it has validated the TGT we do not have to re-validate it on compute nodes.
                    if self.isProxy || !ott.isEmpty {
                        try self.validateToken(tgt: tgt, ott: ott, ottSalt: ottSalt)
                    } else {
                        self.tgtValidator.notifyOfUnvalidatedTokenGrantingToken(tgt, ottSalt: ottSalt)
                        WorkloadJobManagerCheckpoint(
                            logMetadata: self.logMetadata(),
                            message: "Received auth token without one-time token, assuming TGT has been validated on proxy",
                            operationName: "validateToken"
                        ).log(to: WorkloadJobManager.logger, level: .default)
                    }
                    self.state = .validatedTokenGrantingToken(requestBypass: requestBypass, tgt: tgt, ottSalt: ottSalt)
                    switch requestBypass {
                    case .unknown:
                        throw WorkloadJobStateMachineError.requestBypassStateUnknown
                    case .bypassed:
                        if !bufferedMessages.isEmpty {
                            throw WorkloadJobStateMachineError.requestBypassed
                        }
                    case .notBypassed:
                        // nothing to do
                        ()
                    }
                    authTokenPromise.succeed(with: (tgt, ottSalt))
                    return (bufferedMessages, self.state)
                } catch {
                    authTokenPromise.fail(with: error)
                    throw error
                }
            case .validatedTokenGrantingToken:
                throw TokenGrantingTokenError.receivedTokenGrantingTokenTwice
            case .abandoning:
                preconditionFailure("Received auth token after instance abandoned")
            case .terminated:
                preconditionFailure("Received auth token while already terminated")
            }
        }
    }
    
    mutating func receivedRequestBypassMode(bypassed: Bool) {
        WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "requestBypassed"
        ).loggingStateChange(to: Self.logger, level: .debug) {
            let newBypassMode: RequestBypassMode = bypassed ? .bypassed : .notBypassed
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, let bufferedMessages, let authTokenPromise):
                precondition(requestBypass == .unknown, "Received request bypass notification twice")
                precondition(!bypassed || bufferedMessages.isEmpty, "Received request bypass notification with buffered messages")
                self.state = .awaitingOneTimeToken(requestBypass: newBypassMode, bufferedMessages: bufferedMessages, authTokenPromise: authTokenPromise)
            case .awaitingTokenGrantingToken(let requestBypass, let bufferedMessages, let oneTimeToken, let authTokenPromise):
                precondition(requestBypass == .unknown, "Received request bypass notification twice")
                precondition(!bypassed || bufferedMessages.isEmpty, "Received request bypass notification with buffered messages")
                self.state = .awaitingTokenGrantingToken(requestBypass: newBypassMode, bufferedMessages: bufferedMessages, oneTimeToken: oneTimeToken, authTokenPromise: authTokenPromise)
            case .validatedTokenGrantingToken(let requestBypass, let tgt, let ottSalt):
                precondition(requestBypass == .unknown, "Received request bypass notification twice")
                self.state = .validatedTokenGrantingToken(requestBypass: newBypassMode, tgt: tgt, ottSalt: ottSalt)
            case .abandoning:
                preconditionFailure("Received request bypass notification after instance abandoned")
            case .terminated:
                preconditionFailure("Received request bypass notification while already terminated")
            }
            
            return ((), self.state)
        }
    }
    
    /// Whether request bypass is used for the request or not. This will throw if called before the Parameters message
    /// has been received by ROPES and therefore should only be used in flows that can happen only after that message
    /// is received (e.g. worker requests)
    var requestBypassed: Bool {
        get throws {
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, _, _), .awaitingTokenGrantingToken(let requestBypass, _, _, _), .validatedTokenGrantingToken(let requestBypass, _, _):
                switch requestBypass {
                case .unknown: throw WorkloadJobStateMachineError.requestBypassStateUnknown
                case .bypassed: true
                case .notBypassed: false
                }
            case .abandoning:
                throw WorkloadJobStateMachineError.jobAbandoned
            case .terminated:
                throw WorkloadJobStateMachineError.terminated
            }
        }
    }

    mutating func abandon() {
        WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "abandon"
        ).loggingStateChange(to: Self.logger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken(_, _, let authTokenPromise),
                 .awaitingTokenGrantingToken(_, _, _, let authTokenPromise):
                authTokenPromise.fail(with: WorkloadJobStateMachineError.jobAbandoned)
                self.state = .abandoning
            case .terminated:
                preconditionFailure("Attempted to abandon after termination")
            default:
                self.state = .abandoning
            }
            return ((), self.state)
        }
    }

    mutating func terminate() throws {
        _ = try WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "terminate"
        ).loggingStateChange(to: Self.logger, level: .debug) {
            var isAbandoned = false
            switch self.state {
            case .awaitingOneTimeToken(_, _, let authTokenPromise):
                // Reached the end of the request stream without receiving the one-time token from ROPES
                authTokenPromise.fail(with: WorkloadJobStateMachineError.terminating)
                throw TokenGrantingTokenError.missingOneTimeToken
            case .awaitingTokenGrantingToken(_, _, _, let authTokenPromise):
                // Reached the end of the request stream without receiving a TGT
                authTokenPromise.fail(with: WorkloadJobStateMachineError.terminating)
                throw TokenGrantingTokenError.missingTokenGrantingToken
            case .validatedTokenGrantingToken:
                () // Nothing to do
            case .abandoning:
                isAbandoned = true
            case .terminated:
                preconditionFailure("Attempted to terminate more than once")
            }
            self.state = .terminated(isAbandoned)
            return ((), self.state)
        }
    }

    private func validateToken(tgt: Data, ott: Data, ottSalt: Data) throws {
        do {
            self.metrics.emit(Metrics.WorkloadManager.TGTValidationCounter(action: .increment,
                                     automatedDeviceGroup: !(self.automatedDeviceGroup.isEmpty),
                                     featureId: self.featureID,
                                     bundleId: self.bundleID,
                                     inferenceId: self.inferenceID
                                                                           ))
            try self.tgtValidator.validateTokenGrantingToken(tgt, ott: ott, ottSalt: ottSalt)
            WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(),
                message: "Successfully validated TGT",
                operationName: "validateToken"
            ).log(to: Self.logger, level: .default)
        } catch {
            self.metrics.emit(Metrics.WorkloadManager.TGTValidationErrorCounter(action: .increment, automatedDeviceGroup: !(self.automatedDeviceGroup.isEmpty), error: error, featureId: self.featureID, bundleId: self.bundleID, inferenceId: self.inferenceID))
            if self.enforceTGTValidation {
                WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(),
                    message: "Failed to validate TGT",
                    operationName: "validateToken",
                    error: error
                ).log(to: Self.logger, level: .error)
                throw error
            } else {
                WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Failed to validate TGT. Continuing as enforcement is disabled.",
                    operationName: "validateToken",
                    error: error
                ).log(to: Self.logger, level: .default)
            }
        }
    }
    
    mutating func awaitTokenGrantingTokenAndOTTSalt() throws -> Future<(Data, Data), Error> {
        switch self.state {
        case .awaitingOneTimeToken(_, _, let authTokenPromise),
             .awaitingTokenGrantingToken(_, _, _, let authTokenPromise):
            return Future(authTokenPromise)
        case .validatedTokenGrantingToken(_, let tgt, let ottSalt):
            let promise = Promise<(Data, Data), Error>()
            promise.succeed(with: (tgt, ottSalt))
            return Future(promise)
        case .abandoning:
            throw WorkloadJobStateMachineError.jobAbandoned
        case .terminated:
            throw WorkloadJobStateMachineError.terminated
        }
    }

    mutating func receiveRequestID(requestID: String) {
        self.requestID = requestID
    }
    
    mutating func receiveAutomatedDeviceGroup(automatedDeviceGroup: String) {
        self.automatedDeviceGroup = automatedDeviceGroup
    }

    mutating func receiveBundleID(bundleID: String) {
        self.bundleID = bundleID
    }
    
    mutating func receiveFeatureID(featureID: String) {
        self.featureID = featureID
    }
    
    mutating func receiveInferenceID(inferenceID: String?) {
        self.inferenceID = inferenceID
    }
    
    private func logMetadata(spanID: String? = nil) -> CloudBoardJobHelperLogMetadata {
        return CloudBoardJobHelperLogMetadata(
            jobID: self.jobUUID,
            requestTrackingID: self.requestID,
            spanID: spanID
        )
    }
}

enum TokenGrantingTokenError: ReportableError {
    case missingTokenGrantingToken
    case receivedTokenGrantingTokenTwice
    case missingOneTimeToken
    case receivedOneTimeTokenTwice
    
    var publicDescription: String {
        let errorType = switch self {
        case .missingTokenGrantingToken: "missingTokenGrantingToken"
        case .receivedTokenGrantingTokenTwice: "receivedTokenGrantingTokenTwice"
        case .missingOneTimeToken: "missingOneTimeToken"
        case .receivedOneTimeTokenTwice: "receivedOneTimeTokenTwice"
        }
        return "tokenGrantingToken.\(errorType)"
    }
}

protocol ResponseStatusConvertible: Error {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus { get }
}

extension Error {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case let convertibleError as ResponseStatusConvertible:
            return convertibleError.responseStatus
        default:
            return .internalError
        }
    }
}

extension TokenGrantingTokenError: ResponseStatusConvertible {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case .missingTokenGrantingToken, .missingOneTimeToken:
            return .unauthenticated
        case .receivedTokenGrantingTokenTwice, .receivedOneTimeTokenTwice:
            return .invalidRequest
        }
    }
}

extension TokenGrantingTokenValidationError: ResponseStatusConvertible {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        return .unauthenticated
    }
}

extension WorkloadJobManagerError: ResponseStatusConvertible {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case .findWorkerFailed:
            return .proxyFindWorkerError
        case .workerAttestationValidationFailed:
            return .proxyWorkerValidationError
        default:
            return .internalError
        }
    }
}

struct WorkloadJobManagerNoResponseSentError: ReportableError {
    var publicDescription: String {
        return "WorkloadJobManager.noResponseSent"
    }
}

extension WorkloadJobManager {
    private func logMetadata(spanID: String? = nil) async -> CloudBoardJobHelperLogMetadata {
        return await CloudBoardJobHelperLogMetadata(
            jobID: self.jobUUID,
            requestTrackingID: self._requestInProgress.withLock { $0?.requestParameters.plaintextMetadata.requestID },
            remotePID: self.workload.remotePID,
            spanID: spanID
        )
    }
}
