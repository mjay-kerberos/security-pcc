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

// Copyright © 2024 Apple. All rights reserved.

internal import CloudBoardCommon
internal import CloudBoardLogging
import CloudBoardJobAPI
import Foundation
import os

public enum PCCClientError: Error {
    case noHandlerResult
    case illegalTransition
    case usedAfterFinalizedCalled
}

// Used to make outbound requests to other Private Cloud Compute nodes from a cloud app.
public final class PCCClient: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PCCClient"
    )

    private let jobHelperMessenger: JobHelperMessengerProtocol
    private let clientRequestID: String
    private let finalized = OSAllocatedUnfairLock(initialState: false)
    private let forwardBypassedRequestChunksToWorker: OSAllocatedUnfairLock<Bool>

    init(jobHelperMessenger: JobHelperMessengerProtocol, clientRequestID: String, requestBypassed: Bool) {
        self.jobHelperMessenger = jobHelperMessenger
        self.clientRequestID = clientRequestID
        self.forwardBypassedRequestChunksToWorker = .init(initialState: requestBypassed)
    }

    public enum PCCWorkerResponse: Equatable, Sendable {
        public struct Result: Equatable, Sendable {
            public enum Status: Equatable, Sendable, CustomStringConvertible {
                case ok
                case failure

                public var description: String {
                    switch self {
                    case .ok: "OK"
                    case .failure: "Failure"
                    }
                }
            }

            public var status: Status

            static func from(_ result: WorkerResponseMessage.Result) -> PCCWorkerResponse.Result {
                return switch result {
                case .ok: .init(status: .ok)
                case .failure: .init(status: .failure)
                }
            }
        }

        case payload(Data)
        case result(Result)
    }

    public struct PCCRequestSession {
        public struct ResponseData: AsyncSequence {
            public typealias Element = PCCWorkerResponse
            public typealias Failure = Error
            public typealias AsyncIterator = AsyncThrowingStream<Element, Failure>.AsyncIterator

            let responseStream: AsyncThrowingStream<PCCWorkerResponse, Error>

            public func makeAsyncIterator() -> AsyncIterator {
                return self.responseStream.makeAsyncIterator()
            }
        }

        public struct RequestWriter {
            fileprivate typealias DataOutputContinuation = AsyncThrowingStream<Data, Error>.Continuation

            fileprivate let outputContinuation: DataOutputContinuation
            fileprivate init(_ outputContinuation: DataOutputContinuation) {
                self.outputContinuation = outputContinuation
            }

            public func write(_ output: Data) async throws {
                self.outputContinuation.yield(output)
            }

            public func finish() async throws {
                self.outputContinuation.finish()
            }
        }

        public let sessionID: UUID
        public let requestWriter: RequestWriter
        public let responseStream: ResponseData
        public let workerInfo: PCCWorkerInfo

        fileprivate init(
            sessionID: UUID,
            workerInfo: PCCWorkerInfo,
            _ requestWriter: RequestWriter,
            _ responseStream: ResponseData
        ) {
            self.sessionID = sessionID
            self.workerInfo = workerInfo
            self.requestWriter = requestWriter
            self.responseStream = responseStream
        }
    }

    enum RequestTaskGroupResult<ReturnType> {
        case handlerFinished(ReturnType)
        case handlerError(Error)
        case requestStreamFinished
        case requestStreamError(Error)
        case responseStreamFinished
    }

    enum PCCRequestCompletionStatus {
        case awaiting(requestStreamCompleted: Bool, responseStreamCompleted: Bool, handlerCompleted: Bool)
        case allComplete
    }

    /// Establishes a bidirectional request/response stream with another PCC node that matches the provided
    /// `serviceName` and `routingParameters`. Only usable from a cloud proxy app.
    ///
    /// - Parameters:
    ///   - serviceName: The service name to find a worker node for.
    ///   - routingParameters: The routing parameters to use when finding a worker node.
    ///   - responseBypass: If `true` the response stream from the worker will go directly to the initiating client
    ///   rather than coming back to this instance
    ///   - isFinal: If `true` CloudBoard sends a final Request Execution Log entry to the initiating client and
    ///   prevents any further outbound requests
    ///   - handler: Handler that is provided with a session object that provides a request writer to send request
    ///   messages to the worker node and a response stream for response messages from the worker. Node that in the case
    ///   response bypass is enabled, the response stream only ever contains a response summary once the worker request
    ///   completes.
    public func makePCCRequest<ReturnType>(
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        handler: @escaping (PCCRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            responseBypass: responseBypass,
            isFinal: isFinal,
            handler: handler,
            spanID: nil
        )
    }

    /// Calling `finalize` allows CloudBoard to signal back to the client via the Request Execution Log that for the
    /// current request no more outbound requests will be made. Once finalized, further calls to `makePCCRequest` will
    /// fail.
    ///
    /// Calling finalize multiple times or after a `makePCCRequest` has been made that was marked as final has no
    /// effect.
    public func finalize() async throws {
        let alreadyFinalized = self.finalized.withLock {
            let alreadyFinalized = $0
            $0 = true
            return alreadyFinalized
        }
        if !alreadyFinalized {
            try await self.jobHelperMessenger.finalizeRequestExecutionLog()
        }
    }

    public func makePCCRequest<ReturnType>(
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        handler: @escaping (PCCRequestSession) async throws -> ReturnType,
        spanID: String? = nil
    ) async throws -> ReturnType {
        let findWorkerSpanID = TraceContextCache.singletonCache.generateNewSpanID()
        let requestSummary = FindWorkerRequestSummaryProvisioner(
            requestID: self.clientRequestID,
            spanID: findWorkerSpanID,
            parentSpanID: spanID
        )
        try self.finalized.withLock { finalized in
            if finalized {
                throw PCCClientError.usedAfterFinalizedCalled
            } else if isFinal {
                finalized = true
            }
        }

        let (requestStream, requestContinuation) = AsyncThrowingStream<Data, Error>.makeStream(of: Data.self)
        let (responseStream, responseContinuation) = AsyncThrowingStream<PCCWorkerResponse, Error>.makeStream()
        let requestWriter = PCCRequestSession.RequestWriter(requestContinuation)
        let workerID = UUID()

        PCCClientCheckpoint(
            requestID: self.clientRequestID,
            workerID: workerID,
            message: "Received request to find PCC worker",
            spanID: findWorkerSpanID
        ).log(
            serviceName: serviceName,
            routingParameters: routingParameters,
            responseBypass: responseBypass,
            isFinal: isFinal,
            to: Self.logger,
            level: .info
        )

        // If this is the first worker request and the proxy has been bypassed for the request payload, ask ROPES
        // to forward the buffered request chunks to this worker.
        let forwardBypassedRequestChunks = self.forwardBypassedRequestChunksToWorker.withLock {
            let result = $0
            $0 = false
            return result
        }

        let (workerInfo, workerResponseStream) = try await jobHelperMessenger.findWorker(
            query: FindWorkerQuery(
                workerID: workerID,
                serviceName: serviceName,
                routingParameters: routingParameters,
                responseBypass: responseBypass,
                forwardRequestChunks: forwardBypassedRequestChunks,
                isFinal: isFinal,
                spanID: requestSummary.requestSummary.spanID ?? ""
            ), requestSummary: requestSummary
        )

        return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
            // Task group to handle requests from the cloud app to other PCC nodes
            group.addTask {
                do {
                    for try await request in requestStream {
                        try await self.jobHelperMessenger.sendWorkerRequestMessage(workerID: workerID, request)
                    }
                    try await self.jobHelperMessenger.sendWorkerEOF(workerID: workerID, isError: false)
                    return .requestStreamFinished
                } catch {
                    try await self.jobHelperMessenger.sendWorkerEOF(workerID: workerID, isError: true)
                    return .requestStreamError(error)
                }
            }

            // Task group to handle responses received from other PCC nodes via cb_jobhelper
            group.addTask {
                defer {
                    responseContinuation.finish()
                }
                for await response in workerResponseStream {
                    switch response {
                    case .payload(let data):
                        responseContinuation.yield(.payload(data))
                    case .result(let result):
                        responseContinuation.yield(.result(.from(result)))
                    @unknown default:
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            workerID: workerID,
                            message: "Received worker response message of unknown type. Ignoring.",
                            spanID: findWorkerSpanID
                        ).log(to: Self.logger, level: .error)
                    }
                }

                return .responseStreamFinished
            }

            // Task group to run the cloud app handler
            group.addTask {
                do {
                    return try await .handlerFinished(handler(PCCRequestSession(
                        sessionID: workerID,
                        workerInfo: workerInfo,
                        requestWriter,
                        .init(responseStream: responseStream)
                    )))
                } catch {
                    return .handlerError(error)
                }
            }

            var completionStatus = PCCRequestCompletionStatus.awaiting(
                requestStreamCompleted: false,
                responseStreamCompleted: false,
                handlerCompleted: false
            )
            var handlerResult: ReturnType? = nil
            for try await result in group {
                switch result {
                case .handlerFinished(let result):
                    switch completionStatus {
                    case .awaiting(let requestStreamCompleted, let responseStreamCompleted, let handlerCompleted):
                        if handlerCompleted {
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                workerID: workerID,
                                message: "Handler unexpectedly reported to have finished more than once",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.logger, level: .error)
                            await requestSummary.populate(error: PCCClientError.illegalTransition)
                            await requestSummary.log(to: Self.logger)
                            throw PCCClientError.illegalTransition
                        } else {
                            // This can happen due to a race condition which doesn't affect correctness in any way.
                            if !responseStreamCompleted {
                                PCCClientCheckpoint(
                                    requestID: self.clientRequestID,
                                    workerID: workerID,
                                    message: "Handler unexpectedly finished before response stream from worker to cloud app finished",
                                    error: PCCClientError.illegalTransition,
                                    spanID: findWorkerSpanID
                                ).log(to: Self.logger, level: .default)
                                requestContinuation.finish(throwing: PCCClientError.illegalTransition)
                                await requestSummary.populate(error: PCCClientError.illegalTransition)
                                await requestSummary.log(to: Self.logger)
                                throw PCCClientError.illegalTransition
                            }

                            handlerResult = result
                            if requestStreamCompleted {
                                completionStatus = .allComplete
                            } else {
                                completionStatus = .awaiting(
                                    requestStreamCompleted: requestStreamCompleted,
                                    responseStreamCompleted: true,
                                    handlerCompleted: true
                                )
                                requestContinuation.finish()
                            }
                        }
                    case .allComplete:
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            workerID: workerID,
                            message: "Handler unexpectedly reported to have finished more than once",
                            error: PCCClientError.illegalTransition,
                            spanID: findWorkerSpanID
                        ).log(to: Self.logger, level: .error)
                        await requestSummary.populate(error: PCCClientError.illegalTransition)
                        await requestSummary.log(to: Self.logger)
                        throw PCCClientError.illegalTransition
                    }
                case .handlerError(let error):
                    PCCClientCheckpoint(
                        requestID: self.clientRequestID,
                        workerID: workerID,
                        message: "Cloud app failed during outbound request processing",
                        error: error,
                        spanID: findWorkerSpanID
                    ).log(to: Self.logger, level: .error)
                    requestContinuation.finish(throwing: error)
                    group.cancelAll()
                    completionStatus = .allComplete
                    throw error
                case .requestStreamFinished:
                    switch completionStatus {
                    case .awaiting(let requestStreamCompleted, let responseStreamCompleted, let handlerCompleted):
                        if requestStreamCompleted {
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                workerID: workerID,
                                message: "Request stream unexpectedly reported to have finished more than once",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.logger, level: .error)
                            await requestSummary.populate(error: PCCClientError.illegalTransition)
                            await requestSummary.log(to: Self.logger)
                            throw PCCClientError.illegalTransition
                        } else {
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                workerID: workerID,
                                message: "Request stream finished",
                                spanID: findWorkerSpanID
                            ).log(to: Self.logger, level: .debug)
                            if responseStreamCompleted, handlerCompleted {
                                completionStatus = .allComplete
                            } else {
                                completionStatus = .awaiting(
                                    requestStreamCompleted: true,
                                    responseStreamCompleted: responseStreamCompleted,
                                    handlerCompleted: handlerCompleted
                                )
                            }
                        }
                    case .allComplete:
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            workerID: workerID,
                            message: "Request stream unexpectedly reported to have finished more than once",
                            error: PCCClientError.illegalTransition,
                            spanID: findWorkerSpanID
                        ).log(to: Self.logger, level: .error)
                        await requestSummary.populate(error: PCCClientError.illegalTransition)
                        await requestSummary.log(to: Self.logger)
                        throw PCCClientError.illegalTransition
                    }
                case .requestStreamError(let error):
                    PCCClientCheckpoint(
                        requestID: self.clientRequestID,
                        workerID: workerID,
                        message: "Error while forwarding worker request message from cloud app",
                        error: error,
                        spanID: findWorkerSpanID
                    ).log(to: Self.logger, level: .error)
                    await requestSummary.populate(error: error)
                    await requestSummary.log(to: Self.logger)
                    group.cancelAll()
                    completionStatus = .allComplete
                    throw error
                case .responseStreamFinished:
                    switch completionStatus {
                    case .awaiting(let requestStreamCompleted, let responseStreamCompleted, let handlerCompleted):
                        if handlerCompleted {
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                workerID: workerID,
                                message: "Response stream unexpectedly reported to have finished after cloud app handler",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.logger, level: .error)
                            await requestSummary.populate(error: PCCClientError.illegalTransition)
                            await requestSummary.log(to: Self.logger)
                            throw PCCClientError.illegalTransition
                        } else if !responseStreamCompleted {
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                workerID: workerID,
                                message: "Response stream finished",
                                spanID: findWorkerSpanID
                            ).log(to: Self.logger, level: .debug)
                            completionStatus = .awaiting(
                                requestStreamCompleted: requestStreamCompleted,
                                responseStreamCompleted: true,
                                handlerCompleted: handlerCompleted
                            )
                        } else {
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                workerID: workerID,
                                message: "Response stream unexpectedly reported to have finished more than once",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.logger, level: .error)
                            await requestSummary.populate(error: PCCClientError.illegalTransition)
                            await requestSummary.log(to: Self.logger)
                            throw PCCClientError.illegalTransition
                        }
                    case .allComplete:
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            workerID: workerID,
                            message: "Response stream unexpectedly reported to have finished more than once",
                            error: PCCClientError.illegalTransition,
                            spanID: findWorkerSpanID
                        ).log(to: Self.logger, level: .error)
                        await requestSummary.populate(error: PCCClientError.illegalTransition)
                        await requestSummary.log(to: Self.logger)
                        throw PCCClientError.illegalTransition
                    }
                }

                if case .allComplete = completionStatus {
                    PCCClientCheckpoint(
                        requestID: self.clientRequestID,
                        workerID: workerID,
                        message: "Worker request completed",
                        spanID: findWorkerSpanID
                    ).log(to: Self.logger, level: .info)
                    await requestSummary.log(to: Self.logger)
                    group.cancelAll()

                    precondition(handlerResult != nil, "Handler result should not be nil at this point")
                    return handlerResult!
                }
            }

            throw PCCClientError.noHandlerResult
        }
    }
}

struct PCCClientCheckpoint: RequestCheckpoint {
    var requestID: String?
    var workerID: UUID
    var spanID: String?
    var operationName: StaticString
    // RequestCheckpoint requires serviceName to be a static string but we can only
    // determine the cloud app's process name dynamically
    var serviceName: StaticString = "unused"
    var cloudAppServiceName: String {
        DebugContext.appName ??
            ProcessInfo.processInfo.processName
    }

    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString

    public init(
        requestID: String,
        workerID: UUID,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil,
        spanID: String? = nil
    ) {
        self.requestID = requestID
        self.workerID = workerID
        self.operationName = operationName
        self.message = message
        self.spanID = spanID
        self.error = error
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID!, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.cloudAppServiceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.uuid=\(self.workerID, privacy: .public)
        """)
    }

    public func log(
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool,
        isFinal: Bool,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.spanID ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        service.name=\(self.cloudAppServiceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.serviceName=\(serviceName, privacy: .public),
        worker.routingParameters=\(routingParameters, privacy: .public)
        worker.responseBypass=\(responseBypass, privacy: .public)
        worker.isFinal=\(isFinal, privacy: .public)
        worker.uuid=\(self.workerID, privacy: .public)
        """)
    }
}

package actor FindWorkerRequestSummaryProvisioner {
    public var requestSummary: FindWorkerRequestSummary

    init(requestID: String, spanID: String? = nil, parentSpanID: String? = nil) {
        self.requestSummary = FindWorkerRequestSummary(requestID: requestID, spanID: spanID, parentSpanID: parentSpanID)
        self.requestSummary.startTimeNanos = RequestSummaryClock.now
    }

    func populate(workerID: String, requestTrackingID: String?, spanID: String?, parentSpanID: String?) {
        self.requestSummary.populate(
            workerID: workerID,
            requestTrackingID: requestTrackingID,
            spanID: spanID,
            parentSpanID: parentSpanID
        )
    }

    func populate(workerID: String) {
        self.requestSummary.populate(workerID: workerID)
    }

    func populate(error: Error) {
        self.requestSummary.populate(error: error)
    }

    func log(to logger: Logger) {
        self.requestSummary.endTimeNanos = RequestSummaryClock.now
        self.requestSummary.log(to: logger)
    }
}

package struct FindWorkerRequestSummary: RequestSummary, Sendable {
    public var serviceName: String =
        "unused" // RequestCheckpoint requires serviceName to be a static string but we can only determine the cloud
    // app's process name dynamically
    var cloudAppServiceName: String {
        DebugContext.appName ??
            ProcessInfo.processInfo.processName
    }

    public var requestID: String?
    var spanID: String?
    var parentSpanID: String?
    public let automatedDeviceGroup: String? = nil // No automated device group for FindWorker calls

    var workerID: String?
    public var startTimeNanos: Int64?
    public var endTimeNanos: Int64?

    public let operationName = "FindWorker"
    public let type = "RequestSummary"
    public var namespace = "cloudboard"

    public var error: Error?

    init(requestID: String, spanID: String? = nil, parentSpanID: String? = nil) {
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.requestID = requestID
    }

    mutating func populate(workerID: String, requestTrackingID: String?, spanID: String?, parentSpanID: String?) {
        self.workerID = workerID
        self.requestID = requestTrackingID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }

    mutating func populate(workerID: String) {
        self.workerID = workerID
    }

    public func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.spanID ?? "", privacy: .public)
        tracing.parent_span_id=\(self.parentSpanID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.cloudAppServiceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { "\(String(reportable: $0))" } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        worker.uuid=\(self.workerID.map { "\($0)" } ?? "")
        """)
    }
}

/// Information about the worker known once it has been assigned to us
public struct PCCWorkerInfo: Sendable, Equatable {
    /// The sha-256 digest of the release section of the attestation bundle
    /// for the worker encoded identically to how it is advertised in the
    /// service discovery registration
    public var releaseDigest: String
}
