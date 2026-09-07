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

// 配布ファイルの、利用者リポジトリ内での配置。
//   docs-template/.github/** → .github/**
//   docs-template/**        → docs/**（/init-docs が docs/ 配下へ展開する）
function deployedLocation(file) {
  const rel = relative(templateRoot, file).replaceAll("\\", "/");
  if (rel.startsWith(".github/")) return rel;
  return join("docs", rel);
}

// /init-docs が初期配置する 20 ファイル（skills/init-docs/SKILL.md「2. ディレクトリ構造の作成」の
// 手書きスナップショット）。docs/ 配下のリンクは「展開先に必ず在る」初期セット内に限る。
// 初期セット外（05-operations/deployment/ や 03-implementation/templates/ 等）は
// inline code のパスで所在を案内する。
const INITIAL_SET = new Set([
  "docs/MASTER.md",
  "docs/01-context/PROJECT.md",
  "docs/01-context/CONSTRAINTS.md",
  "docs/02-design/ARCHITECTURE.md",
  "docs/02-design/DOMAIN.md",
  "docs/02-design/API.md",
  "docs/02-design/DATABASE.md",
  "docs/03-implementation/PATTERNS.md",
  "docs/03-implementation/CONVENTIONS.md",
  "docs/03-implementation/INTEGRATIONS.md",
  "docs/03-implementation/DECISION_TREE.md",
  "docs/03-implementation/FALLBACK.md",
  "docs/04-quality/TESTING.md",
  "docs/04-quality/VALIDATION.md",
  "docs/05-operations/DEPLOYMENT.md",
  "docs/06-reference/GLOSSARY.md",
  "docs/06-reference/DECISIONS.md",
  "docs/07-project-management/ROADMAP.md",
  "docs/07-project-management/TASKS.md",
  "docs/07-project-management/RISKS.md",
]);

function isLinkableTarget(target) {
  return target.startsWith(".github/") || INITIAL_SET.has(target);
}

// 配布ツリーに実体を持たないが正当な inline code パス表記（理由を書いて載せる）
//   .github/copilot-instructions.md — /setup-ai-config が利用者側で生成する
//   docs/specs/*.md                 — MASTER.md の仕様書運用例（架空の例示）
//   .github/workflows/xxx.yml       — Issue テンプレ（infra.md）の記入例
const INLINE_PATH_EXEMPT = new Set([
  ".github/copilot-instructions.md",
  "docs/specs/spec-template.md",
  "docs/specs/authentication.md",
  ".github/workflows/xxx.yml",
]);

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
// 初期セット内の docs 本体。INITIAL_SET から導く（実在しないものは件数検査が欠落パスを名指しする）
const missingInitialSet = [...INITIAL_SET].filter((p) => {
  const templatePath = toTemplatePath(p);
  return templatePath === null || !existsSync(templatePath);
});
const initialSetFiles = [...INITIAL_SET]
  .map((p) => toTemplatePath(p))
  .filter((p) => p !== null && existsSync(p));
const linkCheckedFiles = [...markdownFiles, ...initialSetFiles];
// 拡張子は .md に限定しない — 雛形 .skeleton.ts / .sql へのリンクも展開先で切れる。
// `<category>.md` のようなプレースホルダー（角括弧・山括弧を含む）は対象外。
// 既知の限界: URL 部分に角括弧を含む正当なリンクも対象外（見逃す側に倒す）。
const relativeLink =
  /\]\((?!https?:|mailto:|#)([^)\s<>\[\]]+\.[A-Za-z0-9]+(?:#[^)]*)?)\)/g;
const inlinePath = /`((?:docs|\.github)\/[^`\s\[\]<>]+\.[A-Za-z0-9]+)`/g;
const referencesLine = /^\s*references:\s*"([^"]+)"\s*$/gm;
// 展開前パスの混入。コピー元の案内 `${CLAUDE_PLUGIN_ROOT}/docs-template/` /
// `${FF_DEV_TOOLKIT_ROOT}/docs-template/` は正当なので、直前が `_ROOT}/` でない出現だけを拾う
const upstreamLeak = /(?<!_ROOT\}\/)docs-template\//;

// INITIAL_SET は skills/init-docs/SKILL.md ステップ2 のツリーの手書き複製。ツリーを解析して
// 集合一致を fail-closed で照合する（片側だけ増減した drift を検出する。抽出の空振りも赤）
function initialSetFromSkill() {
  const skill = readFileSync(join(pluginRoot, "skills/init-docs/SKILL.md"), "utf8");
  const start = skill.indexOf("### 2. ディレクトリ構造の作成");
  if (start < 0) return null;
  const fenceOpen = skill.indexOf("```", start);
  const fenceClose = skill.indexOf("```", fenceOpen + 3);
  if (fenceOpen < 0 || fenceClose < 0) return null;
  const result = new Set();
  let dir = "";
  for (const raw of skill.slice(fenceOpen + 3, fenceClose).split("\n")) {
    const name = raw.replace(/^[\s│├└─]+/, "").trim();
    if (name === "" || name === "docs/") continue;
    if (name.endsWith("/")) dir = name;
    else if (name.endsWith(".md")) result.add(`docs/${dir}${name}`);
  }
  return result;
}

/** 1 文書分を走査し、違反を分類して返す（実ループと自己検証が同じ関数を使う） */
function scanFile(deployedPath, content, relFile = deployedPath) {
  const report = { brokenRelative: [], outsideInitialSet: [], brokenInline: [], upstreamLeak: false };
  const fromDir = dirname(deployedPath);
  for (const match of content.matchAll(relativeLink)) {
    const target = match[1].split("#", 1)[0];
    const deployedTarget = normalize(join(fromDir, target)).replaceAll("\\", "/");
    const templatePath = toTemplatePath(deployedTarget);
    if (templatePath === null || !existsSync(templatePath)) {
      report.brokenRelative.push(`${relFile} -> ${match[1]}`);
    } else if (!isLinkableTarget(deployedTarget)) {
      report.outsideInitialSet.push(`${relFile} -> ${deployedTarget}`);
    }
  }
  for (const match of content.matchAll(inlinePath)) {
    if (INLINE_PATH_EXEMPT.has(match[1])) continue;
    const templatePath = toTemplatePath(match[1]);
    if (templatePath === null || !existsSync(templatePath)) {
      report.brokenInline.push(`${relFile} -> ${match[1]}`);
    }
  }
  report.upstreamLeak = upstreamLeak.test(content);
  return report;
}

console.log("== A'. 検出器の自己検証（合成入力。失敗したら横断検査は実行しない。期待値は参照先テンプレートの実在も含めて固定） ==");
{
  const extract = (md) => [...md.matchAll(relativeLink)].map((m) => m[1].split("#", 1)[0]);
  check(
    JSON.stringify(extract("[a](./deployment/git-workflow.md#s) [b](./templates/typescript/q1.skeleton.ts)")) ===
      JSON.stringify(["./deployment/git-workflow.md", "./templates/typescript/q1.skeleton.ts"]),
    "相対リンク検出器が .md 以外とアンカー付きを拾う",
  );
  check(
    extract("[x](https://example.com/a.md) [y](#sec) [z](../08-knowledge/playbook/<category>.md#ace-xxx)").length === 0,
    "相対リンク検出器が絶対 URL・アンカー・プレースホルダーを拾わない",
  );
  check(
    !isLinkableTarget("docs/05-operations/deployment/git-workflow.md") &&
      isLinkableTarget("docs/MASTER.md") &&
      isLinkableTarget(".github/skills/x/SKILL.md"),
    "初期セット判定が deployment/ 配下を外、初期セットと .github/ 配下（.github 側文書同士の参照用）を内と判定する",
  );
  // 走査ループ本体: 初期セット文書からの初期セット外リンクを「参照元 -> 展開先の参照先」で報告する
  const synthetic = scanFile(
    "docs/05-operations/DEPLOYMENT.md",
    "本文 [x](./deployment/git-workflow.md#step-1) と [m](../MASTER.md) と [t](../03-implementation/templates/typescript/q1-http-api-client.skeleton.ts)",
    "docs-template/05-operations/DEPLOYMENT.md",
  );
  check(
    JSON.stringify(synthetic.outsideInitialSet) ===
      JSON.stringify([
        "docs-template/05-operations/DEPLOYMENT.md -> docs/05-operations/deployment/git-workflow.md",
        "docs-template/05-operations/DEPLOYMENT.md -> docs/03-implementation/templates/typescript/q1-http-api-client.skeleton.ts",
      ]) && synthetic.brokenRelative.length === 0,
    "走査ループが初期セット外リンクを参照元と展開先の参照先つきで報告し、初期セット内リンクは通す",
  );
  check(
    scanFile("docs/MASTER.md", "存在しない [q](./nowhere.md)").brokenRelative.length === 1,
    "走査ループが解決しない相対リンクを報告する",
  );
  check(
    scanFile("docs/X.md", "`${CLAUDE_PLUGIN_ROOT}/docs-template/README.md` は正当").upstreamLeak === false &&
      scanFile("docs/X.md", "自プロジェクトの docs-template/ 配下").upstreamLeak === true,
    "展開前パス検査がコピー元の案内は許し、素の docs-template/ を拾う",
  );
  check(
    [...INLINE_PATH_EXEMPT].every((p) => /^(?:docs|\.github)\/[^`\s\[\]<>]+\.[A-Za-z0-9]+$/.test(p)),
    "免除リストの各エントリが inline code パスとして抽出される形である（免除の空振り防止）",
  );
  check(
    deployedLocation(join(templateRoot, "05-operations/DEPLOYMENT.md")) === "docs/05-operations/DEPLOYMENT.md" &&
      deployedLocation(join(githubRoot, "ISSUE_TEMPLATE/bug.md")) === ".github/ISSUE_TEMPLATE/bug.md",
    "配布ファイルの配置写像（docs/ と .github/）",
  );
  const fromSkill = initialSetFromSkill();
  const onlySkill = fromSkill === null ? [] : [...fromSkill].filter((p) => !INITIAL_SET.has(p));
  const onlyHere = fromSkill === null ? [] : [...INITIAL_SET].filter((p) => !fromSkill.has(p));
  check(
    fromSkill !== null && fromSkill.size > 0 && onlySkill.length === 0 && onlyHere.length === 0,
    "INITIAL_SET が skills/init-docs/SKILL.md ステップ2 のツリーと集合一致する",
    fromSkill === null
      ? "SKILL.md のツリーを抽出できない"
      : `SKILL側のみ: ${onlySkill.join(", ") || "-"} / 本 suite のみ: ${onlyHere.join(", ") || "-"}`,
  );
}
if (failures.length > 0) {
  console.log("");
  console.error(`✗ 検出器の自己検証に失敗（横断検査は実行しない）: ${failures.length} 件`);
  process.exit(1);
}

console.log("== A. 配布参照の展開先解決（.github 配下 + 初期セット文書） ==");
check(markdownFiles.length > 10, "検証対象 Markdown が 10 件を超える");
check(
  missingInitialSet.length === 0,
  `検査対象に初期セット ${INITIAL_SET.size} 文書がすべて含まれる`,
  `欠落: ${missingInitialSet.join(", ")}`,
);

const brokenRelative = [];
const outsideInitialSet = [];
const brokenInline = [];
const brokenReferences = [];
const upstreamLeaks = [];
for (const file of linkCheckedFiles) {
  const content = readFileSync(file, "utf8");
  const relFile = relative(pluginRoot, file);
  const report = scanFile(deployedLocation(file), content, relFile);
  brokenRelative.push(...report.brokenRelative);
  outsideInitialSet.push(...report.outsideInitialSet);
  brokenInline.push(...report.brokenInline);
  if (report.upstreamLeak) upstreamLeaks.push(relFile);

  for (const match of content.matchAll(referencesLine)) {
    for (const ref of match[1].split(",").map((value) => value.trim())) {
      if (ref.startsWith("https://")) continue;
      const templatePath = toTemplatePath(ref);
      if (templatePath === null || !existsSync(templatePath)) {
        brokenReferences.push(`${relFile} -> ${ref}`);
      }
    }
  }
}

check(brokenRelative.length === 0, "相対リンクが展開先で解決する", brokenRelative.join("; "));
check(
  outsideInitialSet.length === 0,
  "初期セット内文書からのリンク先が初期セット内にある（初期セット外は inline code で案内する）",
  outsideInitialSet.join("; "),
);
check(brokenInline.length === 0, "inline code の配布パスが実在する", brokenInline.join("; "));
check(brokenReferences.length === 0, "frontmatter references が実在する", brokenReferences.join("; "));
check(
  upstreamLeaks.length === 0,
  "展開前パス docs-template/ が漏れていない（コピー元の案内 `${...}_ROOT}/docs-template/` は除く）",
  upstreamLeaks.join("; "),
);

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
// 禁止カテゴリはエラークラスの列挙（allowlist）ではなく、各クラスが PATTERNS.md で宣言する
// category（"never-fallback"）で判定する。列挙方式だと新しいエラー型の追加漏れが黙って
// フォールバック対象になるため、契約は「5 クラスが never-fallback を宣言し、FALLBACK が
// category で判定する」に置き換える。
const fallback = text("03-implementation/FALLBACK.md");
const patterns = text("03-implementation/PATTERNS.md");
for (const errorType of [
  "UnauthorizedError",
  "ForbiddenError",
  "ValidationError",
  "ConflictError",
  "SecurityError",
]) {
  const declared = new RegExp(
    `class ${errorType} extends AppError \\{\\n\\s*readonly category: ErrorCategory = "never-fallback";`,
  );
  check(declared.test(patterns), `PATTERNS の ${errorType} が never-fallback を宣言する`);
}
check(
  fallback.includes('error.category === "never-fallback"'),
  "FALLBACK の禁止カテゴリ判定が category 宣言に基づく（クラス列挙を持たない）",
);
check(!fallback.includes("NEVER_FALLBACK_ERRORS"), "FALLBACK に旧 allowlist（NEVER_FALLBACK_ERRORS）が残っていない");

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
// A' が 1 件以上 pass を積むため通常は到達しない。検査の削除で全体が空になる退行への最後の砦として残す
if (pass === 0) {
  console.error("✗ 検査が 1 件も成立していません");
  process.exit(1);
}
console.log("✅ docs-template-portability: all checks passed");
