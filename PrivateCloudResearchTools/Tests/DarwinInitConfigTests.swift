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
import Testing

struct DarwinInitConfigTests {
    @Test
    func testAddCryptexCreatesCryptexArray() throws {
        var config = DarwinInitConfig(dictionary: [:])
        
        try config.appendOrReplaceCryptex(.init(variant: "foo", url: "bar", mergeStrat: .none))

        #expect(configEquals(config, [
            "cryptex": [
                [
                    "variant": "foo",
                    "url": "bar"
                ]
            ]
        ]))
    }
    
    @Test
    func testReplaceCryptexPreservesOrder() throws {
        var config = DarwinInitConfig(dictionary: [
            "cryptex": [
                [
                    "variant": "a",
                    "url": "a"
                ],
                [
                    "variant": "b",
                    "url": "b"
                ]
            ]
        ])
        
        try config.appendOrReplaceCryptex(.init(variant: "a", url: "c", mergeStrat: .none))

        #expect(configEquals(config, [
            "cryptex": [
                [
                    "variant": "a",
                    "url": "c"
                ],
                [
                    "variant": "b",
                    "url": "b"
                ]
            ]
        ]))
    }
    
    @Test
    func testCryptexIsRemoved() throws {
        var config = DarwinInitConfig(dictionary: [
            "cryptex": [
                [
                    "variant": "a",
                    "url": "a"
                ],
                [
                    "variant": "b",
                    "url": "b"
                ]
            ]
        ])
        
        try config.removeCryptex(variant: "a")

        #expect(configEquals(config, [
            "cryptex": [
                [
                    "variant": "b",
                    "url": "b"
                ]
            ]
        ]))
    }

    @Test
    func testCryptexIsRemovedMergeStrategy() throws {
        var config = DarwinInitConfig(dictionary: [
            "cryptex": [
                [
                    "variant": "a",
                    "url": "a"
                ],
                [
                    "variant": "b",
                    "url": "b"
                ]
            ]
        ])

        try config.appendOrReplaceCryptex(.init(variant: "a", url: "", mergeStrat: .remove))

        #expect(configEquals(config, [
            "cryptex": [
                [
                    "variant": "b",
                    "url": "b"
                ]
            ]
        ]))
    }

    @Test
    func testHasCryptexIsCorrectWhenCryptexExists() throws {
        let config = DarwinInitConfig(dictionary: [
            "cryptex": [
                [
                    "variant": "a",
                    "url": "a"
                ]
            ]
        ])
        
        #expect(try config.hasCryptex(variant: "a"))
    }

    @Test
    func testJSONParsingSucceeds() throws {
        let config = try DarwinInitConfig(json: #"{"foo":["bar", "baz"]}"#)

        #expect(configEquals(config, [ "foo": ["bar", "baz"]]))
    }

    @Test
    func testJSONDeserializationSucceeds() throws {
        let config = try DarwinInitConfig(json: #"{"foo":["bar", "baz"]}"#)

        #expect(configEquals(config, [ "foo": ["bar", "baz"]]))
    }

    @Test
    func testJSONSerializationSucceeds() throws {
        let config = DarwinInitConfig(dictionary: [ "foo": ["bar", "baz"]])

        #expect(try config.json() == #"{"foo":["bar","baz"]}"#)
    }

    @Test
    func testEnableSSHCreatesCorrectConfig() throws {
        var config = DarwinInitConfig(dictionary: [:])

        config.enableSSH(publicKey: "foo")

        #expect(configEquals(config, [
            "ssh": true,
            "user": [
                "gid": 0,
                "name": "root",
                "ssh_authorized_key": "foo",
                "uid": 0
            ]
        ]))
    }

    @Test
    func testEnableSSHDisablesConfigSecurityPolicy() throws {
        var config = DarwinInitConfig(dictionary: [
            "config-security-policy": "customer",
            "config-security-policy-version": 1
        ])

        config.enableSSH(publicKey: "foo")

        #expect(configEquals(config, [
            "SSH_DISABLED-config-security-policy": "customer",
            "SSH_DISABLED-config-security-policy-version": 1,
            "ssh": true,
            "user": [
                "gid": 0,
                "name": "root",
                "ssh_authorized_key": "foo",
                "uid": 0
            ]
        ]))
    }

    @Test
    func testDisableSSHReenablesConfigSecurityPolicy() throws {
        var config = DarwinInitConfig(dictionary: [
            "SSH_DISABLED-config-security-policy": "customer",
            "SSH_DISABLED-config-security-policy-version": 1,
            "ssh": true,
            "user": [
                "gid": 0,
                "name": "root",
                "ssh_authorized_key": "foo",
                "uid": 0
            ]
        ])

        config.disableSSH()

        #expect(configEquals(config, [
            "config-security-policy": "customer",
            "config-security-policy-version": 1,
            "ssh": false
        ]))
    }

    @Test
    func listCryptexesParsesConfig() throws {
        let config = DarwinInitConfig(dictionary: [
            "cryptex": [
                [
                    "variant": "foo",
                    "url": "foo.aar"
                ],
                [
                    "variant": "bar",
                    "url": "bar.aar"
                ]
            ]
        ])

        let cryptexes = try config.listCryptexes()

        #expect(cryptexes == [
            .init(variant: "foo", url: "foo.aar", mergeStrat: .none),
            .init(variant: "bar", url: "bar.aar", mergeStrat: .none)
        ])
    }

    @Test
    func configureEnsembleSetsCorrectPreference() throws {
        var config = try DarwinInitConfig(json: "")

        try config.configureEnsemble(name: "foo", nodes: [
            .init(udid: "a", rank: 0, hostName: "a.local"),
            .init(udid: "b", rank: 1, hostName: "b.local")
        ])

        #expect(configEquals(config, [
            "preferences": [
                [
                    "application_id": "com.apple.cloudos.AppleComputeEnsembler",
                    "key": "EnsembleConfiguration",
                    "value": [
                        "ensemble_id": "foo",
                        "nodes": [
                            "a": [
                                "chassisID": "vre",
                                "rank": 0,
                                "hostName": "a.local"
                            ],
                            "b": [
                                "chassisID": "vre",
                                "rank": 1,
                                "hostName": "b.local"
                            ]
                        ]
                    ]
                ]
            ]
        ]))
    }

    @Test
    func ensembleNodeArgumentCanBeParsed() throws {
        // The JSON format is used for CLI arguments and must be stable
        let argument = #"{"udid": "a", "rank": 0, "hostName": "a.local"}"#
        
        let node = try JSONDecoder().decode(DarwinInitConfig.EnsembleNode.self,
                                            from: argument.data(using: .utf8)!)

        #expect(node.udid == "a")
        #expect(node.rank == 0)
        #expect(node.hostName == "a.local")
    }

    func configEquals<K, V>(_ config: DarwinInitConfig, _ dictionary: [K: V]) -> Bool {
        config.dictionary as NSDictionary == dictionary as NSDictionary
    }

    @Test func setPreferenceAppends() async throws {
        var config = try DarwinInitConfig(json: "")
        try config.setPreference(applicationId: "com.apple.cloudos.app_id", key: "preferenceKey", value: "configValue")
        try config.setPreference(applicationId: "com.apple.cloudos.app_id", key: "preferenceKey2", value: "configValue2")

        #expect(configEquals(config, [
            "preferences": [
                [
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "preferenceKey",
                    "value": "configValue"
                ],
                [
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "preferenceKey2",
                    "value": "configValue2"
                ]
            ]
        ]))
    }

    @Test func setPreferenceOverridesOnMatch() async throws {
        var config = try DarwinInitConfig(json: "")
        try config.setPreference(applicationId: "com.apple.cloudos.app_id", key: "preferenceKey", value: "configValue")
        try config.setPreference(applicationId: "com.apple.cloudos.app_id", key: "preferenceKey", value: 1)

        #expect(configEquals(config, [
            "preferences": [
                [
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "preferenceKey",
                    "value": 1
                ]
            ]
        ]))
    }

    @Test func listPreferencesIncludesAddedPrefs() async throws {
        var config = try DarwinInitConfig(json: "")
        try config.setPreference(applicationId: "com.apple.cloudos.app_id", key: "preferenceKey", value: "configValue")
        try config.setPreference(applicationId: "com.apple.cloudos.app_id", key: "preferenceKey2", value: "configValue2")

        let listPreferences = try config.listPreferences()
        #expect(listPreferences[0].applicationId == "com.apple.cloudos.app_id")
        #expect(listPreferences[0].key == "preferenceKey")
        #expect(listPreferences[0].value as? String == "configValue")

        #expect(listPreferences.count == 2)
        #expect(listPreferences[1].applicationId == "com.apple.cloudos.app_id")
        #expect(listPreferences[1].key == "preferenceKey2")
        #expect(listPreferences[1].value as? String == "configValue2")
    }

    @Test func listPreferencesIgnoresInvalidValues() async throws {
        // missing key, missing application_id
        let config = try DarwinInitConfig(json: """
        {
            "preferences": [
                {
                    "aplication_id": "com.apple.cloudos.app_id",
                    "value": "val"
                },
                {
                    "key": "key1",
                    "value": "val"
                }
            ]
        }
        """)

        let listPreferences = try config.listPreferences()
        #expect(listPreferences.count == 0)
    }

    @Test func setSecureConfig() async throws {
        var config = try DarwinInitConfig(json: """
        {
            "secure-config": {
                "com.apple.bundle1.key1": "value",
                "com.apple.bundle1.key2": false,
                "com.apple.bundle2.key1": {
                    "key1": "value1",
                    "key2": false,
                    "key3": [1, 2, 3]
                }
            }
        }
        """)

        // overrides
        try config.setSecureConfig(key: "com.apple.bundle1.key2", value: true)
        // adds new property
        try config.setSecureConfig(key: "com.apple.bundle1.key3", value: "value3")
        // overrides the whole value, not trying to merge bit-by-bit
        try config.setSecureConfig(key: "com.apple.bundle2.key1", value: [
            "key1": "value-modified"
        ])

        let listSecureConfig = try config.listSecureConfig()
        #expect(listSecureConfig["com.apple.bundle1.key1"] as? String == "value")
        #expect(listSecureConfig["com.apple.bundle1.key2"] as? Bool == true)
        #expect(listSecureConfig["com.apple.bundle1.key3"] as? String == "value3")
        #expect(listSecureConfig["com.apple.bundle2.key1"] as? [String: String] == ["key1": "value-modified"])
    }

    @Test func mergeDarwinInit() async throws {
        var config = try DarwinInitConfig(json: """
        {
            "local-host-name": "vmhost",
            "cryptex": [
                {
                    "variant": "VARIANT",
                    "url": "https://hostname/cryptex.tar.gz"
                },
                {
                    "variant": "VARIANT2",
                    "url": "https://hostname/cryptex2.tar.gz"
                }
            ],
            "preferences": [
                {
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key1",
                    "value": "val1"
                },
                {
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key2",
                    "value": "val2"
                }
            ],
            "secure-config": {
                "com.apple.bundle1.key1": "value",
                "com.apple.bundle1.key2": false
            },
            "ssh": false,
            "user": {
                "gid": 0,
                "name": "root",
                "ssh_authorized_key": "foo",
                "uid": 0
            }
        }
        """)

        let overrideConfig = try DarwinInitConfig(json: """
        {
            "local-host-name": "vmhost2",
            "cryptex": [
                {
                    "variant": "VARIANT",
                    "url": "https://hostname/cryptex-replaced.tar.gz"
                }
            ],
            "preferences": [
                {
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key1",
                    "value": "val1-replaced"
                },
                {
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key3",
                    "value": "val3"
                },
            ],
            "secure-config": {
                "com.apple.bundle1.key2": true
            },
            "ssh": true,
            "user": {
                "gid": 500,
                "name": "mobile",
                "ssh_authorized_key": "bar",
                "uid": 500
            }
        }
        """)

        try config.overridingMerge(with: overrideConfig)

        #expect(configEquals(config, [
            "local-host-name": "vmhost2",
            "cryptex": [
                [
                    "variant": "VARIANT",
                    "url": "https://hostname/cryptex-replaced.tar.gz"
                ],
                [
                    "variant": "VARIANT2",
                    "url": "https://hostname/cryptex2.tar.gz"
                ]
            ],
            "preferences": [

                [
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key2",
                    "value": "val2"
                ],
                [
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key1",
                    "value": "val1-replaced"
                ],
                [
                    "application_id": "com.apple.cloudos.app_id",
                    "key": "key3",
                    "value": "val3"
                ]
            ],
            "secure-config": [
                "com.apple.bundle1.key1": "value",
                "com.apple.bundle1.key2": true,
            ],
            "ssh": true,
            "user": [
                "gid": 500,
                "name": "mobile",
                "ssh_authorized_key": "bar",
                "uid": 500
            ]
        ]))
    }
}
