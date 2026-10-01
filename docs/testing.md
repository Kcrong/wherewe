# Testing Wherewe

This guide defines the current Apple-only validation surface and what each gate
proves. Source inventories are checked by `testing-strategy.test.js`.

## Current inventory

- Swift test sources: 24 files, 21 suites, 71 declared tests.
- Deterministic Swift baseline: 66 tests.
- Opt-in Swift runtime and hardware checks: 5 tests across 3 environment keys.
- Node source contracts: 13 files, 54 declared tests.
- `MeetingTranscriberCoreChecks` is a separate executable smoke contract.
- App and DMG checks are shell integration tests, not GUI automation.

Swift compilation and execution require macOS 26+ on ARM64. Linux executes the
Node contracts, public-content scanner, JSON checks, and shell syntax checks.

## Swift source inventory

| Source | Scope |
| --- | --- |
| `AttachmentPathSecurityTests.swift` | Stored attachment containment and safe deletion |
| `CaptureLevelMeterTests.swift` | Level mapping, cadence, and channel isolation |
| `CaptureRegressionTests.swift` | Commit boundaries, input policy, deadlines, and spool ownership |
| `CoreAudioInputPlanningTests.swift` | Microphone and system-input planning |
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
| `NativeServiceTests.swift` | Setup, CRUD, persistence, recording, files, glossary, and export |
| `NativeTranscriptNoiseTests.swift` | Noise filtering boundaries |
| `PCMFramerTests.swift` | Frame sizing, channel order, residual input, and reset |
| `RealtimeOwnershipSecurityTests.swift` | Generation ownership and persistence fencing |
| `RecordingFinalizationRecoveryTests.swift` | Retry and recovery for exactly-once finalisation |
| `StoragePathSecurityTests.swift` | Absolute roots, symbolic links, reveal containment, and modes |
| `SyntheticSpeechFixture.swift` | Runtime-generated audio helper |
| `TranslationRetryRecoveryTests.swift` | Persisted Apple Translation failure and restart recovery |

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
| Manual Test dispatch | Automatic evidence plus real Apple Speech and Translation, app launch/relaunch, and DMG mount verification |
| Local pre-push gate | Same native evidence as manual Test plus clean-worktree checks before and after |
| Release workflow | Pre-secret release gate, then Developer ID signing, notarisation, stapling, Gatekeeper assessment, checksum, and release upload |
| Physical hardware run | Two explicit microphone/system-input route tests on a prepared Mac |

The local gate is:

```bash
bash scripts/pre-push-macos.sh
```

It selects external scratch storage from `KIROCREW_SCRATCH`, `RUNNER_TEMP`, or
`TMPDIR`, in that order. No successful gate leaves build or runtime artifacts in
the repository.

## Runtime evidence

| Environment key | Tests | Scripted requirement |
| --- | ---: | --- |
| `WHEREWE_NATIVE_REAL_APPLE_SPEECH` | 2 | Required by local, manual macOS, and release gates |
| `WHEREWE_NATIVE_REAL_APPLE_TRANSLATION` | 1 | Required by local, manual macOS, and release gates |
| `WHEREWE_NATIVE_REAL_HARDWARE` | 2 | Explicit physical-Mac run only |

Stable success markers:

- `apple-speech-accurate`
- `apple-speech-commit-boundary`
- `apple-translation`
- `physical-dual-input`
- `physical-system-only`

The first three markers are required by every full macOS gate. A marker counts
only when the filtered Swift command also exits successfully.

## Risk and evidence matrix

| Risk | Current evidence | Remaining work |
| --- | --- | --- |
| Repository source safety | Exact manifest, redacted scanner, identity and privacy contracts | Re-run on every change |
| Meeting and SQLite behavior | Service, migration, mutation, translation, and core-check suites | Execute on supported macOS hardware |
| CoreAudio and realtime ownership | Deterministic framing/synchronization suites and generation fencing | Hardware, TCC, route changes, unplug, and sleep/wake remain manual |
| Apple Speech and Translation | Required generated-speech and installed-pack evidence | Host asset availability must be maintained |
| Storage and attachments | Path-policy contracts plus security tests | Add user-facing permission-error coverage |
| Export rollback | Collision and cancellation tests require complete partial-directory removal | Add destination-selection GUI coverage if introduced |
| Retry and recovery | Translation restart and recording finalisation tests | Keep retries explicit and bounded |
| Bundle and DMG | Architecture, minimum OS, signatures, entitlement, launch/relaunch, mounted layout, and payload rejection | Validate final Developer ID and notarised artifacts |
| Release secrets | Pre-secret release gate precedes every credential reference | Protect release environment and approvals |
| Native UI | No XCUIAutomation target | Add deterministic onboarding, recording, file, glossary, and export flows |
| Coverage | No coverage baseline | Add a stable risk-focused coverage threshold |

This guide does not treat Linux source inspection as macOS runtime evidence.
