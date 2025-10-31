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
//  OpenTelemetryPublisher.swift
//  CloudMetricsDaemon
//
//  Created by Andrea Guzzo on 9/28/23.
//

internal import CloudMetricsConstants
package import CloudMetricsUtils
import Foundation
internal import GRPC
private import Logging
private import NIO
private import NIOHPACK
private import NIOSSL
@preconcurrency import OpenTelemetryApi
private import OpenTelemetryProtocolExporterCommon
internal import OpenTelemetryProtocolExporterGrpc
@preconcurrency package import OpenTelemetrySdk
internal import os


package final class OpenTelemetryPublisher: CloudMetricsPublisher, Sendable {

    private enum State {
        case stopped
        case starting
        case running(shutdownPromise: Promise<Void, Error>)
    }

    private let configuration: Configuration
    private let metricsStores: [String: (OpenTelemetryStore, StableMeterProviderSdk)]
    private let metricsFilter: MetricsFilter
    /// Continuation used to pass metric data to the exporter, whose job is usually to talk gRPC.
    private let metricDataContinuation: AsyncStream<(Configuration.Destination, [StableMetricData])>.Continuation

    private let metricReaders: [OpenTelemetryPeriodicMetricReader]

    private let state: OSAllocatedUnfairLock<State> = .init(initialState: .stopped)
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "OpenTelemetryPublisher")

    package init(configuration: Configuration,
                 metricsFilter: MetricsFilter,
                 metricDataContinuation: AsyncStream<(Configuration.Destination, [StableMetricData])>.Continuation) {
        self.configuration = configuration
        self.metricsFilter = metricsFilter
        self.metricDataContinuation = metricDataContinuation

        var allDestinations = configuration.destinations
        allDestinations.append(configuration.defaultDestination)

        var metricsStores: [String: (OpenTelemetryStore, StableMeterProviderSdk)] = [:]
        var metricReaders: [OpenTelemetryPeriodicMetricReader] = []

        for destination in allDestinations {
            let metricsReader = OpenTelemetryPeriodicMetricReader(
                destination: destination,
                metricContinuation: metricDataContinuation)
            metricReaders.append(metricsReader)

            let metricOverrides = MetricOverrides()
            let cloudMetricsAggregation = CloudMetricsAggregation(histogramBuckets: configuration.defaultHistogramBuckets, metricOverrides: metricOverrides)
            let metricsView = StableView.builder().withAggregation(aggregation: cloudMetricsAggregation).build()
            let meterProvider = StableMeterProviderSdk.builder()
                .registerMetricReader(reader: metricsReader)
                .setResource(resource:  EnvVarResource.get())
                .registerView(selector: InstrumentSelector.builder().setInstrument(name: ".*").build(), view: metricsView)
                .build()
            let store = OpenTelemetryStore(
                meter: meterProvider.meterBuilder(name: "CloudMetrics").build(),
                globalLabels: self.configuration.globalLabels,
                metricOverrides: metricOverrides)

            // We have an object cycle metricsReader->store->meterProvider->metricsReader
            // This is likely causing a slow memory leak and is awkward.
            // We should tidy this up.
            metricsReader.store.withLock { $0 = store }
            metricsStores[destination.id] = (store, meterProvider)
        }
        self.metricReaders = metricReaders
        self.metricsStores = metricsStores
    }

    internal func getMetricsStore(for client: String) throws -> MetricsStore? {
        // use the default destination if none is configured for this client.
        let destination = getDestination(for: client)
        guard let (store, _) = metricsStores[destination.id] else {
            // There must always be a default store and a client must always point to one.
            logger.error("Could not find metrics store. client='\(client, privacy: .public)' destination='\(destination.id, privacy: .private)'")
            return nil
        }
        return store
    }

    internal func getDestination(for client: String) -> Configuration.Destination {
        self.configuration.destinations.first { $0.clients.contains(client) } ?? self.configuration.defaultDestination
    }

    package func run() async throws {
        try await self.run(runningPromise: nil)
    }

    package func run(runningPromise: Promise<Void, Error>? = nil) async throws {
        try self.state.withLock { state in
            switch state {
            case .stopped: state = .starting
            case .starting, .running: throw CloudMetricsError.invalidStateTransition
            }
        }

        let shutdownPromise = Promise<Void, Error>()

        defer {
            logger.log("OpenTelemetry publisher stopped")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for reader in self.metricReaders {
                group.addTask {
                    try await reader.run()
                }
            }
            group.addTask {
                try await withTaskCancellationHandler(operation: {
                    try await Future(shutdownPromise).value
                }, onCancel: {
                    self.logger.log("OpenTelemetryPublisher cancelled")
                    self.state.withLock { $0 = .stopped }
                    shutdownPromise.fail(with: CancellationError())
                })
            }
            self.state.withLock { $0 = .running(shutdownPromise: shutdownPromise) }
            runningPromise?.succeed()
            defer {
                group.cancelAll()
            }
            try await group.next()
        }
    }

    package func shutdown() throws {
        try self.state.withLock { state in
            switch state {
            case .stopped, .starting:
                logger.error("Invalid state to begin OpenTelemetryPublusher shutdown")
                throw CloudMetricsError.invalidStateTransition
            case .running(let promise):
                logger.log("OpenTelemetry publisher shutting down")
                for (_, provider) in self.metricsStores.values {
                    _ = provider.shutdown()
                }
                state = .stopped
                promise.succeed()
            }
        }
    }
}
