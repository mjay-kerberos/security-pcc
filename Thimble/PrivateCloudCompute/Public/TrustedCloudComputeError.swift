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
//  TrustedCloudComputeError.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import AppleIntelligenceReporting
import Foundation

private func c(_ code: PrivateCloudComputeError.Code) -> Int {
    return code.rawValue
}

// This is deprecated, but not marked as such because of usages in our code.
public enum TrustedCloudComputeError: Swift.Error, Sendable, Codable, TC2JSON, AppleIntelligenceError {
    // This means that the request cannot be processed because
    // of a rate limit in place, either enforced by the client or
    // discovered by the server. If enforced by the client, it
    // may be thrown from the request writer. If enforced by the
    // server, it may be thrown by the response sequence. It also
    // arises in the case of an HTTP 429 or code RESOURCE_EXHAUSTED.
    case deniedDueToRateLimit(rateLimitInfo: RateLimitInfo)

    public struct RateLimitInfo: Sendable, Codable {
        // filter applied
        public var bundleID: String?
        public var featureID: String?
        public var workloadType: String?
        public var workloadTags: [WorkloadTag]
        public struct WorkloadTag: Sendable, Codable {
            public var key: String
            public var value: String

            public init(key: String, value: String) {
                self.key = key
                self.value = value
            }
        }
        // the rate that is in force
        public var count: UInt
        public var duration: TimeInterval
        // "not before" date for which we expect
        // this error to continue to be surfaced
        public var retryAfterDate: Date

        public init(
            bundleID: String?,
            featureID: String?,
            workloadType: String?,
            workloadTags: [WorkloadTag],
            count: UInt,
            duration: TimeInterval,
            retryAfterDate: Date
        ) {
            self.bundleID = bundleID
            self.featureID = featureID
            self.workloadType = workloadType
            self.workloadTags = workloadTags
            self.count = count
            self.duration = duration
            self.retryAfterDate = retryAfterDate
        }

        package init(retryAfter: TimeInterval?, retryAfterDate: Date) {
            self.bundleID = nil
            self.featureID = nil
            self.workloadType = nil
            self.workloadTags = []
            self.count = 0
            self.duration = retryAfter ?? 0.0
            self.retryAfterDate = retryAfterDate
        }

        fileprivate var code: Int { c(.deniedDueToRateLimit) }
    }

    // This error is given for the remaining availability concerns,
    // with minimal extra metadata. If the client has any reason to
    // believe that ROPES will deny requests for this device (perhaps
    // due to region, fraud, bricking the entire fleet, etc), it
    // can give this error. "Reason" is a best hint as to the
    // underlying cause, and "retryAfterDate" may be computed by the
    // client simply to prevent spinning.
    case deniedDueToAvailability(availabilityInfo: AvailabilityInfo)

    public struct AvailabilityInfo: Sendable, Codable {
        public var reason: Reason?
        // "not before" date for which we expect
        // this error to continue to be surfaced
        public var retryAfterDate: Date

        public init(
            reason: Reason?,
            retryAfterDate: Date
        ) {
            self.reason = reason
            self.retryAfterDate = retryAfterDate
        }

        public enum Reason: Sendable, Codable {
            // UNKNOWN_WORKLOAD / "unknown workload"
            case unknownWorkload

            // NODES_NOT_AVAILABLE / "no nodes available"
            case noNodesAvailable

            // NODES_BUSY / "nodes are busy"
            case nodesBusy

            // NODE_ATTESTATION_CHANGED / "node attestation changed"
            case nodeAttestationChanged

            // NODES_OVER_UTILIZED / "nodes utilization too high"
            case nodesOverUtilized

            // WORKLOAD_NOT_FOUND / "workload not found"
            case workloadNotFound

            // ATTESTATIONS_UNAVAILABLE / "attestations unavailable"
            case attestationsUnavailable
        }

        fileprivate var code: Int {
            switch reason {
            case nil: c(.availabilityError)
            case .unknownWorkload: c(.unknownWorkload)
            case .noNodesAvailable: c(.noNodesAvailable)
            case .nodesBusy: c(.nodesBusy)
            case .nodeAttestationChanged: c(.nodeAttestationChanged)
            case .nodesOverUtilized: c(.nodesOverUtilized)
            case .workloadNotFound: c(.workloadNotFound)
            case .attestationsUnavailable: c(.attestationsUnavailable)
            }
        }
    }

    case timeoutError(timeoutErrorInfo: TimeoutErrorInfo)

    public struct TimeoutErrorInfo: Sendable, Codable {
        public var reason: Reason?
        // "not before" date for which we expect
        // this error to continue to be surfaced
        public var retryAfterDate: Date

        public init(
            reason: Reason?,
            retryAfterDate: Date
        ) {
            self.reason = reason
            self.retryAfterDate = retryAfterDate
        }

        public enum Reason: Sendable, Codable {
            // SETUP_REQUEST_TIMEOUT / "timeout waiting for SetupRequest"
            case setupRequestTimeout

            // DECRYPTION_KEY_TIMEOUT / "timeout waiting for decryption key"
            case decryptionKeyTimeout

            // MAX_REQUEST_LIFETIME_REACHED / "max request lifetime reached"
            case maxRequestLifetimeReached

            // REQUEST_CHUNK_TIMEOUT / "timeout waiting for request chunks"
            case requestChunkTimeout
        }

        fileprivate var code: Int {
            switch reason {
            case nil: c(.timeoutError)
            case .setupRequestTimeout: c(.setupRequestTimeout)
            case .decryptionKeyTimeout: c(.decryptionKeyTimeout)
            case .maxRequestLifetimeReached: c(.maxRequestLifetimeReached)
            case .requestChunkTimeout: c(.requestChunkTimeout)
            }
        }
    }

    case invalidRequestError(invalidRequestErrorInfo: InvalidRequestErrorInfo)

    public struct InvalidRequestErrorInfo: Sendable, Codable {
        public var reason: Reason?

        public init(reason: Reason?) {
            self.reason = reason
        }

        public enum Reason: Sendable, Codable {
            // INVALID_WORKLOAD / "timeout waiting for SetupRequest"
            case invalidWorkload
        }

        fileprivate var code: Int {
            switch reason {
            case nil: c(.invalidRequestError)
            case .invalidWorkload: c(.invalidWorkload)
            }
        }
    }

    case unauthorizedError(unauthorizedErrorInfo: UnauthorizedErrorInfo)

    public struct UnauthorizedErrorInfo: Sendable, Codable {
        public var reason: Reason?

        public init(reason: Reason?) {
            self.reason = reason
        }

        public enum Reason: Sendable, Codable {
            // TENANT_BLOCKED / "tenant is blocked"
            case tenantBlocked

            // SOFTWARE_BLOCKED / "software is blocked or deprecated"
            case softwareBlocked

            // WORKLOAD_BLOCKED / "workload is blocked"
            case workloadBlocked

            // FEATUREID_BLOCKED / "featureId is blocked"
            case featureIdBlocked
        }

        fileprivate var code: Int {
            switch reason {
            case nil: c(.unauthorizedError)
            case .tenantBlocked: c(.tenantBlocked)
            case .softwareBlocked: c(.softwareBlocked)
            case .workloadBlocked: c(.workloadBlocked)
            case .featureIdBlocked: c(.featureIdBlocked)
            }
        }
    }

    case serverError(serverErrorInfo: ServerErrorInfo)

    public struct ServerErrorInfo: Sendable, Codable {
        package var responseMetadata: RopesResponseMetadata

        public var retryable: Bool
        public var retryAfterDate: Date?

        package init(responseMetadata: RopesResponseMetadata) {
            self.responseMetadata = responseMetadata
            self.retryable = responseMetadata.retryable
            self.retryAfterDate = responseMetadata.retryAfterDate
        }

        fileprivate var code: Int { c(.serverError) }
    }

    case internalError(internalErrorInfo: InternalErrorInfo)

    public struct InternalErrorInfo: Sendable, Codable {
        public var message: String
        package var reason: Reason?
        package var privacyProxyErrorReason: String?

        public init(message: String) {
            self.message = message
            self.reason = nil
            self.privacyProxyErrorReason = nil
        }

        package init(message: String, reason: Reason) {
            self.message = message
            self.reason = reason
            self.privacyProxyErrorReason = nil
        }

        package init(message: String, reason: Reason, privacyProxyErrorReason: String) {
            self.message = message
            self.reason = reason
            self.privacyProxyErrorReason = privacyProxyErrorReason
        }

        // internal error reason. DO NOT make this public
        package enum Reason: Sendable, Codable {
            case xpcConnectionInterrupted

            // The following from TrustedRequestError
            case failedToLoadKeyData
            case privacyProxyPermissionDenied
            case privacyProxyIpcFailed
            case privacyProxyInvalidUserTier
            case privacyProxyInvalidParam
            case privacyProxyInvalidConfigData
            case privacyProxyInvalidConfigDataSign
            case privacyProxyServerFailure
            case privacyProxyFeatureDisabled
            case privacyProxyRateLimited
            case privacyProxyInvalidAuthentication
            case privacyProxyInvalidRequest
            case privacyProxyNetworkFailure
            case privacyProxyTransparencyFailure
            case privacyProxyInvalidConfigDates
            case privacyProxyTDMFailure
            case privacyProxyInvalidResponse
            case privacyProxyFailed
            case failedToValidateAllAttestations
            case responseSummaryIndicatesFailure
            case responseSummaryIndicatesUnauthenticated
            case responseSummaryIndicatesInternalError
            case responseSummaryIndicatesInvalidRequest
            case responseSummaryIndicatesProxyFindWorkerError
            case responseSummaryIndicatesProxyWorkerValidationError
            case missingAttestationBundle
            case invalidAttestationBundle
            case routingHintMismatch
            case missingResponseBypassContext
            case expectedResponseOnBypass
            case unexpectedlyReceivedResponseBypassContext
            /// Used when we validated an attestation using CloudAttestation framework, but can't determine NodeKind from
            /// the results.
            case unexpectedAttestationKind
            /// Indicates that the kind of node we have validated an attestation for is not what we expected.
            case attestationKindMismatch
        }

        fileprivate var code: Int {
            switch reason {
            case nil: c(.internalError)
            case .xpcConnectionInterrupted: c(.xpcConnectionInterrupted)
            case .failedToLoadKeyData: c(.failedToLoadKeyData)
            case .privacyProxyPermissionDenied: c(.privacyProxyPermissionDenied)
            case .privacyProxyIpcFailed: c(.privacyProxyIpcFailed)
            case .privacyProxyInvalidUserTier: c(.privacyProxyInvalidUserTier)
            case .privacyProxyInvalidParam: c(.privacyProxyInvalidParam)
            case .privacyProxyInvalidConfigData: c(.privacyProxyInvalidConfigData)
            case .privacyProxyInvalidConfigDataSign: c(.privacyProxyInvalidConfigDataSign)
            case .privacyProxyServerFailure: c(.privacyProxyServerFailure)
            case .privacyProxyFeatureDisabled: c(.privacyProxyFeatureDisabled)
            case .privacyProxyRateLimited: c(.privacyProxyRateLimited)
            case .privacyProxyInvalidAuthentication: c(.privacyProxyInvalidAuthentication)
            case .privacyProxyInvalidRequest: c(.privacyProxyInvalidRequest)
            case .privacyProxyNetworkFailure: c(.privacyProxyNetworkFailure)
            case .privacyProxyTransparencyFailure: c(.privacyProxyTransparencyFailure)
            case .privacyProxyInvalidConfigDates: c(.privacyProxyInvalidConfigDates)
            case .privacyProxyTDMFailure: c(.privacyProxyTDMFailure)
            case .privacyProxyInvalidResponse: c(.privacyProxyInvalidResponse)
            case .privacyProxyFailed: c(.privacyProxyFailed)
            case .failedToValidateAllAttestations: c(.failedToValidateAllAttestations)
            case .responseSummaryIndicatesFailure: c(.responseSummaryIndicatesFailure)
            case .responseSummaryIndicatesUnauthenticated: c(.responseSummaryIndicatesUnauthenticated)
            case .responseSummaryIndicatesInternalError: c(.responseSummaryIndicatesInternalError)
            case .responseSummaryIndicatesInvalidRequest: c(.responseSummaryIndicatesInvalidRequest)
            case .responseSummaryIndicatesProxyFindWorkerError: c(.responseSummaryIndicatesProxyFindWorkerError)
            case .responseSummaryIndicatesProxyWorkerValidationError: c(.responseSummaryIndicatesProxyWorkerValidationError)
            case .missingAttestationBundle: c(.missingAttestationBundle)
            case .invalidAttestationBundle: c(.invalidAttestationBundle)
            case .routingHintMismatch: c(.routingHintMismatch)
            case .missingResponseBypassContext: c(.missingResponseBypassContext)
            case .expectedResponseOnBypass: c(.expectedResponseOnBypass)
            case .unexpectedAttestationKind: c(.unexpectedAttestationKind)
            case .attestationKindMismatch: c(.attestationKindMismatch)
            case .unexpectedlyReceivedResponseBypassContext: c(.unexpectedlyReceivedResponseBypassContext)
            }
        }
    }

    case networkError(networkErrorInfo: NetworkErrorInfo)

    public struct NetworkErrorInfo: Sendable, Codable {
        public var domain: String
        public var code: Int
        public var message: String

        public init(domain: String, code: Int, message: String) {
            self.domain = domain
            self.code = code
            self.message = message
        }
    }

    // MARK: AppleIntelligenceError conformance

    public var rawCode: Int {
        return switch self {
        case .deniedDueToRateLimit(_): 0
        case .deniedDueToAvailability(_): 1
        case .timeoutError(_): 2
        case .invalidRequestError(_): 3
        case .unauthorizedError(_): 4
        case .serverError(_): 5
        case .internalError(_): 6
        case .networkError(_): 7
        }
    }

    public var descriptionWithoutUnderlying: String { errorCaseString() }

    fileprivate var underlyingError: any AppleIntelligenceError {
        let underlyingDomain = {
            return switch self {
            case .networkError(let info): info.domain
            default:
                "com.apple.privatecloudcompute." + errorCaseString()
            }
        }()

        let underlyingMessage = {
            if let errorDetails = self.errorDetails() {
                "\(self.errorMessage()); \(errorDetails)"
            } else {
                errorMessage()
            }
        }()

        return GeneralAppleIntelligenceError(
            domain: underlyingDomain,
            rawCode: errorUnderlyingCode(),
            descriptionWithoutUnderlying: underlyingMessage,
            description: underlyingMessage,
            underlyingErrors: [],
            retryAfterDate: retryAfterDate,
            category: self.category
        )
    }

    public var underlyingErrors: [any AppleIntelligenceError] {
        [underlyingError]
    }

    public var category: AppleIntelligenceErrorCategory {
        switch self {
        case .deniedDueToRateLimit(_): .rateLimited
        case .deniedDueToAvailability(_): .availability
        case .timeoutError(_): .timeout
        case .invalidRequestError(_): .clientError
        case .unauthorizedError(_): .authentication
        case .serverError(_): .serverError
        case .internalError(_): .internalError
        case .networkError(_): .network
        }
    }
}

// MARK: InternalError initializers

extension TrustedCloudComputeError {
    /// This is an initializer intended to create the general "unknown error" error.
    package init(file: StaticString = #file, line: Int = #line) {
        self = .internalError(internalErrorInfo: .init(message: "internal error file=\(file), line=\(line)"))
    }

    /// This is an initializer intended to create the general "unknown error" error.
    package init(file: StaticString = #file, line: Int = #line, message: String) {
        self = .internalError(internalErrorInfo: .init(message: "\(message) file=\(file), line=\(line)"))
    }

    package static var xpcConnectionInterrupted: Self {
        .internalError(internalErrorInfo: .init(message: "XPC connection failure", reason: .xpcConnectionInterrupted))
    }
}

// MARK: initializer for server generated errors

extension TrustedCloudComputeError {
    package init(responseMetadata: RopesResponseMetadata) {
        assert(responseMetadata.isError)

        if case .code(let errorCode) = responseMetadata.receivedErrorCode {
            switch errorCode {
            // deniedDueToRateLimit
            case .rateLimitReached:
                self = .deniedDueToRateLimit(rateLimitInfo: .init(retryAfter: responseMetadata.retryAfter, retryAfterDate: responseMetadata.retryAfterDate))

            // deniedDueToAvailability
            case .unknownWorkload:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .unknownWorkload, retryAfterDate: responseMetadata.retryAfterDate))
            case .nodesNotAvailable:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .noNodesAvailable, retryAfterDate: responseMetadata.retryAfterDate))
            case .nodesBusy:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .nodesBusy, retryAfterDate: responseMetadata.retryAfterDate))
            case .nodeAttestationChanged:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .nodeAttestationChanged, retryAfterDate: responseMetadata.retryAfterDate))
            case .nodesOverUtilized:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .nodesOverUtilized, retryAfterDate: responseMetadata.retryAfterDate))
            case .workloadNotFound:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .workloadNotFound, retryAfterDate: responseMetadata.retryAfterDate))
            case .attestationsUnavailable:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: .attestationsUnavailable, retryAfterDate: responseMetadata.retryAfterDate))
            case .cloudboardResourceExhausted:
                self = .deniedDueToAvailability(availabilityInfo: .init(reason: nil, retryAfterDate: responseMetadata.retryAfterDate))

            // unauthorizedError
            case .tenantBlocked:
                self = .unauthorizedError(unauthorizedErrorInfo: .init(reason: .tenantBlocked))
            case .softwareBlocked:
                self = .unauthorizedError(unauthorizedErrorInfo: .init(reason: .softwareBlocked))
            case .featureIdBlocked:
                self = .unauthorizedError(unauthorizedErrorInfo: .init(reason: .featureIdBlocked))
            case .workloadBlocked:
                self = .unauthorizedError(unauthorizedErrorInfo: .init(reason: .workloadBlocked))

            // timeoutError
            case .setupRequestTimeout:
                self = .timeoutError(timeoutErrorInfo: .init(reason: .setupRequestTimeout, retryAfterDate: responseMetadata.retryAfterDate))
            case .decryptionKeyTimeout:
                self = .timeoutError(timeoutErrorInfo: .init(reason: .decryptionKeyTimeout, retryAfterDate: responseMetadata.retryAfterDate))
            case .maxRequestLifetimeReached:
                self = .timeoutError(timeoutErrorInfo: .init(reason: .maxRequestLifetimeReached, retryAfterDate: responseMetadata.retryAfterDate))
            case .requestChunkTimeout:
                self = .timeoutError(timeoutErrorInfo: .init(reason: .requestChunkTimeout, retryAfterDate: responseMetadata.retryAfterDate))
            case .cloudboardDeadlineExceeded:
                self = .timeoutError(timeoutErrorInfo: .init(reason: nil, retryAfterDate: responseMetadata.retryAfterDate))

            // invalidRequestError
            case .invalidWorkload:
                self = .invalidRequestError(invalidRequestErrorInfo: .init(reason: .invalidWorkload))

            default:
                self = .serverError(serverErrorInfo: .init(responseMetadata: responseMetadata))
            }
        } else {
            self = .serverError(serverErrorInfo: .init(responseMetadata: responseMetadata))
        }
    }
}

// MARK: Retryable properties

extension TrustedCloudComputeError {
    public var retryable: Bool {
        switch self {
        case .deniedDueToRateLimit(_), .deniedDueToAvailability(_), .timeoutError(_):
            return true
        case .invalidRequestError(_), .internalError(_), .unauthorizedError(_), .networkError(_):
            return false
        case .serverError(let info):
            return info.retryable
        }
    }

    public var retryAfterDate: Date? {
        switch self {
        case .deniedDueToRateLimit(let info):
            return info.retryAfterDate
        case .deniedDueToAvailability(let info):
            return info.retryAfterDate
        case .timeoutError(let info):
            return info.retryAfterDate
        case .invalidRequestError, .internalError, .unauthorizedError, .networkError:
            return nil
        case .serverError(let info):
            return info.retryAfterDate
        }
    }
}

// MARK: CustomStringConvertible

// Here are some example error strings!
//
// DeniedDueToRateLimit: exceeded rate limit of 4/60.0 for requests of this type; bundleID=myBundle count=4 duration=60.0 retryAfterDate=2032-09-08T18:46:40-0700
//
// DeniedDueToAvailability: no nodes available; reason=noNodesAvailable retryAfterDate=2032-09-08T18:46:40-0700
//
// InternalError: Internal Error file=Public/TrustedRequest.swift, line=50
//
// InternalError: CancellationError() file=Public/TrustedRequest.swift, line=50

extension TrustedCloudComputeError: CustomStringConvertible {
    public var description: String {
        let errorCaseString = self.errorCaseString()
        let underlyingDescription = underlyingError.description
        return "\(errorCaseString): \(underlyingDescription)"
    }

    package func errorCaseString() -> String {
        switch self {
        case .deniedDueToRateLimit(_):
            return "DeniedDueToRateLimit"
        case .deniedDueToAvailability(_):
            return "DeniedDueToAvailability"
        case .timeoutError(_):
            return "TimeoutError"
        case .invalidRequestError(_):
            return "InvalidRequestError"
        case .unauthorizedError(_):
            return "UnauthorizedError"
        case .serverError(_):
            return "ServerError"
        case .internalError(_):
            return "InternalError"
        case .networkError(_):
            return "NetworkError"
        }
    }

    private func errorMessage() -> String {
        switch self {
        case .deniedDueToRateLimit(let info):
            return info.message
        case .deniedDueToAvailability(let info):
            return info.message
        case .timeoutError(let info):
            return info.message
        case .invalidRequestError(let info):
            return info.message
        case .unauthorizedError(let info):
            return info.message
        case .serverError(let info):
            return info.message
        case .internalError(let info):
            return info.message
        case .networkError(let info):
            return info.message
        }
    }

    private func errorDetails() -> String? {
        switch self {
        case .deniedDueToRateLimit(let info):
            return "\(info)"
        case .deniedDueToAvailability(let info):
            return "\(info)"
        case .timeoutError(let info):
            return "\(info)"
        case .invalidRequestError(let info):
            return "\(info)"
        case .unauthorizedError(let info):
            return "\(info)"
        case .serverError(let info):
            return "\(info)"
        case .internalError(let info):
            return "\(info)"
        case .networkError(let info):
            return "\(info)"
        }
    }

    // This isn't for CustomStringConvertible, it's used for AppleIntelligenceError underlying.
    private func errorUnderlyingCode() -> Int {
        switch self {
        case .deniedDueToRateLimit(let info):
            return info.code
        case .deniedDueToAvailability(let info):
            return info.code
        case .timeoutError(let info):
            return info.code
        case .invalidRequestError(let info):
            return info.code
        case .unauthorizedError(let info):
            return info.code
        case .serverError(let info):
            return info.code
        case .internalError(let info):
            return info.code
        case .networkError(let info):
            return info.code
        }
    }
}

extension TrustedCloudComputeError.RateLimitInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let bundleID {
            result.append("bundleID=\(bundleID)")
        }
        if let featureID {
            result.append("featureID=\(featureID)")
        }
        if let workloadType {
            result.append("workloadType=\(workloadType)")
        }
        for tag in workloadTags {
            result.append("workloadParam=(\(tag.key),\(tag.value))")
        }
        result.append("count=\(count)")
        result.append("duration=\(duration)")
        let dateFormatted = retryAfterDate.ISO8601Format(.init(timeZone: TimeZone.current))
        result.append("retryAfterDate=\(dateFormatted)")
        return result.joined(separator: " ")
    }

    package var message: String {
        if count == 0 {
            return "a rate limit of zero is in place for requests of this type"
        } else {
            return "exceeded rate limit of \(count)/\(duration) for requests of this type"
        }
    }
}

extension TrustedCloudComputeError.AvailabilityInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let reason {
            result.append("reason=\(reason)")
        }
        let dateFormatted = retryAfterDate.ISO8601Format(.init(timeZone: TimeZone.current))
        result.append("retryAfterDate=\(dateFormatted)")
        return result.joined(separator: " ")
    }

    package var message: String {
        switch self.reason {
        case .unknownWorkload?:
            return "unknown workload"
        case .noNodesAvailable?:
            return "no nodes available"
        case .nodesBusy?:
            return "nodes busy"
        case .nodeAttestationChanged?:
            return "node attestation changed"
        case .nodesOverUtilized:
            return "nodes utilization too high"
        case .workloadNotFound:
            return "workload not found"
        case .attestationsUnavailable:
            return "attestations unavailable"
        case nil:
            return "unknown availability error"
        }
    }
}

extension TrustedCloudComputeError.TimeoutErrorInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let reason {
            result.append("reason=\(reason)")
        }
        let dateFormatted = retryAfterDate.ISO8601Format(.init(timeZone: TimeZone.current))
        result.append("retryAfterDate=\(dateFormatted)")
        return result.joined(separator: " ")
    }

    package var message: String {
        switch self.reason {
        case .decryptionKeyTimeout?:
            return "timeout waiting for decryption key"
        case .setupRequestTimeout?:
            return "timeout waiting for SetupRequest"
        case .maxRequestLifetimeReached:
            return "max request lifetime reached"
        case .requestChunkTimeout:
            return "timeout waiting for request chunks"
        case nil:
            return "unknown timeout error"
        }
    }
}

extension TrustedCloudComputeError.InvalidRequestErrorInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let reason {
            result.append("reason=\(reason)")
        }
        return result.joined(separator: " ")
    }

    package var message: String {
        switch self.reason {
        case .invalidWorkload:
            return "invalid workload"
        case nil:
            return "invalid request"
        }
    }

}

extension TrustedCloudComputeError.UnauthorizedErrorInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let reason {
            result.append("reason=\(reason)")
        }
        return result.joined(separator: " ")
    }

    package var message: String {
        switch self.reason {
        case .some(.tenantBlocked):
            return "tenant is blocked"
        case .softwareBlocked:
            return "software is blocked or deprecated"
        case .some(.workloadBlocked):
            return "workload is blocked"
        case .some(.featureIdBlocked):
            return "featureId is blocked"
        case nil:
            return "unauthorized"
        }
    }
}

extension TrustedCloudComputeError.ServerErrorInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let code = responseMetadata.code {
            result.append("response-code=\(code)")
        }
        if let status = responseMetadata.status {
            result.append("status=\(status)")
        }
        if case .code(let errorCode) = responseMetadata.receivedErrorCode {
            result.append("error-code=\(errorCode)")
        }
        if case .unrecognized(let rawValue) = responseMetadata.receivedErrorCode {
            result.append("error-code=\(rawValue)")
        }
        if let errorDescription = responseMetadata.errorDescription {
            result.append("description=\(errorDescription)")
        }
        if let cause = responseMetadata.cause {
            result.append("cause=\(cause)")
        }
        if responseMetadata.retryable {
            result.append("retryable=yes")
            let dateFormatted = responseMetadata.retryAfterDate.ISO8601Format(.init(timeZone: TimeZone.current))
            result.append("retryAfterDate=\(dateFormatted)")
        } else {
            result.append("retryable=no")
        }
        return result.joined(separator: " ")
    }

    package var message: String {
        return "server returned error"
    }
}

extension TrustedCloudComputeError.InternalErrorInfo: CustomStringConvertible {
    public var description: String {
        var result: [String] = []
        if let reason = self.reason {
            result.append("reason=\(reason)")
        }
        return result.joined(separator: " ")
        // omit message
    }

    // message is stored property in struct
}

extension TrustedCloudComputeError.NetworkErrorInfo: CustomStringConvertible {
    public var description: String {
        return "domain=\(domain) code=\(code)"
        // omit message
    }

    // message is stored property in struct
}
