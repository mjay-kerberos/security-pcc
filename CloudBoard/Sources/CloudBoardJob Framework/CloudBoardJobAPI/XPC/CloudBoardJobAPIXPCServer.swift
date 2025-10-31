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
package import CloudBoardAsyncXPC
import Foundation
import os

package actor CloudBoardJobAPIXPCServer {
    static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardJobAPIXPCServer"
    )

    private let listener: CloudBoardAsyncXPCListener
    private weak var delegate: CloudBoardJobAPIClientToServerProtocol?

    internal var endpoint: CloudBoardAsyncXPCEndpoint? {
        get async { await self.listener.endpoint }
    }

    internal init(
        listener: CloudBoardAsyncXPCListener,
        delegate: CloudBoardJobAPIClientToServerProtocol?
    ) {
        self.listener = listener
        self.delegate = delegate
    }
}

extension CloudBoardJobAPIXPCServer {
    package static func localListener(machServiceName: String) -> CloudBoardJobAPIXPCServer {
        self.init(
            listener: CloudBoardAsyncXPCListener(
                localService: machServiceName,
                entitlement: kCloudBoardJobAPIXPCLocalServiceEntitlement
            ),
            delegate: nil
        )
    }
}

extension CloudBoardJobAPIXPCServer: CloudBoardJobAPIServerToClientProtocol {
    package func provideResponseChunk(_ data: Data) async {
        await self.listener.broadcast(DataMessage(data))
    }

    package func endOfResponse() async {
        await self.listener.broadcast(EndOfResponse())
    }

    package func internalError() async {
        await self.listener.broadcast(InternalErrorMessage())
    }

    package func endJob() async {
        await self.listener.broadcast(EndJob())
    }

    package func findWorker(
        workerID: UUID,
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool,
        forwardRequestChunks: Bool,
        isFinal: Bool,
        spanID: String
    ) async throws {
        let requestForWorker = WorkerConstraints(
            workerID: workerID,
            serviceName: serviceName,
            routingParameters: routingParameters,
            responseBypass: responseBypass,
            forwardRequestChunks: forwardRequestChunks,
            isFinal: isFinal,
            spanID: spanID
        )
        await self.listener.broadcast(requestForWorker)
    }

    package func sendWorkerRequestMessage(workerID: UUID, _ data: Data) async {
        await self.listener.broadcast(
            WorkerRequestMessage(workerID: workerID, message: data)
        )
    }

    package func sendWorkerEOF(workerID: UUID, isError: Bool) async {
        let workerEOF = WorkerEOF(workerID: workerID, isError: isError)
        await self.listener.broadcast(workerEOF)
    }

    package func finalizeRequestExecutionLog() async {
        await self.listener.broadcast(FinalizeRequestExecutionLog())
    }

    package func distributeEnsembleKey(
        info: String,
        distributionType: CloudBoardJobAPIEnsembleKeyDistributionType
    ) async throws -> UUID {
        // We can use sendToAny as we know there is only one listener (cb_jobhelper)
        return try await self.listener.sendToAny(CloudAppToJobHelperDeriveKeyMessage.distributeEnsembleKey(
            info: info,
            distributionType: distributionType
        ))
    }

    package func distributeSealedEnsembleKey(
        info: String,
        distributionType: CloudBoardJobAPIEnsembleKeyDistributionType
    ) async throws -> CloudBoardJobAPIEnsembleKeyInfo {
        // We can use sendToAny as we know there is only one listener (cb_jobhelper)
        return try await self.listener
            .sendToAny(CloudAppToJobHelperDeriveSealedKeyMessage.distributeSealedEnsembleKey(
                info: info,
                distributionType: distributionType
            ))
    }
}

extension CloudBoardJobAPIXPCServer: CloudBoardJobAPIServerProtocol {
    package func set(delegate: CloudBoardJobAPIServerDelegateProtocol) async {
        self.delegate = delegate
    }

    package func connect() async {
        await self.listener.listen(buildMessageHandlerStore: self.configureHandlers)
    }

    internal func configureHandlers(
        _ handlers: inout CloudBoardAsyncXPCConnection.MessageHandlerStore
    ) {
        handlers.register(
            CloudBoardJobAPIXPCClientToServerMessage.Warmup.self
        ) { warmupMessage in
            Self.logger.debug("Received Warmup XPC message")
            let delegate = try await self.ensureDelegate(for: CloudBoardJobAPIXPCClientToServerMessage.Warmup.self)
            try await delegate.warmup(details: warmupMessage)
            return ExplicitSuccess()
        }

        handlers.register(
            CloudBoardJobAPIXPCClientToServerMessage.Parameters.self
        ) { parametersMessage in
            Self.logger.debug("Received Parameters XPC message")
            let delegate = try await self.ensureDelegate(for: CloudBoardJobAPIXPCClientToServerMessage.Warmup.self)
            try await delegate.receiveParameters(parametersData: parametersMessage)
            return ExplicitSuccess()
        }

        handlers.register(
            CloudBoardJobAPIXPCClientToServerMessage.InvokeWorkload.self
        ) { message in
            Self.logger.debug("Received InvokeWorkload XPC message in cloud app")
            let delegate = try await self
                .ensureDelegate(for: CloudBoardJobAPIXPCClientToServerMessage.InvokeWorkload.self)
            switch message {
            case .requestChunk(let message):
                try await delegate.provideInput(message.data, isFinal: message.isFinal)
            case .receiveWorkerFoundEvent(let workerFound):
                try await delegate.receiveWorkerFoundEvent(
                    workerID: workerFound.workerID, releaseDigest: workerFound.releaseDigest
                )
            case .receiveWorkerMessage(let response):
                try await delegate.receiveWorkerMessage(workerID: response.workerID, response.message)
            case .receiveWorkerResponseSummary(let summary):
                try await delegate.receiveWorkerResponseSummary(
                    workerID: summary.workerID,
                    succeeded: summary.succeeded
                )
            case .receiveWorkerEOF(let eof):
                try await delegate.receiveWorkerEOF(workerID: eof.workerID)
            }
            return ExplicitSuccess()
        }

        handlers.register(CloudBoardJobAPIXPCClientToServerMessage.Teardown.self) { _ in
            let delegate = try await self.ensureDelegate(for: CloudBoardJobAPIXPCClientToServerMessage.Teardown.self)
            Self.logger.debug("Received Teardown XPC message")
            try await delegate.teardown()
            return ExplicitSuccess()
        }
    }

    internal func ensureDelegate(
        for messageType: any CloudBoardAsyncXPCMessage.Type
    ) throws -> CloudBoardJobAPIClientToServerProtocol {
        guard let delegate = self.delegate else {
            Self.logger.fault("Received \(messageType, privacy: .public) message with no delegate set")
            throw CloudBoardJobAPIError.noDelegateSet
        }

        return delegate
    }
}
