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

package enum CloudBoardJobAPIXPCClientToServerMessage {
    case warmup(WarmupDetails)
    case parameters(ParametersData)
    case invokeWorkload(InvokeWorkloadRequest)
    case teardown

    package enum InvokeWorkloadRequest: ByteBufferCodable, Sendable, Equatable {
        case requestChunk(RequestChunk)
        case receiveWorkerFoundEvent(WorkerFound)
        case receiveWorkerMessage(WorkerResponse)
        case receiveWorkerEOF(WorkerEOF)
        case receiveWorkerResponseSummary(WorkerResponseSummary)

        package func encode(to buffer: inout ByteBuffer) throws {
            switch self {
            case .requestChunk(let chunk):
                buffer.writeInteger(0)
                try chunk.encode(to: &buffer)
            case .receiveWorkerResponseSummary(let summary):
                buffer.writeInteger(1)
                try summary.encode(to: &buffer)
            case .receiveWorkerMessage(let message):
                buffer.writeInteger(2)
                try message.workerID.encode(to: &buffer)
                try message.message.encode(to: &buffer)
            case .receiveWorkerFoundEvent(let event):
                buffer.writeInteger(3)
                try event.workerID.encode(to: &buffer)
                try event.releaseDigest.encode(to: &buffer)
            case .receiveWorkerEOF(let eof):
                buffer.writeInteger(4)
                try eof.workerID.encode(to: &buffer)
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
                let chunk = try CloudBoardJobAPIXPCClientToServerMessage.RequestChunk(from: &buffer)
                self = .requestChunk(chunk)
            case 1:
                let summary = try CloudBoardJobAPIXPCClientToServerMessage.WorkerResponseSummary(from: &buffer)
                self = .receiveWorkerResponseSummary(summary)
            case 2:
                let workerID = try UUID(from: &buffer)
                let message = try WorkerResponseMessage(from: &buffer)
                self = .receiveWorkerMessage(.init(workerID: workerID, message: message))
            case 3:
                let workerID = try UUID(from: &buffer)
                let releaseDigest = try String(from: &buffer)
                self = .receiveWorkerFoundEvent(.init(workerID: workerID, releaseDigest: releaseDigest))
            case 4:
                self = try .receiveWorkerEOF(.init(workerID: .init(from: &buffer)))
            case let value:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "bad result enum case \(value)"
                ))
            }
        }
    }

    package typealias InvokeWorkload = InvokeWorkloadRequest
    package typealias Warmup = WarmupDetails
    package typealias Parameters = ParametersData

    package struct RequestChunk: ByteBufferCodable, Sendable, Equatable {
        package var data: Data?
        package var isFinal: Bool

        internal init(data: Data? = nil, isFinal: Bool) {
            self.data = data
            self.isFinal = isFinal
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.data.encode(to: &buffer)
            try self.isFinal.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.data = try .init(from: &buffer)
            self.isFinal = try .init(from: &buffer)
        }
    }

    package struct WorkerFound: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID
        package var releaseDigest: String

        internal init(workerID: UUID, releaseDigest: String) {
            self.workerID = workerID
            self.releaseDigest = releaseDigest
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.workerID.encode(to: &buffer)
            try self.releaseDigest.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.workerID = try UUID(from: &buffer)
            self.releaseDigest = try .init(from: &buffer)
        }
    }

    package struct WorkerResponse: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID
        package var message: WorkerResponseMessage

        internal init(workerID: UUID, message: WorkerResponseMessage) {
            self.workerID = workerID
            self.message = message
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.workerID.encode(to: &buffer)
            try self.message.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.workerID = try UUID(from: &buffer)
            self.message = try .init(from: &buffer)
        }
    }

    package struct WorkerResponseSummary: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID
        package var succeeded: Bool

        internal init(workerID: UUID, succeeded: Bool) {
            self.workerID = workerID
            self.succeeded = succeeded
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.succeeded.encode(to: &buffer)
            try self.workerID.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.succeeded = try .init(from: &buffer)
            self.workerID = try UUID(from: &buffer)
        }
    }

    package struct WorkerEOF: ByteBufferCodable, Sendable, Equatable {
        package var workerID: UUID

        internal init(workerID: UUID) {
            self.workerID = workerID
        }

        @inlinable
        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.workerID.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.workerID = try .init(from: &buffer)
        }
    }

    internal struct Teardown: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        internal typealias Failure = CloudBoardJobAPIError

        init() {}

        func encode(to _: inout ByteBuffer) throws {}

        init(from _: inout ByteBuffer) throws {}
    }
}

extension CloudBoardJobAPIXPCClientToServerMessage.InvokeWorkload: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = ExplicitSuccess
    package typealias Failure = CloudBoardJobAPIError
}

extension CloudBoardJobAPIXPCClientToServerMessage.Warmup: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = ExplicitSuccess
    package typealias Failure = CloudBoardJobAPIError
}

extension CloudBoardJobAPIXPCClientToServerMessage.Parameters: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = ExplicitSuccess
    package typealias Failure = CloudBoardJobAPIError
}

extension CloudBoardJobAPIError: ByteBufferCodable {
    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .internalError: buffer.writeInteger(0)
        case .noDelegateSet: buffer.writeInteger(1)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            self = .internalError
        case 1:
            self = .noDelegateSet
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}
