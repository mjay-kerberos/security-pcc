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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
@_spi(Private) import CloudAttestation
import CryptoKit
import Foundation

extension CLI.ReleaseCmd {
    struct ReleaseVerifyCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Verify downloaded assets against release tickets."
        )

        @OptionGroup var globalOptions: CLI.globalOptions
        @OptionGroup var swlogOptions: CLI.ReleaseCmd.options

        @Option(name: [.customLong("release"), .customShort("R")],
                help: "SW Release Log index.")
        var releaseIndex: UInt64

        @Option(name: [.customLong("image"), .customShort("i")],
                help: ArgumentHelp("Path to a specific image to verify.", visibility: .customerHidden),
                transform: { try CLI.validateFilePath($0) })
        var imagePath: String?

        @Flag(name: [.customLong("detail")], help: "Output detailed summary of operations.")
        var showDetail: Bool = false

        // ReleaseTicketInfo serves as container for information extracted from a release ticket from Transparency Log
        private struct ReleaseTicketInfo {
            let name: String // hex string of ticket digest
            let platformProps: Image4Manifest.Properties // MANP section of ticket
            let digests: [String: Data]
        }

        // CompareResults is container holding the digests gleaned from a release ticket, BuildManifest target,
        //  and measurement of the file itself within an image, and results of comparison
        private struct CompareResults {
            let ticket4cc: String
            let ticketDigest: Data
            var manifestTag: String = ""
            var manifestPath: String = ""
            var manifestDigest: (any CryptoKit.Digest)? = nil
            var matched: Bool = false
        }

        func run() async throws {
            var logParams: [String] = []
            logParams.append("index=\(releaseIndex)")
            if let imagePath {
                logParams.append("image=\(imagePath)")
            }
            CLI.logger.log("verify downloaded assets \(logParams.joined(separator: "; "), privacy: .public))")

            var imagePaths: [CryptexHelper] = try imagePath != nil ? [CryptexHelper(path: imagePath!)] : []

            var assetHelper: AssetHelper
            do {
                assetHelper = try AssetHelper(directory: CLIDefaults.assetsDirectory.path)
            } catch {
                throw CLIError("\(CLIDefaults.assetsDirectory.path): \(error)")
            }

            let releaseTickets: SWRelease.Tickets
            let releaseMetadata: SWRelease.Metadata
            do {
                (releaseTickets, releaseMetadata) = try assetHelper.loadRelease(
                    index: releaseIndex,
                    logEnvironment: swlogOptions.environment
                )

                CLI.logger.log("ticket: \(releaseTickets.digest().bytes.hexString, privacy: .public)")
            } catch {
                let logmsg = "release lookup [\(swlogOptions.environment):\(releaseIndex)]: \(error)"
                CLI.logger.error("\(logmsg, privacy: .public)")

                throw CLIError("SW Release info not found for index \(releaseIndex): have assets been downloaded?")
            }

            if imagePaths.isEmpty {
                if let osAsset = releaseMetadata.assetsByType(.os)?.first {
                    do {
                        try imagePaths.append(CryptexHelper(path: CLI.expandAssetPath(osAsset).string))
                    } catch {
                        throw CLIError("obtain OS asset image: \(error)")
                    }
                }

                if let pcsAsset = releaseMetadata.assetsByType(.pcs)?.first {
                    do {
                        try imagePaths.append(CryptexHelper(path: CLI.expandAssetPath(pcsAsset).string))
                    } catch {
                        throw CLIError("obtain PCS asset image: \(error)")
                    }
                }
            }

            guard !imagePaths.isEmpty else {
                throw CLIError("no assets found to process")
            }

            let (succeeded, failed) = try verifyAssets(cryptexes: imagePaths, releaseTickets: releaseTickets)

            // exit code based on results
            if failed > 0 {
                if imagePaths.count > 1 {
                    print("FAILED to verify \(failed) / \(imagePaths.count) images")
                } else {
                    print("FAILED to verify image")
                }
                CLI.exit(withError: ExitCode(3))
            }

            if succeeded != imagePaths.count {
                if imagePaths.count > 1 {
                    if succeeded > 0 {
                        print("SUCCESSFULLY verified \(succeeded) / \(imagePaths.count) images")
                    }
                    print("FAILED to process \(imagePaths.count - succeeded) / \(imagePaths.count) images")
                } else {
                    print("FAILED to process image")
                }
                CLI.exit(withError: ExitCode(2))
            }

            if imagePaths.count > 1 {
                print("SUCCESSFULLY verified \(imagePaths.count) images")
            } else {
                print("SUCCESSFULLY verified image")
            }
            CLI.exit(withError: ExitCode(0))
        }

        // verify cryptexes against set of release tickets - returns number of cryptexes that have successfully
        //  verified entirely and those which have had at least 1 verify failure; successful count != cryptex count,
        //  implies an issue processing at least one of the cryptexes
        private func verifyAssets(cryptexes: [CryptexHelper],
                                  releaseTickets: SWRelease.Tickets) throws
            -> (succeeded: Int, failed: Int)
        {
            let (apTicketInfo,
                 codeTicketInfo,
                 dataTicketInfo) = try splitReleaseTickets(releaseTickets: releaseTickets)
            var failedCount = 0
            var successCount = 0

            print("Release: \(releaseTickets.name)")
            if showDetail {
                var allTickets = [apTicketInfo]
                allTickets.append(contentsOf: codeTicketInfo)
                allTickets.append(contentsOf: dataTicketInfo)
                printTicketInfo(allTickets)

                if !dataTicketInfo.isEmpty {
                    print("  Note: ignoring \(dataTicketInfo.count) data-only cryptex " +
                        "ticket\(dataTicketInfo.count != 1 ? "s" : "")")
                }
                print()
            }

            for cryptex in cryptexes {
                CLI.logger.log("processing cryptex: \(cryptex.archivePath.path, privacy: .public)")

                var cryptex = cryptex
                try cryptex.mount()
                defer { try? cryptex.eject() }

                var last_ticket: ReleaseTicketInfo?
                var last_results: [CompareResults]? = try compareDigests(cryptex: &cryptex,
                                                                         ticketInfo: apTicketInfo,
                                                                         apTicket: true)

                if last_results != nil {
                    last_ticket = apTicketInfo
                } else {
                    // when comparing cryptex against code tickets, final result is one with fewest mismatches
                    for cmTicket in codeTicketInfo {
                        guard let results = try compareDigests(cryptex: &cryptex, ticketInfo: cmTicket, apTicket: false) else {
                            continue
                        }

                        if last_results == nil ||
                            results.filter({ $0.matched }).count > last_results!.filter({ $0.matched }).count
                        {
                            last_results = results
                            last_ticket = cmTicket
                        }

                        // if no mismatches, we have the perfect match
                        if last_results!.filter({ $0.matched }).isEmpty {
                            break
                        }
                    }
                }

                if let last_results, let last_ticket {
                    if last_results.filter({ !$0.matched }).isEmpty {
                        successCount += 1
                    } else {
                        failedCount += 1
                    }

                    printCompareResults(cryptexPath: cryptex.archivePath,
                                        ticket: last_ticket,
                                        results: last_results)
                    print()
                } else {
                    CLI.warning("could not match cryptex against any release tickets")
                }
            }

            return (succeeded: successCount, failed: failedCount)
        }

        // splitReleaseTickets retrieves properties and digest info from a set of tickets, as
        //  apTicket, codeCryptex, and dataCryptex containers respectively
        private func splitReleaseTickets(releaseTickets: SWRelease.Tickets) throws
            -> (apTicket: ReleaseTicketInfo,
                codeCryptexes: [ReleaseTicketInfo],
                dataCryptexes: [ReleaseTicketInfo])
        {
            let apI4M = Image4Manifest(data: releaseTickets.apTicket.bytes, kind: .ap)
            let apTicketInfo: ReleaseTicketInfo
            do {
                apTicketInfo = try extractTicketInfo(ticket: apI4M)
            } catch {
                throw CLIError("OS ticket \(apI4M.name): \(error)")
            }

            var codeCryptexTicketInfo: [ReleaseTicketInfo] = []
            var dataCryptexTicketInfo: [ReleaseTicketInfo] = []

            for cryptexTicket in releaseTickets.cryptexTickets {
                let cIM = Image4Manifest(data: cryptexTicket.bytes, kind: .cryptex)
                do {
                    let ticketInfo = try extractTicketInfo(ticket: cIM)
                    if cIM.isDataOnly() {
                        dataCryptexTicketInfo.append(ticketInfo)
                    } else {
                        codeCryptexTicketInfo.append(ticketInfo)
                    }
                } catch {
                    CLI.warning("Cryptex ticket: \(cIM.name): \(error)")
                    continue
                }
            }

            return (apTicket: apTicketInfo,
                    codeCryptexes: codeCryptexTicketInfo,
                    dataCryptexes: dataCryptexTicketInfo)
        }

        // extractTicketInfo extracts platform and digest properties from a ticket into ReleaseTicketInfo container
        private func extractTicketInfo(ticket: Image4Manifest) throws -> ReleaseTicketInfo {
            guard let platformProps = ticket.platformProps() else {
                throw CLIError("failed to parse platform properties")
            }

            guard let digests = ticket.digests() else {
                throw CLIError("failed to extract digest info")
            }

            for fourcc in digests.keys {
                guard let _ = Image4Manifest.tagOf(fourcc: fourcc) else {
                    throw CLIError("unrecognized 4cc: \(fourcc)")
                }
            }

            return ReleaseTicketInfo(
                name: ticket.name,
                platformProps: platformProps,
                digests: digests
            )
        }

        // compareDigests compares digests collected from the image and the ticket, returning
        //  the results in a container with details suitable for summarizing and details
        private func compareDigests(cryptex: inout CryptexHelper,
                                    ticketInfo: ReleaseTicketInfo,
                                    apTicket: Bool = false) throws
            -> [CompareResults]?
        {
            var results: [CompareResults] = []

            let buildManifest = try cryptex.loadBuildManifest()
            guard let matchingBuilds = buildManifest.pickBuildIdentities(constraints: ticketInfo.platformProps),
                  !matchingBuilds.isEmpty
            else {
                CLI.logger.log("no matching builds for ticket:\(ticketInfo.name, privacy: .public)")
                return nil
            }

            for build in matchingBuilds {
                guard let manifest = build.manifest else {
                    CLI.logger.error("buildIdentity does not contain a manifest")
                    continue
                }

                if apTicket && !build.isOSImage {
                    CLI.logger.debug("skip comparing apTicket against OS manifest")
                    continue
                }

                // cryptexMeasurements contains digests captured directly from files within the image
                let cryptexMeasurements = try cryptex.measure(manifest: manifest)

                for (fourcc, tktDigest) in ticketInfo.digests {
                    // skip 4cc tags associated with RestoreOS artifacts, and certificate measurements
                    if Image4Manifest.isRestore4cc(fourcc) || ["ftap", "ftsp"].contains(fourcc) {
                        continue
                    }

                    var result = CompareResults(ticket4cc: fourcc, ticketDigest: tktDigest)

                    guard let tag = Image4Manifest.tagOf(fourcc: fourcc) else {
                        CLI.logger.warning("unknown 4cc tag [\(fourcc)] in ticket: \(ticketInfo.name)")
                        CLI.warning("unknown 4cc tag [\(fourcc)] in ticket: \(ticketInfo.name)")
                        continue
                    }

                    result.manifestTag = tag
                    if let mdigest = cryptexMeasurements[tag] {
                        result.manifestPath = mdigest.path
                        result.manifestDigest = mdigest.computed
                        result.matched = mdigest.computed != nil && tktDigest == mdigest.computed!.bytes
                    }

                    results.append(result)
                }

                CLI.logger.log("")
                // only process the first matching build identity
                break
            }

            return results.isEmpty ? nil : results
        }

        // printTicketInfo outputs contents of a Transparency Log release ticket in readable form
        private func printTicketInfo(_ relTickets: [ReleaseTicketInfo]) {
            for relTicket in relTickets {
                print("  Ticket: \(relTicket.name)")
                for (fourcc, val) in relTicket.platformProps.sorted(by: { $0.key < $1.key }) {
                    let pval = switch val {
                    case let val as UInt64: String(format: "0x%02X", val)
                    case let val as Data:
                        if ["love", "osev", "ostp", "pave", "prtp", "sdkp", "tagt", "tatp", "vnum"].contains(fourcc),
                           let str = String(data: val, encoding: .utf8)
                        {
                            str
                        } else {
                            val.hexString
                        }
                    default: "\(val)"
                    }
                    print("      \(fourcc): \(pval)")
                }

                print("      Digests:")
                for (fourcc, digest) in relTicket.digests.sorted(by: { $0.key < $1.key }) {
                    print("        \(fourcc): \(digest.hexString)")
                }

                print("  ----")
            }
        }

        // printCompareResults outputs results of ticket/cryptex verification - if showDetail is true,
        //  additional details are included
        private func printCompareResults(cryptexPath: URL,
                                         ticket: ReleaseTicketInfo,
                                         results: [CompareResults])
        {
            let cryptexName = showDetail ? cryptexPath.path : cryptexPath.lastPathComponent
            let success = results.filter { !$0.matched }.isEmpty
            if success {
                CLI.logger.log("verify \(cryptexPath.path, privacy: .public): SUCCESS ")
            } else {
                CLI.logger.error("verify \(cryptexPath.path, privacy: .public): FAILED")
            }
            print("Asset: \(cryptexName): [\(success ? "SUCCESS" : "FAILED")]")
            print("  Ticket: \(ticket.name)")

            for result in results.sorted(by: { $0.manifestTag < $1.manifestTag }) {
                print("    \(result.manifestTag.isEmpty ? "unknown" : result.manifestTag) [\(result.ticket4cc)]: " +
                    "\(result.manifestPath.isEmpty ? "unknown" : result.manifestPath) - " +
                    "\(result.matched ? "SUCCESS" : "FAILED")"
                )
                if showDetail {
                    if let manifestDigest = result.manifestDigest {
                        let digAlgo = type(of: manifestDigest)
                        print("      [\(digAlgo)]")
                        if result.matched {
                            print("      \(manifestDigest.bytes.hexString)")
                        } else {
                            print("      ticket:   \(result.ticketDigest.hexString)")
                            print("      measured: \(manifestDigest.bytes.hexString)")
                        }
                    } else {
                        print("      ticket:   \(result.ticketDigest.hexString)")
                    }
                }
            }
        }
    }
}
