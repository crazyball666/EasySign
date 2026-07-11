# ZSign Entitlement Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ZSign backend produce only entitlement claims authorized by the selected provisioning profile, detect unsupported bundle topologies and malformed Mach-O input before signing, and verify a candidate IPA before atomically publishing it.

**Architecture:** Keep the existing Apple/codesign path and `Vendor/ZSign` unchanged. Add Swift-owned, focused components for profile context, entitlement reconciliation, Mach-O scanning/signature inspection, and output publication; `ResignTask.startZSignResign()` becomes their orchestrator. All policy decisions are fail-closed and work on every entitlement key, with narrow rules for Apple-defined special cases.

**Tech Stack:** Swift/Foundation/Security, existing Objective-C++ ZSign bridge, standalone `swiftc` test executables, macOS `codesign` and `unzip`.

---

## File structure

- `EasySign/Core/Resigning/Model/MobileProvision.swift` — expose and validate raw profile app-ID-prefix, team, certificate, expiry, and entitlement identity context without changing Apple backend behavior.
- `EasySign/Core/Resigning/Model/ZSignProfileContext.swift` — pure, testable validation of profile expiry/identity fields and P12 DER membership; `MobileProvision` only adapts decoded CMS data into this context.
- `EasySign/Core/Resigning/Model/EntitlementReconciler.swift` — pure policy engine: source selection, profile authorization, ZSign-safe plist typing, and deterministic XML serialization.
- `EasySign/Core/Resigning/Model/MachOExecutableScanner.swift` — bounded thin/fat Mach-O parsing and recursive app bundle/injected dylib preflight.
- `EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift` — independently inspect every Mach-O slice's SuperBlob, XML/DER entitlements, CodeDirectory identifier/team/execseg flags.
- `EasySign/Core/Resigning/Model/ResignOutputPublisher.swift` — sibling temporary IPA URL, candidate cleanup, and atomic final publication.
- `EasySign/Core/Resigning/Model/ResignTask.swift` — call the new ZSign-only preflight/reconciliation/verification sequence; preserve Apple methods untouched.
- `Tests/EntitlementReconcilerTests.swift`, `Tests/ZSignProfileContextTests.swift`, `Tests/MachOZSignSafetyTests.swift`, `Tests/ResignOutputPublisherTests.swift` — standalone regression executables.
- `Tests/ZSignManualSmokeTest.md` — reproducible real-credential/real-device acceptance procedure, including the reported enterprise profile mismatch.
- `Tests/ZSignEntitlementIntegrationSourceTests.sh` — source-level guard that prevents the ZSign path from regressing to the old generic entitlement updater or direct output overwrite.

### Task 1: Provisioning-profile identity context and entitlement reconciler

**Files:**
- Create: `EasySign/Core/Resigning/Model/EntitlementReconciler.swift`
- Create: `EasySign/Core/Resigning/Model/ZSignProfileContext.swift`
- Modify: `EasySign/Core/Resigning/Model/MobileProvision.swift`
- Create: `Tests/EntitlementReconcilerTests.swift`
- Create: `Tests/ZSignProfileContextTests.swift`

- [ ] **Step 1: Write failing reconciler tests**

Cover these independently: a profile with `get-task-allow=false` removes the key even when source requests true; a missing App Group removes the complete claim; profile wildcard and scoped app-ID matching form `<prefix>.<targetBundleId>`; the original default keychain group rewrites only to an authorized new default group; custom XML has priority over the requested claims while original Mach-O identity remains available; missing source falls back to an empty dictionary; unknown wildcard and scalar/array cross-type mismatches throw; numeric/Data/Date claims throw; and each result records explicit keep/remove/rewrite changes. Separately test profile context rejection of an expired profile, non-unique team IDs, entitlement-team mismatch, missing pattern prefix, and nonmatching target Bundle ID; test that P12 certificate DER membership accepts only an exact `DeveloperCertificates` entry.

Run:

```bash
swiftc -o /tmp/easysign-entitlement-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift EasySign/Core/Resigning/Model/EntitlementReconciler.swift Tests/EntitlementReconcilerTests.swift && /tmp/easysign-entitlement-tests
swiftc -o /tmp/easysign-profile-context-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift Tests/ZSignProfileContextTests.swift && /tmp/easysign-profile-context-tests
```

Expected: compilation fails because `EntitlementReconciler` does not exist.

- [ ] **Step 2: Add raw profile identity fields**

In `MobileProvision`, retain the complete top-level `ApplicationIdentifierPrefix`, `TeamIdentifier`, and `DeveloperCertificates` arrays; raw entitlement `application-identifier`; and raw entitlement team identifier. Adapt them into `ZSignProfileContext.validated(targetBundleIdentifier:now:) throws`: reject missing/expired profile dates, empty/non-unique team arrays, inconsistent team IDs, no exact app-ID-prefix match for the raw pattern prefix, and an application-ID pattern that does not match the target candidate. Deduplicate historical app-ID prefixes for matching rather than rejecting the whole array. Derive `applicationIdentifier` only for display compatibility; do not use `teamId` to rewrite the raw application identifier. `ZSignProfileContext.containsCertificateDER(_:)` must use exact DER equality.

- [ ] **Step 3: Implement the pure reconciler**

Create `EntitlementReconciliationInput` with requested custom XML, original entitlement dictionary, source application identifier captured from the original Mach-O (not custom XML), a validated profile context, and target bundle ID. Create `EntitlementReconciliationResult` containing final entitlements, XML, and an ordered `keep/remove/rewrite` change log. `EntitlementReconciler.reconcile(_:) throws -> EntitlementReconciliationResult` applies these invariant rules:

```swift
// Always derive these from the selected profile; never preserve source values.
result["application-identifier"] = "\\(prefix).\\(targetBundleId)"
result["com.apple.developer.team-identifier"] = teamIdentifier

// get-task-allow false is omitted, not serialized, because the vendored ZSign
// treats key presence as CS_EXECSEG_ALLOW_UNSIGNED.
if requestedBool && profileBool { result["get-task-allow"] = true }
```

For every remaining source key, remove it when profile lacks the key. Use explicit policies for identity keys, Boolean claims, `aps-environment` profile authority, `keychain-access-groups` wildcard-array subsets, `com.apple.developer.icloud-container-environment` profile-array/scalar containment, and `com.apple.developer.icloud-services` profile-set containment. For keychain groups, capture the signed original `application-identifier` before reading a custom file; rewrite only that exact old default group to the new candidate application identifier, only if a `keychain-access-groups` entry authorizes it, then validate all remaining groups as requested. The fallback only accepts exact Bool/String, exact-subset Array/Dictionary; unknown wildcard or type-crossing relations throw. Validate recursively that output leaves are only Bool or String before serializing a plist XML string.

- [ ] **Step 4: Run the reconciler test executable**

Run the Step 1 command. Expected: every assertion passes and output ends in `ALL PASS`.

- [ ] **Step 5: Commit task 1**

```bash
git add EasySign/Core/Resigning/Model/MobileProvision.swift EasySign/Core/Resigning/Model/EntitlementReconciler.swift Tests/EntitlementReconcilerTests.swift
git add EasySign/Core/Resigning/Model/ZSignProfileContext.swift Tests/ZSignProfileContextTests.swift
git commit -m "feat: reconcile zsign entitlements against profile"
```

### Task 2: Mach-O topology preflight and independent signature inspection

**Files:**
- Create: `EasySign/Core/Resigning/Model/MachOExecutableScanner.swift`
- Create: `EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift`
- Create: `Tests/MachOZSignSafetyTests.swift`

- [ ] **Step 1: Write failing Mach-O safety tests**

Build synthetic thin, fat, and fat64 data. Assert detection of file type `MH_EXECUTE` versus `MH_DYLIB`; reject a nested executable; reject an injected dylib containing any executable slice; and inspect an unsigned/invalid Code Signature blob as an error rather than crashing. Include a synthetic SuperBlob with mismatched XML and DER values and a CodeDirectory with `CS_EXECSEG_ALLOW_UNSIGNED` to demonstrate the intended verification failure.

Run: `swiftc -o /tmp/easysign-macho-zsign-tests EasySign/Core/Resigning/Model/MachOExecutableScanner.swift EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift Tests/MachOZSignSafetyTests.swift && /tmp/easysign-macho-zsign-tests`

Expected: compilation fails because the scanner and inspector types do not exist.

- [ ] **Step 2: Implement bounded Mach-O parsing and ZSign preflight**

Implement one internal byte-reader with overflow-safe range checks. Recognize thin 32/64 and fat/fat64 headers, return every slice's file type, and reject truncated/overlapping/out-of-range slices. Recursively enumerate regular files under the app without following directory symlinks; fail if a symlink resolves outside the app root. `validateAppTopology` permits only the declared main executable as `MH_EXECUTE`; `validateInjectedDylib` requires all slices to be `MH_DYLIB`. The orchestration must call `validateAppTopology` and `validateInjectedDylib` before changing `Info.plist` or asking ZSign to process input, then rerun `validateAppTopology` against the unzipped candidate before publication.

- [ ] **Step 3: Implement signature inspector and minimal DER decoder**

Parse each slice's `LC_CODE_SIGNATURE`, SuperBlob, XML entitlement slot, DER entitlement slot, and every primary/alternate CodeDirectory. For the sole allowed `MH_EXECUTE`, require ZSign's CodeDirectory version `0x20400`, expected identifier/team ID, XML/DER semantic equality with the reconciled expected entitlements across all slices, and zero `CS_EXECSEG_ALLOW_UNSIGNED` when `get-task-allow` is absent. For every non-executable Mach-O, require entitlement slots to be absent or semantically empty. Decode only the ZSign DER forms (`Bool`, UTF-8 string, sequence array, set dictionary); reject malformed length/depth/count data and unsupported tags. Expose structural inspection only—CMS/page/resource validation remains `codesign --verify` in the orchestrator.

- [ ] **Step 4: Run the Mach-O safety executable**

Run the Step 1 command. Expected: every assertion passes and output ends in `ALL PASS`.

- [ ] **Step 5: Commit task 2**

```bash
git add EasySign/Core/Resigning/Model/MachOExecutableScanner.swift EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift Tests/MachOZSignSafetyTests.swift
git commit -m "feat: add zsign Mach-O safety checks"
```

### Task 3: Candidate IPA publication

**Files:**
- Create: `EasySign/Core/Resigning/Model/ResignOutputPublisher.swift`
- Create: `Tests/ResignOutputPublisherTests.swift`

- [ ] **Step 1: Write failing output publication tests**

In a temporary directory, assert `candidateURL` is a sibling hidden `.EasySign-*.tmp.ipa`; a failed candidate cleanup preserves an existing final IPA byte-for-byte; and publish replaces final only after a candidate exists.

Run: `swiftc -o /tmp/easysign-output-tests EasySign/Core/Resigning/Model/ResignOutputPublisher.swift Tests/ResignOutputPublisherTests.swift && /tmp/easysign-output-tests`

Expected: compilation fails because `ResignOutputPublisher` does not exist.

- [ ] **Step 2: Implement publisher**

Create the final parent directory if needed. Generate a UUID candidate in the final IPA directory. `discardCandidate()` only deletes the candidate. `publish()` uses `replaceItemAt` where a final exists and `moveItem` otherwise, and throws if candidate is absent. Never remove the final output before validation succeeds.

- [ ] **Step 3: Run output publication tests**

Run the Step 1 command. Expected: every assertion passes and output ends in `ALL PASS`.

- [ ] **Step 4: Commit task 3**

```bash
git add EasySign/Core/Resigning/Model/ResignOutputPublisher.swift Tests/ResignOutputPublisherTests.swift
git commit -m "feat: publish zsign ipa atomically"
```

### Task 4: Wire the components into the ZSign backend

**Files:**
- Modify: `EasySign/Core/Resigning/Model/ResignTask.swift`
- Create: `Tests/ZSignEntitlementIntegrationSourceTests.sh`
- Create: `Tests/ZSignManualSmokeTest.md`

- [ ] **Step 1: Write the failing integration/source guard**

Assert the ZSign method validates topology and injected dylibs before `appBundle.update`, captures original signed app-ID identity before `appBundle.update`, rejects an expired/inconsistent selected profile, calls ZSign-only reconciliation rather than `updateEntitlements`, logs reconciliation changes, checks P12 membership against the profile, signs to a `ResignOutputPublisher` candidate, checks exact embedded profile bytes and post-sign profile authorization, reruns topology validation on the candidate, invokes `codesign --verify --deep --strict --verbose=4`, structurally verifies the candidate against reconciled entitlements, and publishes only afterward. Assert `startAppleResign` still calls the old `updateEntitlements` method and no file under `EasySign/Vendor/ZSign` is changed by this branch.

Run: `sh Tests/ZSignEntitlementIntegrationSourceTests.sh`

Expected: exits non-zero until the integration exists.

- [ ] **Step 2: Implement ZSign-only orchestration**

In `startZSignResign`, parse the selected profile, obtain the target bundle ID, then validate profile expiry/team/prefix/candidate invariants. Before changing `Info.plist`, validate the source app topology and injected dylibs, then read original signed entitlements and original signed `application-identifier`; custom XML changes only requested claims, never that identity capture. Load P12 and reject if its DER is absent from profile `DeveloperCertificates`. Reconcile the entitlement XML and log every change, sign to `ResignOutputPublisher.candidateURL`, unzip candidate to a workspace verification directory, require exactly one direct `Payload/*.app`, exact `embedded.mobileprovision` bytes, reparse/validate that embedded profile, target bundle ID/executable, rerun candidate topology validation, perform post-sign profile authorization, and inspect every Mach-O against the reconciled expected result. Then execute:

```swift
try TaskCenter.execute(lanuchPath: "/usr/bin/codesign",
    arguments: ["--verify", "--deep", "--strict", "--verbose=4", verifiedApp.path])
try publisher.publish()
```

Use `defer { publisher.discardCandidate() }` so every pre-publish failure preserves the prior final IPA. Do not alter `startAppleResign`, `updateEntitlements`, or vendored ZSign sources.

- [ ] **Step 3: Confirm synchronized target membership and run source guard and focused regression executables**

The `EasySign/` source tree is a filesystem-synchronized root group, so new production Swift sources under it are automatically part of the app target. Do not edit `project.pbxproj` or add signing sources to the Quick Look/Thumbnail extension targets.

Run:

```bash
sh Tests/ZSignEntitlementIntegrationSourceTests.sh
swiftc -o /tmp/easysign-entitlement-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift EasySign/Core/Resigning/Model/EntitlementReconciler.swift Tests/EntitlementReconcilerTests.swift && /tmp/easysign-entitlement-tests
swiftc -o /tmp/easysign-profile-context-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift Tests/ZSignProfileContextTests.swift && /tmp/easysign-profile-context-tests
swiftc -o /tmp/easysign-macho-zsign-tests EasySign/Core/Resigning/Model/MachOExecutableScanner.swift EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift Tests/MachOZSignSafetyTests.swift && /tmp/easysign-macho-zsign-tests
swiftc -o /tmp/easysign-output-tests EasySign/Core/Resigning/Model/ResignOutputPublisher.swift Tests/ResignOutputPublisherTests.swift && /tmp/easysign-output-tests
```

Expected: all commands exit zero.

- [ ] **Step 4: Build and commit task 4**

```bash
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build
git add EasySign/Core/Resigning/Model/ResignTask.swift Tests/ZSignEntitlementIntegrationSourceTests.sh Tests/ZSignManualSmokeTest.md
git commit -m "fix: validate zsign entitlement claims before publish"
```

### Task 5: Final verification and review

**Files:**
- Verify: all files above

- [ ] **Step 1: Run the full focused verification suite**

Run the four Task 4 commands and the pre-existing reader regression:

```bash
swiftc -o /tmp/easysign-macho-reader-tests EasySign/Core/Resigning/Model/IPAPreviewService.swift EasySign/Core/Resigning/Model/MachOEntitlementsReader.swift Tests/MachOEntitlementsTests.swift && /tmp/easysign-macho-reader-tests
swiftc -o /tmp/easysign-profile-context-tests EasySign/Core/Resigning/Model/ZSignProfileContext.swift Tests/ZSignProfileContextTests.swift && /tmp/easysign-profile-context-tests
```

- [ ] **Step 2: Build Debug configuration**

Run: `xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Execute the manual real-signing acceptance procedure**

Follow `Tests/ZSignManualSmokeTest.md` using an IPA that originally contains `get-task-allow=true` and an App Group plus an enterprise profile which has `get-task-allow=false` and omits the App Group. Confirm candidate packaging succeeds, the final IPA replaces the prior output only after verification, the IPA installs on a physical device, and the post-sign XML has neither the App Group nor `get-task-allow`. Record the exact IPA/profile certificate identifiers and device install result in the test run log. If no authorized real credentials/device are present in the execution environment, leave this step explicitly unverified rather than treating automated tests as installation proof.

- [ ] **Step 4: Inspect the final diff and source boundaries**

Run: `git diff --check main...HEAD` and `git diff --name-only main...HEAD`. Confirm no `EasySign/Vendor/ZSign/**` path and no Apple-path entitlement behavior changed.

- [ ] **Step 5: Request final code review, then use `superpowers:finishing-a-development-branch`**

Provide the verification output and the exact diff to the reviewer. Do not claim completion unless the reviewer’s issues are resolved and the above commands remain green.
