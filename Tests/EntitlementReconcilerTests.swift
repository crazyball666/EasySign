//
//  EntitlementReconcilerTests.swift
//
//  Standalone regression tests for the ZSign entitlement policy engine.
//
//  Run:
//    swiftc -o /tmp/easysign-entitlement-tests \
//      EasySign/Core/Resigning/Model/EntitlementReconciler.swift \
//      Tests/EntitlementReconcilerTests.swift && /tmp/easysign-entitlement-tests
//

import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func expectThrows(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        failures += 1
        print("FAIL  \(name)")
    } catch {
        print("PASS  \(name): \(error.localizedDescription)")
    }
}

private func plistXML(_ entitlements: [String: Any]) -> String {
    let data = try! PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    return String(decoding: data, as: UTF8.self)
}

private func profile(
    entitlements: [String: Any],
    appIdentifierPattern: String = "PREFIX.com.example.*",
    prefixes: [String] = ["PREFIX"],
    teams: [String] = ["TEAM"]
) -> EntitlementProfileContext {
    EntitlementProfileContext(
        entitlements: entitlements,
        applicationIdentifierPattern: appIdentifierPattern,
        applicationIdentifierPrefixes: prefixes,
        teamIdentifiers: teams
    )
}

private func reconcile(
    customXML: String? = nil,
    original: [String: Any]? = nil,
    profileEntitlements: [String: Any],
    sourceApplicationIdentifier: String? = "OLDPREFIX.com.example.old",
    targetBundleID: String = "com.example.new",
    prefixes: [String] = ["PREFIX"],
    teams: [String] = ["TEAM"]
) throws -> EntitlementReconciliationResult {
    try EntitlementReconciler.reconcile(
        EntitlementReconciliationInput(
            customEntitlementsXML: customXML,
            originalEntitlements: original,
            profile: profile(entitlements: profileEntitlements, prefixes: prefixes, teams: teams),
            sourceApplicationIdentifier: sourceApplicationIdentifier,
            targetBundleIdentifier: targetBundleID
        )
    )
}

@main
struct EntitlementReconcilerTests {
    static func main() {
        let baseProfile: [String: Any] = [
            "application-identifier": "PREFIX.com.example.*",
            "com.apple.developer.team-identifier": "TEAM",
            "get-task-allow": false,
            "aps-environment": "production"
        ]

        do {
            let result = try reconcile(
                original: [
                    "application-identifier": "OLDPREFIX.com.example.old",
                    "com.apple.developer.team-identifier": "OLDTEAM",
                    "get-task-allow": true,
                    "com.apple.security.application-groups": ["group.com.example.old"],
                    "aps-environment": "development"
                ],
                profileEntitlements: baseProfile
            )
            expect(result.entitlements["application-identifier"] as? String == "PREFIX.com.example.new", "app identifier uses profile prefix and target bundle ID")
            expect(result.entitlements["com.apple.developer.team-identifier"] as? String == "TEAM", "team identifier uses profile team ID")
            expect(result.entitlements["get-task-allow"] == nil, "profile false removes get-task-allow entirely")
            expect(result.entitlements["com.apple.security.application-groups"] == nil, "profile-missing App Group removes entire entitlement")
            expect(result.entitlements["aps-environment"] as? String == "production", "aps environment remains profile-authoritative")
            expect(!result.xml.contains("<key>get-task-allow</key>"), "serialized XML omits get-task-allow key")
        } catch {
            failures += 1
            print("FAIL  false task allow reconciliation: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["keychain-access-groups": ["PREFIX.com.example.new", "PREFIX.shared"]],
                profileEntitlements: baseProfile.merging([
                    "keychain-access-groups": ["PREFIX.com.example.*", "PREFIX.shared"]
                ]) { _, new in new }
            )
            expect(result.entitlements["keychain-access-groups"] as? [String] == ["PREFIX.com.example.new", "PREFIX.shared"], "keychain group wildcard authorizes concrete requested groups")
        } catch {
            failures += 1
            print("FAIL  keychain wildcard reconciliation: \(error)")
        }

        do {
            let custom = plistXML(["com.apple.developer.associated-domains": ["applinks:custom.example"]])
            let result = try reconcile(
                customXML: custom,
                original: ["com.apple.developer.associated-domains": ["applinks:original.example"]],
                profileEntitlements: baseProfile.merging([
                    "com.apple.developer.associated-domains": ["applinks:custom.example", "applinks:original.example"]
                ]) { _, new in new }
            )
            expect(result.entitlements["com.apple.developer.associated-domains"] as? [String] == ["applinks:custom.example"], "valid custom XML takes priority over original entitlement")
        } catch {
            failures += 1
            print("FAIL  custom entitlement priority: \(error)")
        }

        do {
            let result = try reconcile(original: nil, profileEntitlements: baseProfile)
            expect(result.entitlements.count == 2, "missing source starts from an empty entitlement dictionary")
            expect(result.entitlements["application-identifier"] != nil && result.entitlements["com.apple.developer.team-identifier"] != nil, "empty source still receives derived identity claims")
        } catch {
            failures += 1
            print("FAIL  empty source fallback: \(error)")
        }

        expectThrows("unknown wildcard entitlement fails closed") {
            _ = try reconcile(
                original: ["com.example.unknown": "thing.example.com"],
                profileEntitlements: baseProfile.merging(["com.example.unknown": "thing.*"]) { _, new in new }
            )
        }

        expectThrows("invalid custom entitlement XML does not silently fall back to original") {
            _ = try reconcile(
                customXML: "<not-a-plist>",
                original: ["aps-environment": "production"],
                profileEntitlements: baseProfile
            )
        }

        do {
            let result = try reconcile(
                original: [:],
                profileEntitlements: baseProfile,
                prefixes: ["HISTORICAL", "PREFIX"]
            )
            expect(result.entitlements["application-identifier"] as? String == "PREFIX.com.example.new", "historical prefixes do not block the profile pattern prefix")
        } catch {
            failures += 1
            print("FAIL  historical prefix reconciliation: \(error)")
        }

        expectThrows("unknown scalar to array entitlement relation fails closed") {
            _ = try reconcile(
                original: ["com.example.unknown": "value"],
                profileEntitlements: baseProfile.merging(["com.example.unknown": ["value"]]) { _, new in new }
            )
        }

        do {
            let result = try reconcile(
                original: ["com.example.removed-before-parse": Data([0x01, 0x02])],
                profileEntitlements: baseProfile
            )
            expect(result.entitlements["com.example.removed-before-parse"] == nil, "profile-missing unsupported leaf is removed without parsing")
        } catch {
            failures += 1
            print("FAIL  profile-missing unsupported leaf: \(error)")
        }

        do {
            let profileWithoutAPS = baseProfile.filter { $0.key != "aps-environment" }
            let result = try reconcile(
                original: ["aps-environment": 7],
                profileEntitlements: profileWithoutAPS
            )
            expect(result.entitlements["aps-environment"] == nil, "profile-missing aps claim is removed before requested type parsing")
        } catch {
            failures += 1
            print("FAIL  profile-missing aps claim: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["com.example.exact": "old"],
                profileEntitlements: baseProfile.merging(["com.example.exact": "new"]) { _, new in new }
            )
            expect(result.entitlements["com.example.exact"] == nil, "generic exact scalar mismatch removes its claim")
        } catch {
            failures += 1
            print("FAIL  generic exact scalar mismatch: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["com.example.array": ["allowed", "blocked", "allowed"]],
                profileEntitlements: baseProfile.merging(["com.example.array": ["allowed"]]) { _, new in new }
            )
            expect(result.entitlements["com.example.array"] as? [String] == ["allowed"], "generic array subset filters and stably deduplicates members")
        } catch {
            failures += 1
            print("FAIL  generic array subset filtering: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["com.example.dictionary": ["allowed": "yes", "blocked": "no", "nested": ["allowed": "yes", "blocked": "no"]]],
                profileEntitlements: baseProfile.merging(["com.example.dictionary": ["allowed": "yes", "nested": ["allowed": "yes"]]]) { _, new in new }
            )
            let dictionary = result.entitlements["com.example.dictionary"] as? [String: Any]
            expect(dictionary?["allowed"] as? String == "yes" && dictionary?["blocked"] == nil, "generic dictionary filters blocked direct members")
            expect((dictionary?["nested"] as? [String: Any])?["allowed"] as? String == "yes" && (dictionary?["nested"] as? [String: Any])?["blocked"] == nil, "generic dictionary recursively filters blocked members")
        } catch {
            failures += 1
            print("FAIL  generic dictionary filtering: \(error)")
        }

        do {
            var requestedNested: [String: Any] = [:]
            requestedNested["second"] = "two"
            requestedNested["first"] = "one"
            var profileNested: [String: Any] = [:]
            profileNested["first"] = "one"
            profileNested["second"] = "two"
            let result = try reconcile(
                original: ["com.example.equal-dictionary": requestedNested],
                profileEntitlements: baseProfile.merging(["com.example.equal-dictionary": profileNested]) { _, new in new }
            )
            expect(result.changes.contains { change in
                change.keyPath == "com.example.equal-dictionary" && change.action == .kept
            }, "semantically equal dictionaries are kept regardless of construction order")
        } catch {
            failures += 1
            print("FAIL  semantic dictionary equality: \(error)")
        }

        expectThrows("numeric entitlement leaves fail before ZSign DER encoding") {
            _ = try reconcile(
                original: ["com.example.numeric": 7],
                profileEntitlements: baseProfile.merging(["com.example.numeric": 7]) { _, new in new }
            )
        }

        do {
            let result = try reconcile(
                original: ["keychain-access-groups": ["OLDPREFIX.com.example.old"]],
                profileEntitlements: baseProfile.merging(["keychain-access-groups": ["PREFIX.com.example.*"]]) { _, new in new }
            )
            expect(result.entitlements["keychain-access-groups"] as? [String] == ["PREFIX.com.example.new"], "only the old default keychain group migrates to the authorized new default")
        } catch {
            failures += 1
            print("FAIL  default keychain group migration: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["keychain-access-groups": ["OLDPREFIX.com.example.old", "custom.unauthorized", "OLDPREFIX.com.example.old"]],
                profileEntitlements: baseProfile.merging(["keychain-access-groups": ["PREFIX.com.example.new"]]) { _, new in new }
            )
            expect(result.entitlements["keychain-access-groups"] as? [String] == ["PREFIX.com.example.new"], "keychain filters unauthorized custom groups and deduplicates migrated default")
        } catch {
            failures += 1
            print("FAIL  keychain filtering: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["keychain-access-groups": ["OLDPREFIX.com.example.old"]],
                profileEntitlements: baseProfile.merging(["keychain-access-groups": ["PREFIX.com.example.new"]]) { _, new in new }
            )
            expect(result.entitlements["keychain-access-groups"] as? [String] == ["PREFIX.com.example.new"], "exact keychain profile group authorizes default-group migration")
        } catch {
            failures += 1
            print("FAIL  exact keychain group migration: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["com.apple.developer.icloud-container-environment": "Development"],
                profileEntitlements: baseProfile.merging(["com.apple.developer.icloud-container-environment": ["Production"]]) { _, new in new }
            )
            expect(result.entitlements["com.apple.developer.icloud-container-environment"] == nil, "unauthorized iCloud container environment is removed")
        } catch {
            failures += 1
            print("FAIL  iCloud container environment filtering: \(error)")
        }

        expectThrows("iCloud container environment request must be scalar String") {
            _ = try reconcile(
                original: ["com.apple.developer.icloud-container-environment": ["Production"]],
                profileEntitlements: baseProfile.merging(["com.apple.developer.icloud-container-environment": "Production"]) { _, new in new }
            )
        }

        do {
            let result = try reconcile(
                original: ["com.apple.developer.icloud-services": ["CloudKit", "NotAllowed", "CloudKit"]],
                profileEntitlements: baseProfile.merging(["com.apple.developer.icloud-services": "*"]) { _, new in new }
            )
            expect(result.entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit", "NotAllowed"], "iCloud services scalar wildcard authorizes and deduplicates requested array")
        } catch {
            failures += 1
            print("FAIL  iCloud services wildcard profile: \(error)")
        }

        expectThrows("iCloud services request must be a String array") {
            _ = try reconcile(
                original: ["com.apple.developer.icloud-services": "CloudKit"],
                profileEntitlements: baseProfile.merging(["com.apple.developer.icloud-services": "CloudKit"]) { _, new in new }
            )
        }

        expectThrows("wildcard target bundle identifier is rejected") {
            _ = try reconcile(profileEntitlements: baseProfile, targetBundleID: "com.example.*")
        }

        expectThrows("bare keychain wildcard profile is rejected") {
            _ = try reconcile(
                original: ["keychain-access-groups": ["PREFIX.com.example.new"]],
                profileEntitlements: baseProfile.merging(["keychain-access-groups": ["*"]]) { _, new in new }
            )
        }

        expectThrows("bare keychain wildcard profile is rejected even when the app does not request keychain access") {
            _ = try reconcile(
                original: [:],
                profileEntitlements: baseProfile.merging(["keychain-access-groups": ["*"]]) { _, new in new }
            )
        }

        do {
            let result = try reconcile(
                original: ["beta-reports-active": false],
                profileEntitlements: baseProfile.merging(["beta-reports-active": true]) { _, new in new }
            )
            expect(result.entitlements["beta-reports-active"] == nil, "beta reports false is omitted")
        } catch {
            failures += 1
            print("FAIL  beta reports false omission: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["beta-reports-active": true],
                profileEntitlements: baseProfile.merging(["beta-reports-active": true]) { _, new in new }
            )
            expect(result.entitlements["beta-reports-active"] as? Bool == true, "beta reports only keeps mutually true claim")
        } catch {
            failures += 1
            print("FAIL  beta reports true keep: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["com.example.audit": ["blocked", "allowed"]],
                profileEntitlements: baseProfile.merging(["com.example.audit": ["allowed"]]) { _, new in new }
            )
            expect(result.changes.contains { change in
                change.keyPath == "com.example.audit[0]" && change.action == .removed && !change.reason.isEmpty
            }, "audit log records path-level array removal with reason")
        } catch {
            failures += 1
            print("FAIL  path-level audit log: \(error)")
        }

        do {
            let result = try reconcile(
                original: [:],
                profileEntitlements: baseProfile,
                teams: ["TEAM", "TEAM"]
            )
            expect(result.entitlements["com.apple.developer.team-identifier"] as? String == "TEAM", "duplicate identical TeamIdentifier entries reconcile to one team")
        } catch {
            failures += 1
            print("FAIL  duplicate identical team identifiers: \(error)")
        }

        do {
            let result = try reconcile(
                original: ["com.apple.developer.icloud-services": ["CloudKit"]],
                profileEntitlements: baseProfile.merging(["com.apple.developer.icloud-services": "CloudKit"]) { _, new in new }
            )
            expect(result.entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"], "scalar profile iCloud service authorizes requested array")
        } catch {
            failures += 1
            print("FAIL  scalar iCloud services profile: \(error)")
        }

        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
