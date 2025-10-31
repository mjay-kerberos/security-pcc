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
//  main.swift
//  cablemeshtest
//
//  Created by Marc Orr on 12/19/23.
//

import Foundation

// BackendDelegate designed to test the cable mesh connectivity.
class TestBackendAgent: BackendDelegate {
	var counter = 0
	var chassisCounts: [String: Int] = .init()
	var nodeCounts: [Int: Int] = .init()
	var channelIndexCounts: [Int: Int] = .init()
	let nsLock = NSRecursiveLock()
	let debug: Bool

	init(debug: Bool) {
		self.debug = debug
	}

	// A channel is available/unavailable from the backend.
	func channelChange(node: Int, chassis: String, channelIndex: Int, connected: Bool) {
		nsLock.withLock {
			if debug {
				if self.nodeCounts[node] != nil {
					return
				}
			}
			counter += 1
			chassisCounts[chassis, default: 0] += 1
			nodeCounts[node, default: 0] += 1
			channelIndexCounts[channelIndex, default: 0] += 1
		}
	}

	// A connection has been established/disconnected to a node over the channel.
	func connectionChange(
		direction: BackendConnectionDirection,
		node: Int,
		channelIndex: Int,
		connected: Bool) {
		print("BackendTestAgent.connectionChange(): Not implemented.")
		}

	// An incoming message from a node.
	func incomingMessage(node: Int, message: Data) {
		print("BackendTestAgent.incomingMessage(): Not implemented.")
	}
}

// Print the command-line usage.
func usage(_ message: String? = nil) {
	if let message = message {
		print(message)
		print("---")
	}
	print("Usage: cablemeshtest [--debug] [--timeout=seconds] <ensemble=ensemble_config> <rank=noderank>")
}

// Helper to run a function under a timeout condition. We need a timeout because we're waiting for
// callbacks into a delegate. The timeout code is based on the swift forum discussion, below. This
// approach reminds me of a HW watch dog.
// https://forums.swift.org/t/running-an-async-task-with-a-timeout/49733/27
public func withTimeout<R>(
	seconds: Int,
	operation: @escaping @Sendable () async throws -> R) async throws -> R {
	return try await withThrowingTaskGroup(of: R.self) { group in
		defer {
			group.cancelAll()
		}

		// Start actual work.
		group.addTask {
			let result = try await operation()
			try Task.checkCancellation()
			return result
		}

		// Start timeout child task.
		group.addTask {
			if seconds > 0 {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			}
			try Task.checkCancellation()
			// We’ve reached the timeout.
			throw CableMeshTestError.TimeoutError
		}
		// First finished child task wins, cancel the other task.
		let result = try await group.next()!
		return result
	}
}

// Test Fixture.
class CableMeshTest {
	// Command-line args.
	var ensembleConfigFile: String = "nil"
	var myNodeRank: Int = -1
	var testCaseTimeout = 60
	var debug = false

	// CIO interface.
	var testBackendAgent: TestBackendAgent?
	var backend: Backend?
	var ensembleConfig: EnsembleConfiguration?

	// Ensemble info.
	var expectedChassis: [String]?

	// Test expectations.
	struct CableMeshExpectation {
		let chassisCounts: [Int]
		let neighborsCount: Int
		let channelIndexes: [Int]
	}
	var chassisCountsWant = [
		4: CableMeshExpectation(
			chassisCounts: [3],
			neighborsCount: 3,
			channelIndexes: [0, 1, 2]
		),
		8: CableMeshExpectation(
			chassisCounts: [1, 3],
			neighborsCount: 4,
			channelIndexes: [0, 1, 2, 3]
		)
	]

	// Parse command-line arguments.
	func parseArgs() throws {
		let args = CommandLine.arguments

		// Parse <ensemble=ensemble_config> arg.
		let ensembleConfigArg = args.first(where: { $0.hasPrefix("ensemble=") })
		guard let ensembleConfigArg = ensembleConfigArg else {
			let oopsMessage = "Oops. Missing <ensemble=ensemble_config> arg."
			usage(oopsMessage)
			throw CableMeshTestError.InvalidInput(oopsMessage)
		}
		self.ensembleConfigFile = String(ensembleConfigArg.dropFirst("ensemble=".count))

		// Parse <rank=node_rank> arg.
		let nodeRankArg = args.first(where: { $0.hasPrefix("rank=") })
		guard let nodeRankArg = nodeRankArg else {
			let oopsMessage = "Oops. Missing <rank=noderank> arg."
			usage(oopsMessage)
			throw CableMeshTestError.InvalidInput(oopsMessage)
		}
		let myNodeRank = Int(String(nodeRankArg.dropFirst("rank=".count)))
		if myNodeRank == nil {
			let oopsMessage = "Oops. Unable to parse <rank=noderank> arg: \(nodeRankArg)"
			usage(oopsMessage)
			throw CableMeshTestError.InvalidInput(oopsMessage)
		}
		self.myNodeRank = myNodeRank!

		// Parse [--timeout=seconds] arg.
		let timeoutArg = args.first(where: { $0.hasPrefix("--timeout=") })
		if let timeoutArg = timeoutArg {
			let testCaseTimeout = Int(timeoutArg.dropFirst("--timeout=".count))
			guard let testCaseTimeout = testCaseTimeout else {
				let oopsMessage = "Oops. Unable to parse --timeout arg: \(timeoutArg)"
				usage(oopsMessage)
				throw CableMeshTestError.InvalidInput(oopsMessage)
			}
			self.testCaseTimeout = testCaseTimeout
		}

		// Parse [--debug] arg.
		if args.contains(where: { $0 == "--debug" }) {
			self.debug = true
		}
	}

	// Initialize the test fixture (e.g., the CIO backend).
	func setUpClass() throws {
		self.testBackendAgent = TestBackendAgent(debug: self.debug)
		guard let testBackendAgent = self.testBackendAgent else {
			throw CableMeshTestError.UnexpectedError(
				"Failed to init TestBackendAgent. This should never happen!")
		}

		let backendHelper = BackendHelper(
			delegate: testBackendAgent,
			ensembleConfigFile: self.ensembleConfigFile,
			myNodeRank: self.myNodeRank,
			timeout: self.testCaseTimeout)
		if self.debug {
			self.backend = try backendHelper.SetupSocketBackend()
		} else {
			self.backend = try backendHelper.SetupCIOBackend()
		}
		if self.backend == nil {
			throw CableMeshTestError.InvalidInput(
				"Could not create a Backend from ensemble configuration file " +
				"\(self.ensembleConfigFile) for node rank \(self.myNodeRank)")
		}
		self.ensembleConfig = backendHelper.ensembleConfig
		guard let ensembleConfig = self.ensembleConfig else {
			throw CableMeshTestError.UnexpectedError(
				"`ensembleConfig` is nil after setting up the backend: This should never happen.")
		}
		guard ensembleConfig.nodeCount == 4 || ensembleConfig.nodeCount == 8 else {
			throw CableMeshTestError.InvalidInput(
				"Bad ensemble config file, \(self.ensembleConfigFile): Expected 4 or 8 nodes, " +
				"got \(ensembleConfig.nodeCount).")
		}

		self.expectedChassis = try ensembleConfig.getChassisIDs()
		if self.expectedChassis == nil {
			throw CableMeshTestError.InvalidInput(
				"Bad ensemble config file, \(self.ensembleConfigFile): " +
				"Expected \(ensembleConfig.chassisCount) chassis.")
		}
	}

	// Main function.
	func main() async throws {
		try self.parseArgs()

		try self.setUpClass()

		// Run the test cases.
		let results = try await withTimeout(
			seconds: self.testCaseTimeout,
			operation: self.TestCableConnectivity)

		// Report the results.
		if results.isEmpty {
			print("Cable connectivity test passed :-).")
		} else {
			print("Cable connectivity test FAILED!")
			print(results)
		}
	}

  // Cable connectivity test.
	@Sendable
	func TestCableConnectivity() throws -> [String] {
		guard let backend = self.backend,
					let testBackendAgent = self.testBackendAgent,
					let ensembleConfig = self.ensembleConfig,
					let expectedChassis = self.expectedChassis
		else {
			throw CableMeshTestError.UnexpectedError(
				"Oops. These member-level variables should be non-nil. Was self.setUpClass() called?")
		}

		guard let want = self.chassisCountsWant[ensembleConfig.nodeCount] else {
			throw CableMeshTestError.InvalidInput(
				"Ensemble size \(ensembleConfig.nodeCount) not supported.")
		}

		// Activate the backend.
		if self.debug {
			let socketBackend = backend as! SocketBackend
			socketBackend.setBooted(booted: true)
			try backend.activate()
		}

		var channelsEstablished = false
		while !Task.isCancelled && !channelsEstablished {
			testBackendAgent.nsLock.withLock {
				if testBackendAgent.counter >= want.neighborsCount {
					channelsEstablished = true
				}
			}
		}

		var results: [String] = .init()

		testBackendAgent.nsLock.withLock {
			// Expectation #1:
			// 4-node ensemble: 3 intra-chassis connections
			// 8-node ensemble: 3 intra-chassis connections + 1 inter-chassis connection
			var chassisCountsGot: [Int] = []
			for chassis in expectedChassis {
				if let count = testBackendAgent.chassisCounts[chassis] {
					chassisCountsGot.append(count)
				} else {
					results.append("Expected connections to chassis \(chassis)")
				}
			}

			if chassisCountsGot.count != want.chassisCounts.count ||
				 chassisCountsGot.sorted() != want.chassisCounts.sorted() {
				results.append(
					"Bad chassis counts. Expected \(want.chassisCounts). " +
					"Got \(chassisCountsGot)")
			}

			// Expectation #2:
			// 4-node ensemble: We should be connected to three different nodes.
			// 8-node ensemble: We should be connected to four different nodes.
			if testBackendAgent.nodeCounts.count != want.neighborsCount {
				results.append(
					"Expected connectivity to \(want.neighborsCount) distinct nodes. " +
					"Got connectivity to \(testBackendAgent.nodeCounts.count) distinct nodes.")
			}

			// Loop through `nodeCounts` and check that each value is set to `1`.
			for (node, count) in testBackendAgent.nodeCounts {
				if count != 1 {
					results.append("Bad count for node \(node). Got \(count). Expected 1.")
				}
			}

			// Expectation #3:
			// 4-node ensemble: The channel indexes are [0, 1, 2]
			// 8-node ensemble: The channel indexes are [0, 1, 2, 3]
			if testBackendAgent.channelIndexCounts.count != want.channelIndexes.count ||
				 testBackendAgent.channelIndexCounts.keys.sorted() != want.channelIndexes.sorted() {
				results.append(
					"Expected channel indexes to be \(want.channelIndexes.sorted()), " +
					"got \(testBackendAgent.channelIndexCounts.keys.sorted())")
			}

			for (channelIndex, count) in testBackendAgent.channelIndexCounts {
				if count != 1 {
					results.append("Got > 1 instance of channel index \(channelIndex)")
				}
			}
		}

		return results
	}
}

var cableMeshTest: CableMeshTest = .init()
try await cableMeshTest.main()
