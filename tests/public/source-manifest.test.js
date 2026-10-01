"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const MANIFEST_PATH = path.join(ROOT, "source-manifest.json");
const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
const repositoryFiles = new Set(manifest.files);
const executableFiles = new Set(manifest.executable_files);

function assertSortedUnique(values, label) {
  assert.deepEqual(values, [...new Set(values)].sort(), `${label} must be sorted and unique`);
}

function assertSafeRelativePath(candidate, label) {
  assert.equal(typeof candidate, "string", `${label} must be a string`);
  assert.ok(candidate.length > 0, `${label} must not be empty`);
  assert.equal(candidate, path.posix.normalize(candidate), `${label} must be normalized`);
  assert.ok(!path.posix.isAbsolute(candidate), `${label} must be relative`);
  assert.ok(!candidate.includes("\\"), `${label} must use POSIX separators`);
  assert.ok(!candidate.split("/").includes(".."), `${label} must not traverse parents`);
}

function isForbidden(candidate) {
  const basename = path.posix.basename(candidate);
  const segments = candidate.split("/");
  const policy = manifest.forbidden;
  return (
    policy.exact_names.includes(basename)
    || policy.name_prefixes.some((prefix) => basename.startsWith(prefix))
    || policy.path_prefixes.some((prefix) => candidate.startsWith(prefix))
    || policy.extensions.some((extension) =>
      segments.some((segment) => segment.endsWith(extension))
    )
  );
}

function classify(candidate) {
  if (isForbidden(candidate)) return "forbidden";
  if (repositoryFiles.has(candidate)) return "tracked";
  return "unlisted";
}

function currentRepositoryFiles() {
  return execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    { cwd: ROOT }
  ).toString("utf8").split("\0").filter(Boolean).sort();
}

test("source manifest describes the current repository state", () => {
  assert.equal(manifest.schema_version, 1);
  assert.deepEqual(Object.keys(manifest), [
    "schema_version",
    "purpose",
    "generated_on",
    "expected_files",
    "default_file_mode",
    "files",
    "executable_files",
    "expected_binary_files",
    "excluded_categories",
    "forbidden",
  ]);
  assertSortedUnique(manifest.files, "repository files");
  assertSortedUnique(manifest.executable_files, "repository executables");
  assertSortedUnique(manifest.excluded_categories, "excluded categories");
  assert.equal(manifest.files.length, manifest.expected_files);
  assert.deepEqual(manifest.expected_binary_files, []);

  for (const candidate of manifest.files) {
    assertSafeRelativePath(candidate, candidate);
    assert.ok(!isForbidden(candidate), `${candidate} violates repository policy`);
  }
  for (const candidate of executableFiles) {
    assert.ok(repositoryFiles.has(candidate), `${candidate} is executable but unclassified`);
  }
});

test("forbidden and unlisted paths are rejected", () => {
  assert.equal(classify(manifest.files[0]), "tracked");
  for (const candidate of [
    ".git/config",
    ".env.production",
    "build/Wherewe.app/Contents/MacOS/Wherewe",
    "capture.sqlite",
    "release/Wherewe.dmg",
  ]) {
    assert.equal(classify(candidate), "forbidden", candidate);
  }
  const omittedMedia = ["tests", "fixtures", "speech-en" + ".wav"].join("/");
  assert.equal(classify(omittedMedia), "unlisted");
  assert.equal(classify("unreviewed/new-file.txt"), "unlisted");
});

test("every current repository file is classified and has the expected mode", () => {
  const files = currentRepositoryFiles();
  assert.ok(files.length > 0);
  for (const candidate of files) {
    assert.equal(classify(candidate), "tracked", `${candidate} is not classified`);
    const isExecutable = (fs.statSync(path.join(ROOT, candidate)).mode & 0o111) !== 0;
    assert.equal(
      isExecutable,
      executableFiles.has(candidate),
      `${candidate} executable mode does not match the manifest`
    );
  }
});
