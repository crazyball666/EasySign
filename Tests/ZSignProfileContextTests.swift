//
//  ZSignProfileContextTests.swift
//
//  Run:
//    swiftc -o /tmp/easysign-profile-context-tests \
//      EasySign/Core/Resigning/Model/ZSignProfileContext.swift \
//      Tests/ZSignProfileContextTests.swift && /tmp/easysign-profile-context-tests
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

private func context(
    expirationDate: Date? = Date(timeIntervalSince1970: 2_000_000_000),
    pattern: String = "PREFIX.com.example.*",
    prefixes: [String] = ["OLD", "PREFIX"],
    teams: [String] = ["TEAM"],
    entitlementTeam: String? = "TEAM",
    certificates: [Data] = [Data([0x01, 0x02])]
) -> ZSignProfileContext {
    var entitlements: [String: Any] = ["application-identifier": pattern]
    if let entitlementTeam {
        entitlements["com.apple.developer.team-identifier"] = entitlementTeam
    }
    return ZSignProfileContext(
        entitlements: entitlements,
        applicationIdentifierPrefixes: prefixes,
        teamIdentifiers: teams,
        developerCertificateDERs: certificates,
        expirationDate: expirationDate
    )
}

@main
struct ZSignProfileContextTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let profile = context()
            let identity = try profile.validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
            expect(identity.applicationIdentifierPattern == "PREFIX.com.example.*", "valid profile preserves raw application identifier pattern")
            expect(identity.applicationIdentifierPrefix == "PREFIX", "valid profile selects prefix referenced by its pattern")
            expect(identity.teamIdentifier == "TEAM", "valid profile yields unique team ID")
            expect(profile.containsCertificateDER(Data([0x01, 0x02])), "exact P12 DER exists in DeveloperCertificates")
            expect(!profile.containsCertificateDER(Data([0x01, 0x03])), "different P12 DER is not accepted")
        } catch {
            failures += 1
            print("FAIL  valid profile context: \(error)")
        }

        expectThrows("expired provisioning profile is rejected") {
            _ = try context(expirationDate: Date(timeIntervalSince1970: 1_600_000_000)).validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
        }

        expectThrows("missing expiration date is rejected") {
            _ = try context(expirationDate: nil).validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
        }

        expectThrows("top-level team and entitlement team disagreement is rejected") {
            _ = try context(entitlementTeam: "OTHER").validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
        }

        expectThrows("profile pattern prefix absent from top-level prefixes is rejected") {
            _ = try context(prefixes: ["OLD"]).validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
        }

        expectThrows("profile pattern that excludes target bundle ID is rejected") {
            _ = try context(pattern: "PREFIX.com.example.fixed").validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
        }

        expectThrows("wildcard target bundle identifier is rejected") {
            _ = try context().validatedIdentity(targetBundleIdentifier: "com.example.*", now: now)
        }

        expectThrows("multiple distinct team identifiers are rejected") {
            _ = try context(teams: ["TEAM", "OTHER"]).validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
        }

        do {
            let identity = try context(teams: ["TEAM", "TEAM"]).validatedIdentity(targetBundleIdentifier: "com.example.new", now: now)
            expect(identity.teamIdentifier == "TEAM", "duplicate identical team identifiers are normalized")
        } catch {
            failures += 1
            print("FAIL  duplicate identical team identifiers: \(error)")
        }

        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
