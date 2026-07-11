//
//  ZSignProfileContext.swift
//  EasySign
//
//  Validation boundary between decoded provisioning profiles and the ZSign path.
//

import Foundation

struct ZSignProfileContext {
    let entitlements: [String: Any]
    let applicationIdentifierPrefixes: [String]
    let teamIdentifiers: [String]
    let developerCertificateDERs: [Data]
    let expirationDate: Date?

    func containsCertificateDER(_ certificateDER: Data) -> Bool {
        developerCertificateDERs.contains(certificateDER)
    }

    func validatedIdentity(targetBundleIdentifier: String, now: Date = .now) throws -> ZSignProfileIdentity {
        guard let expirationDate else {
            throw ZSignProfileContextError.invalid("profile does not contain an expiration date")
        }
        guard expirationDate > now else {
            throw ZSignProfileContextError.invalid("profile expired at \(expirationDate)")
        }
        guard let pattern = entitlements["application-identifier"] as? String,
              let separator = pattern.firstIndex(of: ".")
        else {
            throw ZSignProfileContextError.invalid("profile does not contain a valid application-identifier entitlement")
        }
        guard !targetBundleIdentifier.isEmpty,
              !targetBundleIdentifier.contains("*"),
              !targetBundleIdentifier.hasPrefix("."),
              !targetBundleIdentifier.hasSuffix(".")
        else {
            throw ZSignProfileContextError.invalid("target bundle identifier is malformed")
        }

        let prefix = String(pattern[..<separator])
        let matchingPrefixes = Set(applicationIdentifierPrefixes.filter { !$0.isEmpty && $0 == prefix })
        guard matchingPrefixes.count == 1 else {
            throw ZSignProfileContextError.invalid("application identifier pattern prefix is not uniquely present in ApplicationIdentifierPrefix")
        }

        let distinctTeams = Set(teamIdentifiers.filter { !$0.isEmpty })
        guard distinctTeams.count == 1, let teamIdentifier = distinctTeams.first else {
            throw ZSignProfileContextError.invalid("profile must contain exactly one distinct TeamIdentifier")
        }
        if let entitlementTeam = entitlements["com.apple.developer.team-identifier"] {
            guard let entitlementTeam = entitlementTeam as? String, entitlementTeam == teamIdentifier else {
                throw ZSignProfileContextError.invalid("TeamIdentifier disagrees with com.apple.developer.team-identifier")
            }
        }

        let candidate = "\(prefix).\(targetBundleIdentifier)"
        guard try matches(candidate, pattern: pattern) else {
            throw ZSignProfileContextError.invalid("target application identifier \(candidate) is outside \(pattern)")
        }
        return ZSignProfileIdentity(
            applicationIdentifierPattern: pattern,
            applicationIdentifierPrefix: prefix,
            teamIdentifier: teamIdentifier
        )
    }
}

struct ZSignProfileIdentity: Equatable {
    let applicationIdentifierPattern: String
    let applicationIdentifierPrefix: String
    let teamIdentifier: String
}

enum ZSignProfileContextError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "Invalid provisioning profile: \(message)"
        }
    }
}

private extension ZSignProfileContext {
    func matches(_ value: String, pattern: String) throws -> Bool {
        let wildcardCount = pattern.filter { $0 == "*" }.count
        guard wildcardCount <= 1, wildcardCount == 0 || pattern.hasSuffix("*") else {
            throw ZSignProfileContextError.invalid("application identifier pattern has an unsupported wildcard")
        }
        guard wildcardCount == 1 else {
            return value == pattern
        }
        let prefix = String(pattern.dropLast())
        return value.hasPrefix(prefix) && value.count > prefix.count
    }
}
