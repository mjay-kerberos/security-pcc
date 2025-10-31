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
//  AsyncEvent.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import Synchronization

final class AsyncEvent<Element: Sendable>: Sendable {

    private typealias Continuation = CancellableContinuation<Element>

    // Our state is exactly one of: continuations that are waiting
    // on a result to be given, or the result that has been given.
    // Once we have a result we're done accumulating continuations.
    private enum EventState {
        // A collection of all the continuations waiting, while no
        // fire has yet occurred.
        case waiting([Continuation])

        // The result of the fire that occurred.
        case completed(Result<Element, any Error>)

        init() {
            self = .waiting([])
        }

        // Add a new continuation; only legal when waiting
        mutating func wait(with continuation: Continuation) {
            switch self {
            case .waiting(var continuations):
                continuations.append(continuation)
                self = .waiting(continuations)  // .waiting <- .waiting
            case .completed:
                preconditionFailure()
            }
        }

        // Transition to complete, with a result, and resuming
        // any existing continuations. Legal at any time, but
        // idempotent. Returns whether or not the transition took
        // place.
        mutating func complete(_ result: Result<Element, any Error>) -> Bool {
            switch self {
            case .waiting(let continuations):
                for continuation in continuations {
                    continuation.resume(with: result)
                }
                self = .completed(result)  // .completed <- .waiting
                return true
            case .completed:
                return false
            }
        }
    }

    private let eventState = Mutex<EventState>(.init())

    @discardableResult
    func fire(_ value: Element) -> Bool {
        self.eventState.withLock {
            return $0.complete(.success(value))
        }
    }

    @discardableResult
    func fire(throwing error: any Error) -> Bool {
        self.eventState.withLock {
            return $0.complete(.failure(error))
        }
    }

    // This is the state per call to receive(), and is concerned with the
    // coordination between the code on the happy path, i.e. actually giving
    // a value or suspending the task in wait for one, vs the code on the
    // cancellation. Each receive() has its own state to track separately.
    private enum ReceiveState {
        case initialized
        case deferred(Continuation)
        case ran
        case cancelled

        init() {
            self = .initialized
        }

        // In the context of the eventState, and with a continuation, perform
        // the main work of receive, which is to say:
        //  1. If the eventState is waiting, defer the continuation into it
        //  2. If the eventState is completed, immediately run the continuation
        //  3. If the receive is already cancelled, opt out of the event
        mutating func runOrDefer(eventState: inout EventState, continuation: Continuation) {
            switch (eventState, self) {
            case (.waiting, .initialized):
                // No result yet, and there's been no cancel
                eventState.wait(with: continuation)
                self = .deferred(continuation)  // .deferred <- .initialized
            case (.completed(let result), .initialized):
                // We have a result, and no cancel
                continuation.resume(with: result)
                self = .ran  // .ran <- .initialized
            case (_, .deferred):
                assertionFailure()
            case (_, .ran):
                assertionFailure()
            case (.waiting, .cancelled):
                // Cancel already ran; just fail
                continuation.cancel()
            case (.completed(let result), .cancelled):
                // Cancel already ran, but hey we have a result
                continuation.resume(with: result)
                self = .ran  // .ran <- .cancelled
            }
        }

        // Cancel this receive. This might be called while in any state, and
        // so deals with a situation where the main work of receive may or
        // may not have happened yet. If the main work of receive did happen
        // and it deferred, it may be necessary to undo the deferral.
        mutating func cancel(eventState: inout EventState) {
            switch (eventState, self) {
            case (_, .initialized):
                // Have not yet run, this is the pre-emptive cancel
                self = .cancelled  // .cancelled <- .initialized
            case (.waiting, .deferred(let continuation)):
                // We ran to a defer but no result has been fired
                continuation.cancel()
                self = .cancelled  // .cancelled <- .deferred
            case (.completed, .deferred):
                // We ran to a defer and the event since completed
                break
            case (_, .ran):
                // Already ran, nothing to do
                break
            case (_, .cancelled):
                break
            }
        }
    }

    private func receive() async throws -> Element {
        let receiveState = Mutex<ReceiveState>(.init())
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation {
                let continuation = Continuation($0)
                self.eventState.withLock { eventState in
                    receiveState.withLock {
                        $0.runOrDefer(eventState: &eventState, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            self.eventState.withLock { eventState in
                receiveState.withLock {
                    $0.cancel(eventState: &eventState)
                }
            }
        }
    }

    func callAsFunction() async throws -> Element {
        try await self.receive()
    }
}

extension AsyncEvent where Element == Void {
    func fire() {
        self.fire(())
    }
}
