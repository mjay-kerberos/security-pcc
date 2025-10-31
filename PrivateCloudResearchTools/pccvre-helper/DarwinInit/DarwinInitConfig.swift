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

//  Copyright © 2024-2025 Apple, Inc. All rights reserved.
//

import Foundation

struct DarwinInitConfig {
    typealias JSONDict = [String: Any]

    struct Cryptex: Encodable, Equatable {
        let variant: String
        let url: String
        let mergeStrat: MergeStrat

        /// Cryptex merging strategy
        enum MergeStrat: String, Codable {
            /// pick all the values from the provided item
            case none = "NONE"
            /// drop the cryptex if found, ignores the provided URL
            case remove = "REMOVE"
        }
    }

    enum Keys {
        static let cryptex = "cryptex"

        static let ssh = "ssh"
        static let sshPWAuth = "ssh_pwauth"
        static let user = "user"
        static let gid = "gid"
        static let name = "name"
        static let ssh_authorized_key = "ssh_authorized_key"
        static let uid = "uid"
        static let config_security_policy = "config-security-policy"
        static let config_security_policy_version = "config-security-policy-version"
        static let local_host_name = "local-host-name"
        static let preferences = "preferences"
        static let secureConfig = "secure-config"

        enum CryptexKeys {
            static let variant = "variant"
            static let url = "url"
            static let mergeStrat = "MERGE_STRAT"
        }

        enum PreferencesKeys {
            static let application_id = "application_id"
            static let key = "key"
            static let value = "value"
        }
    }

    static let sshDisabledKeyPrefix = "SSH_DISABLED-"

    var dictionary: JSONDict
    
    init(dictionary: JSONDict) {
        self.dictionary = dictionary
    }

    init(json: String) throws {
        let data = (json == "" ? "{}" : json).data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw ParsingError("JSON is not a dictionary")
        }
        self.dictionary = dictionary
    }

    func json(pretty: Bool = false) throws -> String {
        let options: JSONSerialization.WritingOptions = pretty ?
        [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys, .prettyPrinted] :
        [.fragmentsAllowed, .withoutEscapingSlashes]

        let jsonData = try JSONSerialization.data(withJSONObject: dictionary as NSDictionary, options: options)
        return String(decoding: jsonData, as: UTF8.self)
    }

    /// replaces the cryptex
    mutating func appendOrReplaceCryptex(_ cryptex: Cryptex) throws {
        if dictionary[Keys.cryptex] == nil {
            dictionary[Keys.cryptex] = []
        }
        guard let cryptexes = dictionary[Keys.cryptex] as? [Any] else {
            throw ParsingError("'\(Keys.cryptex)' is not an array")
        }

        let newEntry = [
            Keys.CryptexKeys.variant: cryptex.variant,
            Keys.CryptexKeys.url: cryptex.url
        ]

        var replaced = false
        var newCryptexes: [Any] = try cryptexes.compactMap { existing in
            guard let existingDictionary = existing as? [String: Any] else {
                throw ParsingError("cryptex entry is not a dictionary")
            }
            guard let variant = existingDictionary[Keys.CryptexKeys.variant] as? String else {
                throw ParsingError("cryptex '\(Keys.CryptexKeys.variant)' is not a string")
            }
            if variant == cryptex.variant {
                replaced = true
                if cryptex.mergeStrat == .remove {
                    return nil
                } else {
                    return newEntry
                }
            } else {
                return existing
            }
        }
        
        if !replaced {
            newCryptexes.append(newEntry)
        }
        
        dictionary[Keys.cryptex] = newCryptexes
    }
    
    mutating func removeCryptex(variant: String) throws {
        try self.appendOrReplaceCryptex(.init(variant: variant, url: "", mergeStrat: .remove))
    }

    func listCryptexes() throws -> [Cryptex] {
        if dictionary[Keys.cryptex] == nil {
            return []
        }
        guard let cryptexes = dictionary[Keys.cryptex] as? [Any] else {
            throw ParsingError("'\(Keys.cryptex)' is not an array")
        }
        return try cryptexes.map { cryptex in
            guard let cryptexDictionary = cryptex as? [String: Any] else {
                throw ParsingError("cryptex entry is not a dictionary")
            }
            guard let variant = cryptexDictionary[Keys.CryptexKeys.variant] as? String else {
                throw ParsingError("cryptex '\(Keys.CryptexKeys.variant)' is not a string")
            }
            guard let url = cryptexDictionary[Keys.CryptexKeys.url] as? String else {
                throw ParsingError("cryptex '\(Keys.CryptexKeys.url)' is not a string")
            }
            let mergeStrat: Cryptex.MergeStrat = if let mergeStrat = cryptexDictionary[Keys.CryptexKeys.mergeStrat] as? String {
                if let mergeStrat = Cryptex.MergeStrat(rawValue: mergeStrat) {
                    mergeStrat
                } else {
                    throw ParsingError("cryptex '\(Keys.CryptexKeys.mergeStrat)' is not recognised: \(mergeStrat)")
                }
            } else {
                Cryptex.MergeStrat.none
            }
            return Cryptex(variant: variant, url: url, mergeStrat: mergeStrat)
        }
    }
    
    var localHostname: String? {
        get {
            dictionary[Keys.local_host_name] as? String
        }
        set {
            dictionary[Keys.local_host_name] = newValue
        }
    }

    mutating func enableSSH(publicKey: String) {
        dictionary[Keys.ssh] = true
        dictionary[Keys.user] = [
            Keys.gid: 0,
            Keys.name: "root",
            Keys.ssh_authorized_key: publicKey,
            Keys.uid: 0
        ]

        disable(key: Keys.config_security_policy, prefix: Self.sshDisabledKeyPrefix)
        disable(key: Keys.config_security_policy_version, prefix: Self.sshDisabledKeyPrefix)
    }

    func hasCryptex(variant: String) throws -> Bool {
        if dictionary[Keys.cryptex] == nil {
            return false
        }
        guard let cryptexes = dictionary[Keys.cryptex] as? [Any] else {
            throw ParsingError("'\(Keys.cryptex)' is not an array")
        }
        return try cryptexes.contains {
            guard let cryptexDictionary = $0 as? [String: Any] else {
                throw ParsingError("cryptex entry is not a dictionary")
            }
            guard let cryptexVariant = cryptexDictionary[Keys.CryptexKeys.variant] as? String else {
                throw ParsingError("cryptex '\(Keys.CryptexKeys.variant)' is not a string")
            }
            return cryptexVariant == variant
        }
    }

    mutating func disableSSH() {
        dictionary[Keys.ssh] = false
        dictionary[Keys.user] = nil

        enable(key: Keys.config_security_policy, prefix: Self.sshDisabledKeyPrefix)
        enable(key: Keys.config_security_policy_version, prefix: Self.sshDisabledKeyPrefix)
    }

    @discardableResult
    mutating func disable(key: String, prefix: String) -> Bool {
        guard let value = dictionary[key] else {
            return false
        }
        dictionary[prefix + key] = value
        dictionary[key] = nil
        return true
    }

    @discardableResult
    mutating func enable(key: String, prefix: String) -> Bool {
        guard
            let value = dictionary[prefix + key],
            dictionary[key] == nil
        else {
            return false
        }
        dictionary[key] = value
        dictionary[prefix + key] = nil
        return true
    }

    struct ParsingError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }

        init(_ message: String) {
            self.message = message
        }
    }
}

extension DarwinInitConfig {
    init(launcher: ProcessLauncher, instance: String) throws {
        let arguments = ["instance", "configure", "darwin-init", "dump", "--name", instance]
        let result = try launcher.exec(executablePath: CLI.pccvrePath, arguments: arguments)
        try self.init(json: result.stdout)
    }

    func save(launcher: ProcessLauncher, instance: String) throws {
        let tempFileURL = try FileManager.tempDirectory(
            subPath: CLI.applicationName, instance).appending(path: "darwin-init.json")

        CLI.debugPrint("Modified darwin-init: \(tempFileURL)")
        try self.json(pretty: true).write(to: tempFileURL, atomically: true, encoding: .utf8)

        let arguments = ["instance", "configure", "darwin-init", "set",
                         "--name", instance,
                         "--input", tempFileURL.path(percentEncoded: false)]
        let result = try launcher.exec(executablePath: CLI.pccvrePath, arguments: arguments)

        guard result.exitCode == 0 else {
            throw CLIError("Failed to save darwin-init configuration: \(result.stdout)")
        }
    }
}

extension DarwinInitConfig {
    struct EnsembleNode: Decodable {
        let udid: String
        let rank: UInt8
        let hostName: String
    }

    mutating func configureEnsemble(name: String, nodes: [EnsembleNode]) throws {
        var ensembleNodes: JSONDict = [:]
        for node in nodes {
            ensembleNodes[node.udid] = [
                "chassisID": "vre",
                "rank": node.rank,
                "hostName": node.hostName
            ]
        }

        try setPreference(applicationId: "com.apple.cloudos.AppleComputeEnsembler",
                          key: "EnsembleConfiguration",
                          value: [
                            "ensemble_id": name,
                            "nodes": ensembleNodes
                          ])
    }
}

// MARK: Handle preferences
extension DarwinInitConfig {
    struct Preference {
        var applicationId: String
        var key: String
        var value: Any
    }

    func listPreferences() throws -> [Preference] {
        if dictionary[Keys.preferences] == nil {
            return []
        }
        guard let preferences = dictionary[Keys.preferences] as? [Any] else {
            throw ParsingError("'\(Keys.preferences)' is not an array")
        }

        return preferences.compactMap {
            if let preference = $0 as? JSONDict,
               let applicationId = preference[Keys.PreferencesKeys.application_id] as? String,
               let key = preference[Keys.PreferencesKeys.key] as? String
            {
                let value = preference[Keys.PreferencesKeys.value] as Any
                return Preference(applicationId: applicationId, key: key, value: value)
            } else {
                return nil
            }
        }
    }

    mutating func setPreference(applicationId: String, key: String, value: Any) throws {
        let preferences = try self.listPreferences()

        var withoutSetPreference: [Preference] = preferences.filter { preference in
            return !(preference.applicationId == applicationId && preference.key == key)
        }

        withoutSetPreference.append(.init(
            applicationId: applicationId,
            key: key,
            value: value
        ))

        let jsonDictionaryPreferences: [JSONDict] = withoutSetPreference.map {
            return [
                Keys.PreferencesKeys.application_id: $0.applicationId,
                Keys.PreferencesKeys.key: $0.key,
                Keys.PreferencesKeys.value: $0.value
            ]
        }

        dictionary[Keys.preferences] = jsonDictionaryPreferences
    }
}

// MARK: Handle secureconfig
extension DarwinInitConfig {
    func listSecureConfig() throws -> [String: Any] {
        if dictionary[Keys.secureConfig] == nil {
            return [:]
        }
        guard let secureConfig = dictionary[Keys.secureConfig] as? [String: Any] else {
            throw ParsingError("'\(Keys.secureConfig)' is not a dictionary with String key")
        }
        return secureConfig
    }

    mutating func setSecureConfig(key: String, value: Any) throws {
        var secureConfig = try listSecureConfig()
        secureConfig[key] = value
        dictionary[Keys.secureConfig] = secureConfig
    }
}

extension DarwinInitConfig {
    /// Merges provided configuration onto the current one, overriding any conflicting values such as cryptexes, preferences, secureconfig values
    mutating func overridingMerge(with overrideInit: DarwinInitConfig) throws {
        let supportedKeys = [
            Keys.cryptex,
            Keys.local_host_name,
            Keys.preferences,
            Keys.secureConfig,
            Keys.ssh,
            Keys.sshPWAuth,
            Keys.user,
        ]
        for key in overrideInit.dictionary.keys {
            if !supportedKeys.contains(key) {
                throw ParsingError("Unable to merge key \(key) - supported keys are: \(supportedKeys)")
            }
        }

        // cryptexes
        for cryptex in try overrideInit.listCryptexes() {
            try self.appendOrReplaceCryptex(cryptex)
        }

        if let localHostnameOverride = overrideInit.localHostname {
            self.localHostname = localHostnameOverride
        }

        // preferences
        for preference in try overrideInit.listPreferences() {
            try self.setPreference(
                applicationId: preference.applicationId,
                key: preference.key,
                value: preference.value
            )
        }

        // secureConfig
        for secureConfigValue in try overrideInit.listSecureConfig() {
            try setSecureConfig(key: secureConfigValue.key, value: secureConfigValue.value)
        }

        // ssh and user configs
        if let overrideSsh = overrideInit.dictionary[Keys.ssh] {
            dictionary[Keys.ssh] = overrideSsh
        }

        if let overrideSshPWAuth = overrideInit.dictionary[Keys.sshPWAuth] {
            dictionary[Keys.sshPWAuth] = overrideSshPWAuth
        }

        if let overrideUser = overrideInit.dictionary[Keys.user] {
            dictionary[Keys.user] = overrideUser
        }
    }
}
