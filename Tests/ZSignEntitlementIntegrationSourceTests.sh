#!/bin/sh
set -eu

SOURCE="EasySign/Core/Resigning/Model/ResignTask.swift"
PROFILE="EasySign/Core/Resigning/Model/MobileProvision.swift"

rg -n "zsignProfileContext\(\)" "$PROFILE" >/dev/null
rg -n "validateAppTopology" "$SOURCE" >/dev/null
rg -n "validateInjectedDylib" "$SOURCE" >/dev/null
rg -n "EntitlementReconciler\.reconcile" "$SOURCE" >/dev/null
rg -n "ResignOutputPublisher" "$SOURCE" >/dev/null
rg -n "candidateURL" "$SOURCE" >/dev/null
rg -n "verifyZSignCandidate" "$SOURCE" >/dev/null
rg -n -- "--verify.*--deep.*--strict" "$SOURCE" >/dev/null
rg -n "publisher\.publish" "$SOURCE" >/dev/null

# Apple path keeps its existing entitlement behavior; ZSign uses the dedicated reconciler.
awk '/private func startAppleResign\(\)/,/private func startZSignResign\(\)/' "$SOURCE" | rg -n "updateEntitlements" >/dev/null
awk '/private func startZSignResign\(\)/,/^}/' "$SOURCE" | rg -n "EntitlementReconciler\.reconcile" >/dev/null

# This branch must not patch the vendored ZSign implementation.
if git diff --name-only main...HEAD 2>/dev/null | rg '^EasySign/Vendor/ZSign/' >/dev/null; then
    echo "Vendor/ZSign must remain unmodified" >&2
    exit 1
fi
