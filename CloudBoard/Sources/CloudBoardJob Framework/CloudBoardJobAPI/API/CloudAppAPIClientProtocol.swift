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

package protocol CloudBoardJobAPIClientToServerProtocol: Actor {
    func warmup(details: WarmupDetails) async throws
    func receiveParameters(parametersData: ParametersData) async throws
    func provideInput(_ data: Data?, isFinal: Bool) async throws
    func receiveWorkerFoundEvent(workerID: UUID, releaseDigest: String) async throws
    func receiveWorkerMessage(workerID: UUID, _ response: WorkerResponseMessage) async throws
    func receiveWorkerResponseSummary(workerID: UUID, succeeded: Bool) async throws
    func receiveWorkerEOF(workerID: UUID) async throws
    func teardown() async throws
}

package struct WarmupDetails: Sendable, ByteBufferCodable, Equatable {
    public init() {}

    package func encode(to _: inout ByteBuffer) throws {}

    package init(from _: inout ByteBuffer) throws {}
}

/// Parameters message sent from cb_jobhelper to the cloud app
package struct ParametersData: Sendable, ByteBufferCodable, Hashable, Equatable {
    package var parametersReceived: Date
    package var plaintextMetadata: PlaintextMetadata
    package var requestBypassed: Bool
    package var traceContext: TraceContext

    package init(
        parametersReceived: Date,
        plaintextMetadata: PlaintextMetadata,
        requestBypassed: Bool,
        traceContext: TraceContext
    ) {
        self.parametersReceived = parametersReceived
        self.plaintextMetadata = plaintextMetadata
        self.requestBypassed = requestBypassed
        self.traceContext = traceContext
    }

    package func encode(to buffer: inout ByteBuffer) throws {
        try self.plaintextMetadata.encode(to: &buffer)
        try self.parametersReceived.encode(to: &buffer)
        try self.requestBypassed.encode(to: &buffer)
        try self.traceContext.encode(to: &buffer)
    }

    package init(from buffer: inout ByteBuffer) throws {
        self.plaintextMetadata = try .init(from: &buffer)
        self.parametersReceived = try .init(from: &buffer)
        self.requestBypassed = try .init(from: &buffer)
        self.traceContext = try .init(from: &buffer)
    }
}

extension ParametersData {
    package struct PlaintextMetadata: ByteBufferCodable, Sendable, Hashable {
        public var bundleID: String
        public var bundleVersion: String
        public var featureID: String
        public var clientInfo: String
        public var workloadType: String
        public var workloadParameters: [String: [String]]
        public var requestID: String
        public var automatedDeviceGroup: String

        public init(
            bundleID: String,
            bundleVersion: String,
            featureID: String,
            clientInfo: String,
            workloadType: String,
            workloadParameters: [String: [String]],
            requestID: String,
            automatedDeviceGroup: String
        ) {
            self.bundleID = bundleID
            self.bundleVersion = bundleVersion
            self.featureID = featureID
            self.clientInfo = clientInfo
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
            self.requestID = requestID
            self.automatedDeviceGroup = automatedDeviceGroup
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.automatedDeviceGroup.encode(to: &buffer)
            try self.bundleID.encode(to: &buffer)
            try self.bundleVersion.encode(to: &buffer)
            try self.clientInfo.encode(to: &buffer)
            try self.featureID.encode(to: &buffer)
            try self.requestID.encode(to: &buffer)
            try self.workloadType.encode(to: &buffer)
            try self.workloadParameters.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.automatedDeviceGroup = try .init(from: &buffer)
            self.bundleID = try .init(from: &buffer)
            self.bundleVersion = try .init(from: &buffer)
            self.clientInfo = try .init(from: &buffer)
            self.featureID = try .init(from: &buffer)
            self.requestID = try .init(from: &buffer)
            self.workloadType = try .init(from: &buffer)
            self.workloadParameters = try .init(from: &buffer)
        }
    }

    package struct TraceContext: ByteBufferCodable, Sendable, Hashable, Equatable {
        public var traceID: String
        public var spanID: String

        public init(traceID: String, spanID: String) {
            self.traceID = traceID
            self.spanID = spanID
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.traceID.encode(to: &buffer)
            try self.spanID.encode(to: &buffer)
        }

        public init(from buffer: inout ByteBuffer) throws {
            self.traceID = try .init(from: &buffer)
            self.spanID = try .init(from: &buffer)
        }
    }
}

package enum WorkerResponseMessage: ByteBufferCodable, Sendable, Equatable {
    package enum Result: Codable, Sendable {
        case ok
        case failure
    }

    case payload(Data)
    case result(Result)

    package func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .payload(let data):
            buffer.writeInteger(0)
            try data.encode(to: &buffer)
        case .result(let result):
            buffer.writeInteger(1)
            switch result {
            case .ok: buffer.writeInteger(0)
            case .failure: buffer.writeInteger(1)
            }
        }
    }

    package init(from buffer: inout ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            let payload = try Data(from: &buffer)
            self = .payload(payload)
        case 1:
            guard let enumCase: Int = buffer.readInteger() else {
                throw DecodingError.valueNotFound(
                    WorkerResponseMessage.Result.self,
                    .init(codingPath: [], debugDescription: "no expected enum case")
                )
            }
            switch enumCase {
            case 0: self = .result(.ok)
            case 1: self = .result(.failure)
            case let value:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(WorkerResponseMessage.Result.self)],
                    debugDescription: "bad result enum case \(value)"
                ))
            }
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}
