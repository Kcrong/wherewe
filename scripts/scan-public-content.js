"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { TextDecoder } = require("node:util");

const MAX_FILE_BYTES = 5 * 1_024 * 1_024;
const decoder = new TextDecoder("utf-8", { fatal: true });

function lineNumber(text, index) {
  let line = 1;
  for (let cursor = 0; cursor < index; cursor += 1) {
    if (text.charCodeAt(cursor) === 10) line += 1;
  }
  return line;
}

function finding(file, line, rule) {
  return { path: file, line, rule };
}

function secretRules() {
  return [
    {
      id: "private-key",
      expression: new RegExp(
        ["-----BEGIN ", "(?:RSA |EC |OPENSSH )?", "PRIVATE", " KEY-----"].join(""),
        "g"
      ),
    },
    {
      id: "github-token",
      expression: new RegExp(["gh", "p_", "[A-Za-z0-9]{36,}"].join(""), "g"),
    },
    {
      id: "github-fine-grained-token",
      expression: new RegExp(["github", "_pat_", "[A-Za-z0-9_]{40,}"].join(""), "g"),
    },
    {
      id: "cloud-access-key-id",
      expression: new RegExp(["(?:A", "KIA|A", "SIA)", "[A-Z0-9]{16}"].join(""), "g"),
    },
    {
      id: "slack-token",
      expression: new RegExp(["xo", "x[baprs]-", "[A-Za-z0-9-]{20,}"].join(""), "g"),
    },
  ];
}

function entropy(value) {
  const counts = new Map();
  for (const character of value) {
    counts.set(character, (counts.get(character) || 0) + 1);
  }
  let result = 0;
  for (const count of counts.values()) {
    const probability = count / value.length;
    result -= probability * Math.log2(probability);
  }
  return result;
}

function placeholder(value) {
  const lowered = value.toLowerCase();
  return ["placeholder", "example", "dummy", "must-not-pass", "not-a-secret"]
    .some((marker) => lowered.includes(marker));
}

function privateAddress(value) {
  const octets = value.split(".").map(Number);
  if (octets.length !== 4 || octets.some((part) => part < 0 || part > 255)) return false;
  return octets[0] === 10
    || octets[0] === 127
    || (octets[0] === 169 && octets[1] === 254)
    || (octets[0] === 192 && octets[1] === 168)
    || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31);
}

function scanText(text, file = "<memory>") {
  const findings = [];
  const digest = (value) => require("node:crypto")
    .createHash("sha256")
    .update(value, "utf8")
    .digest("hex");
  const prohibitedContextHashes = new Set([
    "cbc62794911ff31b2864ecd3dbbbee7ebcb7ea41c5a42e2cba377f3cfdb42811",
    "7d1507284a5757cac6b62708a4ef00bfc5d695256489cb704f12b4b9e6255df2",
    "2d7f45d7b98b427f824e0c643295583e9cf013faffdb5e7095d070ff85276bf4",
    "8ed11f92a7eda35be21b2dea4884a03f564e53c90b7176b895030b10f7585ba9",
    "ebfd80b56e9ee6ae97ed4f7c77b8739153505678eeb773b18bfc6c9b5522db3a",
    "c70eca6b0f88f44d81a41311647e50fda1ac454ec04ffd442b0eb4743a993131",
    "c857d09db23e6822e3600bc06ad8d58f92ed62bc8efd81c753f77048662cb97d",
    "f776fd61b1a82d656202fd35560dbd3be548d43cf1418d9cd6e2b154304c8c37",
    "67fc0152aca28deaa658700de35058291fc796ee21d04387a29b94288e980d64",
    "e288f9b68872514f2c3974666d8db40fc5fb377de05e72acc42b4401f5035a74",
    "3ef01e1a033b931226043c0ef59adc36e14b31e0d63b4da0e416c94a147e2916",
    "701f086a8316bd6045799f2bcc7a21898a2c294ad60b2ba860f5a66c5ffb0886",
    "ba7955598f2007bc8cee7329ece0f63ee59f2dbb40d59ad17aadfee76b1092ae",
    "e3ce9cc5efa9354c42b30704bed3e17cfad9ba9968592ffaa06b41dc7256cf4c",
    "d203a277f19a8f7d78fe8e9a621534b2cbd8ef1f0d809908ffc481e778858872",
    "1653d8193609ba335d60c8e7444669650ce7a581f03982230e42f5e383fd564d",
    "aa49f08c9b8388059adb0d374e469053c3a608354a1e2f6fc2277d11f7a8726b",
    "7d3194f79e645c42e4396dda38be04766810ec6a00d00aced3ffc2a0a1f1a9ef",
    "126b2bde531432eb42dad95f685a858ec9e180117e172bd2d16fc7291863ffc5",
    "08f58a29da78e9598fde2ab804faa20ec48671dee26df46a7bf7c3ddf6787657",
    "9a38a68618a1314bd0b5daabce1b2ecd914bdb4323a2b4ac529657637a85c571",
    "167df62207a753d6c3d5f703495a1f44e92bf672e1f790abd264c74d7746af37",
    "f805983b885f50e10f1db808b7ade8c377080006b2e3aebb0263ff9c50040fcd",
    "88a1a75812a0531665ee287bb80fe3c1e28c8f23be62113f67ef78e1ae0ddf7e",
    "da603df4d3d8bcbc843b692e5914b686fddde0d6653d2c665c017cd6abffcba5",
    "0ae2b61c0abcaadfa7aeac682d4278c51ebcc0fb53d5912ea24f0e6de60bc362",
    "71beed8b7ec72d0ac3c573b9cdc9e508ecc3df51155ab1960994d758c66e3857",
    "c4c05d40a8c3ebc0eb0c4edcff5d4e9964a5fbb5e24860711a92aa16668bfbd7",
    "66f62d1807d3821a3865f2573b69c74be033f1341240ac861fefc6d430bff5e0",
    "02540942346fdfbf21a94f8b823af2ae315f20cb71721c2cc6e205097d560840",
    "31e06f7d89feb99a0e6c0affe198748c3bb5bef5e3cc92d95cb9e996197d3fc3",
    "611496f412cac947be720d17a0ee6d7463221d14731fbc18244756271e8f5189",
    "650ffa82126b74c533df581cbc078399d1d5a4fd29b8907458ef4e06a5e2b648",
    "5782b18687e6cf8a482fc32d2db5b196d8821c458a0c069c6acf3953446e7bb5",
    "ea08b71ef7fab7f389692b79ca634e07705286c55d97d58b0769557fbfe0b7e0",
    "3cf985959c384638495dbb99ae5f79f44b7e6dc92a3df12457c826ea90f7d321",
    "1afdcb9e59907e736d7f7a52b68c1e934b8551499a4a57a22a82d46394fc3865",
  ]);
  const prohibitedCredentialPrefixHashes = new Set([
    "d2460eb704ec163515ef7e0ecd3735496b137219912bb87e4ac3d54b4f18f54a",
  ]);

  for (const [lineIndex, line] of text.split(/\r?\n/).entries()) {
    const normalized = line.normalize("NFKC").toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .trim();
    const words = normalized ? normalized.split(/\s+/) : [];
    let matched = false;
    for (let start = 0; start < words.length && !matched; start += 1) {
      for (let size = 1; size <= 3 && start + size <= words.length; size += 1) {
        if (prohibitedContextHashes.has(digest(words.slice(start, start + size).join(" ")))) {
          findings.push(finding(file, lineIndex + 1, "prohibited-context"));
          matched = true;
          break;
        }
      }
    }
  }

  const providerCredential = /\b[A-Za-z][A-Za-z0-9_-]{38}\b/g;
  for (const match of text.matchAll(providerCredential)) {
    if (prohibitedCredentialPrefixHashes.has(digest(match[0].slice(0, 4)))) {
      findings.push(finding(file, lineNumber(text, match.index), "provider-credential"));
    }
  }

  for (const rule of secretRules()) {
    for (const match of text.matchAll(rule.expression)) {
      findings.push(finding(file, lineNumber(text, match.index), rule.id));
    }
  }

  const assignment = /(?:password|passwd|token|secret|api[_-]?key)\s*[:=]\s*["']([^"'${}\s]{20,})["']/gi;
  for (const match of text.matchAll(assignment)) {
    if (!placeholder(match[1])) {
      findings.push(finding(file, lineNumber(text, match.index), "literal-secret-assignment"));
    }
  }

  const emails = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
  for (const match of text.matchAll(emails)) {
    const domain = match[0].split("@")[1].toLowerCase();
    if (!["example.com", "example.net", "users.noreply.github.com"].includes(domain)) {
      findings.push(finding(file, lineNumber(text, match.index), "email-address"));
    }
  }

  const addresses = /\b(?:\d{1,3}\.){3}\d{1,3}\b/g;
  for (const match of text.matchAll(addresses)) {
    if (privateAddress(match[0])) {
      findings.push(finding(file, lineNumber(text, match.index), "private-network-address"));
    }
  }

  const privateHosts = /https?:\/\/[^\s/"')]+/gi;
  for (const match of text.matchAll(privateHosts)) {
    let host;
    try { host = new URL(match[0]).hostname.toLowerCase(); } catch { continue; }
    if (host === "localhost" || host.endsWith(".internal") || host.endsWith(".local")) {
      findings.push(finding(file, lineNumber(text, match.index), "private-endpoint"));
    }
  }

  const machinePaths = [
    /\/(?:home|Users)\/[A-Za-z0-9._-]+\//g,
    /[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\/g,
  ];
  for (const expression of machinePaths) {
    for (const match of text.matchAll(expression)) {
      findings.push(finding(file, lineNumber(text, match.index), "machine-specific-path"));
    }
  }

  const encoded = /\b[A-Za-z0-9+/_=-]{40,}\b/g;
  for (const match of text.matchAll(encoded)) {
    const value = match[0];
    if (/^[0-9a-f]{40}$/i.test(value) || /^[0-9a-f]{64}$/i.test(value)) continue;
    if (/^(?:(?:com|co)\/)?[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/(?:blob|tree)\/[0-9a-f]{40}(?:\/[A-Za-z0-9._-]+)*$/i.test(value)) continue;
    if (placeholder(value)) continue;
    if (entropy(value) >= 4.5 && /[A-Za-z]/.test(value) && /\d/.test(value)) {
      findings.push(finding(file, lineNumber(text, match.index), "high-entropy-token"));
    }
  }

  return findings;
}

function scanPath(relative, manifest) {
  const findings = [];
  const policy = manifest.forbidden;
  const basename = path.posix.basename(relative);
  const segments = relative.split("/");
  if (policy.exact_names.includes(basename)
      || policy.name_prefixes.some((prefix) => basename.startsWith(prefix))
      || policy.path_prefixes.some((prefix) => relative.startsWith(prefix))
      || policy.extensions.some((extension) =>
        segments.some((segment) => segment.endsWith(extension)))) {
    findings.push(finding(relative, 0, "forbidden-path"));
  }
  return findings;
}

function archiveOrExecutableMagic(buffer) {
  if (buffer.length < 4) return false;
  const firstFour = buffer.subarray(0, 4).toString("hex");
  return new Set([
    "504b0304",
    "1f8b0800",
    "7f454c46",
    "cafebabe",
    "cffaedfe",
    "feedfacf",
  ]).has(firstFour);
}

function candidateFiles(root) {
  const output = execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    { cwd: root }
  );
  return output.toString("utf8").split("\0").filter(Boolean).sort();
}

function scanRepository(root) {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(root, "source-manifest.json"), "utf8")
  );
  const findings = [];
  let bytes = 0;
  const files = candidateFiles(root);
  for (const relative of files) {
    findings.push(...scanPath(relative, manifest));
    const absolute = path.join(root, relative);
    const stat = fs.lstatSync(absolute);
    if (stat.isSymbolicLink()) {
      findings.push(finding(relative, 0, "symbolic-link"));
      continue;
    }
    if (!stat.isFile()) {
      findings.push(finding(relative, 0, "non-regular-file"));
      continue;
    }
    if (stat.size > MAX_FILE_BYTES) {
      findings.push(finding(relative, 0, "oversized-repository-file"));
      continue;
    }
    const buffer = fs.readFileSync(absolute);
    bytes += buffer.length;
    if (buffer.includes(0) || archiveOrExecutableMagic(buffer)) {
      findings.push(finding(relative, 0, "unexpected-binary-or-archive"));
      continue;
    }
    let text;
    try { text = decoder.decode(buffer); }
    catch {
      findings.push(finding(relative, 0, "invalid-utf8"));
      continue;
    }
    findings.push(...scanText(text, relative));
  }
  const unique = [...new Map(
    findings.map((item) => [`${item.path}\0${item.line}\0${item.rule}`, item])
  ).values()];
  return { files: files.length, bytes, findings: unique };
}

function main() {
  const root = path.resolve(__dirname, "..");
  const result = scanRepository(root);
  if (result.findings.length > 0) {
    process.stderr.write(`PUBLIC_CONTENT_SCAN_FAILED findings=${result.findings.length}\n`);
    for (const item of result.findings.slice(0, 200)) {
      process.stderr.write(`${item.path}:${item.line} ${item.rule}\n`);
    }
    process.exitCode = 1;
    return;
  }
  process.stdout.write(
    `PUBLIC_CONTENT_SCAN_OK files=${result.files} bytes=${result.bytes} findings=0\n`
  );
}

module.exports = {
  entropy,
  scanPath,
  scanRepository,
  scanText,
};

if (require.main === module) main();
