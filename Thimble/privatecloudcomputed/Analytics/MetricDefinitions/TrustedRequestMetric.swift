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
//  TrustedRequestMetric.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CloudTelemetry
import Network

struct TrustedRequestMetric: CloudTelemetryReportable {
    let name = "Trusted20240215235354"
    var fields: [EventName: EventValue]
    var bundleID: String?

    enum EventName: String {
        // High level fields
        case eventTime = "eventTime"
        case environment = "env"
        case clientInfo = "appleClientInfo"
        case featureID = "appleFeatureid"
        case bundleID = "appleBundleid"
        case originatingBundleID = "originatingBundleID"
        case locale = "appleLocale"
        case clientRequestId = "clientRequestId"

        // Trusted Request Measurements
        // This will measure overall success of a request from a client, as well as the wall clock time it took to complete.
        case trustedRequestSuccess = "trustedRequestSuccess"
        case trustedRequestTotalTime = "trustedrequesttotaltimems"
        case trustedRequestError = "trustedRequestError"

        // Authentication Measurements
        // This will measure how from request start to fetch the TGT/OTT
        case authTokenFetchTime = "authtokenfetchtimems"
        case authTokenFetchSuccess = "authTokenFetchSuccess"
        case authTokenFetchError = "authTokenFetchError"
        // This will measure how long from reqeust start to sending the TGT/OTT
        case authTokenSendTime = "authtokensendtimems"
        case authTokenSendSuccess = "authTokenSendSuccess"
        case authTokenSendError = "authTokenSendError"

        // OHTTP Connection Establishment Measurements
        // This will measure when our rootConnection becomes ready.
        case ohttpConnectionEstablishmentTime = "ohttpconnectionestablishementtimems"
        case ohttpConnectionEstablishmentSuccess = "ohttpConnectionEstablishmentSuccess"
        case ohttpConnectionEstablishmentError = "ohttpConnectionEstablishmentError"
        case ohttpProxyVendor = "ohttpProxyVendor"

        /// The duration of the connection's establishment in milliseconds, reported by NWConnection.EstablishmentReport.
        /// Per NWConnection.EstablishmentReport, this is the total time from when the successful
        /// connection attempt began until the connection becomes ready, including resolution, proxy
        /// evaluation, and protocol handshakes.
        case connectionEstablishmentReportDurationTime = "connectionEstablishmentReportDurationTimeMs"

        // Invoke Request Measurements
        // This will measure when we send our invokeRequest
        case invokeRequestSendTime = "invokerequestsendtimems"
        case invokeRequestSendSuccess = "invokeRequestSendSuccess"
        case invokeRequestSendError = "invokeRequestSendError"

        // Sending first chunk after TGT/OTT
        // This will measure how long it took us to send our first chunk to ROPES
        case firstChunkSendTime = "firstchunksendtimems"
        case firstChunkSendWithinBudget = "firstChunkSendWithinBudget"

        // .attestationList Measurements
        // Measurements around the network request when we get the .attestationList invokeResponse
        case attestationFetchTime = "attestationfetchtimems"
        // Measurements around overall attestation state
        case attestationIsFirstFetch = "isFirstAttestationFetch"
        case verifiedAttestationCount = "verifiedattestationcount"
        case hasCachedAttestations = "hasCachedAttestations"
        case cachedAttestationCount = "cachedAttestationCount"

        // sending kData overall
        case kDataSendTime = "kdatasendtimems"
        case kDataSendCount = "kdataSendCount"

        /// Measures the time till the client received "readyForMoreChunks" message from ROPES.
        /// Originally that event used to be called "node selected", hence the raw value.
        case readyForMoreChunksTime = "nodeselectedtimems"

        // Measurements around when we send the remainder of the client request after a node is selected
        case remainingChunkSendTime = "remainingchunksendtimems"

        // First response measurements
        case firstResponseReceivedTime = "firstresponsereceivedtimems"

        case cancellationReason = "cancellationReason"
        case trustedProxy = "trustedProxy"
    }

    init<
        Clock: _Concurrency.Clock,
        AttestationStore: AttestationStoreProtocol,
        SystemInfo: SystemInfoProtocol,
        BiomeReporter: BiomeReporterProtocol
    >(
        eventTime: Date,
        bundleID: String,
        environment: String,
        systemInfo: SystemInfo,
        featureID: String?,
        originatingBundleID: String?,
        locale: Locale,
        clientRequestId: UUID,
        trustedProxy: Bool,
        requestMetricsState: RequestMetrics<Clock, AttestationStore, SystemInfo, BiomeReporter>.State
    ) {
        var fields: [EventName: EventValue] = [
            .bundleID: .string(bundleID),
            .eventTime: .int(Int64(eventTime.timeIntervalSince1970)),
            .environment: .string(environment),
            .clientInfo: .string(systemInfo.osInfoWithDeviceModel),
            .locale: .string(locale.identifier),
            .clientRequestId: .string(clientRequestId.uuidString),

        ]

        if let featureID {
            fields[.featureID] = .string(featureID)
        }
        if let originatingBundleID {
            fields[.originatingBundleID] = .string(originatingBundleID)
        }

        switch requestMetricsState.connectionEstablishState {
        case .notEstablished:
            break
        case .established(let duration, let report):
            fields[.ohttpConnectionEstablishmentSuccess] = true
            fields[.ohttpConnectionEstablishmentTime] = .milliseconds(duration)
            if let report {
                if case .url(let proxyURL) = report.proxyEndpoint {
                    fields[.ohttpProxyVendor] = .string(proxyURL.absoluteString)
                }
                fields[.connectionEstablishmentReportDurationTime] = .milliseconds(report.duration)
            }
        case .failed(let duration, let error):
            fields[.ohttpConnectionEstablishmentSuccess] = false
            fields[.ohttpConnectionEstablishmentTime] = .milliseconds(duration)
            fields[.ohttpConnectionEstablishmentError] = error.telemetryString
        }

        switch requestMetricsState.authTokenFetchState {
        case .notStarted:
            break
        case .succeeded(let duration):
            fields[.authTokenFetchSuccess] = true
            fields[.authTokenFetchTime] = .milliseconds(duration)
        case .failed(let error, let duration):
            fields[.authTokenFetchSuccess] = false
            fields[.authTokenFetchTime] = .milliseconds(duration)
            fields[.authTokenFetchError] = error.telemetryString
        }

        switch requestMetricsState.authTokenSendState {
        case .notStarted:
            break
        case .succeeded(let duration):
            fields[.authTokenSendTime] = .milliseconds(duration)
            fields[.authTokenSendSuccess] = true
        case .failed(let error, let duration):
            fields[.authTokenSendTime] = .milliseconds(duration)
            fields[.authTokenSendSuccess] = false
            fields[.authTokenSendError] = error.telemetryString
        }

        switch requestMetricsState.attestationsReceivedState {
        case .noAttestationReceived:
            break
        case .receivedAttestations(count: _, let durationSinceStart):
            fields[.attestationFetchTime] = .milliseconds(durationSinceStart)
            fields[.attestationIsFirstFetch] = true
        }

        switch requestMetricsState.ropesRequestSentState {
        case .notSend:
            break
        case .succeeded(let durationSinceStart):
            fields[.invokeRequestSendTime] = .milliseconds(durationSinceStart)
            fields[.invokeRequestSendSuccess] = true
        case .failed(let error, let durationSinceStart):
            fields[.invokeRequestSendTime] = .milliseconds(durationSinceStart)
            fields[.invokeRequestSendSuccess] = false
            fields[.invokeRequestSendError] = error.telemetryString
        }

        if let duration = requestMetricsState.durationFromStartUntilReadyForMoreChunks {
            fields[.readyForMoreChunksTime] = .milliseconds(duration)
        }

        let cachedAttestationCount = requestMetricsState.nodes.values.reduce(into: 0, { $0 += $1.isFromCache ? 1 : 0 })
        fields[.hasCachedAttestations] = .bool(cachedAttestationCount > 0)
        fields[.cachedAttestationCount] = .int(Int64(cachedAttestationCount))

        let verifiedAttestationCount = requestMetricsState.nodes.values.reduce(
            into: 0,
            { result, element in
                switch element.state {
                case .unverified, .verifying, .verifiedFailed:
                    break
                case .finished, .receiving, .sentKey, .verified:
                    result += 1
                }
            })

        fields[.verifiedAttestationCount] = .int(Int64(verifiedAttestationCount))

        switch requestMetricsState.firstChunkSentState {
        case .notSend:
            break
        case .succeeded(let duration, let withinBudget):
            fields[.firstChunkSendWithinBudget] = .bool(withinBudget)
            fields[.firstChunkSendTime] = .milliseconds(duration)
        }

        if let duration = requestMetricsState.durationFromStartUntilLastPayloadChunkSent {
            fields[.remainingChunkSendTime] = .milliseconds(duration)
        }

        if let duration = requestMetricsState.durationFromStartUntilFirstToken {
            fields[.firstResponseReceivedTime] = .milliseconds(duration)
        }

        switch requestMetricsState.ropesRequestState {
        case .initialized, .waitingForConnection, .requestSent, .responseHeadReceived, .attestationsReceived:
            break
        case .finished(let duration):
            fields[.trustedRequestTotalTime] = .milliseconds(duration)
            fields[.trustedRequestSuccess] = true
        case .failed(let error, let duration):
            fields[.trustedRequestTotalTime] = .milliseconds(duration)
            fields[.trustedRequestError] = error.telemetryString
            fields[.trustedRequestSuccess] = false
        }

        switch requestMetricsState.kDataSendState {
        case .notSend:
            break
        case .sent(let duration, let count):
            fields[.kDataSendTime] = .milliseconds(duration)
            fields[.kDataSendCount] = .int(Int64(count))
        }

        if let cancellationReason = requestMetricsState.cancellationReason {
            fields[.cancellationReason] = cancellationReason.telemetryString
        }

        fields[.trustedProxy] = .bool(trustedProxy)

        self.fields = fields
        self.bundleID = bundleID
    }
}
