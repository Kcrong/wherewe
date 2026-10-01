# Wherewe

Wherewe is a native macOS 26 desktop app for local meeting recording,
transcription, translation, review, and export on Apple Silicon.

The app captures a selected microphone and optional CoreAudio system-input
route, transcribes audio with Apple SpeechAnalyzer, and translates text with
Apple Translation. Meeting data stays in local SQLite storage. There is no
listening port, network downloader, helper executable, or child process.

## Capabilities

- Independent microphone and system-input capture through CoreAudio.
- On-device transcription through Apple SpeechAnalyzer using the system model.
- Apple Translation for English, Korean, Japanese, and Chinese when the
  corresponding macOS language packs are installed.
- Meeting creation, title/context editing, recording recovery, and deletion.
- SQLite transcript persistence, meeting and transcript search, translation
  retry, and manual editing of persisted transcript rows through editable
  segments.
- Local PDF, Markdown, text, HTML, and CSV attachments up to 5 MB each.
- Global and meeting-specific glossary review.
- Local export of metadata, transcript, context, glossary, and attachments.

## Requirements

### Running the app

- macOS 26 or later.
- Apple Silicon (`arm64`).
- Apple SpeechAnalyzer availability and the selected recognition-language
  assets.
- Apple Translation language packs for each selected language pair.
- For system audio, a user-configured CoreAudio input route. Wherewe does not
  install or configure an audio loopback driver.

macOS owns Speech and Translation asset installation. Wherewe checks Speech
asset availability and can open Language & Region for system-managed packs; it
does not request, download, or install language assets itself.

### Building the app

- A macOS 26+ Apple Silicon development Mac.
- Xcode with the Swift 6.2 toolchain selected through `xcrun`.
- Node.js for source-contract tests.
- Standard macOS signing, disk-image, and notarisation tools.

## Build and test

The complete local gate is:

```bash
bash scripts/pre-push-macos.sh
```

It requires a clean worktree and an external writable scratch root selected in
this order: `KIROCREW_SCRATCH`, `RUNNER_TEMP`, then `TMPDIR`. It runs JavaScript
and shell syntax checks, the redacted public-content scanner, all Node source
contracts, Swift tests, native service checks, required real Apple Speech and
Apple Translation evidence, app launch/relaunch smoke tests, and DMG mount
verification. Artifacts remain outside the repository.

The automatic Test workflow runs Linux static contracts, then a macOS 26 ARM64
Swift build, unit tests, and native service checks for pull requests and `main`.
An explicit workflow dispatch adds real installed Apple runtime evidence plus app
and DMG packaging checks.

Detailed inventory and evidence semantics are in
[`docs/testing.md`](docs/testing.md).

## Application bundle

Build an ad-hoc signed app with:

```bash
bash scripts/build-macos-app.sh
```

The default output is `dist/macos/Wherewe.app`. The bundle contains the Wherewe
executable, `Info.plist`, and no embedded framework, language model, policy
payload, sidecar, or helper runtime. The hardened runtime remains enabled with
library validation intact. The app requests only the audio-input entitlement
needed for microphone capture.

Build and verify a DMG with:

```bash
bash scripts/build-macos-dmg.sh
bash scripts/test-macos-dmg.sh
```

## Local data and privacy

A default installation stores configuration and durable data beneath
`~/Library/Application Support/Wherewe/`. Directories use user-only `0700`
permissions; configuration, SQLite, attachment, and temporary spool files use
`0600` permissions.

SQLite stores meetings, transcripts, edited segments, translation state,
glossary entries, and attachment metadata. Attachment bodies remain separate
files in the configured files directory. Stored file paths are validated for
absolute-path, root-containment, regular-file, size, and symbolic-link safety
before read, export, or deletion.

Raw PCM is temporary and process-owned. Recording shutdown drains pending audio
before finalisation, and stale recording generations cannot write after a newer
claim takes ownership.

Exports are new user-only directories under the operating system temporary
location. Cancelling an export removes its partial directory. Deleting a
meeting removes its database rows and attempts to remove associated attachment
files; already-created exports remain until the user or operating system removes
them.

Wherewe itself sends no meeting content over a network. macOS may contact Apple
services to install or manage operating-system Speech and Translation assets.

## Signed releases

Pushing a `vMAJOR.MINOR.PATCH` tag that points exactly to the current
`origin/main` commit starts `.github/workflows/release-macos.yml`. The workflow:

1. Runs the complete non-secret release gate.
2. Validates tag and bundle metadata.
3. Imports an ephemeral Developer ID Application certificate.
4. Builds and verifies the signed app and DMG.
5. Notarises, staples, and Gatekeeper-assesses the DMG.
6. Publishes the versioned ARM64 DMG and SHA-256 file to the matching GitHub
   Release.

Required repository secrets are `MACOS_CERTIFICATE_P12_BASE64`,
`MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and
`APPLE_APP_SPECIFIC_PASSWORD`. They are unavailable to pull requests and are
referenced only after the non-secret gate succeeds.
