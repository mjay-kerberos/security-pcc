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

//  Copyright © 2024 Apple Inc. All rights reserved.

import CloudBoardCommon
import CloudBoardJobHelperAPI
import CloudBoardMetrics
import DequeModule
import os
import Tracing

private let log: Logger = .init(
    subsystem: "com.apple.cloudos.cloudboard",
    category: "JobHelperInstanceProvider"
)

// This placeholder delegate is needed for prewarmed JobHelperInstance instances until
// they are used and we get a real delegate for handling responses from associated
// JobHelperInstance instances. Instances of this are never expected to be invoked.
actor PrewarmedJobHelperResponseDelegate: CloudBoardJobHelperAPIClientDelegateProtocol {
    let metrics: MetricsSystem

    init(metrics: MetricsSystem) {
        self.metrics = metrics
    }

    nonisolated func cloudBoardJobHelperAPIClientSurpriseDisconnect() {
        log.error("surprise disconnect of prewarmed JobHelperInstance")
    }

    nonisolated func handleWorkloadResponse(_: JobHelperToCloudBoardDaemonMessage) {
        self.metrics
            .emit(Metrics.JobHelperInstanceProvider.PlaceholderDelegateWorkloadResponseInvoked(action: .increment))
        log.error("sendWorkloadResponse unexpectedly called on PrewarmedJobHelperResponseDelegate")
    }
}

enum JobHelperInstanceInstanceQueueError: Error {
    case usedAfterTerminateCalled
    case terminateCalledMultipleTimes
}

actor JobHelperInstanceQueue {
    private var readyJobHelperInstances: Deque<JobHelperInstance> = Deque()
    private var waiters: [Promise<JobHelperInstance, Error>] = []
    private var terminated: Bool = false
    private var prewarmedPoolSize: Int
    private let metrics: MetricsSystem

    init(prewarmedPoolSize: Int, metrics: MetricsSystem) {
        self.prewarmedPoolSize = prewarmedPoolSize
        self.metrics = metrics
    }

    private func enqueue(_ instance: JobHelperInstance, _ operation: (JobHelperInstance) -> Void) throws {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.usedAfterTerminateCalled
        }
        if self.waiters.count > 0 {
            let waiter = self.waiters.removeFirst()
            self.metrics.emit(Metrics.JobHelperInstanceProvider.WaitedForCreationTotal(
                action: .increment,
                prewarmedPoolSize: self.prewarmedPoolSize
            ))
            waiter.succeed(with: instance)
        } else {
            operation(instance)
        }
    }

    func push(_ instance: JobHelperInstance) throws {
        try self.enqueue(instance) { self.readyJobHelperInstances.append($0) }
    }

    func pushFirst(_ instance: JobHelperInstance) throws {
        try self.enqueue(instance) { self.readyJobHelperInstances.insert($0, at: 0) }
    }

    func popFirst() async throws -> JobHelperInstance {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.usedAfterTerminateCalled
        }

        if let readyInstance = self.readyJobHelperInstances.popFirst() {
            return readyInstance
        }

        let waiterPromise = Promise<JobHelperInstance, Error>()
        let result: Result<JobHelperInstance, Error>
        do {
            self.waiters.append(waiterPromise)
            result = try await Future(waiterPromise).resultWithCancellation
        } catch {
            // Can only fail on cancellation while waiting for the promise in which case the promise has not yet been
            // fulfilled and we need to fulfil it here
            waiterPromise.fail(with: CancellationError())
            self.waiters.removeAll(where: { $0 === waiterPromise })
            throw CancellationError()
        }
        return try result.get()
    }

    func remove(_ instance: JobHelperInstance) -> Bool {
        guard let index = self.readyJobHelperInstances.firstIndex(where: { $0 == instance }) else {
            return false
        }

        self.readyJobHelperInstances.remove(at: index)
        return true
    }

    func terminate(error: Error) throws -> Deque<JobHelperInstance> {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.terminateCalledMultipleTimes
        }
        self.terminated = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.fail(with: error)
        }

        defer { self.readyJobHelperInstances = [] }
        return self.readyJobHelperInstances
    }
}

enum JobHelperInstanceProviderError: Error {
    case teardownInitiatedBecauseRefillStreamFinished
    case invalidPrewarmedPoolSizeSpecified
    case invalidMaxProcessCountSpecified
    case failedToAllocateJobHelperInstance
}

// JobHelperInstanceProvider is left as a class so that we don't serialize all
// calls to withClient() (support multiple jobs in parallel)
final class JobHelperInstanceProvider: Sendable {
    private let metrics: MetricsSystem
    private let tracer: any Tracer
    private let launchdJobFinder: any LaunchdJobFinderProtocol
    private let jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol

    private let jobHelperInstanceGetRetryCount: Int = 3
    private let prewarmedPoolSize: Int
    private let maxProcessCount: Int

    private var prewarmingDisabled: Bool {
        return self.prewarmedPoolSize == 0
    }

    private var processLimitDisabled: Bool {
        return self.maxProcessCount == 0
    }

    private let prewarmedQueue: JobHelperInstanceQueue
    private let refillStream: AsyncStream<ContinuousTimeMeasurement>
    private let refillContinuation: AsyncStream<ContinuousTimeMeasurement>.Continuation

    private struct State {
        var prewarmedCount: Int = 0
        var totalRunningCount: Int = 0
        var pendingCreationCount: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private func incrementPrewarmedPoolCount() {
        self.state.withLock { state in
            state.prewarmedCount += 1
            self.metrics.emit(Metrics.JobHelperInstanceProvider.PrewarmedPoolSizeGauge(
                value: state.prewarmedCount, configuredPoolSize: self.prewarmedPoolSize
            ))
        }
    }

    private func decrementPrewarmedPoolCount() {
        self.state.withLock { state in
            state.prewarmedCount -= 1
            self.metrics.emit(Metrics.JobHelperInstanceProvider.PrewarmedPoolSizeGauge(
                value: state.prewarmedCount, configuredPoolSize: self.prewarmedPoolSize
            ))
        }
    }

    init(
        prewarmedPoolSize: Int,
        maxProcessCount: Int,
        metrics: MetricsSystem,
        tracer: any Tracer,
        launchdJobFinder: any LaunchdJobFinderProtocol,
        jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol
    ) throws {
        log.log(
            "Initializing JobHelperInstanceProvider with prewarmedPoolSize: \(prewarmedPoolSize, privacy: .public), maxProcessCount: \(maxProcessCount, privacy: .public)"
        )
        if prewarmedPoolSize < 0, prewarmedPoolSize > 100 {
            log.error(
                "Invalid prewarmedPoolSize specified (\(prewarmedPoolSize, privacy: .public)), value must be in [0, 100]"
            )
            throw JobHelperInstanceProviderError.invalidPrewarmedPoolSizeSpecified
        }
        if maxProcessCount != 0, prewarmedPoolSize > maxProcessCount {
            log.error(
                "Specified prewarmedPoolSize (\(prewarmedPoolSize, privacy: .public)), exceeds provided maxProcessCount (\(maxProcessCount, privacy: .public))"
            )
            throw JobHelperInstanceProviderError.invalidPrewarmedPoolSizeSpecified
        }
        self.prewarmedPoolSize = prewarmedPoolSize

        if maxProcessCount < 0, maxProcessCount > 200 {
            log.error(
                "Invalid maxProcessCount specified (\(maxProcessCount, privacy: .public)), value must be in [0, 200]"
            )
            throw JobHelperInstanceProviderError.invalidMaxProcessCountSpecified
        }
        self.maxProcessCount = maxProcessCount

        self.prewarmedQueue = JobHelperInstanceQueue(
            prewarmedPoolSize: self.prewarmedPoolSize,
            metrics: metrics
        )
        (self.refillStream, self.refillContinuation) = AsyncStream<ContinuousTimeMeasurement>.makeStream()
        self.metrics = metrics
        self.tracer = tracer
        self.launchdJobFinder = launchdJobFinder
        self.jobHelperXPCClientFactory = jobHelperXPCClientFactory
    }

    /// Run  the provided `JobHelperInstance` until it terminates and handler teardown triggers.
    /// Completes on `JobHelperInstance` finishing (the underlying process terminating).
    ///
    /// This is non-throwing because we don't want errors managing/running a specific job helper instance to
    /// be propagated outside of the management context of that specific instance.
    ///
    /// - Parameter jobHelperInstance: the jobhelper instance to run
    private func runJobHelperInstance(_ jobHelperInstance: JobHelperInstance) async {
        await withTaskGroup(of: Void.self) { instanceTaskGroup in
            instanceTaskGroup.addTask {
                do {
                    try await jobHelperInstance.run()
                } catch {
                    log.error("""
                    \(jobHelperInstance.logMetadata(), privacy: .public) \
                    manageJobHelperInstance instance.run() received an error: \
                    \(String(unredacted: error), privacy: .public)
                    """)
                }

                // Check to see if the jobhelper instance is still on the prewarmed queue,
                // if it is, remove it and complete the promise as we are responsible for it.
                // If it's not, the current holder of the jobhelper instance is responsible
                // for completing the promise.
                if await self.prewarmedQueue.remove(jobHelperInstance) {
                    self.metrics.emit(Metrics.JobHelperInstanceProvider.PrewarmedInstancesDiedTotal(action: .increment))
                    self.decrementPrewarmedPoolCount()
                    await jobHelperInstance.triggerTeardown()
                }
            }

            instanceTaskGroup.addTask {
                // this expects the trigger for teardown to be invoked elsewhere - if it isn't,
                // promise gets leaked and cloudboardd will crash.
                await jobHelperInstance.teardownOnTrigger()
            }

            await instanceTaskGroup.waitForAll()
        }

        self.jobHelperInstanceConsumed()
    }

    func run() async throws {
        let definitions = try self.launchdJobFinder.getJobDefinitions(
            type: CloudBoardJobType.cbJobHelper
        )
        guard definitions.count == 1 else {
            log.error("unexpected cb_jobhelper managed jobs count \(definitions.count, privacy: .public)")
            throw JobHelperInstanceError.tooManyManagedJobs
        }
        let definition = definitions[0]
        log.log("discovered cb_jobhelper launchd job")

        self.state.withLock { state in
            for _ in 0 ..< self.prewarmedPoolSize {
                self.refillContinuation.yield(.start())
                state.pendingCreationCount += 1
            }
        }

        // We don't want the child tasks to throw here since each is responsible for handling
        // the errors in creating and managing its associated jobhelper instance.
        await withDiscardingTaskGroup { group in
            // Each time we receive a signal on this stream, create one new JobHelperInstance
            for await processRequestedAt in self.refillStream {
                let initiatedAt = ContinuousTimeMeasurement.start()
                let jobHelperInstance = JobHelperInstance(
                    definition,
                    jobHelperXPCClientFactory: self.jobHelperXPCClientFactory,
                    delegate: PrewarmedJobHelperResponseDelegate(metrics: self.metrics),
                    metrics: self.metrics,
                    tracer: self.tracer
                )

                log.info("\(jobHelperInstance.logMetadata(), privacy: .public) created JobHelperInstance")
                group.addTask {
                    await self.runJobHelperInstance(jobHelperInstance)
                    // getting here means the jobhelper instance has terminated
                    self.state.withLock { state in
                        state.totalRunningCount -= 1
                    }
                    self.jobHelperInstanceConsumed()
                }

                group.addTask {
                    // prewarm the jobhelper instance - races with `runJobHelperInstance`, but that is handled by the
                    // jobhelper instance's state machine
                    do {
                        try await jobHelperInstance.warmup()

                        self.incrementPrewarmedPoolCount()
                        try await self.prewarmedQueue.push(jobHelperInstance)
                        let launchDuration = initiatedAt.duration
                        // time from
                        let launchLatency = processRequestedAt.duration
                        log.debug("""
                        \(jobHelperInstance.logMetadata(), privacy: .public) warmed up
                        latency=\(launchLatency.milliseconds, privacy: .public)ms
                        launch=\(launchDuration.milliseconds, privacy: .public)ms
                        queue=\((launchLatency - launchDuration).milliseconds, privacy: .public)ms
                        """)
                        self.metrics.emit(
                            Metrics.JobHelperInstanceProvider.TimeToLaunchJobHelperInstanceHistogram(
                                duration: launchLatency,
                                prewarmingEnabled: !self.prewarmingDisabled,
                                prewarmedPoolSize: self.prewarmedPoolSize
                            )
                        )
                    } catch {
                        // Dont rethrow this error because we want to let run complete so the JobHelperInstance
                        // can be torn down and removed from the prewarmed queue.
                        log.error("""
                        \(jobHelperInstance.logMetadata(), privacy: .public) \
                        warmup failed with error: \
                        \(String(unredacted: error), privacy: .public) \
                        tearing down
                        """)
                        self.metrics.emit(Metrics.JobHelperInstanceProvider.InvokeWarmupErrorTotal(action: .increment))
                        await jobHelperInstance.triggerTeardown(error: error)
                    }
                }

                self.state.withLock { state in
                    state.totalRunningCount += 1
                    state.pendingCreationCount -= 1
                }
            }

            log.error(
                "JobHelperInstanceProvider run() refillStream finished, tearing down any remaining prewarmed instances"
            )
            do {
                let error = JobHelperInstanceProviderError.teardownInitiatedBecauseRefillStreamFinished
                for jobHelperInstance in try await self.prewarmedQueue.terminate(error: error) {
                    await jobHelperInstance.triggerTeardown(error: error)
                    self.decrementPrewarmedPoolCount()
                }
            } catch {
                log.error("""
                JobHelperInstanceProvider run() teardown failed to invoke \
                terminate() on prewarmed queue: \
                \(String(unredacted: error), privacy: .public)
                """)
            }
        }
    }

    // Called whenever a JobHelperInstance goes away for any reason.
    // Does the logical check and determines
    // "do we need a new one - yes/no?", if yes enqueue a void message into the
    // stream that the run refill tasks awaits on.
    // Avoid throwing and async routines to maintain simplicity here
    // called when one is consumed from the free queue AND when one actually
    // dies.
    private func jobHelperInstanceConsumed() {
        // While the # of (currently running + creation in-flight processes) is less than the ceiling
        // AND the # of (currently prewarmed + creation in-flight processes) is less than the prewarmed pool size,
        // submit new creation requests.
        self.state.withLock { state in
            var pendingPlusRunningProcessCount: Int {
                state.totalRunningCount + state.pendingCreationCount
            }

            var pendingPlusPrewarmedCount: Int {
                state.prewarmedCount + state.pendingCreationCount
            }

            while self.processLimitDisabled ||
                pendingPlusRunningProcessCount < self.maxProcessCount,
                pendingPlusPrewarmedCount < self.prewarmedPoolSize {
                state.pendingCreationCount += 1
                self.refillContinuation.yield(.start())
            }
        }
    }

    private func dequeueJobHelperInstance(
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol?
    ) async throws -> JobHelperInstance {
        let waitForAllocationMeasurement = ContinuousTimeMeasurement.start()

        let retryMaxCount = self.jobHelperInstanceGetRetryCount
        for attempt in 1 ... retryMaxCount {
            // If prewarming is disabled, signal to request a new JobHelperInstance
            if self.prewarmingDisabled {
                self.state.withLock { state in
                    state.pendingCreationCount += 1
                }
                self.refillContinuation.yield(.start())
            }

            let jobHelperInstance: JobHelperInstance
            do {
                jobHelperInstance = try await self.prewarmedQueue.popFirst()
            } catch {
                log.error("""
                dequeueJobHelperInstance popFirst returned error: \
                \(String(unredacted: error), privacy: .public)
                """)
                throw error
            }
            self.decrementPrewarmedPoolCount()
            self.jobHelperInstanceConsumed()

            do {
                // This could fail if the JobHelperInstance died and we de-queued it
                // before manageJobHelperInstance() handled the death notification and
                // removed it from the prewarmed queue.
                if let delegate {
                    try await jobHelperInstance.set(delegate: delegate)
                }
                self.metrics.emit(
                    Metrics.JobHelperInstanceProvider.AttemptsToAllocateJobHelperInstanceHistogram(value: attempt)
                )
                self.metrics.emit(
                    Metrics.JobHelperInstanceProvider.TimeToAllocateJobHelperInstanceHistogram(
                        duration: waitForAllocationMeasurement.duration,
                        prewarmingEnabled: !self.prewarmingDisabled,
                        prewarmedPoolSize: self.prewarmedPoolSize
                    )
                )
                return jobHelperInstance
            } catch {
                log.error("""
                \(jobHelperInstance.logMetadata(), privacy: .public) dequeueJobHelperInstance failed \
                to use dequeued instance: \
                \(String(unredacted: error), privacy: .public)
                """)
                // Ensure the jobhelper instance is torn down
                await jobHelperInstance.triggerTeardown()
            }
        }

        self.metrics.emit(Metrics.JobHelperInstanceProvider.FailedToAllocateTotal(
            action: .increment,
            retryCount: retryMaxCount
        ))
        throw JobHelperInstanceProviderError.failedToAllocateJobHelperInstance
    }

    // Assumption here is that we have ownership of the JobHelperInstance at this point,
    // if someone else does use it, they have violated the ownership contract defined
    // by use of the withJobHelperInstance() call (which expects all usage of the client to be contained
    // within the body). There's no great way to defend against violation of this contract.
    private func returnJobHelperInstance(_ jobHelperInstance: JobHelperInstance) async {
        let instanceUsed = await jobHelperInstance.condition != .waiting
        // If the instance was used or prewarming is disabled, return the jobhelper instance
        if instanceUsed || self.prewarmingDisabled {
            await jobHelperInstance.triggerTeardown()
            return
        }

        do {
            try await jobHelperInstance.set(delegate: PrewarmedJobHelperResponseDelegate(metrics: self.metrics))
        } catch {
            log.error("""
            \(jobHelperInstance.logMetadata(), privacy: .public) failed to reclaim \
            unused JobHelperInstance instance: \
            \(String(unredacted: error), privacy: .public)
            """)
            self.metrics.emit(Metrics.JobHelperInstanceProvider.FailedToReclaimTotal(action: .increment))
            // We complete the teardown promise, which signals to the associated task in manageJobHelperInstance()
            // that we should initiate teardown of this instance.
            await jobHelperInstance.triggerTeardown()
            return
        }

        log.info("\(jobHelperInstance.logMetadata(), privacy: .public) reclaimed unused JobHelperInstance instance")
        do {
            try await self.prewarmedQueue.pushFirst(jobHelperInstance)
        } catch {
            log.error("""
            \(jobHelperInstance.logMetadata(), privacy: .public) failed to return unused \
            JobHelperInstance instance to prewarmed queue: \
            \(String(unredacted: error), privacy: .public), \
            initiating teardown
            """)
            self.metrics.emit(Metrics.JobHelperInstanceProvider.FailedToReclaimTotal(action: .increment))
            // We complete the teardown promise, which signals to the associated task in manageJobHelperInstance()
            // that we should initiate teardown of this instance.
            await jobHelperInstance.triggerTeardown()
            return
        }
        self.incrementPrewarmedPoolCount()
        self.metrics.emit(Metrics.JobHelperInstanceProvider.ReclaimedPrewarmedTotal(action: .increment))
    }

    // All usage of the JobHelperInstance provided to the body must be completed
    // by the time the body returns.
    func withJobHelperInstance<ReturnValue>(
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol,
        _ body: (JobHelperInstance) async throws -> ReturnValue
    ) async throws
    -> ReturnValue {
        let jobHelperInstance: JobHelperInstance
        do {
            try await jobHelperInstance = self.dequeueJobHelperInstance(delegate: delegate)
        } catch {
            log.error("""
            withJobHelperInstance(): failed to obtain JobHelperInstance: \
            \(String(unredacted: error), privacy: .public)
            """)
            throw error
        }

        log.info("\(jobHelperInstance.logMetadata(), privacy: .public) allocated for usage")

        do {
            let returnValue = try await body(jobHelperInstance)
            await self.returnJobHelperInstance(jobHelperInstance)
            log.info("withJobHelperInstance returning")
            return returnValue
        } catch {
            log.error("""
            \(jobHelperInstance.logMetadata(), privacy: .public) \
            withJobHelperInstance() body returned error \
            \(String(unredacted: error), privacy: .public)
            """)
            await self.returnJobHelperInstance(jobHelperInstance)
            throw error
        }
    }

    public func restartPrewarmedInstances() async throws {
        // The WorkloadController only allows this to be called in the "busy"
        // state so no more requests can come in at this point.
        log.info("Restarting prewarmed instances")

        let count = self.state.withLock { state in
            return state.prewarmedCount + state.pendingCreationCount
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    do {
                        let jobHelperInstance = try await self.dequeueJobHelperInstance(
                            delegate: nil
                        )
                        let id = jobHelperInstance.id
                        log.info("Disposing stale JobHelperInstance jobID=\(id, privacy: .public)")
                        try await jobHelperInstance.abandon()
                        await jobHelperInstance.triggerTeardown()
                    } catch {
                        log.error("""
                        Failed to dispose of stale JobHelperInstance: \
                        \(String(reportable: error), privacy: .public)
                        """)
                    }
                }
            }

            try await group.waitForAll()
        }
    }
}
