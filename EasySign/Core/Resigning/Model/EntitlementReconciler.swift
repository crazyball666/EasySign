//
//  EntitlementReconciler.swift
//  EasySign
//
//  Policy-only entitlement reconciliation for the ZSign backend.
//

import CoreFoundation
import Foundation

struct EntitlementProfileContext {
    let entitlements: [String: Any]
    let applicationIdentifierPattern: String
    let applicationIdentifierPrefixes: [String]
    let teamIdentifiers: [String]
}

struct EntitlementReconciliationInput {
    let customEntitlementsXML: String?
    let originalEntitlements: [String: Any]?
    let profile: EntitlementProfileContext
    /// Captured from the original signed Mach-O before custom XML or Info.plist changes.
    let sourceApplicationIdentifier: String?
    let targetBundleIdentifier: String
}

struct EntitlementReconciliationChange: Equatable {
    enum Action: Equatable {
        case kept
        case removed
        case rewritten
    }

    let action: Action
    let keyPath: String
    let reason: String
}

// `Array.contains { }` resolves to the generic Collection overload on some Swift SDKs.
// This narrow overload keeps the lightweight standalone tests readable.
extension Array where Element == EntitlementReconciliationChange {
    func contains(_ predicate: (Element) -> Bool) -> Bool {
        contains(where: predicate)
    }
}

struct EntitlementReconciliationResult {
    let entitlements: [String: Any]
    let xml: String
    let changes: [EntitlementReconciliationChange]
}

enum EntitlementReconciliationError: LocalizedError {
    case invalidProfile(String)
    case invalidEntitlement(String)
    case unsupportedEntitlement(String)
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message):
            return "Invalid provisioning profile: \(message)"
        case .invalidEntitlement(let message):
            return "Invalid entitlement: \(message)"
        case .unsupportedEntitlement(let message):
            return "Unsupported entitlement: \(message)"
        case .serializationFailed:
            return "Unable to serialize reconciled entitlements"
        }
    }
}

enum EntitlementReconciler {
    private static let applicationIdentifierKey = "application-identifier"
    private static let teamIdentifierKey = "com.apple.developer.team-identifier"
    private static let getTaskAllowKey = "get-task-allow"
    private static let betaReportsActiveKey = "beta-reports-active"
    private static let apsEnvironmentKey = "aps-environment"
    private static let keychainAccessGroupsKey = "keychain-access-groups"
    private static let iCloudContainerEnvironmentKey = "com.apple.developer.icloud-container-environment"
    private static let iCloudServicesKey = "com.apple.developer.icloud-services"

    static func reconcile(_ input: EntitlementReconciliationInput) throws -> EntitlementReconciliationResult {
        try validateProfileEntitlements(input.profile)
        let identity = try validatedIdentity(profile: input.profile, targetBundleIdentifier: input.targetBundleIdentifier)
        let requested = try requestedEntitlements(customXML: input.customEntitlementsXML, original: input.originalEntitlements)

        var result: [String: Any] = [
            applicationIdentifierKey: identity.applicationIdentifier,
            teamIdentifierKey: identity.teamIdentifier
        ]
        var changes: [EntitlementReconciliationChange] = [
            change(.rewritten, applicationIdentifierKey, "derived from the selected provisioning profile"),
            change(.rewritten, teamIdentifierKey, "derived from the selected provisioning profile")
        ]

        for key in requested.keys.sorted() {
            guard key != applicationIdentifierKey, key != teamIdentifierKey,
                  let requestedValue = requested[key]
            else {
                continue
            }

            // Profile presence precedes all requested-value parsing. This lets us safely
            // drop a revoked claim even if an old app contains a type ZSign cannot encode.
            guard let profileValue = input.profile.entitlements[key] else {
                changes.append(change(.removed, key, "absent from the provisioning profile"))
                continue
            }

            switch key {
            case getTaskAllowKey, betaReportsActiveKey:
                try reconcileBooleanClaim(key, requested: requestedValue, profile: profileValue, into: &result, changes: &changes)
            case apsEnvironmentKey:
                try reconcileAPSEnvironment(key, requested: requestedValue, profile: profileValue, into: &result, changes: &changes)
            case keychainAccessGroupsKey:
                try reconcileKeychainAccessGroups(
                    requested: requestedValue,
                    profile: profileValue,
                    sourceApplicationIdentifier: input.sourceApplicationIdentifier,
                    targetApplicationIdentifier: identity.applicationIdentifier,
                    into: &result,
                    changes: &changes
                )
            case iCloudContainerEnvironmentKey:
                try reconcileICloudContainerEnvironment(requested: requestedValue, profile: profileValue, into: &result, changes: &changes)
            case iCloudServicesKey:
                try reconcileICloudServices(requested: requestedValue, profile: profileValue, into: &result, changes: &changes)
            default:
                if let value = try reconcileGeneric(requestedValue, profile: profileValue, at: key, changes: &changes) {
                    result[key] = value
                    changes.append(change(
                        deepEqual(value, requestedValue) ? .kept : .rewritten,
                        key,
                        deepEqual(value, requestedValue) ? "authorized by the provisioning profile" : "unauthorized nested values were removed"
                    ))
                } else {
                    changes.append(change(.removed, key, "no requested value remains authorized by the provisioning profile"))
                }
            }
        }

        try validateZSignTree(result, at: "reconciled entitlements")
        let xml = try serialize(result)
        return EntitlementReconciliationResult(entitlements: result, xml: xml, changes: changes)
    }
}

private extension EntitlementReconciler {
    struct Identity {
        let applicationIdentifier: String
        let teamIdentifier: String
    }

    static func validateProfileEntitlements(_ profile: EntitlementProfileContext) throws {
        guard let rawGroups = profile.entitlements[keychainAccessGroupsKey] else { return }
        guard let groups = rawGroups as? [Any] else {
            throw EntitlementReconciliationError.invalidProfile("keychain-access-groups must be an array of Strings")
        }
        for (index, rawGroup) in groups.enumerated() {
            guard let group = rawGroup as? String else {
                throw EntitlementReconciliationError.invalidProfile("keychain-access-groups[\(index)] must be a String")
            }
            do {
                _ = try matchesTrailingWildcard("probe", group)
            } catch {
                throw EntitlementReconciliationError.invalidProfile("keychain-access-groups[\(index)] has an unsupported wildcard pattern")
            }
        }
    }

    static func validatedIdentity(profile: EntitlementProfileContext, targetBundleIdentifier: String) throws -> Identity {
        guard let dot = profile.applicationIdentifierPattern.firstIndex(of: ".") else {
            throw EntitlementReconciliationError.invalidProfile("application identifier pattern has no prefix separator")
        }
        let prefix = String(profile.applicationIdentifierPattern[..<dot])
        let matchingPrefixes = Set(profile.applicationIdentifierPrefixes.filter { !$0.isEmpty && $0 == prefix })
        guard matchingPrefixes.count == 1 else {
            throw EntitlementReconciliationError.invalidProfile("application identifier pattern prefix is not uniquely present in ApplicationIdentifierPrefix")
        }
        let distinctTeams = Set(profile.teamIdentifiers.filter { !$0.isEmpty })
        guard distinctTeams.count == 1, let team = distinctTeams.first else {
            throw EntitlementReconciliationError.invalidProfile("exactly one distinct team identifier is required")
        }
        guard !targetBundleIdentifier.isEmpty,
              !targetBundleIdentifier.contains("*"),
              !targetBundleIdentifier.hasPrefix("."),
              !targetBundleIdentifier.hasSuffix(".")
        else {
            throw EntitlementReconciliationError.invalidEntitlement("target bundle identifier is empty or malformed")
        }

        let candidate = "\(prefix).\(targetBundleIdentifier)"
        guard try matchesTrailingWildcard(candidate, profile.applicationIdentifierPattern) else {
            throw EntitlementReconciliationError.invalidEntitlement("application identifier \(candidate) is not authorized by \(profile.applicationIdentifierPattern)")
        }
        if let entitlementTeam = profile.entitlements[teamIdentifierKey] {
            guard try string(entitlementTeam, at: teamIdentifierKey) == team else {
                throw EntitlementReconciliationError.invalidProfile("top-level TeamIdentifier does not match its entitlement")
            }
        }
        if let entitlementPattern = profile.entitlements[applicationIdentifierKey] {
            guard try string(entitlementPattern, at: applicationIdentifierKey) == profile.applicationIdentifierPattern else {
                throw EntitlementReconciliationError.invalidProfile("application identifier pattern disagrees with its entitlement")
            }
        }
        return Identity(applicationIdentifier: candidate, teamIdentifier: team)
    }

    static func requestedEntitlements(customXML: String?, original: [String: Any]?) throws -> [String: Any] {
        guard let customXML, !customXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return original ?? [:]
        }
        guard let data = customXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else {
            throw EntitlementReconciliationError.invalidEntitlement("custom entitlements XML must be a property-list dictionary")
        }
        return dictionary
    }

    static func reconcileBooleanClaim(
        _ key: String,
        requested: Any,
        profile: Any,
        into result: inout [String: Any],
        changes: inout [EntitlementReconciliationChange]
    ) throws {
        let requestedBool = try bool(requested, at: key)
        let profileBool = try bool(profile, at: key)
        guard requestedBool && profileBool else {
            changes.append(change(.removed, key, "boolean claims are signed only when both request and profile are true"))
            return
        }
        result[key] = true
        changes.append(change(.kept, key, "request and provisioning profile both authorize true"))
    }

    static func reconcileAPSEnvironment(
        _ key: String,
        requested: Any,
        profile: Any,
        into result: inout [String: Any],
        changes: inout [EntitlementReconciliationChange]
    ) throws {
        let requestedEnvironment = try string(requested, at: key)
        let profileEnvironment = try string(profile, at: key)
        result[key] = profileEnvironment
        changes.append(change(requestedEnvironment == profileEnvironment ? .kept : .rewritten, key, "aps-environment is profile-authoritative"))
    }

    static func reconcileKeychainAccessGroups(
        requested: Any,
        profile: Any,
        sourceApplicationIdentifier: String?,
        targetApplicationIdentifier: String,
        into result: inout [String: Any],
        changes: inout [EntitlementReconciliationChange]
    ) throws {
        let requestedGroups = try stringArray(requested, at: keychainAccessGroupsKey, allowWildcard: false)
        let profileGroups = try stringArray(profile, at: keychainAccessGroupsKey, allowWildcard: true)
        var kept: [String] = []

        for (index, group) in requestedGroups.enumerated() {
            let path = "\(keychainAccessGroupsKey)[\(index)]"
            let candidate: String
            if group == sourceApplicationIdentifier,
               try profileGroups.contains(where: { try matchesTrailingWildcard(targetApplicationIdentifier, $0) }) {
                candidate = targetApplicationIdentifier
                changes.append(change(.rewritten, path, "the original default keychain group migrated to the new application identifier"))
            } else {
                candidate = group
            }
            guard try profileGroups.contains(where: { try matchesTrailingWildcard(candidate, $0) }) else {
                changes.append(change(.removed, path, "keychain group is not authorized by the provisioning profile"))
                continue
            }
            guard appendUnique(candidate, to: &kept) else {
                changes.append(change(.removed, path, "duplicate authorized keychain group"))
                continue
            }
            if candidate == group {
                changes.append(change(.kept, path, "keychain group is authorized by the provisioning profile"))
            }
        }
        guard !kept.isEmpty else {
            changes.append(change(.removed, keychainAccessGroupsKey, "no keychain group remains authorized"))
            return
        }
        result[keychainAccessGroupsKey] = kept
    }

    static func reconcileICloudContainerEnvironment(
        requested: Any,
        profile: Any,
        into result: inout [String: Any],
        changes: inout [EntitlementReconciliationChange]
    ) throws {
        let requestedValue = try string(requested, at: iCloudContainerEnvironmentKey)
        let profileValues = try stringCollection(profile, at: iCloudContainerEnvironmentKey, allowWildcard: false)
        guard profileValues.contains(requestedValue) else {
            changes.append(change(.removed, iCloudContainerEnvironmentKey, "container environment is not authorized by the provisioning profile"))
            return
        }
        result[iCloudContainerEnvironmentKey] = requestedValue
        changes.append(change(.kept, iCloudContainerEnvironmentKey, "container environment is authorized by the provisioning profile"))
    }

    static func reconcileICloudServices(
        requested: Any,
        profile: Any,
        into result: inout [String: Any],
        changes: inout [EntitlementReconciliationChange]
    ) throws {
        let requestedServices = try stringArray(requested, at: iCloudServicesKey, allowWildcard: false)
        let profileServices: [String]
        let allowsAll: Bool
        if let profileString = profile as? String {
            allowsAll = profileString == "*"
            profileServices = [profileString]
        } else {
            allowsAll = false
            profileServices = try stringArray(profile, at: iCloudServicesKey, allowWildcard: false)
        }
        var kept: [String] = []
        for (index, service) in requestedServices.enumerated() {
            let path = "\(iCloudServicesKey)[\(index)]"
            guard allowsAll || profileServices.contains(service) else {
                changes.append(change(.removed, path, "iCloud service is not authorized by the provisioning profile"))
                continue
            }
            guard appendUnique(service, to: &kept) else {
                changes.append(change(.removed, path, "duplicate authorized iCloud service"))
                continue
            }
            changes.append(change(.kept, path, allowsAll ? "profile wildcard authorizes all iCloud services" : "iCloud service is authorized by the provisioning profile"))
        }
        guard !kept.isEmpty else {
            changes.append(change(.removed, iCloudServicesKey, "no iCloud service remains authorized"))
            return
        }
        result[iCloudServicesKey] = kept
    }

    static func reconcileGeneric(
        _ requested: Any,
        profile: Any,
        at path: String,
        changes: inout [EntitlementReconciliationChange]
    ) throws -> Any? {
        if let requestedDictionary = requested as? [String: Any] {
            guard let profileDictionary = profile as? [String: Any] else {
                throw EntitlementReconciliationError.unsupportedEntitlement("\(path) compares a dictionary with a different type")
            }
            var result: [String: Any] = [:]
            for key in requestedDictionary.keys.sorted() {
                let childPath = "\(path).\(key)"
                guard let requestedChild = requestedDictionary[key] else { continue }
                guard let profileChild = profileDictionary[key] else {
                    changes.append(change(.removed, childPath, "absent from the provisioning profile"))
                    continue
                }
                if let child = try reconcileGeneric(requestedChild, profile: profileChild, at: childPath, changes: &changes) {
                    result[key] = child
                }
            }
            return result.isEmpty ? nil : result
        }

        if let requestedArray = requested as? [Any] {
            guard let profileArray = profile as? [Any] else {
                throw EntitlementReconciliationError.unsupportedEntitlement("\(path) compares an array with a different type")
            }
            var result: [Any] = []
            for (index, requestedChild) in requestedArray.enumerated() {
                let childPath = "\(path)[\(index)]"
                let authorized = try profileArray.contains { try exactAuthorization(requestedChild, profile: $0, at: childPath) }
                guard authorized else {
                    changes.append(change(.removed, childPath, "array member is not authorized by the provisioning profile"))
                    continue
                }
                guard appendUnique(requestedChild, to: &result) else {
                    changes.append(change(.removed, childPath, "duplicate authorized array member"))
                    continue
                }
                changes.append(change(.kept, childPath, "array member is authorized by the provisioning profile"))
            }
            return result.isEmpty ? nil : result
        }

        if let requestedString = requested as? String {
            let profileString = try string(profile, at: path)
            guard !requestedString.contains("*"), !profileString.contains("*") else {
                throw EntitlementReconciliationError.unsupportedEntitlement("wildcard comparison for \(path) is not defined")
            }
            guard requestedString == profileString else {
                changes.append(change(.removed, path, "exact String value differs from the provisioning profile"))
                return nil
            }
            return requestedString
        }

        if let requestedBool = try boolOrNil(requested, at: path) {
            guard let profileBool = try boolOrNil(profile, at: path) else {
                throw EntitlementReconciliationError.unsupportedEntitlement("\(path) compares a Boolean with a different type")
            }
            guard requestedBool, profileBool else {
                changes.append(change(.removed, path, "false Boolean values are omitted for the ZSign backend"))
                return nil
            }
            return true
        }

        throw unsupportedLeaf(requested, at: path)
    }

    static func exactAuthorization(_ requested: Any, profile: Any, at path: String) throws -> Bool {
        if let requestedDictionary = requested as? [String: Any] {
            guard let profileDictionary = profile as? [String: Any] else {
                throw EntitlementReconciliationError.unsupportedEntitlement("\(path) compares a dictionary with a different type")
            }
            for key in requestedDictionary.keys.sorted() {
                guard let requestedChild = requestedDictionary[key], let profileChild = profileDictionary[key],
                      try exactAuthorization(requestedChild, profile: profileChild, at: "\(path).\(key)")
                else { return false }
            }
            return true
        }
        if let requestedArray = requested as? [Any] {
            guard let profileArray = profile as? [Any] else {
                throw EntitlementReconciliationError.unsupportedEntitlement("\(path) compares an array with a different type")
            }
            return try requestedArray.allSatisfy { requestedChild in
                try profileArray.contains { try exactAuthorization(requestedChild, profile: $0, at: path) }
            }
        }
        if let requestedString = requested as? String {
            let profileString = try string(profile, at: path)
            guard !requestedString.contains("*"), !profileString.contains("*") else {
                throw EntitlementReconciliationError.unsupportedEntitlement("wildcard comparison for \(path) is not defined")
            }
            return requestedString == profileString
        }
        if let requestedBool = try boolOrNil(requested, at: path) {
            guard let profileBool = try boolOrNil(profile, at: path) else {
                throw EntitlementReconciliationError.unsupportedEntitlement("\(path) compares a Boolean with a different type")
            }
            return requestedBool == profileBool
        }
        throw unsupportedLeaf(requested, at: path)
    }

    static func matchesTrailingWildcard(_ value: String, _ pattern: String) throws -> Bool {
        let stars = pattern.filter { $0 == "*" }
        guard stars.count <= 1, stars.isEmpty || pattern.hasSuffix("*") else {
            throw EntitlementReconciliationError.unsupportedEntitlement("unsupported wildcard pattern \(pattern)")
        }
        guard !stars.isEmpty else { return value == pattern }
        let prefix = String(pattern.dropLast())
        guard !prefix.isEmpty else {
            throw EntitlementReconciliationError.unsupportedEntitlement("wildcard pattern must have a non-empty prefix")
        }
        return value.hasPrefix(prefix) && value.count > prefix.count
    }

    static func string(_ value: Any, at path: String) throws -> String {
        guard let string = value as? String else {
            throw EntitlementReconciliationError.unsupportedEntitlement("\(path) must be a String")
        }
        return string
    }

    static func stringArray(_ value: Any, at path: String, allowWildcard: Bool) throws -> [String] {
        guard let values = value as? [Any] else {
            throw EntitlementReconciliationError.unsupportedEntitlement("\(path) must be an array of Strings")
        }
        return try values.enumerated().map { index, value in
            let string = try string(value, at: "\(path)[\(index)]")
            guard allowWildcard || !string.contains("*") else {
                throw EntitlementReconciliationError.unsupportedEntitlement("wildcard request for \(path) is not defined")
            }
            if allowWildcard { _ = try matchesTrailingWildcard("probe", string) }
            return string
        }
    }

    static func stringCollection(_ value: Any, at path: String, allowWildcard: Bool) throws -> [String] {
        if let string = value as? String {
            guard allowWildcard || !string.contains("*") else {
                throw EntitlementReconciliationError.unsupportedEntitlement("wildcard profile value for \(path) is not defined")
            }
            return [string]
        }
        return try stringArray(value, at: path, allowWildcard: allowWildcard)
    }

    static func bool(_ value: Any, at path: String) throws -> Bool {
        guard let value = try boolOrNil(value, at: path) else {
            throw EntitlementReconciliationError.unsupportedEntitlement("\(path) must be a Boolean")
        }
        return value
    }

    static func boolOrNil(_ value: Any, at path: String) throws -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw EntitlementReconciliationError.unsupportedEntitlement("\(path) uses a numeric leaf")
        }
        return number.boolValue
    }

    static func validateZSignTree(_ value: Any, at path: String) throws {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() { try validateZSignTree(dictionary[key] as Any, at: "\(path).\(key)") }
            return
        }
        if let array = value as? [Any] {
            for (index, child) in array.enumerated() { try validateZSignTree(child, at: "\(path)[\(index)]") }
            return
        }
        if try boolOrNil(value, at: path) != nil || value is String { return }
        throw unsupportedLeaf(value, at: path)
    }

    static func unsupportedLeaf(_ value: Any, at path: String) -> EntitlementReconciliationError {
        if value is Data { return .unsupportedEntitlement("\(path) uses a Data leaf") }
        if value is Date { return .unsupportedEntitlement("\(path) uses a Date leaf") }
        if value is NSNumber { return .unsupportedEntitlement("\(path) uses a numeric leaf") }
        return .unsupportedEntitlement("\(path) has an unsupported leaf type")
    }

    static func appendUnique(_ value: Any, to values: inout [Any]) -> Bool {
        guard !values.contains(where: { deepEqual($0, value) }) else { return false }
        values.append(value)
        return true
    }

    static func appendUnique(_ value: String, to values: inout [String]) -> Bool {
        guard !values.contains(value) else { return false }
        values.append(value)
        return true
    }

    static func deepEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            return left.count == right.count && left.allSatisfy { key, value in
                right[key].map { deepEqual(value, $0) } ?? false
            }
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy { deepEqual($0.0, $0.1) }
        }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber,
           CFGetTypeID(left) == CFBooleanGetTypeID(), CFGetTypeID(right) == CFBooleanGetTypeID() {
            return left.boolValue == right.boolValue
        }
        if let left = lhs as? String, let right = rhs as? String {
            return left == right
        }
        return false
    }

    static func change(_ action: EntitlementReconciliationChange.Action, _ path: String, _ reason: String) -> EntitlementReconciliationChange {
        EntitlementReconciliationChange(action: action, keyPath: path, reason: reason)
    }

    static func serialize(_ entitlements: [String: Any]) throws -> String {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            guard let xml = String(data: data, encoding: .utf8) else { throw EntitlementReconciliationError.serializationFailed }
            return xml
        } catch let error as EntitlementReconciliationError {
            throw error
        } catch {
            throw EntitlementReconciliationError.serializationFailed
        }
    }
}
