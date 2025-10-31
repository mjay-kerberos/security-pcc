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

/// This matches ``FindWorkerQuery`` but it is desirable to keep the
/// XPC layer separate so it can be evolved independently.
///
/// Sent from Cloud App to CloudBoardJobHelper.
package struct WorkerConstraints: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = ExplicitSuccess
    public typealias Failure = Never

    package var workerID: UUID
    package var serviceName: String
    package var routingParameters: [String: [String]]
    package var responseBypass: Bool
    package var forwardRequestChunks: Bool
    package var isFinal: Bool
    package var spanID: String

    internal init(
        workerID: UUID,
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool,
        forwardRequestChunks: Bool,
        isFinal: Bool,
        spanID: String
    ) {
        self.workerID = workerID
        self.serviceName = serviceName
        self.routingParameters = routingParameters
        self.responseBypass = responseBypass
        self.forwardRequestChunks = forwardRequestChunks
        self.isFinal = isFinal
        self.spanID = spanID
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.serviceName.encode(to: &buffer)
        try self.routingParameters.encode(to: &buffer)
        try self.responseBypass.encode(to: &buffer)
        try self.forwardRequestChunks.encode(to: &buffer)
        try self.isFinal.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.workerID = try .init(from: &buffer)
        self.serviceName = try .init(from: &buffer)
        self.routingParameters = try .init(from: &buffer)
        self.responseBypass = try .init(from: &buffer)
        self.forwardRequestChunks = try .init(from: &buffer)
        self.isFinal = try .init(from: &buffer)
        self.spanID = try .init(from: &buffer)
    }
}

package struct WorkerRequestMessage: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = Never
    public typealias Failure = Never

    package var workerID: UUID
    package var message: Data

    internal init(workerID: UUID, message: Data) {
        self.workerID = workerID
        self.message = message
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.message.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.workerID = try UUID(from: &buffer)
        self.message = try Data(from: &buffer)
    }
}

package struct WorkerEOF: Sendable, Equatable, CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = Never
    public typealias Failure = Never

    package var workerID: UUID
    package var isError: Bool

    internal init(workerID: UUID, isError: Bool) {
        self.workerID = workerID
        self.isError = isError
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.isError.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.workerID = try .init(from: &buffer)
        self.isError = try .init(from: &buffer)
    }
}

struct FinalizeRequestExecutionLog: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    typealias Success = Never
    typealias Failure = Never

    init() {}

    func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}

    init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
}

struct EndJob: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    typealias Success = ExplicitSuccess
    typealias Failure = Never

    init() {}

    func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}

    init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
}

struct EndOfResponse: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    typealias Success = ExplicitSuccess
    typealias Failure = Never

    init() {}

    func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}

    init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
}

package struct InternalErrorMessage: CloudBoardAsyncXPCByteBufferMessage, Equatable {
    package typealias Success = ExplicitSuccess
    package typealias Failure = Never

    init() {}
    package func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
    package init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
}

// We cannot add `extension Data: CloudBoardAsyncXPCByteBufferMessage` directly
// it would leak CloudBoardAsyncXPC into the ABI
// Rather than special case Data everywhere in the (complex) sending path we provide an low
// overhead wrapper thanks to CoW
package struct DataMessage: CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = Never
    public typealias Failure = Never

    public var data: Data

    package init(_ data: Data) {
        self.data = data
    }

    @inlinable
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.data.encode(to: &buffer)
    }

    @inlinable
    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.data = try .init(from: &buffer)
    }
}

package enum CloudAppToJobHelperDeriveKeyError: Codable, Sendable, Error {
    /// Any failure to derive or distribute the key
    case failedKeyDerivation
    /// CancellationError. We need a dedicated `Failure` type so can't use that directly.
    case cancelled
}

package enum CloudAppToJobHelperDeriveKeyMessage: CloudBoardAsyncXPCCodableMessage {
    public typealias Success = UUID
    public typealias Failure = CloudAppToJobHelperDeriveKeyError

    case distributeEnsembleKey(info: String, distributionType: CloudBoardJobAPIEnsembleKeyDistributionType)
}

package enum CloudAppToJobHelperDeriveSealedKeyMessage: CloudBoardAsyncXPCCodableMessage {
    public typealias Success = CloudBoardJobAPIEnsembleKeyInfo
    public typealias Failure = CloudAppToJobHelperDeriveKeyError

    case distributeSealedEnsembleKey(info: String, distributionType: CloudBoardJobAPIEnsembleKeyDistributionType)
}
