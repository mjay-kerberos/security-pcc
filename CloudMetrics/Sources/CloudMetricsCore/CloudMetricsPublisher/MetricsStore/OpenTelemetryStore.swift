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
//  OpenTelemetryStore.swift
//  CloudMetricsDaemon
//
//  Created by Andrea Guzzo on 9/28/23.
//

internal import CloudMetricsConstants
internal import CloudMetricsXPC
import Foundation
private import GRPC
private import NIO
@preconcurrency import OpenTelemetryApi
private import OpenTelemetryProtocolExporterGrpc
internal import OpenTelemetrySdk
internal import os

internal final class MetricOverrides: Sendable {
    private let overrides: OSAllocatedUnfairLock<[MetricID: CloudMetricsOverride]> = .init(initialState: [:])
    init() {
    }

    internal func getOverrides() -> [MetricID: CloudMetricsOverride] {
        self.overrides.withLock { $0 }
    }

    internal func setOverride(id: MetricID, override: CloudMetricsOverride) {
        self.overrides.withLock { $0[id] = override }
    }
}

internal final class GaugeWrapper: Sendable {
    internal let value: OSAllocatedUnfairLock<Double>
    internal let gauge: ObservableDoubleGauge & Sendable

    internal init(value: Double, gauge: ObservableDoubleGauge) {
        self.value = .init(initialState: value)
        self.gauge = gauge
    }

    internal init(valueWithLock: OSAllocatedUnfairLock<Double>, gauge: ObservableDoubleGauge) {
        self.value = valueWithLock
        self.gauge = gauge
    }

}

internal enum OpenTelemetryStoreError: Error {
    case unimplemented(functionality: String)
    case unknownMetric(label: String)
    case noMeterForDestination(destinationID: String)
    case counterTypeMismatch
    case typeOverflow
}

// swiftlint:disable function_parameter_count force_unwrapping
internal final class OpenTelemetryStore: MetricsStore, Sendable {
    private let intCounters: OSAllocatedUnfairLock<[MetricID: LongCounter]> = .init(initialState: [:])
    private let doubleCounters: OSAllocatedUnfairLock<[MetricID: DoubleCounter]> = .init(initialState: [:])
    private let gauges: OSAllocatedUnfairLock<[MetricID: GaugeWrapper]> = .init(initialState: [:])
    private let histograms: OSAllocatedUnfairLock<[MetricID: DoubleHistogram]> = .init(initialState: [:])
    private let timers: OSAllocatedUnfairLock<[MetricID: AnyMeasureMetric<Double>]> = .init(initialState: [:])
    private let meter: StableMeter
    private let globalLabels: [String: String]
    private let metricOverrides: OSAllocatedUnfairLock<MetricOverrides>
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "OpenTelemetryStore")


    internal init(meter: StableMeter, globalLabels: [String: String], metricOverrides: MetricOverrides) {
        self.meter = meter
        self.globalLabels = globalLabels
        self.metricOverrides = .init(initialState: metricOverrides)
    }

    internal func counterIncrement(
        label: String,
        dimensions: [String: String],
        step: Int,
        // swiftlint:disable:next identifier_name
        by: Double,
        timestamp: Date
    ) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        if intCounters.withLock({ $0[id]}) != nil {
            throw OpenTelemetryStoreError.counterTypeMismatch
        }
        self.doubleCounters.withLock { doubleCounters in
            var counter: DoubleCounter
            if let optionalCounter = doubleCounters[id] {
                counter = optionalCounter
            } else {
                counter = meter.counterBuilder(name: label).ofDoubles().build()
            }
            counter.add(value: by, attributes: allDimensions.mapValues { .string($0) })
            doubleCounters[id] = counter
        }
    }

    internal func counterIncrement(
        label: String,
        dimensions: [String: String],
        step: Int,
        // swiftlint:disable:next identifier_name
        by: Int64,
        timestamp: Date
    ) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        try self.doubleCounters.withLock { doubleCounters in
            if doubleCounters[id] != nil {
                throw OpenTelemetryStoreError.counterTypeMismatch
            }
        }
        try self.intCounters.withLock { intCounters in
            var counter: LongCounter
            if let optionalCounter = intCounters[id] {
                counter = optionalCounter
            } else {
                counter = meter.counterBuilder(name: label).build()
            }
            if by > Int.max || by < Int.min {
                throw OpenTelemetryStoreError.typeOverflow
            }
            counter.add(value: Int(by), attribute: allDimensions.mapValues { .string($0) })
            intCounters[id] = counter
        }
    }

    internal func counterReset(
        label: String,
        dimensions: [String: String]
    ) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        let foundDouble = self.doubleCounters.withLock { doubleCounters in
            if doubleCounters[id] != nil {
                doubleCounters[id] = meter.counterBuilder(name: label).ofDoubles().build()
                return true
            }
            return false
        }
        if !foundDouble {
            try self.intCounters.withLock { intCounters in
                if intCounters[id] != nil {
                    intCounters[id] = meter.counterBuilder(name: label).build()
                } else {
                    throw OpenTelemetryStoreError.unknownMetric(label: id.label)
                }
            }
        }
    }

    internal func counterReset(label: String, dimensions: [String: String], initialValue: Double) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        try self.intCounters.withLock { intCounters in
            if intCounters[id] != nil {
                throw OpenTelemetryStoreError.counterTypeMismatch
            }
        }
        self.doubleCounters.withLock { doubleCounters in
            doubleCounters[id] = meter.counterBuilder(name: label).ofDoubles().build()
            doubleCounters[id]!.add(value: initialValue, attributes: allDimensions.mapValues { .string($0) })
        }
    }

    internal func counterReset(label: String, dimensions: [String: String], initialValue: Int64) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        try self.doubleCounters.withLock { doubleCounters in
            if doubleCounters[id] != nil {
                throw OpenTelemetryStoreError.counterTypeMismatch
            }
        }
        try self.intCounters.withLock { intCounters in
            intCounters[id] = meter.counterBuilder(name: label).build()
            if initialValue > Int.max || initialValue < Int.min {
                throw OpenTelemetryStoreError.typeOverflow
            }
            intCounters[id]!.add(value: Int(initialValue), attribute: allDimensions.mapValues { .string($0) })
        }
    }

    internal func gaugeSet(
        label: String,
        dimensions: [String: String],
        step: Int,
        value: Double,
        timestamp: Date
    ) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        self.gauges.withLock { gauges in
            if let gauge = gauges[id] {
                gauge.value.withLock { $0 = value }
            } else {
                let valueWithLock = OSAllocatedUnfairLock<Double>(initialState: value)
                let gauge = meter.gaugeBuilder(name: label).buildWithCallback { observableDoubleMeasurement in
                    valueWithLock.withLock { value in
                        observableDoubleMeasurement.record(value: value,
                                                           attributes: allDimensions.mapValues { .string($0) })
                    }
                }
                let gaugeWrapper = GaugeWrapper(valueWithLock: valueWithLock, gauge: gauge)
                gauges[id] = gaugeWrapper
            }
        }
    }

    internal func recorderSet(
        label: String,
        dimensions: [String: String],
        step: Int,
        value: Double,
        timestamp: Date
    ) throws {
        let allDimensions = dimensions.merging(globalLabels) { _, other in other }
        let id = MetricID(label: label, dimensions: allDimensions)
        let attributes: [String: AttributeValue] = allDimensions.mapValues { .string($0) }
        self.histograms.withLock { histograms in
            if histograms[id] != nil {
                histograms[id]!.record(value: value, attributes: attributes)
            } else {
                // Create a new recorder - summary is the default
                var recorder = meter.histogramBuilder(name: id.label).build()
                recorder.record(value: value, attributes: attributes)
                histograms[id] = recorder
            }
        }
    }

    internal func histogramSet(label: String,
                               dimensions: [String: String],
                               step: Int,
                               buckets: [Double],
                               value: Double,
                               timestamp: Date) throws {
        try configureHistogramBuckets(label: label, buckets: buckets)
        try recorderSet(label: label, dimensions: dimensions, step: step, value: value, timestamp: timestamp)
    }

    internal func histogramSetBuckets(label: String,
                                      dimensions: [String: String],
                                      step: Int,
                                      buckets: [Double],
                                      values: [Int],
                                      sum: Double,
                                      count: Int,
                                      timestamp: Date) async throws {
        throw OpenTelemetryStoreError.unimplemented(functionality: "histogramSetBuckets()")
    }

    internal func summarySet(label: String,
                             dimensions: [String: String],
                             step: Int,
                             quantiles _: [Double],
                             value: Double,
                             timestamp: Date) async throws {
        throw OpenTelemetryStoreError.unimplemented(functionality: "summarySet()")
    }

    internal func summarySetQuantiles(label: String,
                                      dimensions: [String: String],
                                      step: Int,
                                      quantiles: [Double],
                                      values: [Double],
                                      sum: Double,
                                      count: Int,
                                      timestamp: Date) async throws {
        throw OpenTelemetryStoreError.unimplemented(functionality: "summarySet()")
    }

    internal func configureMetric(
        label: String,
        dimensions: [String: String],
        step: Int,
        override: CloudMetricsOverride
    ) throws {
        let id = MetricID(label: label, dimensions: dimensions)
        try self.histograms.withLock { histograms in
            // Metric must not already exist to be configured
            guard histograms[id] == nil else {
                throw MetricsStoreError.metricExists(label: label, dimensions: dimensions)
            }
        }
        self.metricOverrides.withLock { $0.setOverride(id: id, override: override) }
        logger.log("Configured metric override. metric_label=\(label, privacy: .public)")
    }

    internal func collectAllMetrics(producer: MetricProducer) -> [OpenTelemetrySdk.StableMetricData] {
        producer.collectAllMetrics()
    }

    internal func configureHistogramBuckets(label: String, buckets: [Double]) throws {
        let id = MetricID(label: label, dimensions: [:])
        let overrides = metricOverrides.withLock { $0.getOverrides()}
        if let override = overrides[id] {
            switch override {
            case .histogram(buckets: let configuredBuckets):
                if configuredBuckets != buckets {
                    throw MetricsStoreError.metricExists(label: label, dimensions: [:])
                }
                // do nothing if the buckets match
                return
            default:
                throw MetricsStoreError.metricExists(label: label, dimensions: [:])
            }
        }
        try configureMetric(label: label, dimensions: [:], step: 0, override: .histogram(buckets: buckets))
    }
}
