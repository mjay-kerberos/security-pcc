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
//  RuleTagger.swift
//  SecurityMonitorLite
//
final class RuleTagger: SMLTransform {
    enum Operation: String, CaseIterable {
        case equals
        case not_equal
        case regex
        case included_in
        case not_included_in
        case no_field
    }
    enum ConstraintCriteria {
        case all
        case none
        case any
    }

    public init(_ rules: [Rule]) {
        self.rules = rules
        // dedup all constraints so we can evaluate all rules at the same time
        self.allConstraints = Array(Set(rules.flatMap { $0.constraints.compactMap { $0 as? Constraint } }))
    }

    final class Constraint: ConstraintDefinition {
        let stringValue: String
        let intValue: Int?
        let doubleValue: Double?
        let boolValue: Bool?

        init(operation: Operation, field: String, value: any Hashable & Sendable) {
            self.operation = operation
            self.field = field
            self.value = value
            self.stringValue = {
                if let stringValue = value as? String {
                    return stringValue
                }
                return String(describing: value)
            }()
            self.intValue = {
                if let intValue = value as? Int {
                    return intValue
                }
                return Int(String(describing: value))
            }()
            self.doubleValue = {
                if let doubleValue = value as? Double {
                    return doubleValue
                }
                return Double(String(describing: value))
            }()
            self.boolValue = {
                if let boolValue = value as? Bool {
                    return boolValue
                }
                return Bool(String(describing: value))
            }()

        }

        static func == (lhs: RuleTagger.Constraint, rhs: RuleTagger.Constraint) -> Bool {
            lhs.hashValue == rhs.hashValue
        }

        let operation: Operation
        let field: String
        let value: any Sendable & Hashable

        func hash(into hasher: inout Hasher) {
            hasher.combine(operation.rawValue)
            hasher.combine(field)
            hasher.combine(value)
        }
    }
    protocol ConstraintDefinition: Sendable, Hashable {
        var value: any Hashable & Sendable { get }
        var stringValue: String { get }
        var intValue: Int? { get }
        var doubleValue: Double? { get }
        var boolValue: Bool? { get }
        var operation: Operation { get }
        var field: String { get }
    }

    struct Rule {
        let constraints: [any ConstraintDefinition]
        let criteria: ConstraintCriteria
        let name: String
        let tags: Set<String>
    }

    let rules: [Rule]
    let allConstraints: [Constraint]

    func process(_ event: any SMLUEFEvent) async -> (SMLTransformResult, (any SMLUEFEvent)?) {
        let evaluationResult: [Int: Bool] = Dictionary(uniqueKeysWithValues: await self.allConstraints.compactMapInTasks { constraint in
            let mirror = Mirror(reflecting: event)
            var eval = false
            var destFieldVal: Any?
            if constraint.field == "archetype" {
                destFieldVal = event.archetype.rawValue
            } else if let val = event.fields[constraint.field] {
                destFieldVal = val
            } else if let val = mirror.children.first(where: { constraint.field == $0.label }) {
                destFieldVal = val.value
            }

            if let destFieldVal {
                switch constraint.operation {
                case .equals:
                    if let typedVal = destFieldVal as? String, typedVal == constraint.stringValue {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let compTypedVal = constraint.intValue, typedVal == compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let compTypedVal = constraint.doubleValue, typedVal == compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let compTypedVal = constraint.boolValue, typedVal == compTypedVal {
                        eval = true
                    } else {
                        // unknown type in message field
                    }
                case .not_equal:
                    if let typedVal = destFieldVal as? String, typedVal != constraint.stringValue {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let compTypedVal = constraint.intValue, typedVal != compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let compTypedVal = constraint.doubleValue, typedVal != compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let compTypedVal = constraint.boolValue, typedVal != compTypedVal {
                        eval = true
                    } else {
                        // unknown type in message field
                    }
                case .regex:
                    if let test = try? Regex(constraint.stringValue) {
                        if let typedVal = destFieldVal as? String, (try? test.firstMatch(in: typedVal) != nil) != nil {
                            eval = true
                        }
                    }
                case .included_in:
                    if let typedVal = destFieldVal as? String, let needles = constraint.value as? [String], needles.contains(typedVal) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let needles = constraint.value as? [Int], needles.contains(typedVal) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let needles = constraint.value as? [Double], needles.contains(typedVal) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let needles = constraint.value as? [Bool], needles.contains(typedVal) {
                        eval = true
                    } else {
                        // unknown type
                    }
                case .not_included_in:
                    if let typedVal = destFieldVal as? String, let needles = constraint.value as? [String], !needles.contains(typedVal) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let needles = constraint.value as? [Int], !needles.contains(typedVal) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let needles = constraint.value as? [Double], !needles.contains(typedVal) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let needles = constraint.value as? [Bool], !needles.contains(typedVal) {
                        eval = true
                    } else {
                        // unknown type
                    }
                case .no_field:
                    eval = false
                }
            } else {
                // target field not found in destination
                if constraint.operation == .no_field {
                    eval = true
                }
            }
            return (constraint.hashValue, eval)
        })

        var curEvent = event
        var mutated = false
        for rule in rules {
            let evaluations = rule.constraints.map { constraint in
                let cid = constraint.hashValue
                if let prevEval = evaluationResult[cid] {
                    return prevEval
                }
                // should never get here!
                SMLDaemon.daemonLog.error("Error unexpected evaluation result for constraint \(cid, privacy: .public)")
                return false
            }

            var ruleHit = false
            switch rule.criteria {
            case .all:
                if evaluations.contains(true) && !evaluations.contains(false) {
                    ruleHit = true
                }
            case .any:
                if evaluations.contains(true) {
                    ruleHit = true
                }
            case .none:
                if evaluations.contains(false) && !evaluations.contains(true) {
                    ruleHit = true
                }
            }
            if ruleHit {
                // tag alert, mutates it
                curEvent.tags.formUnion(rule.tags)
                mutated = true
            }
        }

        return (mutated ? .proceed_mutated : .proceed, curEvent)
    }

    func configure() throws {
    }
}
