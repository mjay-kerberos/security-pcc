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
import CloudBoardCommon
import CloudBoardController
import CloudBoardMetrics
import os

public enum WorkloadControllerError: Error, Equatable, CustomStringConvertible {
    case controllerError(message: String)
    case controllerUnknownState
    case controllerDisconnected

    public var description: String {
        switch self {
        case .controllerError(let message):
            return "Controller reported error: \(message)"
        case .controllerUnknownState:
            return "Controller reported unknown state"
        case .controllerDisconnected:
            return "Controller disconnected"
        }
    }
}

public actor WorkloadController {
    internal static let debounceDuration: Duration = .seconds(5)

    private var state: ControllerState
    private let healthPublisher: ServiceHealthMonitor
    private var server: CloudBoardControllerAPIXPCServer?
    private var serviceDiscoveryPublisher: ServiceDiscoveryPublisherProtocol?
    private var providerPause: ((String?) async throws -> Void)?
    private var restartPrewarmedInstances: (() async throws -> Void)?
    private var restartingPrewarmedInstances: Bool = false
    private var concurrentRequestCount: Int
    private var announcedService: Bool = false
    private var metrics: MetricsSystem
    private var isLeader: Bool = true

    private var workloadProperties: WorkloadProperties?
    private var workloadConfig: WorkloadConfig?

    private var scheduledPublishing: Task<Void, Never>?
    private var lastDebouncedPublishingTime: ContinuousClock.Instant?

    public enum ControllerState: Sendable, Equatable, CustomStringConvertible {
        case initializing
        case ready
        case busyTransitioning(reason: String?)
        case busy(reason: String?)
        case error(WorkloadControllerError?)

        public var description: String {
            switch self {
            case .initializing:
                return "Initializing"
            case .ready:
                return "Ready"
            case .busyTransitioning(let reason):
                return "Busy (Transitioning)\(reason.map { ": \($0)" } ?? "")"
            case .busy(let reason):
                return "Busy\(reason.map { ": \($0)" } ?? "")"
            case .error(let error):
                if let error {
                    return "Error: \(String(describing: error))"
                }
                return "Error"
            }
        }

        var needDebouncing: Bool {
            self == .ready
        }
    }

    public static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadController"
    )

    public init(
        healthPublisher: ServiceHealthMonitor,
        testConfig: (WorkloadProperties, WorkloadConfig)? = nil,
        metrics: MetricsSystem
    ) {
        self.metrics = metrics
        self.state = .initializing
        self.healthPublisher = healthPublisher
        self.concurrentRequestCount = 0

        if let (testWorkloadProperties, testWorkloadConfig) = testConfig {
            self.workloadProperties = testWorkloadProperties
            self.workloadConfig = testWorkloadConfig
            self.state = .ready
        }
        self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 1, healthStatus: self.state))
    }

    public func run(
        serviceDiscoveryPublisher: ServiceDiscoveryPublisherProtocol?,
        concurrentRequestCountStream: AsyncStream<Int>,
        providerPause: @escaping (String?) async throws -> Void,
        restartPrewarmedInstances: (() async throws -> Void)?
    ) async throws {
        defer {
            self.scheduledPublishing?.cancel()
        }
        self.isLeader = true
        self.serviceDiscoveryPublisher = serviceDiscoveryPublisher
        self.providerPause = providerPause
        self.restartPrewarmedInstances = restartPrewarmedInstances
        self.server = CloudBoardControllerAPIXPCServer.localListener()
        Self.log.info("Starting WorkloadController server")
        await self.server?.connect(listenerDelegate: self, serverDelegate: self)
        Self.log.info("WorkloadController server started")

        // For testing only -- if initialized with a test config instead of
        // using real controller then announce the config immediately.
        if case .ready = self.state,
           let properties = self.workloadProperties,
           self.workloadConfig != nil {
            Self.log.info("""
            Announcing test service \(properties.workloadName, privacy: .public)
            """)
            self.sendStatusUpdate()
        }

        try await self.concurrentRequestCountMonitor(
            concurrentRequestCountStream: concurrentRequestCountStream
        )
    }

    // on follower nodes we dont need service discovery
    public func runInFollowerMode() async throws {
        self.isLeader = false
        Self.log.info("Starting WorkloadController server")
        self.server = CloudBoardControllerAPIXPCServer.localListener()
        await self.server?.connect(listenerDelegate: self, serverDelegate: self)
        Self.log.info("WorkloadController server started")

        while true {
            // Sleep for an hour. This is the longest reasonable interval to approximate
            // "wait forever" without producing unreasonably large numbers.
            try await Task.sleep(for: .seconds(60 * 60))
        }
    }

    private func sendServiceDiscoveryUpdate() {
        guard let properties = self.workloadProperties,
              let config = self.workloadConfig else {
            return
        }

        switch self.state {
        case .ready:
            if self.announcedService == false {
                self.serviceDiscoveryPublisher?.announceService(
                    name: properties.workloadName,
                    workloadConfig: .init(from: config)
                )
                self.announcedService = true
            }
        case .initializing, .busy, .busyTransitioning, .error:
            return
        }
    }

    private func sendHealthPublisherUpdate() {
        if self.isLeader {
            self.sendHealthPublisherUpdateLeader()
        } else {
            self.sendHealthPublisherUpdateFollower()
        }
    }

    private func sendHealthPublisherUpdateLeader() {
        if case .error = self.state {
            self.healthPublisher.updateStatus(.unhealthy)
            return
        }

        guard let properties = self.workloadProperties else {
            Self.log.warning("""
            Skipping health publisher update because workload properties \
            have not been received
            """)
            return
        }
        guard let config = self.workloadConfig else {
            Self.log.warning("""
            Skipping health publisher update because workload config \
            has not been received
            """)
            return
        }

        let maxBatchSize: Int
        let optimalBatchSize: Int
        if case .ready = self.state {
            maxBatchSize = config.maxBatchSize
            optimalBatchSize = config.optimalBatchSize
        } else {
            maxBatchSize = 0
            optimalBatchSize = 0
        }
        self.healthPublisher.updateStatus(.healthy(.init(
            workloadType: properties.workloadName,
            tags: config.workloadTags,
            maxBatchSize: maxBatchSize,
            currentBatchSize: config.currentBatchSize,
            optimalBatchSize: optimalBatchSize
        )))
    }

    private func sendHealthPublisherUpdateFollower() {
        switch self.state {
        case .initializing:
            return
        case .ready, .busy, .busyTransitioning:
            self.healthPublisher.updateStatus(.healthy(nil))
        case .error:
            self.healthPublisher.updateStatus(.unhealthy)
        }
    }

    public func shutdown() async throws {
        try await self.server?.shutdown()
    }

    private func concurrentRequestCountMonitor(
        concurrentRequestCountStream: AsyncStream<Int>
    ) async throws {
        for try await concurrentRequestCount in concurrentRequestCountStream {
            self.concurrentRequestCount = concurrentRequestCount
            self.sendHealthPublisherUpdate()
        }
    }
}

extension WorkloadController: CloudBoardControllerAPIServerDelegateProtocol {
    public func registerWorkload(
        config: WorkloadConfig,
        properties: WorkloadProperties
    ) async throws {
        Self.log.log("""
        Received 'RegisterWorkload' from CloudBoardController: \
        config=\(config.description, privacy: .public), \
        properties=\(properties.description, privacy: .public)
        """)

        if config.optimalBatchSize > config.maxBatchSize {
            Self.log.warning(
                "Optimal batch size is larger than max batch size"
            )
        }

        self.workloadConfig = config
        self.workloadProperties = properties
        self.announcedService = false

        self.sendStatusUpdate()
    }

    public func updateHealthStatus(
        status: WorkloadControllerStatus
    ) async throws {
        Self.log.log("""
        Received 'UpdateHealthStatus' from CloudBoardController: \
        status=\(status.description, privacy: .public)
        """)

        let oldWorkloadState = self.state
        switch status.state {
        case .initializing:
            self.state = .initializing
        case .ready:
            guard self.restartingPrewarmedInstances == false else {
                Self.log.error("""
                Cannot transition to \(status.state, privacy: .public) while restart of \
                prewarmed instances is in progress
                """)
                throw CloudBoardControllerAPIError.restartPrewarmedInProgress
            }
            self.state = .ready
        case .busy:
            if case .busyTransitioning = self.state {
                throw CloudBoardControllerAPIError.alreadyTransitioning(.busy)
            }
            self.state = .busyTransitioning(reason: nil)
        case .busyWithReason(let newReason):
            if case .busyTransitioning(let reason) = self.state {
                throw CloudBoardControllerAPIError.alreadyTransitioning(reason.map { .busyWithReason($0) } ?? .busy)
            }
            self.state = .busyTransitioning(reason: newReason)
        case .error:
            self.state = .error(nil)
        default:
            self.state = .error(.controllerUnknownState)
        }

        if self.isLeader, case .busyTransitioning = self.state {
            guard self.providerPause != nil else {
                Self.log.error("""
                Unable to transition to '\(status.state, privacy: .public)' because no \
                providerPause handler is configured
                """)
                self.state = oldWorkloadState
                throw CloudBoardControllerAPIError.unavailable
            }
        }

        if oldWorkloadState != self.state {
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 0, healthStatus: oldWorkloadState))
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 1, healthStatus: self.state))
        }

        self.sendOrDebounceStatusUpdate()

        if self.isLeader, case .busyTransitioning(let reason) = self.state {
            do {
                try await self.providerPause!(reason)
            } catch {
                throw CloudBoardControllerAPIError.alreadyTransitioning(.busy)
            }
        }
        if case .busyTransitioning(let reason) = self.state {
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 0, healthStatus: self.state))
            self.state = .busy(reason: reason)
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 1, healthStatus: self.state))
        }
    }

    private func sendOrDebounceStatusUpdate() {
        if self.state.needDebouncing {
            if self.scheduledPublishing != nil {
                return
            }
            let delay = if let lastDebouncedPublishingTime = self.lastDebouncedPublishingTime {
                Self.debounceDuration - lastDebouncedPublishingTime.duration(to: .now)
            } else {
                Duration.zero
            }
            if delay <= Duration.zero {
                self.sendStatusUpdate()
                return
            }
            self.scheduledPublishing = Task {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    Self.log.debug("Scheduled status update publishing cancelled")
                    return
                }
                self.sendStatusUpdate()
            }
        } else {
            self.sendStatusUpdate()
        }
    }

    private func sendStatusUpdate() {
        self.scheduledPublishing?.cancel()
        self.scheduledPublishing = nil
        self.sendServiceDiscoveryUpdate()
        self.sendHealthPublisherUpdate()
        if self.state.needDebouncing {
            self.lastDebouncedPublishingTime = .now
        }
    }

    public func restartPrewarmedInstances() async throws {
        Self.log.log("""
        Received 'RestartPrewarmedInstances' from CloudBoardController
        """)

        guard let handler = self.restartPrewarmedInstances else {
            Self.log.error("""
            No underlying handler configured for 'RestartPrewarmedInstances'
            """)
            throw CloudBoardControllerAPIError.unavailable
        }

        guard self.restartingPrewarmedInstances == false else {
            Self.log.error("Restart of prewarmed instances already in progress")
            throw CloudBoardControllerAPIError.restartPrewarmedInProgress
        }

        guard case .busy = self.state else {
            Self.log.error(
                "Cannot restart prewarmed instances in state \(self.state, privacy: .public)"
            )
            throw CloudBoardControllerAPIError.restartPrewarmedInvalidState(
                WorkloadControllerState(from: self.state)
            )
        }
        self.restartingPrewarmedInstances = true
        defer {
            self.restartingPrewarmedInstances = false
        }
        do {
            try await handler()
        } catch {
            Self.log.error(
                "Error while restarting prewarmed instances: \(error, privacy: .public)"
            )
            throw CloudBoardControllerAPIError.restartPrewarmedFailed
        }
    }
}

extension WorkloadController: CloudBoardAsyncXPCListenerDelegate {
    package func invalidatedConnection(_ connection: CloudBoardAsyncXPCConnection) async {
        Self.log.log("""
        Received 'InvalidatedConnection' from CloudBoardController: \
        id=\(String(describing: connection.id), privacy: .public)
        """)

        // Ignoring ID since we only support one controller connection.
        self.state = .error(
            WorkloadControllerError.controllerDisconnected
        )

        self.sendServiceDiscoveryUpdate()
        self.sendHealthPublisherUpdate()
    }
}

extension WorkloadControllerState {
    public init(from controllerState: WorkloadController.ControllerState) {
        switch controllerState {
        case .initializing:
            self = .initializing
        case .ready:
            self = .ready
        case .busy(let reason), .busyTransitioning(let reason):
            if let reason {
                self = .busyWithReason(reason)
            } else {
                self = .busy
            }
        case .error(let error):
            if case .controllerError(let message) = error {
                self = .error(message: message)
            }
            self = .error(message: nil)
        }
    }
}
