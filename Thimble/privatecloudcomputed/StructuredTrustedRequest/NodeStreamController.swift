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
//  NodeStreamController.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import PrivateCloudCompute
import Synchronization

// The node stream controller is responsible for the situation where a number of
// streams are managed by registering them by their ID and suspending their tasks,
// until one stream indicates it has been selected.
//
// Upon selection, every remaining (and future) stream resumes by throwing
// `CancellationError`. The selected stream remains suspended until its Task
// is cancelled, at which point it resumes (without throwing).
//
// To that last point, the cancellation of a task that is suspended via register
// results in one of the following.
//  a) as we've seen, if the register was for the stream that was selected, then
//     the task resumes without throwing.
//  b) if no stream has been selected, then the task resumes without throwing and
//     is forgotten
//  c) the situation where a stream has been selected but the cancel was for a
//     different stream is impossible, since the selection will have resumed the
//     the other streams by throwing `CancellationError` first.
final class NodeStreamController: Sendable {
    private struct StateMachine {
        enum State {
            case waitingForNodeReceivedData([String: CheckedContinuation<Void, any Error>])
            case nodeReceivedData(winnerNodeID: String, continuation: CheckedContinuation<Void, any Error>?)
            case nodeStreamFinished
        }

        var isEmpty: Bool {
            switch self.state {
            case .waitingForNodeReceivedData(let dict):
                return dict.isEmpty
            case .nodeReceivedData(_, let continuation):
                return continuation == nil
            case .nodeStreamFinished:
                return true
            }
        }

        private var state: State = .waitingForNodeReceivedData([:])

        mutating func registerNodeStream(nodeID: String, continuation: CheckedContinuation<Void, any Error>) -> CheckedContinuation<Void, any Error>? {
            if Task.isCancelled {
                return continuation
            }

            switch self.state {
            case .waitingForNodeReceivedData(var nodes):
                precondition(nodes[nodeID] == nil)
                nodes[nodeID] = continuation
                self.state = .waitingForNodeReceivedData(nodes)
                return nil

            case .nodeReceivedData(let winnerNodeID, continuation: let maybeContinuation):
                // The registration and selection of a node are in a race, so sometimes
                // we may see selection prior to registration, which is this case.
                if winnerNodeID == nodeID {
                    precondition(maybeContinuation == nil)
                    self.state = .nodeReceivedData(winnerNodeID: winnerNodeID, continuation: continuation)
                    return nil
                } else {
                    return continuation
                }

            case .nodeStreamFinished:
                return continuation
            }
        }

        mutating func cancelRegister(nodeID: String) -> CheckedContinuation<Void, any Error>? {
            switch self.state {
            case .nodeReceivedData(let winnerNodeID, continuation: let maybeContinuation):
                if winnerNodeID == nodeID {
                    self.state = .nodeStreamFinished
                    return maybeContinuation
                } else {
                    return nil
                }

            case .waitingForNodeReceivedData(var nodes):
                if let continuation = nodes.removeValue(forKey: nodeID) {
                    self.state = .waitingForNodeReceivedData(nodes)
                    return continuation
                } else {
                    return nil
                }

            case .nodeStreamFinished:
                return nil
            }
        }

        mutating func nodeReceivedData(nodeID: String) -> some Collection<CheckedContinuation<Void, any Error>> & Sendable {
            switch self.state {
            case .nodeReceivedData, .nodeStreamFinished:
                preconditionFailure("Invalid state: \(self.state)")

            case .waitingForNodeReceivedData(var nodes):
                // Here, if we have a registration we use it; if we don't then we remember
                // the winner in hopes that its registration will come later.
                let winnerContinuation = nodes.removeValue(forKey: nodeID)
                self.state = .nodeReceivedData(winnerNodeID: nodeID, continuation: winnerContinuation)
                return nodes.values
            }
        }
    }

    private let stateLock = Mutex(StateMachine())

    init() {}

    deinit {
        precondition(self.stateLock.withLock { $0.isEmpty }, "All continuations must have been released beforehand")
    }

    /// This registers a stream with a nodeID. It suspends until one of the following occurs
    /// 1. If canceled, it resumes without throwing
    /// 2. If another stream is selected via `dataReceived`, if resumes by throwing
    ///    `CancellationError`.
    /// 3. If its stream is selected, it remains indefinitely suspended; to be used correctly,
    ///     it is meant to then be canceled to trigger condition 1.
    ///
    /// - Parameter nodeID: The nodeID to which a stream is established
    /// - Throws: This function throws, if another node was faster in establishing a stream.
    ///           It does not throw it its underlying task is cancelled.
    func registerNodeStream(nodeID: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let maybeContinuation = self.stateLock.withLock {
                    $0.registerNodeStream(nodeID: nodeID, continuation: continuation)
                }

                maybeContinuation?.resume(throwing: CancellationError())
            }
        } onCancel: {
            let maybeContinuation = self.stateLock.withLock {
                $0.cancelRegister(nodeID: nodeID)
            }

            maybeContinuation?.resume()
        }
    }

    /// The node substream that receives data must call this method in order to cancel all other
    /// node substreams that wait for data. It is an error to call this method more than once on
    /// a given controller.
    ///
    /// - Parameter nodeID: The node's id, which is sending data
    func dataReceived(nodeID: String) {
        let otherContinuations = self.stateLock.withLock {
            $0.nodeReceivedData(nodeID: nodeID)
        }

        for continuation in otherContinuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}
