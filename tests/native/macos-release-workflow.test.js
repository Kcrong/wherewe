"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const release = read(".github/workflows/release-macos.yml");
const ci = read(".github/workflows/test.yml");
const appBuild = read("scripts/build-macos-app.sh");
const appSmoke = read("scripts/test-macos-app-bundle.sh");
const dmgBuild = read("scripts/build-macos-dmg.sh");
const dmgSmoke = read("scripts/test-macos-dmg.sh");
const localGate = read("scripts/pre-push-macos.sh");
const releaseGate = read("scripts/test-release-prerequisites.sh");
const releaseNotes = read("scripts/generate-release-notes.sh");

function actionReferences(source) {
  return [...source.matchAll(/^\s*-?\s*uses:\s*(\S+)/gm)].map((match) => match[1]);
}

function namedStep(source, name) {
  const marker = `      - name: ${name}\n`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow step: ${name}`);
  const next = source.indexOf("\n      - ", start + marker.length);
  return source.slice(start, next === -1 ? source.length : next);
}

test("automatic CI runs Linux static then macOS build unit and core checks", () => {
  assert.match(ci, /push:\s*\n\s+branches: \[main\]/);
  assert.match(ci, /^\s{2}pull_request:\s*$/m);
  assert.match(ci, /^\s{2}workflow_dispatch:\s*$/m);
  assert.match(ci, /static:[\s\S]*runs-on: ubuntu-24\.04/);
  assert.match(ci, /macos:[\s\S]*needs: static[\s\S]*runs-on: macos-26/);
  assert.match(namedStep(ci, "Build Swift package"), /xcrun swift build/);
  assert.match(namedStep(ci, "Run Swift unit tests"), /xcrun swift test/);
  assert.match(namedStep(ci, "Run native service contract checks"), /MeetingTranscriberCoreChecks/);
  assert.match(namedStep(ci, "Probe available Apple runtime assets"), /if: \$\{\{ github\.event_name == 'workflow_dispatch' \}\}/);
  assert.match(ci, /node scripts\/scan-public-content\.js/);
  assert.match(ci, /node --test tests\/native\/\*\.test\.js tests\/public\/\*\.test\.js/);
});

test("manual CI publishes a mount-verified test DMG without requiring host assets", () => {
  assert.match(localGate, /WHEREWE_NATIVE_REAL_APPLE_SPEECH/);
  assert.match(localGate, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION/);
  assert.match(localGate, /apple-speech-accurate/);
  assert.match(localGate, /apple-speech-commit-boundary/);
  assert.match(localGate, /apple-translation/);
  assert.match(localGate, /NativeRuntimeIntegrationTests/);

  const releaseProbeStep = namedStep(release, "Probe available Apple runtime assets");
  assert.match(releaseProbeStep, /continue-on-error: true/);
  assert.match(releaseProbeStep, /timeout-minutes: 5/);
  assert.match(releaseProbeStep, /WHEREWE_NATIVE_REAL_APPLE_SPEECH: 'auto'/);
  assert.match(releaseProbeStep, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION: 'auto'/);
  assert.match(releaseProbeStep, /NativeRuntimeIntegrationTests/);
  assert.doesNotMatch(releaseGate, /WHEREWE_NATIVE_REAL_APPLE_(?:SPEECH|TRANSLATION)|NativeRuntimeIntegrationTests/);

  const buildStep = namedStep(ci, "Build native app");
  const smokeStep = namedStep(ci, "Smoke-test clean launch and relaunch");
  const dmgStep = namedStep(ci, "Build and mount-verify DMG");
  const uploadStep = namedStep(ci, "Upload downloadable test DMG");
  const summaryStep = namedStep(ci, "Publish test DMG download details");
  const probeStep = namedStep(ci, "Probe available Apple runtime assets");
  const orderedNames = [
    "Build native app",
    "Smoke-test clean launch and relaunch",
    "Build and mount-verify DMG",
    "Upload downloadable test DMG",
    "Publish test DMG download details",
    "Probe available Apple runtime assets",
  ];
  const indices = orderedNames.map((name) => ci.indexOf(`name: ${name}`));
  assert.ok(indices.every((value, index) => index === 0 || value > indices[index - 1]));

  for (const step of [buildStep, smokeStep, dmgStep, uploadStep]) {
    assert.match(step, /if: \$\{\{ github\.event_name == 'workflow_dispatch' \}\}/);
  }
  assert.match(ci, /group: native-test-\$\{\{ github\.workflow \}\}-\$\{\{ github\.event_name \}\}-\$\{\{ github\.ref \}\}/);
  assert.match(ci, /cancel-in-progress: \$\{\{ github\.event_name != 'workflow_dispatch' \}\}/);

  assert.match(dmgStep, /bash scripts\/test-macos-dmg\.sh/);
  assert.match(dmgStep, /dmg_candidates=/);
  assert.match(dmgStep, /\$\{#dmg_candidates\[@\]\}.*-eq 1/);
  assert.match(dmgStep, /GITHUB_RUN_ID/);
  assert.match(dmgStep, /GITHUB_RUN_ATTEMPT/);

  assert.match(uploadStep, /uses: actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7\.0\.1/);
  assert.match(uploadStep, /path: \$\{\{ env\.WHEREWE_DMG_OUTPUT_DIR \}\}\/Wherewe-\*-arm64-run-\$\{\{ github\.run_id \}\}-attempt-\$\{\{ github\.run_attempt \}\}\.dmg/);
  assert.match(uploadStep, /if-no-files-found: error/);
  assert.match(uploadStep, /retention-days: 7/);
  assert.doesNotMatch(uploadStep, /overwrite:/);
  assert.match(uploadStep, /archive: false/);

  assert.match(summaryStep, /steps\.upload-test-dmg\.outputs\.artifact-url/);
  assert.match(summaryStep, /steps\.upload-test-dmg\.outputs\.artifact-digest/);
  assert.match(summaryStep, /GitHub sign-in is required/);
  assert.match(summaryStep, /unsigned, non-notarized DMG containing an ad-hoc-signed app/);

  assert.match(probeStep, /continue-on-error: true/);
  assert.match(probeStep, /timeout-minutes: 5/);
  assert.match(probeStep, /WHEREWE_NATIVE_REAL_APPLE_SPEECH: 'auto'/);
  assert.match(probeStep, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION: 'auto'/);
  assert.match(probeStep, /--filter NativeRuntimeIntegrationTests/);
  assert.doesNotMatch(ci, /name: Require real Apple Speech and Translation evidence/);
});

test("local and release gates keep artifacts outside the repository", () => {
  for (const source of [localGate, releaseGate]) {
    assert.match(source, /uname -m\)" == "arm64"/);
    assert.match(source, /MACOS_MAJOR" -ge 26/);
    assert.match(source, /KIROCREW_SCRATCH/);
    assert.match(source, /RUNNER_TEMP/);
    assert.match(source, /TMPDIR/);
    assert.match(source, /scratch root must be outside the repository/);
    assert.match(source, /status --porcelain=v1 -z --untracked-files=all/g);
    assert.match(source, /(?:node|"\$NODE_BIN") --test tests\/native\/\*\.test\.js tests\/public\/\*\.test\.js/);
    assert.match(source, /MeetingTranscriberCoreChecks/);
    assert.match(source, /test-macos-app-bundle\.sh/);
    assert.match(source, /test-macos-dmg\.sh/);
  }
});

test("app and DMG packaging reject non-system payloads", () => {
  assert.match(appBuild, /for forbidden_directory in Frameworks Agents Models/);
  assert.match(appSmoke, /for forbidden_directory in Frameworks Agents Models Sidecar Helpers/);
  assert.match(dmgSmoke, /for forbidden_directory in Frameworks Agents Models Sidecar Helpers/);
  for (const source of [appBuild, appSmoke, dmgSmoke]) {
    assert.match(source, /\.framework/);
    assert.match(source, /\.xcframework/);
    assert.match(source, /\.mlmodel/);
    assert.match(source, /\.bin/);
  }
  assert.doesNotMatch(appBuild, /install_name_tool|PlistBuddy/);
  const entitlement = read("macos/Resources/MeetingTranscriber.entitlements");
  const entitlementKeys = [...entitlement.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]);
  assert.deepEqual(entitlementKeys, ["com.apple.security.device.audio-input"]);
  assert.match(appBuild, /codesign --verify --deep --strict/);
  assert.match(appSmoke, /unexpectedly spawned child processes/);
});

test("release is tag-bound and publishes a draft with commit-message notes and a versioned ARM64 DMG", () => {
  assert.match(release, /^\s{4}tags:\s*$/m);
  assert.match(release, /^\s{2}workflow_dispatch:\s*$/m);
  assert.match(release, /\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$/);
  assert.match(release, /Wherewe-\$RELEASE_VERSION-arm64\.dmg/);
  assert.match(release, /shasum -a 256/);
  assert.match(release, /persist-credentials: false/);
  assert.ok(release.includes("group: macos-release-${{ inputs.release_tag || github.ref_name }}"));

  const validationIndex = release.indexOf("name: Validate release tag before repository scripts");
  const gateIndex = release.indexOf("name: Run complete non-secret release gate");
  const firstSecret = release.indexOf("${{ secrets.");
  assert.ok(validationIndex >= 0 && validationIndex < gateIndex && gateIndex < firstSecret);
  const validationStep = namedStep(release, "Validate release tag before repository scripts");
  assert.match(validationStep, /git checkout --detach "\$TAG_COMMIT"/);
  assert.match(validationStep, /git rev-parse --verify HEAD/);
  assert.match(validationStep, /git merge-base --is-ancestor "\$TAG_COMMIT" origin\/main/);
  assert.match(validationStep, /current origin\/main history/);

  const notesStep = namedStep(release, "Generate release notes from commit messages");
  assert.match(notesStep, /bash scripts\/generate-release-notes\.sh "\$RELEASE_TAG" "\$RELEASE_NOTES_PATH"/);
  assert.match(releaseNotes, /git rev-list --first-parent/);
  assert.match(releaseNotes, /git tag --points-at "\$commit"/);
  assert.match(releaseNotes, /git log --reverse --format=/);

  const releaseStep = namedStep(release, "Create draft GitHub Release");
  const remoteTagLookupIndex = releaseStep.indexOf("git ls-remote --exit-code origin");
  const remoteTagComparisonIndex = releaseStep.indexOf('[[ "$REMOTE_TAG_COMMIT" == "$TAG_COMMIT" ]]');
  const releaseCreationIndex = releaseStep.indexOf("gh release create");
  assert.ok(remoteTagLookupIndex >= 0 && remoteTagLookupIndex < remoteTagComparisonIndex);
  assert.ok(remoteTagComparisonIndex < releaseCreationIndex);
  assert.match(releaseStep, /refs\/tags\/\$RELEASE_TAG\^\{\}/);
  assert.match(releaseStep, /peeled != "" \? peeled : direct/);
  assert.match(releaseStep, /git rev-parse --verify HEAD/);
  assert.match(
    releaseStep,
    /moved after validation; refusing to publish mismatched assets\." >&2\n\s+exit 1\n\s+\}\n\s+gh release create/,
  );
  assert.match(releaseStep, /gh release create/);
  assert.match(releaseStep, /--verify-tag/);
  assert.match(releaseStep, /--notes-file "\$RELEASE_NOTES_PATH"/);
  assert.match(releaseStep, /--draft/);
  assert.match(releaseStep, /already exists; refusing to modify it/);
  assert.doesNotMatch(releaseStep, /gh release (?:edit|upload)|--clobber|--generate-notes|--prerelease/);

  const probeStep = namedStep(release, "Probe available Apple runtime assets");
  assert.match(probeStep, /continue-on-error: true/);
  assert.match(probeStep, /timeout-minutes: 5/);
  assert.match(probeStep, /WHEREWE_NATIVE_REAL_APPLE_SPEECH: 'auto'/);
  assert.match(probeStep, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION: 'auto'/);
  assert.ok(release.indexOf("name: Create draft GitHub Release") < release.indexOf("name: Probe available Apple runtime assets"));
});

test("release notes use the nearest strict version tag and commit subjects", () => {
  const scratchRoot = process.env.KIROCREW_SCRATCH || process.env.RUNNER_TEMP || os.tmpdir();
  const repository = fs.mkdtempSync(path.join(scratchRoot, "wherewe-release-notes-"));
  const git = (...args) => execFileSync("git", args, {
    cwd: repository,
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_NOSYSTEM: "1" },
  });
  const commit = (subject) => {
    fs.appendFileSync(path.join(repository, "history.txt"), `${subject}\n`);
    git("add", "history.txt");
    git("-c", "commit.gpgsign=false", "commit", "-m", subject);
  };

  try {
    git("init", "-b", "main");
    git("config", "user.name", "Release Test");
    git("config", "user.email", "release-test@users.noreply.github.com");
    commit("chore: oldest release");
    git("-c", "tag.gpgSign=false", "tag", "v9.0.0");
    commit("fix: nearest previous release");
    git("-c", "tag.gpgSign=false", "tag", "v0.0.1");
    commit("feat: current release change");
    git("-c", "tag.gpgSign=false", "tag", "v0.0.2");

    const output = path.join(repository, "release-notes.md");
    execFileSync("bash", [path.join(ROOT, "scripts/generate-release-notes.sh"), "v0.0.2", output], {
      cwd: repository,
      env: process.env,
    });
    const notes = fs.readFileSync(output, "utf8");
    assert.match(notes, /Commit messages since `v0\.0\.1`/);
    assert.match(notes, /feat: current release change/);
    assert.doesNotMatch(notes, /fix: nearest previous release|chore: oldest release|v9\.0\.0/);
  } finally {
    fs.rmSync(repository, { recursive: true, force: true });
  }
});

test("release credentials select signed or ad-hoc draft mode after the non-secret gate", () => {
  const gateIndex = release.indexOf("name: Run complete non-secret release gate");
  const modeIndex = release.indexOf("name: Determine release signing mode");
  const firstSecret = release.indexOf("${{ secrets.");
  assert.ok(gateIndex >= 0 && modeIndex > gateIndex && firstSecret >= modeIndex);
  for (const name of [
    "MACOS_CERTIFICATE_P12_BASE64",
    "MACOS_CERTIFICATE_PASSWORD",
    "APPLE_ID",
    "APPLE_TEAM_ID",
    "APPLE_APP_SPECIFIC_PASSWORD",
  ]) {
    assert.ok(release.includes(`secrets.${name}`), `missing release secret: ${name}`);
    assert.ok(!releaseGate.includes(name), `non-secret gate references ${name}`);
  }

  const modeStep = namedStep(release, "Determine release signing mode");
  assert.match(modeStep, /id: release-mode/);
  assert.match(modeStep, /CONFIGURED_COUNT/);
  assert.match(modeStep, /0\)[\s\S]{0,120}echo 'signed=false' >> "\$GITHUB_OUTPUT"/);
  assert.match(modeStep, /5\)[\s\S]{0,120}echo 'signed=true' >> "\$GITHUB_OUTPUT"/);
  assert.match(modeStep, /\*\)[\s\S]{0,160}partially configured[\s\S]{0,80}exit 1/);
  assert.match(modeStep, /ad-hoc-signed and not notarized/);

  for (const name of ["Import Developer ID certificate", "Store and validate notarisation credentials", "Notarise and staple DMG"]) {
    assert.match(namedStep(release, name), /if: steps\.release-mode\.outputs\.signed == 'true'/);
  }
  const buildStep = namedStep(release, "Build and verify app");
  assert.match(buildStep, /SIGNED_RELEASE: \$\{\{ steps\.release-mode\.outputs\.signed \}\}/);
  assert.match(buildStep, /Authority=Developer ID Application:/);
  assert.match(buildStep, /Signature=adhoc/);
  assert.match(release, /notarytool submit/);
  assert.match(release, /stapler staple/);
  assert.match(release, /stapler validate/);
  assert.match(release, /spctl --assess --type open/);
  assert.match(release, /security delete-keychain/);
});

test("signed releases validate a copied app through Gatekeeper and LaunchServices", () => {
  const notarizeStep = namedStep(release, "Notarise and staple DMG");
  const installedStep = namedStep(release, "Validate installed app");
  assert.match(installedStep, /if: steps\.release-mode\.outputs\.signed == 'true'/);
  assert.ok(release.indexOf("name: Notarise and staple DMG") < release.indexOf("name: Validate installed app"));
  assert.ok(release.indexOf("name: Validate installed app") < release.indexOf("name: Create SHA-256 checksum"));

  assert.match(notarizeStep, /stapler validate/);
  assert.match(installedStep, /RUNNER_TEMP\/notarized-dmg-mount/);
  assert.match(installedStep, /RUNNER_TEMP\/notarized-app-install/);
  assert.match(installedStep, /hdiutil attach "\$WHEREWE_DMG_PATH"/);
  assert.match(installedStep, /ditto "\$MOUNT_POINT\/Wherewe\.app" "\$INSTALLED_APP"/);
  assert.match(installedStep, /hdiutil detach "\$MOUNT_POINT"/);
  assert.match(installedStep, /spctl --assess --type execute --verbose=4 "\$INSTALLED_APP"/);
  assert.match(installedStep, /WHEREWE_NATIVE_LAUNCH_MODE=launchservices/);
  assert.match(installedStep, /bash scripts\/test-macos-app-bundle\.sh/);
  assert.match(installedStep, /trap teardown EXIT INT TERM/);
  assert.ok(installedStep.indexOf("for path in") < installedStep.indexOf("trap teardown EXIT INT TERM"));
  assert.match(installedStep, /rm -rf "\$MOUNT_POINT" "\$INSTALL_ROOT" "\$SMOKE_ROOT"/);

  assert.match(appSmoke, /LAUNCH_MODE="\$\{WHEREWE_NATIVE_LAUNCH_MODE:-direct\}"/);
  assert.match(appSmoke, /\/usr\/bin\/open -n -W "\$APP_PATH"/);
  assert.match(appSmoke, /running_app_pids/);
  assert.match(appSmoke, /-f "\$SUPPORT\/data\/meetings\.db"/);
  assert.match(appSmoke, /kill -TERM "\$APP_PID"/);
});

test("all third-party workflow actions are pinned to full commits", () => {
  const references = [...actionReferences(ci), ...actionReferences(release)];
  assert.ok(references.length >= 3);
  assert.ok(references.every((reference) => /@[0-9a-f]{40}$/.test(reference)));
});

test("DMG builder preserves signed versioned arm64 output", () => {
  assert.match(dmgBuild, /DMG_NAME="Wherewe-\$\{VERSION\}-arm64\.dmg"/);
  assert.match(dmgBuild, /codesign --verify --deep --strict/);
  assert.match(dmgBuild, /hdiutil create/);
  assert.match(dmgBuild, /hdiutil verify/);
  assert.match(dmgSmoke, /Applications/);
  assert.match(dmgSmoke, /LSMinimumSystemVersion/);
});
