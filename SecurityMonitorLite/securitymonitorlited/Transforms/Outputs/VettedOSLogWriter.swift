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
//  SMLEvent.swift
//  SecurityMonitorLite
//

import os

final class VettedOSLogWriter: SMLTransform {
    enum Tags: String, CaseIterable {
        case log_vetted
    }
    func process(_ event: any SMLUEFEvent) -> (SMLTransformResult, (any SMLUEFEvent)?) {
        if let event = event as? ESClient.ESClientProcExecEvent {
            ProcessExecEvent.export(event)
        } else if let event = event as? ESClient.ESClientProcExitEvent {
            ProcessExitEvent.export(event)
        } else if let event = event as? ESClient.ESClientIOKitOpenEvent {
            IOKitOpenEvent.export(event)
        } else if let event = event as? ESClient.ESClientSSHLoginEvent {
            SSHLoginEvent.export(event)
        } else if let event = event as? ESClient.ESClientSSHLogoutEvent {
            SSHLogoutEvent.export(event)
        } else if let event = event as? NStatClient.NStatClientNWEvent {
            NWOpenEvent.export(event)
        } else if let event = event as? SandboxViolation.Event {
            SandboxViolationEvent.export(event)
        } else if let event = event as? RestrictedExecutionModeViolation.Event {
            RestrictedExecutionModeViolationEvent.export(event)
        } else if let event = event as? MDNSResponderQueries.Event {
            MDNSResponderQueriesEvent.export(event)
        }

        return (.proceed, nil)
    }

    func configure() throws { }

    protocol SMLEvent {
        static var formatString: String { get }
        static var eventName: String { get }
    }

    struct ProcessExitEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %f, pid: %u, executable: %{public}s, exit_status: %d"
        static let eventName: String = "ProcessExit"

        static func export(_ event: ESClient.ESClientProcExitEvent) {
            // Log event data to os_log where it can be picked up by splunkloggingd
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp), \
            pid: \(event.pid), \
            executable: \(event.executable, privacy: .public), \
            exit_status: \(event.exitStatus)
            """
            )
        }
    }

    struct ProcessExecEvent: SMLEvent {
        static let formatString = "%{public}s: start_time: %f, cwd: %{public}s, args: %{public}s, executable: %{public}s, signing_id: %{public}s, platform_binary: %{public}s, tty: %{public}s, script: %{public}s, pid: %u, euid: %u, egid: %u, codesigning_flags: %u, ppid: %d, parent_executable: %{public}s, parent_signing_id: %{public}s, parent_platform_binary: %{public}s"
        static let eventName: String = "ProcessExec"

        static func export(_ event: ESClient.ESClientProcExecEvent) {
            // Log event data to os_log where it can be picked up by splunkloggingd
            SMLDaemon.eventLog.log("""
        \(self.eventName, privacy: .public): \
        start_time: \(event.startTime), \
        cwd: \(event.cwd, privacy: .public), \
        args: \(event.args.prefix(512), privacy: .public), \
        executable: \(event.executable, privacy: .public), \
        signing_id: \(event.signingID, privacy: .public), \
        platform_binary: \(event.platformBinary ? "true" : "false", privacy: .public), \
        tty: \(event.tty, privacy: .public), \
        script: \(event.script, privacy: .public), \
        pid: \(event.pid), \
        euid: \(event.euid), \
        egid: \(event.egid), \
        codesigning_flags: \(event.codesigningFlags), \
        ppid: \(event.ppid), \
        parent_executable: \(event.parentExecutable, privacy: .public), \
        parent_signing_id: \(event.parentSigningID, privacy: .public), \
        parent_platform_binary: \(event.parentPlatformBinary ? "true" : "false", privacy: .public)
        """
            )
        }
    }

    struct IOKitOpenEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %f, pid: %u, executable: %{public}s, user_client_class: %{public}s, user_client_type: %u"
        static let eventName: String = "IOKitOpen"

        static func export(_ event: ESClient.ESClientIOKitOpenEvent) {
            // Log event data to os_log where it can be picked up by splunkloggingd
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp), \
            pid: \(event.pid), \
            executable: \(event.executable, privacy: .public), \
            user_client_class: \(event.userClientClass, privacy: .public), \
            user_client_type: \(event.userClientType)
            """
            )
        }
    }

    struct NWOpenEvent: SMLEvent {
        static let formatString = "%{public}s: start_time: %f, remote_addr: %{public}s, remote_port: %hu, local_port: %hu, epid: %d, proc_name: %{public}s, uid: %u"
        static let eventName: String = "NWOpen"

        static func export(_ event: NStatClient.NStatClientNWEvent) {
            // Log event data to os_log where it can be picked up by splunkloggingd
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            start_time: \(event.startTime), \
            remote_addr: \(event.remoteAddr, privacy: .public), \
            remote_port: \(event.remotePort), \
            local_port: \(event.localPort), \
            epid: \(event.epid), \
            proc_name: \(event.procName, privacy: .public), \
            uid: \(event.uid)
            """
            )
        }
    }

    struct SSHLogoutEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %f, src_addr: %{public}s, username: %{public}s, uid: %u"
        static let eventName: String = "SSHLogout"

        static func export(_ event: ESClient.ESClientSSHLogoutEvent) {
            // Log event data to os_log where it can be picked up by splunkloggingd
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp), \
            src_addr: \(event.srcAddr, privacy: .public), \
            username: \(event.username, privacy: .public), \
            uid: \(event.uid)
            """
            )
        }
    }

    struct SSHLoginEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %f, src_addr: %{public}s, username: %{public}s, success: %{public}s, uid: %{public}s"
        static let eventName: String = "SSHLogin"

        static func export(_ event: ESClient.ESClientSSHLoginEvent) {
            // Log event data to os_log where it can be picked up by splunkloggingd
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp), \
            src_addr: \(event.srcAddr, privacy: .public), \
            username: \(event.username, privacy: .public), \
            success: \(event.success, privacy: .public), \
            uid: \(event.uid, privacy: .public)
            """
            )
        }
    }

    struct SandboxViolationEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %{public}f, process: %{public}s, pid: %{public}ld, action: %{public}s, rule: %{public}s, dupes: %{public}ld, path: %{public}s"
        static let eventName: String = SandboxViolation.Event().subtype

        static func export(_ event: SandboxViolation.Event) {
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp.timeIntervalSince1970, privacy: .public), \
            process: \(event.process, privacy: .public), \
            pid: \(event.processID, privacy: .public), \
            action: \(event.action, privacy: .public), \
            rule: \(event.rule, privacy: .public), \
            dupes: \(event.duplicates, privacy: .public), \
            path: \(event.path, privacy: .public)
            """
            )
        }
    }

    struct RestrictedExecutionModeViolationEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %{public}f, binary: %{public}s, identity: %{public}s, remstate: %{public}s, reason: %{public}s"
        static let eventName: String = RestrictedExecutionModeViolation.Event().subtype

        static func export(_ event: RestrictedExecutionModeViolation.Event) {
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp.timeIntervalSince1970, privacy: .public), \
            binary: \(event.binary, privacy: .public), \
            identity: \(event.identity, privacy: .public), \
            remstate: \(event.remstate, privacy: .public), \
            reason: \(event.reason, privacy: .public)
            """
            )
        }
    }

    struct MDNSResponderQueriesEvent: SMLEvent {
        static let formatString = "%{public}s: timestamp: %{public}f, type: %{public}s, id: %{public}s, process: %{public}s, pid: %{public}ld, qname: %{public}s, subqname: %{public}s, qtype: %{public}s, flags: %{public}s, if: %{public}ld, namehash: %{public}s, rdata: %{public}s, se: %{public}f, sse: %{public}f"
        static let eventName: String = MDNSResponderQueries.Event().subtype

        static func export(_ event: MDNSResponderQueries.Event) {
            SMLDaemon.eventLog.log("""
            \(self.eventName, privacy: .public): \
            timestamp: \(event.timestamp.timeIntervalSince1970, privacy: .public), \
            type: \(event.rowtype, privacy: .public), \
            id: \(event.queryID, privacy: .public), \
            process: \(event.process, privacy: .public), \
            pid: \(event.processID, privacy: .public), \
            qname: \(event.qname, privacy: .public), \
            subqname: \(event.subqname, privacy: .public), \
            qtype: \(event.qtype, privacy: .public), \
            flags: \(event.flags, privacy: .public), \
            if: \(event.interfaceIndex, privacy: .public), \
            namehash: \(event.namehash, privacy: .public), \
            rdata: \(event.rdata, privacy: .public), \
            se: \((event.qnameSE), privacy: .public), \
            sse: \((event.subqnameSE), privacy: .public)
            """
            )
        }
    }
}
