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
//  EnsembleConfigurationTests.swift
//  EnsembleConfigurationTests
//
//  Created by Dhanasekar Thangavel on 11/18/24.
//

import CryptoKit
import AppleComputeEnsembler
@testable import EnsembleConfiguration
import notify
import XCTest

// bad config, with two node having same rank
let twoNodeBadConfigDuplicateRank = EnsembleConfiguration(
	backendType: BackendType.StubBackend,
	hypercube: false,
	nodes: [
		"udid-0": NodeConfiguration(
			chassisID: "chassis1",
			rank: Rank.Rank0,
			hostName: "localhost",
			port: 8029
		),
		"udid-1": NodeConfiguration(
			chassisID: "chassis1",
			rank: Rank.Rank0,
			hostName: "localhost",
			port: 8030
		),
	]
)

final class EnsembleConfigurationTests: XCTestCase {
	// Verify state machine for single node
	func testStateMachinesSingleNode() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 1)
		try self.validateEnsemblerStateMachine(config: ensembleConfig)
	}

	// Verify state machine for 2 node
	// leaders starts first followed by follower1
	func testStateMachinesTwoNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	func invalidRankChassisIDConfiguration(nodeCount: Int) throws {
		let ensembleConfig = self.getEnsembleConfigInvalid(nodeCount: nodeCount)
		do {
			let ensembler = try EnsemblerTLS(
				ensembleConfig: ensembleConfig,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: ensembleConfig.nodes.keys.first,
				skipJobQuiescence: true
			)
            ensembler.stopServer()
		} catch InitializationError.invalidRankChassisdIDConfiguration {
			return
		}
		XCTFail("Invalid configuration is accepted, which should not be the case")
	}

	func testInvalidRankChassisIDConfiguration() throws {
		try self.invalidRankChassisIDConfiguration(nodeCount: 2)
		try self.invalidRankChassisIDConfiguration(nodeCount: 4)
		try self.invalidRankChassisIDConfiguration(nodeCount: 8)
		try self.invalidRankChassisIDConfiguration(nodeCount: 16)
	}

	func validRankChassisIDConfiguration(nodeCount: Int) throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: nodeCount)
		do {
			let ensembler = try EnsemblerTLS(
				ensembleConfig: ensembleConfig,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: ensembleConfig.nodes.keys.first,
				skipJobQuiescence: true
			)
            ensembler.stopServer()
		} catch InitializationError.invalidRankChassisdIDConfiguration {
			XCTFail("Valid configuration is not accepted, something wrong")
			return
		}
	}

	func testValidRankChassisIDConfiguration() throws {
		try self.validRankChassisIDConfiguration(nodeCount: 2)
		try self.validRankChassisIDConfiguration(nodeCount: 4)
		try self.validRankChassisIDConfiguration(nodeCount: 8)
		try self.validRankChassisIDConfiguration(nodeCount: 16)
	}

	// Verify state machine for two node for key rotation scenario
	// simulate node coming up in order i.e first node is started, and then second node it started.
	func testStateMachinesTwoNodeKeyrotation() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
		try self.validateEnsemblerStateMachineInternalForKeyRotation(
			config: ensembleConfig,
			startIndex: 0
		)
	}

	// Verify state machine for 2 node
	// follower1 starts first followed by leader
	func testStateMachinesTwoNodeUnordered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
		try self.validateEnsemblerStateMachine(config: ensembleConfig)
	}

	// simulate failure with both rank 0, expected state will be both stuck in coordinating state.
	func testStateMachinesTwoNodeWithFailure() throws {
		try self.validateEnsemblerStateMachineWithFailure(
			config: twoNodeBadConfigDuplicateRank,
			expectedState: .coordinating
		)
	}

	// Verify state machine for 4 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesFourNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 4)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 4 node
	// follower2 starts first followed by follower3, leader, follower1,2.
	func testStateMachinesFourNodeUnordered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 4)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 3)
	}

	// Verify distributing Datakey and getting the key on all followers
	func testValidateDistributeDataKey() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
		try self.validateDataKeyDistribution(config: ensembleConfig)
	}

	// Verify state machine for 8 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesEigthNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 8 node
	// follower3 starts first followed by follower4,5,..n and then leader, follower1,2.
	func testStateMachinesEigthNodeUnordered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 4)
	}

	// Verify state machine for 16 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesSixteenNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 16)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 16 node
	// follower3 starts first followed by follower4,5,..n and then leader, follower1,2.
	func testStateMachinesSixteenNodeUnOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 16)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 4)
	}

	// Verify state machine for 32 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesThirtyTwoNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 32)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 32 node
	// follower3 starts first followed by follower4,5,..n and then leader, follower1,2.
	func testStateMachinesThirtyTwoNodeUnOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 32)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 4)
	}

	// Helper functions
	// get the ensemble configuration which does gauranteee rank0-3 ( and so on) contains same
	// chassisid
	func getEnsembleConfig(nodeCount: Int) -> EnsembleConfiguration {
		var nodes: [String: NodeConfiguration] = [:]
		for i in 0 ..< nodeCount {
			let node = NodeConfiguration(
				chassisID: "chassis-".appending(String(i / 4)),
				rank: Rank(rawValue: i)!,
				hostName: "127.0.0.1",
				port: UInt16(8029 + i)
			)
			nodes["udid-".appending(String(i))] = node
		}

		return EnsembleConfiguration(
			backendType: BackendType.StubBackend,
			hypercube: false,
			nodes: nodes
		)
	}

	// get the ensemble configuration which does not gauranteee rank0-3 ( and so on) contains same
	// chassisid
	func getEnsembleConfigInvalid(nodeCount: Int) -> EnsembleConfiguration {
		var nodes: [String: NodeConfiguration] = [:]

		if nodeCount == 2 {
			let node1 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 0)!,
				hostName: "127.0.0.1",
				port: UInt16(8029)
			)
			nodes["udid-".appending(String(0))] = node1

			let node2 = NodeConfiguration(
				chassisID: "chassis2",
				rank: Rank(rawValue: 1)!,
				hostName: "127.0.0.1",
				port: UInt16(8030)
			)
			nodes["udid-".appending(String(1))] = node2
		} else if nodeCount == 4 {
			let node1 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 0)!,
				hostName: "127.0.0.1",
				port: UInt16(8029)
			)
			nodes["udid-".appending(String(0))] = node1

			let node2 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 1)!,
				hostName: "127.0.0.1",
				port: UInt16(8030)
			)
			nodes["udid-".appending(String(1))] = node2

			let node3 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 2)!,
				hostName: "127.0.0.1",
				port: UInt16(8029)
			)
			nodes["udid-".appending(String(2))] = node3

			let node4 = NodeConfiguration(
				chassisID: "chassis2",
				rank: Rank(rawValue: 3)!,
				hostName: "127.0.0.1",
				port: UInt16(8030)
			)
			nodes["udid-".appending(String(3))] = node4
		} else {
			// This will generate
			// rank1-4 assigned chassisid1, rank5-8 chassisid2... rank13,14,15,0 chassisd4 for 16 node.
			for i in 0 ..< nodeCount {
				let node = NodeConfiguration(
					chassisID: "chassis-".appending(String(i / 4)),
					rank: Rank(rawValue: (i + 1) % nodeCount)!,
					hostName: "127.0.0.1",
					port: UInt16(8029 + i)
				)
				nodes["udid-".appending(String(i))] = node
			}
		}

		return EnsembleConfiguration(
			backendType: BackendType.StubBackend,
			hypercube: false,
			nodes: nodes
		)
	}

	func validateEnsemblerStateMachine(
		config: EnsembleConfiguration,
		expectedState _: EnsemblerStatus = .ready
	) throws {
		for i in 1 ..< config.nodes.count {
			try self.validateEnsemblerStateMachineInternal(config: config, startIndex: i)
			Thread.sleep(forTimeInterval: 2)
		}
	}

	// We will simulate creating the nodes in different order, so we can simulate the nodes coming up
	// in different order.
	func validateEnsemblerStateMachineInternal(
		config: EnsembleConfiguration,
		startIndex: Int = 0
	) throws {
		let timeOut = Double(config.nodes.count) * 20.0
		// Create an expectation
		let expectation = self.expectation(description: "Test should complete within \(timeOut)")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)
            
			print("wait for all nodes to either get into ready state or failed state")
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			print("check if all nodes are in ready state")
			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready)
			}

			if config.nodes.count > 1 {
				print(
					"validate the keys are distributed by encrypting on one node and decrypting on other node"
				)
				try self.validateEncryptionDecryption(
					config: config,
					startIndex: startIndex,
					ensemblers: ensemblers
				)
			}

			for i in 0 ..< config.nodes.count {
				ensemblers[i].stopServer()
			}
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: timeOut)
	}

	func validateDataKeyDistribution(
		config: EnsembleConfiguration
	) throws {
		let timeOut = Double(config.nodes.count) * 20.0
		// Create an expectation
		let expectation = self.expectation(description: "Test should complete within \(timeOut)")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: 0)

			print("wait for all nodes to either get into ready state or failed state")
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			print("check if all nodes are in ready state")
			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready)
			}

			if config.nodes.count > 1 {
				print(
					"validate the keys are distributed by encrypting on one node and decrypting on other node"
				)
				try self.validateEncryptionDecryption(
					config: config,
					startIndex: 0,
					ensemblers: ensemblers
				)
			}

			let key = SymmetricKey(size: .bits128)
			let distributedKeyData = key.withUnsafeBytes {
				return Data(Array($0))
			}

			let startTime = Date()
			let token = try ensemblers[0].distributeDataKey(key: distributedKeyData, type: .distributed)
			let endTime = Date() // Record the end time
			let timeInterval = endTime.timeIntervalSince(startTime) // Calculate time taken
			print("Time taken for distributeDataKey API call: \(timeInterval) seconds")

			for node in 1 ..< config.nodes.count {
				guard let obtainedKeyData = try ensemblers[node].getDataKey(token: token) else {
					XCTFail("Got nil key")
					return
				}
				print(
					"leader distributedKey for token:\(token) is \(distributedKeyData.map { String(format: "%02x", $0) }.joined()), obtained key for token in follower is : \(obtainedKeyData.map { String(format: "%02x", $0) }.joined())"
				)
				XCTAssert(distributedKeyData == obtainedKeyData)
			}

			for i in 0 ..< config.nodes.count {
				ensemblers[i].stopServer()
			}
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: timeOut)
	}

	// We will simulte creating the nodes in different order, so we can simulate the nodes coming up in
	// different order.
	func validateEnsemblerStateMachineInternalForKeyRotation(
		config: EnsembleConfiguration,
		expectedState: EnsemblerStatus = .ready,
		startIndex: Int = 0
	) throws {
		// Create an expectation
		let timeOut = 15.0 * Double(config.nodes.count)
		let expectation = self.expectation(description: "Test should complete within \(timeOut) seconds")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready)
			}

			let node1 = startIndex
			let node2 = (startIndex + 1) % config.nodes.count
			try self.validateEncryptionDecryption(
				config: config,
				startIndex: startIndex,
				ensemblers: ensemblers
			)
			var encryptedData = try ensemblers[node1].encryptData(data: "hello1".data(using: .utf8)!)
			// Now that we are ready and keys are distributed, lets trigger key rotation
			try ensemblers[0].rotateKey()

			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			// First wait and check if we are going to ready state
			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready, "We should be in ready state")
			}

			// Now we should be able to encrypt on one node and decrypt on another node

			let message = "hello2"
			// encrypt on one instance
			encryptedData = try ensemblers[node1].encryptData(data: message.data(using: .utf8)!)

			// decrypt on other instance
			let decryptData = try ensemblers[node2].decryptData(data: encryptedData)
			let decryptedMessage = String(data: decryptData, encoding: .utf8)
			XCTAssert(message == decryptedMessage)

			for i in 0 ..< config.nodes.count {
				ensemblers[i].stopServer()
			}
			expectation.fulfill()
		}

		wait(for: [expectation], timeout: timeOut)

		for i in 0 ..< config.nodes.count {
			XCTAssert(ensemblers[i].getStatus() == expectedState)
		}
	}

	func populateEnsemblers(config: EnsembleConfiguration, startIndex: Int) throws -> [EnsemblerTLS] {
		var ensemblers: [EnsemblerTLS] = []
		let udids = Array(config.nodes.keys).sorted()

		print("Creating ensemblers in order from \(startIndex) to \(config.nodes.count)")
		for i in startIndex ..< config.nodes.count {
			print("createing ensemblers[\(i)]")

			let ensembler = try EnsemblerTLS(
				ensembleConfig: config,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: udids[i],
				skipJobQuiescence: true,
				skipWaitingForDenali: true
			)
			ensemblers.append(ensembler)
			try ensembler.activate()
		}

		print("Creating ensemblers in order from 0 to \(startIndex)")
		for i in 0 ..< startIndex {
			print("createing ensemblers[\(i)]")
			let ensembler = try EnsemblerTLS(
				ensembleConfig: config,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: udids[i],
				skipJobQuiescence: true,
				skipWaitingForDenali: true
			)
			ensemblers.append(ensembler)
			try ensembler.activate()
		}

		return ensemblers
	}

	func getEmptyKey() throws -> SymmetricKey {
		let keyStr = String(repeating: "0", count: 32)
		guard let keyData = keyStr.data(using: .utf8) else {
			throw EnsembleError.internalError(error: "Cannot create empty keydata")
		}

		return SymmetricKey(data: keyData)
	}

	func validateEncryptionDecryption(
		config: EnsembleConfiguration,
		startIndex: Int,
		ensemblers: [EnsemblerTLS]
	) throws {
		let node1 = startIndex
		let node2 = (startIndex + 1) % config.nodes.count
		let message = "hello"
		// encrypt on one instance
		let encryptedData = try ensemblers[node1].encryptData(data: message.data(using: .utf8)!)

		// decrypt on other instance
		let decryptData = try ensemblers[node2].decryptData(data: encryptedData)
		let decryptedMessage = String(data: decryptData, encoding: .utf8)
		print("Original text: \(message) Decrypted text: \(decryptedMessage!)")
		XCTAssert(message == decryptedMessage)
	}

	func validateEnsemblerStateMachineWithFailure(
		config: EnsembleConfiguration,
		expectedState: EnsemblerStatus = .failed
	) throws {
		for i in 0 ..< config.nodes.count {
			try self.validateEnsemblerStateMachineWithFailuresInternal(
				config: config,
				expectedState: expectedState,
				startIndex: i
			)
		}
	}

	func validateEnsemblerStateMachineWithFailuresInternal(
		config: EnsembleConfiguration,
		expectedState: EnsemblerStatus = .failed,
		startIndex: Int = 0
	) throws {
		let timeOut = 3.0 * Double(config.nodes.count)
		// Create an expectation
		let expectation = self.expectation(description: "Test should complete within \(timeOut) seconds")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)

			expectation.fulfill()
		}

		wait(for: [expectation], timeout: timeOut)

		for i in 0 ..< config.nodes.count {
			ensemblers[i].stopServer()
		}

		for i in 0 ..< config.nodes.count {
			XCTAssert(ensemblers[i].getStatus() == expectedState)
		}
	}
}
