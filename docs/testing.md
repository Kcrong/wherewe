# Testing Wherewe

This guide defines the current Apple-only validation surface and what each gate
proves. Source inventories are checked by `testing-strategy.test.js`.

## Current inventory

- Swift test sources: 26 files, 23 suites, 91 declared tests.
- Deterministic Swift baseline: 86 tests.
- Opt-in Swift runtime and hardware checks: 5 tests across 3 environment keys.
- Node source contracts: 13 files, 64 declared tests.
- `MeetingTranscriberCoreChecks` is a separate executable smoke contract.
- App and DMG checks are shell integration tests, not GUI automation.

Swift compilation and execution require macOS 26+ on ARM64. Linux executes the
Node contracts, public-content scanner, JSON checks, and shell syntax checks.

## Swift source inventory

| Source | Scope |
| --- | --- |
| `AttachmentPathSecurityTests.swift` | Stored attachment containment, deletion failures, and retry recovery |
| `CaptureLevelMeterTests.swift` | Level mapping, cadence, and channel isolation |
| `CaptureRegressionTests.swift` | Commit boundaries, input policy, deadlines, and spool ownership |
| `CoreAudioInputPlanningTests.swift` | Microphone and system-input planning |
| `DualInputSynchronizerTests.swift` | Input-loss silence synthesis, recovery, and bounded buffering |
| `ExportFailureSecurityTests.swift` | Export rollback after collision or cancellation |
| `HostTimeAudioResamplerTests.swift` | Sample-rate continuity and drift |
| `LiveNativeServiceContractTests.swift` | Setup-required startup without an auxiliary runtime |
| `ModelsTests.swift` | Codable service and protocol compatibility |
| `NativeDatabaseMigrationTests.swift` | Additive migration and transcript preservation |
| `NativePhysicalAudioTests.swift` | Opt-in physical CoreAudio routes |
| `NativePreferencesTests.swift` | Preference import and fallback |
| `NativeRealtimeIsolationTests.swift` | Active connection and reconnect behavior |
| `NativeRuntimeEvidence.swift` | Runtime opt-in conditions and evidence markers |
| `NativeRuntimeIntegrationTests.swift` | Real Apple Speech and Apple Translation |
| `NativeServiceConfigurationTests.swift` | Defaults and compatibility aliases |
| `NativeServiceTestDependencies.swift` | Explicit deterministic Speech and Translation test dependencies |
| `NativeServiceTests.swift` | Setup, CRUD, persistence, invalid database rollback, recording, files, glossary, and export |
| `NativeTranscriptNoiseTests.swift` | Noise filtering boundaries |
| `PCMFramerTests.swift` | Frame sizing, channel order, residual input, and reset |
| `RealtimeOwnershipSecurityTests.swift` | Generation ownership and persistence fencing |
| `RecordingFinalizationRecoveryTests.swift` | Retry and recovery for exactly-once finalisation and complete PCM delivery |
| `StoragePathSecurityTests.swift` | Absolute roots, symbolic links, reveal containment, and modes |
| `SyntheticSpeechFixture.swift` | Runtime-generated audio helper |
| `TranslationRetryRecoveryTests.swift` | Persisted Apple Translation failure and restart recovery |
| `TranslationStalenessTests.swift` | Source-version, source-hash, and target-language freshness fencing |

## Node source-contract inventory

Native application and release contracts:

- `macos-native-layout.test.js`
- `macos-release-workflow.test.js`
- `native-contract-surface.test.js`

Repository security, privacy, and strategy contracts:

- `filesystem-boundaries.test.js`
- `source-manifest.test.js`
- `privacy-boundaries.test.js`
- `public-content-scan.test.js`
- `realtime-ownership.test.js`
- `spool-ownership.test.js`
- `storage-security.test.js`
- `testing-strategy.test.js`
- `translation-retry.test.js`
- `wherewe-identity.test.js`

## Execution profiles

| Profile | Required evidence |
| --- | --- |
| Pull request and `main` push | Linux syntax/scanner/contracts followed by macOS 26 ARM64 Swift build, unit tests, and core checks |
| Manual Test dispatch | Automatic evidence, an advisory Apple runtime probe, app launch/relaunch, DMG mount verification, and a directly downloadable `.dmg` artifact retained for 7 days |
| Local pre-push gate | Deterministic tests plus required real Apple Speech and Translation evidence, app launch/relaunch, and DMG mount verification |
| Release workflow | Pre-secret deterministic and packaging gate, then a Developer ID/notarized DMG when all five release secrets exist or a clearly marked ad-hoc test DMG when none exist; partial configuration fails closed |
| Physical hardware run | Two explicit microphone/system-input route tests on a prepared Mac |

The local gate is:

```bash
bash scripts/pre-push-macos.sh
```

It selects external scratch storage from `KIROCREW_SCRATCH`, `RUNNER_TEMP`, or
`TMPDIR`, in that order. No successful gate leaves build or runtime artifacts in
the repository.

A manually dispatched Test workflow produces an unsigned, non-notarized DMG
containing an ad-hoc-signed app for hands-on validation. The workflow summary
links directly to the `.dmg` and its SHA-256 digest; testers must be signed into
GitHub. macOS may require an explicit Open action because this test artifact is
not a signed release.

A version tag creates a draft release with the DMG, checksum, and commit-subject
release notes. All five release secrets select Developer ID signing and
notarisation; zero secrets select an ad-hoc test build with a warning in the draft;
a partial secret set fails before the final release build and upload. An ad-hoc
draft must not be published as a production release.

## Runtime evidence

| Environment key | Tests | Scripted requirement |
| --- | ---: | --- |
| `WHEREWE_NATIVE_REAL_APPLE_SPEECH` | 2 | Required by the local gate; Test and release workflows use advisory `auto` mode |
| `WHEREWE_NATIVE_REAL_APPLE_TRANSLATION` | 1 | Required by the local gate; Test and release workflows use advisory `auto` mode |
| `WHEREWE_NATIVE_REAL_HARDWARE` | 2 | Explicit physical-Mac run only |

Stable success markers:

- `apple-speech-accurate`
- `apple-speech-commit-boundary`
- `apple-translation`
- `physical-dual-input`
- `physical-system-only`

The first three markers are required by the local gate. Manual Test and release
workflows report what the hosted runner can use but still package a DMG when those
assets are unavailable. A marker counts only when the filtered Swift command also
exits successfully.

## Risk and evidence matrix

| Risk | Current evidence | Remaining work |
| --- | --- | --- |
| Repository source safety | Exact manifest, redacted scanner, identity and privacy contracts | Re-run on every change |
| Meeting and SQLite behavior | Service, migration, mutation, translation, and core-check suites | Execute on supported macOS hardware |
| CoreAudio and realtime ownership | Deterministic framing/synchronization suites and generation fencing | Hardware, TCC, route changes, unplug, and sleep/wake remain manual |
| Apple Speech and Translation | Advisory hosted probes plus required local generated-speech and installed-pack evidence | Test each draft-release DMG with installed assets on a real Mac before publishing |
| Storage and attachments | Path-policy contracts plus security, deletion-failure, and retry tests | Exercise sandbox and external-volume permission failures manually |
| Export rollback and result scope | Collision and cancellation rollback plus selected-meeting request ownership | Add destination-selection GUI coverage if introduced |
| Retry and recovery | Translation restart and recording finalisation tests | Keep retries explicit and bounded |
| Bundle and DMG | Architecture, minimum OS, signature mode, entitlement, launch/relaunch, mounted layout, payload rejection, and draft asset checksum | Publish only a Developer ID signed and notarised draft; keep ad-hoc drafts for hands-on testing |
| Release secrets | Pre-secret release gate precedes credential inspection; zero/all/partial sets select ad-hoc/signed/fail-closed modes | Protect release environment and configure all five secrets before production publication |
| Native UI | No XCUIAutomation target | Add deterministic onboarding, recording, file, glossary, and export flows |
| Coverage | No coverage baseline | Add a stable risk-focused coverage threshold |

This guide does not treat Linux source inspection or an advisory hosted probe as
required macOS runtime evidence.
