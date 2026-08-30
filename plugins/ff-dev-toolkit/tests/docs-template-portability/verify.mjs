import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} from "node:fs";
import { dirname, join, normalize, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const suiteDir = dirname(fileURLToPath(import.meta.url));
const pluginRoot = resolve(suiteDir, "../..");
const templateRoot = join(pluginRoot, "docs-template");
const githubRoot = join(templateRoot, ".github");

let pass = 0;
const failures = [];

function check(condition, label, detail = "") {
  if (condition) {
    pass += 1;
    console.log(`  ✓ ${label}`);
    return;
  }
  failures.push(detail === "" ? label : `${label}: ${detail}`);
  console.error(`  ✗ ${label}${detail === "" ? "" : `: ${detail}`}`);
}

function listMarkdown(dir) {
  const files = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) files.push(...listMarkdown(full));
    else if (entry.endsWith(".md")) files.push(full);
  }
  return files;
}

function deployedLocation(file) {
  return join(".github", relative(githubRoot, file));
}

function toTemplatePath(deployedPath) {
  const path = normalize(deployedPath).replaceAll("\\", "/");
  if (path.startsWith(".github/")) return join(templateRoot, path);
  if (path.startsWith("docs/")) {
    return join(templateRoot, path.slice("docs/".length));
  }
  return null;
}

function text(rel) {
  return readFileSync(join(templateRoot, rel), "utf8");
}

const markdownFiles = listMarkdown(githubRoot);
const relativeLink = /\]\((?!https?:|mailto:|#)([^)\s]+\.md(?:#[^)]*)?)\)/g;
const inlinePath = /`((?:docs|\.github)\/[^`\s\[\]<>]+\.md)`/g;
const referencesLine = /^\s*references:\s*"([^"]+)"\s*$/gm;

console.log("== A. .github 配布参照の展開先解決 ==");
check(markdownFiles.length > 10, "検証対象 Markdown が 10 件を超える");

const brokenRelative = [];
const brokenInline = [];
const brokenReferences = [];
const upstreamLeaks = [];
for (const file of markdownFiles) {
  const content = readFileSync(file, "utf8");
  const relFile = relative(pluginRoot, file);
  const fromDir = dirname(deployedLocation(file));

  for (const match of content.matchAll(relativeLink)) {
    const target = match[1].split("#", 1)[0];
    const deployedTarget = normalize(join(fromDir, target));
    const templatePath = toTemplatePath(deployedTarget);
    if (templatePath === null || !existsSync(templatePath)) {
      brokenRelative.push(`${relFile} -> ${match[1]}`);
    }
  }

  for (const match of content.matchAll(inlinePath)) {
    const templatePath = toTemplatePath(match[1]);
    if (templatePath === null || !existsSync(templatePath)) {
      brokenInline.push(`${relFile} -> ${match[1]}`);
    }
  }

  for (const match of content.matchAll(referencesLine)) {
    for (const ref of match[1].split(",").map((value) => value.trim())) {
      if (ref.startsWith("https://")) continue;
      const templatePath = toTemplatePath(ref);
      if (templatePath === null || !existsSync(templatePath)) {
        brokenReferences.push(`${relFile} -> ${ref}`);
      }
    }
  }

  if (content.includes("docs-template/")) upstreamLeaks.push(relFile);
}

check(brokenRelative.length === 0, "相対 Markdown リンクが解決する", brokenRelative.join("; "));
check(brokenInline.length === 0, "inline code の配布パスが実在する", brokenInline.join("; "));
check(brokenReferences.length === 0, "frontmatter references が実在する", brokenReferences.join("; "));
check(upstreamLeaks.length === 0, "展開前パス docs-template/ が漏れていない", upstreamLeaks.join("; "));

const issueAndPrTemplates = markdownFiles.filter(
  (file) =>
    file.startsWith(join(githubRoot, "ISSUE_TEMPLATE")) ||
    file === join(githubRoot, "pull_request_template.md"),
);
const bodyRelativeLinks = issueAndPrTemplates.flatMap((file) =>
  [...readFileSync(file, "utf8").matchAll(relativeLink)].map(
    (match) => `${relative(pluginRoot, file)} -> ${match[0]}`,
  ),
);
check(issueAndPrTemplates.length > 0, "Issue / PR テンプレートが検査対象にある");
check(bodyRelativeLinks.length === 0, "Issue / PR 本文に相対リンクがない", bodyRelativeLinks.join("; "));

console.log("== B. 8 欠陥の内容契約 ==");
const fallback = text("03-implementation/FALLBACK.md");
for (const errorType of [
  "UnauthorizedError",
  "ForbiddenError",
  "ValidationError",
  "ConflictError",
  "SecurityError",
]) {
  check(fallback.includes(errorType), `FALLBACK が ${errorType} を禁止対象に含む`);
}

const conventions = text("03-implementation/CONVENTIONS.md");
const integrations = text("03-implementation/INTEGRATIONS.md");
check(!conventions.includes("public details: any[]"), "CONVENTIONS の any 例を除去");
for (const pattern of [
  "context: any",
  "queueEmail(type: string, data: any)",
  "expiresIn: number = 3600",
  "chunkArray(messages, 1000)",
  "this.delay(1000)",
]) {
  check(!integrations.includes(pattern), `INTEGRATIONS から ${pattern} を除去`);
}

const pullRequest = text(".github/pull_request_template.md");
check(!/^- \[ \].*scripts\//m.test(pullRequest), "PR チェック項目が未配置スクリプトを必須にしない");

const decisions = text("06-reference/DECISIONS.md");
check(decisions.includes("このファイルの ADR は「記入例」です"), "DECISIONS が記入例だと冒頭で明示する");
check(!/^(承認済み|検討中)$/m.test(decisions), "サンプル ADR の状態を実決定と同じ表記にしない");

const playbook = text("08-knowledge/PLAYBOOK.md");
const aceCycle = text("05-operations/deployment/ace-cycle.md");
check(
  playbook.includes("playbook/<category>.md` 末尾へ追記し、本ファイルには索引行だけ"),
  "PLAYBOOK の追記先がカテゴリ別サブファイルで一意",
);
check(
  aceCycle.includes("PLAYBOOK.md#カテゴリ一覧"),
  "ace-cycle がカテゴリ一覧の SSOT を参照する",
);
check(
  !aceCycle.includes("coding/architecture/testing/security/performance/devops/process/tooling"),
  "ace-cycle にカテゴリの重複列挙がない",
);
check(!aceCycle.includes("PLAYBOOK.md に追記"), "ace-cycle が PLAYBOOK 本体への直接追記を指示しない");
check(
  playbook.includes("https://github.com/feel-flow/ai-spec-driven-development/blob/HEAD/docs/ACE_FRAMEWORK.md"),
  "PLAYBOOK の ACE_FRAMEWORK 参照が公開絶対 URL",
);

console.log("");
console.log(`結果: pass=${pass} fail=${failures.length}`);
if (failures.length > 0) process.exit(1);
if (pass === 0) {
  console.error("✗ 検査が 1 件も成立していません");
  process.exit(1);
}
console.log("✅ docs-template-portability: all checks passed");
