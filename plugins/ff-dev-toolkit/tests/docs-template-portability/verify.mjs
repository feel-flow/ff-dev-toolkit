import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} from "node:fs";
import { dirname, join, normalize, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { copyLeakLines, copyTokenPattern, copyUnitsFromMaster } from "./copy-units.mjs";

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
//   docs/00-planning/my-*planning.md — 初心者・新規プロジェクトガイドで読み手が作る企画書の保存先
//   .github/agents/review-router.agent.md — COPILOT_AGENTS のディレクトリ構造が示す、利用側で作るルーター
//   docs/02-design/OLD_AUTH_DESIGN.md ほか 3 件 — archive-strategy の退避・復活手順の記入例（架空の文書名）
// 「必要時にコピー」の文書の素テキストの docs/ 参照にも同じ免除を掛ける
const INLINE_PATH_EXEMPT = new Set([
  ".github/copilot-instructions.md",
  "docs/specs/spec-template.md",
  "docs/specs/authentication.md",
  ".github/workflows/xxx.yml",
  "docs/00-planning/my-planning.md",
  "docs/00-planning/my-project-planning.md",
  ".github/agents/review-router.agent.md",
  "docs/02-design/OLD_AUTH_DESIGN.md",
  "docs/archive/2025/OLD_AUTH_DESIGN.md",
  "docs/02-design/X.md",
  "docs/archive/2025/X.md",
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

/**
 * 1 文書分を走査し、違反を分類して返す（実ループと自己検証が同じ関数を使う）。
 * sameUnit は「この文書と一緒にコピーされる」展開先パスの集合（コピー単位の兄弟）。
 * 初期セット・.github/ に加えてここへのリンクも通す
 */
function scanFile(deployedPath, content, relFile = deployedPath, sameUnit = new Set()) {
  const report = { brokenRelative: [], outsideInitialSet: [], brokenInline: [], upstreamLeak: false };
  const fromDir = dirname(deployedPath);
  for (const match of content.matchAll(relativeLink)) {
    const target = match[1].split("#", 1)[0];
    const deployedTarget = normalize(join(fromDir, target)).replaceAll("\\", "/");
    const templatePath = toTemplatePath(deployedTarget);
    if (templatePath === null || !existsSync(templatePath)) {
      report.brokenRelative.push(`${relFile} -> ${match[1]}`);
    } else if (!isLinkableTarget(deployedTarget) && !sameUnit.has(deployedTarget)) {
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

// コピー単位の導出・展開前パス検出は copy-units.mjs（定義の説明もそちら）。ここは配置の展開と走査
function expandTemplatePath(path) {
  const full = join(templateRoot, path);
  if (!existsSync(full)) return null;
  if (path.endsWith("/")) {
    if (!statSync(full).isDirectory()) return null;
    return listMarkdown(full).map((file) => relative(templateRoot, file).replaceAll("\\", "/"));
  }
  return path.endsWith(".md") ? [path] : [];
}

/**
 * コピー単位ごとの走査（実ループと自己検証が同じ関数を使う）。各単位の文書を「初期セット +
 * 同じ単位」の中で解決できるかを見て、違反を種類ごとに集める。readText は docs-template 相対
 * パスを受けて本文を返す。案内テキストのコピー元（`${…_ROOT}/docs-template/<path>`、アンカーは
 * 除く）は expand で実在を確かめる — リンクを案内テキストへ置き換えた先が誤記でも緑にしない
 */
function scanCopyUnits(units, readText, expand, skip = () => false) {
  const out = { broken: [], outside: [], leaks: [], unresolved: [], guides: [], links: 0 };
  for (const unit of units) {
    const sameUnit = new Set([...unit.members].map((member) => `docs/${member}`));
    for (const member of [...unit.members].filter((m) => !skip(m))) {
      const content = readText(member);
      const report = scanFile(`docs/${member}`, content, `docs-template/${member}`, sameUnit);
      out.broken.push(...report.brokenRelative, ...report.brokenInline);
      out.outside.push(...report.outsideInitialSet);
      out.leaks.push(...copyLeakLines(content).map(([n, line]) => `${member} L${n}: ${line.trim()}`));
      const rawDocRefs = [...new Set(content.match(/(?<![\w/}])docs\/[A-Za-z0-9_.\/-]+\.md/g) ?? [])].filter(
        (ref) => !INLINE_PATH_EXEMPT.has(ref),
      );
      out.unresolved.push(
        ...rawDocRefs
          .filter((ref) => expand(ref.slice("docs/".length)) === null)
          .map((ref) => `${member} -> ${ref}`),
      );
      for (const match of content.matchAll(copyTokenPattern)) {
        const source = match[1].split("#", 1)[0];
        if (expand(source) === null) out.guides.push(`${member} -> ${match[1]}`);
      }
      out.links += [...content.matchAll(relativeLink)].length;
    }
  }
  return out;
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
  // コピー単位の導出（合成の MASTER と合成の配置。期待値は定義から手で組む — ACE-1507-2）
  const root = "${CLAUDE_PLUGIN_ROOT}/docs-template/";
  const fakeLayout = {
    "A.md": ["A.md"],
    "set/INDEX.md": ["set/INDEX.md"],
    "set/sub/": ["set/sub/a.md", "set/sub/b.md"],
    "set/sub/b.md": ["set/sub/b.md"],
    "K.md": ["K.md"],
  };
  const fakeExpand = (path) => fakeLayout[path] ?? null;
  const syntheticMaster = [
    "### 集め（初期セット外・必要時にコピー）",
    "",
    "- A.md — 単独。`" + root + "A.md` からコピー",
    "- set — 相互にリンクする一式。`" + root + "set/INDEX.md` と `" + root + "set/sub/` からコピー",
    "",
    "```",
    "- F.md — コードブロックの中は指示ではない。`" + root + "F.md` からコピー",
    "```",
    "",
    "## 本文",
    "",
    "詳細は b（初期セット外・`" + root + "set/sub/b.md` からコピー）を参照。",
    "単独の案内は k（`" + root + "K.md` からコピー）。",
    "SSOT は `" + root + "README.md` の章（コピーしない）。",
  ].join("\n");
  const derived = copyUnitsFromMaster(syntheticMaster, fakeExpand);
  check(
    JSON.stringify(derived.units.map((unit) => [...unit.members].sort())) ===
      JSON.stringify([["A.md"], ["set/INDEX.md", "set/sub/a.md", "set/sub/b.md"], ["K.md"]]),
    "コピー単位が節の箇条 1 行ごと（ディレクトリは配下の .md へ展開）と、本文だけにある指示の単一文書から導かれる",
    JSON.stringify(derived.units.map((unit) => [...unit.members])),
  );
  check(
    derived.errors.length === 1 && derived.errors[0].startsWith("MASTER.md L12: ") && derived.errors[0].includes("一部だけ"),
    "本文の指示が複数ファイルの単位の一部だけを名指ししたら赤にし、コードブロックの中は指示として読まない",
    derived.errors.join(" / ") || "エラー 0 件",
  );
  const errorsOf = (md) => copyUnitsFromMaster(md, fakeExpand).errors;
  check(
    errorsOf("## 関連\n\n- `" + root + "A.md` からコピー")[0] === "`###` 見出しに「必要時にコピー」を含む節が見つからない" &&
      errorsOf("#### x（必要時にコピー）\n\n- `" + root + "A.md` からコピー")[0] === "`###` 見出しに「必要時にコピー」を含む節が見つからない" &&
      errorsOf("### x（必要時にコピー）\n\n- `" + root + "Z.md` からコピー")[0]?.includes("Z.md が配布物に無い"),
    "コピー単位の導出が、節の不在（`###` 以外の見出しは節にしない）とコピー元の不在を検査不成立として赤にする",
  );
  const bulletErrors = errorsOf(
    [
      "### x（必要時にコピー）",
      "",
      "- A.md — 言い回し違い。`" + root + "A.md` をコピー",
      "- K.md — 折り返した箇条の 1 行目",
      "  `" + root + "K.md` からコピー",
      "- set — 変数違いも指示として読む。`${FF_DEV_TOOLKIT_ROOT}/docs-template/set/INDEX.md` からコピー",
    ].join("\n"),
  );
  check(
    bulletErrors.length === 2 &&
      bulletErrors[0].startsWith("MASTER.md L3: ") &&
      bulletErrors[1].startsWith("MASTER.md L4: ") &&
      bulletErrors.every((e) => e.includes("指示を読み取れない")),
    "「必要時にコピー」節の箇条が指示を持たない（言い回し違い・折り返し）と赤にし、`${FF_DEV_TOOLKIT_ROOT}` のコピー元は指示として読む",
    bulletErrors.join(" / ") || "エラー 0 件",
  );
  const overlapErrors = errorsOf(
    [
      "### x（必要時にコピー）",
      "",
      "- `" + root + "set/sub/` からコピー",
      "- `" + root + "set/sub/b.md` からコピー",
      "",
      "## 本文",
      "",
      "`" + root + "A.md` と `" + root + "set/sub/` からコピー",
    ].join("\n"),
  );
  check(
    overlapErrors.length === 2 &&
      overlapErrors[0] === "MASTER.md L4: set/sub/b.md が MASTER.md L3 の単位にも含まれる（単位が重なる）" &&
      overlapErrors[1].startsWith("MASTER.md L8: 1 つの指示が複数の単位（または単位の外）にまたがる"),
    "箇条どうしの重なりと、単位の要素と単位外の文書にまたがる本文の指示を赤にする",
    overlapErrors.join(" / ") || "エラー 0 件",
  );
  // 走査ループ本体（scanCopyUnits）の単位別スコープ: 合成の 2 単位で、兄弟は通り別単位は報告される
  const scanFixture = {
    "05-operations/ORGANIZATIONAL_ROLLOUT.md":
      "[p](./organizational-rollout/phased-rollout.md) [g](../GETTING_STARTED.md) [m](../MASTER.md)\n" +
      "find docs-template docs -name x\n" +
      "`" + root + "nowhere-1896.md#x`（初期セット外・必要ならコピーする）",
    "05-operations/organizational-rollout/phased-rollout.md": "",
    "GETTING_STARTED.md": "",
  };
  const unitScan = scanCopyUnits(
    [
      { members: new Set(["05-operations/ORGANIZATIONAL_ROLLOUT.md", "05-operations/organizational-rollout/phased-rollout.md"]) },
      { members: new Set(["GETTING_STARTED.md"]) },
    ],
    (member) => scanFixture[member],
    expandTemplatePath,
  );
  check(
    JSON.stringify(unitScan.outside) === JSON.stringify(["docs-template/05-operations/ORGANIZATIONAL_ROLLOUT.md -> docs/GETTING_STARTED.md"]) &&
      JSON.stringify(unitScan.leaks) === JSON.stringify(["05-operations/ORGANIZATIONAL_ROLLOUT.md L2: find docs-template docs -name x"]) &&
      JSON.stringify(unitScan.guides) === JSON.stringify(["05-operations/ORGANIZATIONAL_ROLLOUT.md -> nowhere-1896.md#x"]) &&
      unitScan.broken.length === 0 &&
      unitScan.links === 3,
    "走査ループが単位ごとに兄弟へのリンクを通し、別の単位へのリンク・引数の docs-template・実在しないコピー元を報告する",
    JSON.stringify(unitScan),
  );
  const cloned = "git clone https://github.com/feel-flow/ai-spec-driven-development.git\ncp ../ai-spec-driven-development/docs-template/A.md docs/A.md";
  check(
    copyLeakLines(cloned).length === 0 &&
      copyLeakLines("[履歴](https://github.com/o/r/commits/develop/docs-template/x)").length === 0 &&
      copyLeakLines("`${FF_DEV_TOOLKIT_ROOT}/docs-template/A.md` と `${CLAUDE_PLUGIN_ROOT}/docs-template` から").length === 0 &&
      JSON.stringify(
        copyLeakLines("cp ../upstream/docs-template/A.md docs/A.md\ncp docs-template/B.md docs/B.md\ngrep -r x docs-template docs").map(([n]) => n),
      ) === JSON.stringify([1, 2, 3]),
    "展開前パス検出が URL・コピー元の案内・クローン手順のあるクローン相対パスを通し、それ以外の docs-template を引数の形も含めて行番号つきで拾う",
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

// 08-knowledge の JWT 検証例。検査は**例のコードブロックだけ**を対象にする。
// ファイル全体に掛けると、同じ文書の別の例にある正当な記述（HTTP 境界での
// normalizeExternalError、Error へ絞り込んだ後の error.message）まで縛ってしまい、
// 検査が契約より広くなる。
function jwtExample(rel) {
  const content = text(rel);
  const start = content.indexOf("// 安全なJWT検証");
  if (start === -1) return "";
  const end = content.indexOf("```", start);
  return end === -1 ? content.slice(start) : content.slice(start, end);
}

for (const [label, rel] of [
  ["TROUBLESHOOTING", "08-knowledge/TROUBLESHOOTING.md"],
  ["LESSONS_LEARNED", "08-knowledge/LESSONS_LEARNED.md"],
]) {
  const block = jwtExample(rel);
  // アンカーを失うと以降の否定形検査が全部素通りするので、実在を先に固定する
  check(block !== "", `08-knowledge/${label} に JWT 検証例のアンカーが実在する`);
  check(
    !/:\s*any\b/.test(block),
    `08-knowledge/${label} の JWT 例に any 注釈が無い`,
  );
  check(
    /verifyToken\(token: string\): VerifiedTokenPayload/.test(block),
    `08-knowledge/${label} の verifyToken が検証済みペイロード型を返す`,
  );
  check(
    /\): value is VerifiedTokenPayload/.test(block) &&
      /if \(!isVerifiedTokenPayload\(decoded\)\)/.test(block),
    `08-knowledge/${label} が型ガードを通してから検証済みペイロードを返す`,
  );
  check(
    !/\berror\.message\b/.test(block),
    `08-knowledge/${label} の catch 節が unknown な error から直接 .message を読まない`,
  );
  // normalizeExternalError は HTTP ステータスを持つ境界専用（PATTERNS.md）。
  // ステータスを読めないエラーは UpstreamError（transient）へ倒れるため、
  // JWT 検証失敗をここへ通すと署名不正のトークンが再試行・本番フォールバックの
  // 対象になる。専用マッパー経由であることを両方向で固定する
  check(
    !/normalizeExternalError\(/.test(block),
    `08-knowledge/${label} の JWT 例が HTTP 境界専用の normalizeExternalError を通さない`,
  );
  check(
    /function toTokenVerificationError\(error: unknown\): AppError/.test(block) &&
      /throw toTokenVerificationError\(error\);/.test(block),
    `08-knowledge/${label} の JWT 検証 catch 節が専用マッパーを経由する`,
  );
  check(
    /new UnauthorizedError\(/.test(block) && /new SecurityError\(/.test(block),
    `08-knowledge/${label} の JWT 検証エラーが never-fallback カテゴリへ写る`,
  );
}

// SETUP_CLAUDE_CODE.md は heredoc の**中**で、生成先（消費プロジェクト）を基準に `docs/` と
// 書く必要がある。実際には外側の `docs-template/` 表記がそのまま内側へ流れ込んでいた（実測 14 件）。
// 生成された CLAUDE.md は消費プロジェクトで AI が最初に読む文書なので、そこに解決できない
// パスがあると初回体験が壊れる。
// heredoc の**外**も同じ基準で解決する（この手順書自体が消費側へコピーされる運用なので、
// 外側にも解決しない参照が残っていた — 実測 12 件）。検査は下の「heredoc の外」ブロック。
//
// 範囲は行番号ではなくマーカーで取る（heredoc は編集で伸縮する）。マーカーを見つけられない
// 回は「違反 0 件」ではなく検査不成立として落とす — 生成ブロックの書き方が変わった日に
// 黙って空振りさせないため。
const setupClaude = text("SETUP_CLAUDE_CODE.md");
const setupLines = setupClaude.split("\n");
const heredocStart = setupLines.findIndex((line) => line.startsWith("cat > CLAUDE.md << 'EOF'"));
const heredocEnd = heredocStart === -1
  ? -1
  : setupLines.findIndex((line, i) => i > heredocStart && line === "EOF");
check(
  heredocStart !== -1 && heredocEnd !== -1,
  "SETUP_CLAUDE_CODE の CLAUDE.md 生成 heredoc を特定できる",
  `start=${heredocStart} end=${heredocEnd}`,
);
if (heredocStart !== -1 && heredocEnd !== -1) {
  const inside = setupLines.slice(heredocStart + 1, heredocEnd);
  const strays = inside
    .map((line, i) => [heredocStart + 2 + i, line])
    .filter(([, line]) => line.includes("docs-template/"));
  check(
    strays.length === 0,
    "生成される CLAUDE.md が消費側に実在しない docs-template/ を指さない",
    strays.map(([n, line]) => `L${n}: ${line.trim()}`).join(" / "),
  );
  // 基準を揃えるだけでは足りない。元の参照が階層を落としていれば、揃えた結果も解決できない
  // （実測: `docs-template/ARCHITECTURE.md` は実体が `02-design/` 配下なので、機械置換した
  // `docs/ARCHITECTURE.md` は消費側に存在しない）。参照は**実体と突き合わせる**。
  // 消費側の `docs/X` は配布時の `docs-template/X` に対応する。
  const docRefs = [
    ...new Set(
      inside
        .flatMap((line) => line.match(/docs\/[A-Za-z0-9_.\/-]+\.md/g) ?? [])
        .map((ref) => ref.replace(/^docs\//, "")),
    ),
  ];
  const unresolved = docRefs.filter((ref) => !existsSync(join(templateRoot, ref)));
  check(
    unresolved.length === 0,
    "生成される CLAUDE.md の参照が配布物の実体へ解決できる",
    unresolved.map((ref) => `docs/${ref}`).join(" / "),
  );
  // 内側が空になる（heredoc を空にする / 参照を全部消す）退行を、違反 0 件と同じ緑にしない。
  // 解決検査は参照が 0 件でも緑になるため、この下限が無いと参照を全部消す変異を通す。
  // 件数は下限で縛る。検査数の baseline と違って**不等号が正しい** — 参照を足すのは
  // 正常な変更だからで、縛りたいのは「まとめて消える」退行のほうである。
  const EXPECTED_DOC_REFS = 8;
  check(
    docRefs.length >= EXPECTED_DOC_REFS,
    `生成される CLAUDE.md が消費側の docs/ を ${EXPECTED_DOC_REFS} 件以上参照している`,
    `inside=${inside.length} 行 / 参照 ${docRefs.length} 件`,
  );

  // heredoc の**外**も基準は同じ。この手順書自体が消費プロジェクトへコピーされて読まれる
  // 運用で（MASTER.md「AIツール初期設定ガイド（初期セット外・必要時にコピー）」）、コピー先は
  // docs/SETUP_CLAUDE_CODE.md。消費側に docs-template/ は無いので、外側の参照も内側と同じく
  // **実体と突き合わせる**。外側は heredoc の補集合として取る（行番号で切らない）。
  // 対象外: `${...}_ROOT}/docs-template/...` — プラグイン実体を指す正当な参照で、消費側基準
  // ではない（upstreamLeak が同じ除外規則を持つ）。
  // 行番号を保ったまま補集合を取る（落ちたとき 790 行のどこかを名指しできるようにする）
  const outsidePairs = setupLines
    .map((line, i) => [i + 1, line])
    .filter(([n]) => n <= heredocStart + 1 || n >= heredocEnd + 1);
  const outside = outsidePairs.map(([, line]) => line).join("\n");
  const outsideReport = scanFile(
    "docs/SETUP_CLAUDE_CODE.md",
    outside,
    "docs-template/SETUP_CLAUDE_CODE.md（heredoc の外）",
  );
  const outsideStrays = outsidePairs.filter(([, line]) => upstreamLeak.test(line));
  check(
    outsideStrays.length === 0,
    "SETUP_CLAUDE_CODE の heredoc の外に展開前パス docs-template/ が残っていない",
    outsideStrays.map(([n, line]) => `L${n}: ${line.trim()}`).join(" / "),
  );
  const outsideBrokenLinks = [...outsideReport.brokenRelative, ...outsideReport.brokenInline];
  check(
    outsideBrokenLinks.length === 0,
    "SETUP_CLAUDE_CODE の heredoc の外のリンクと inline code パスが展開先で解決する",
    outsideBrokenLinks.join(" / "),
  );
  // 解決するだけでは足りない。/init-docs が展開するのは初期セットの 20 文書だけなので、
  // 初期セット外へ Markdown リンクを張るとコピー直後にリンク切れになる（配布ツリーには
  // 実体が在るので上の解決検査は通ってしまう）。初期セット外はコピー元パス付きの案内
  // テキストで示す — MASTER.md が「初期セット外・必要時にコピー」の文書に採っている形。
  check(
    outsideReport.outsideInitialSet.length === 0,
    "SETUP_CLAUDE_CODE の heredoc の外のリンク先が初期セット内にある（初期セット外はコピー元パスの案内テキストで示す）",
    outsideReport.outsideInitialSet.join(" / "),
  );
  // リンクでも inline code でもない素のテキスト（アップロード手順・プロンプト例）の docs/ 参照。
  // 内側と同じ抽出を掛ける — 実測ではこの形が最も多く、階層を落とした参照もここに混ざる。
  const outsideDocRefs = [
    ...new Set(
      (outside.match(/docs\/[A-Za-z0-9_.\/-]+\.md/g) ?? []).map((ref) =>
        ref.replace(/^docs\//, ""),
      ),
    ),
  ];
  const outsideUnresolved = outsideDocRefs.filter((ref) => !existsSync(join(templateRoot, ref)));
  check(
    outsideUnresolved.length === 0,
    "SETUP_CLAUDE_CODE の heredoc の外の docs/ 参照が配布物の実体へ解決できる",
    outsideUnresolved.map((ref) => `docs/${ref}`).join(" / "),
  );
  // 内側と同じ理由の下限。解決検査は参照 0 件でも緑になるので、外側の参照をまとめて消す
  // 退行を「違反 0 件」と区別できるようにする。
  // 下限は素テキストの docs/ 参照と Markdown リンクで**別に**置く。片方だけだともう一方を
  // 全部消す退行が通る（素テキストの下限だけを置いた段階では、`./` 始まりのリンクは
  // docs/ 正規表現に一致しないため全削除しても緑のままだった）。
  const EXPECTED_OUTSIDE_DOC_REFS = 5;
  check(
    outsideDocRefs.length >= EXPECTED_OUTSIDE_DOC_REFS,
    `SETUP_CLAUDE_CODE の heredoc の外が消費側の docs/ を ${EXPECTED_OUTSIDE_DOC_REFS} 件以上参照している`,
    `参照 ${outsideDocRefs.length} 件`,
  );
  const outsideLinks = [...outside.matchAll(relativeLink)].map((match) => match[1]);
  const EXPECTED_OUTSIDE_LINKS = 2;
  check(
    outsideLinks.length >= EXPECTED_OUTSIDE_LINKS,
    `SETUP_CLAUDE_CODE の heredoc の外が展開先の文書へ ${EXPECTED_OUTSIDE_LINKS} 件以上リンクしている`,
    `リンク ${outsideLinks.length} 件: ${outsideLinks.join(" / ") || "-"}`,
  );
}

// MASTER.md が「必要時にコピー」と案内する文書（AI ツール設定ガイド・初心者向けガイド・組織展開
// ガイド一式など）も、消費側 docs/ へコピーして読む運用なので同じ検査を掛ける。対象は MASTER.md
// からコピー単位（定義は copy-units.mjs）として導く — 手書きの対象リストを持たないので、
// 箇条へ文書を足した日に検査が自動で追随する。単位の中の相互リンクは通し、単位の外（別の単位・
// どの単位にも属さない初期セット外）を指すリンクだけを赤にする。
// 節が見つからない・SETUP_* の 2 件が揃わない回は検査不成立として赤にする（書き換えで対象が空に
// なり、違反 0 件の緑へ倒れるのを防ぐ）。
const copyUnits = copyUnitsFromMaster(text("MASTER.md"), expandTemplatePath);
const copyMembers = copyUnits.units.flatMap((unit) => [...unit.members]);
check(
  copyUnits.errors.length === 0,
  "MASTER の「必要時にコピー」の指示からコピー単位を矛盾なく導ける（単位の重なり・一部だけのコピー・コピー元の不在が無い）",
  copyUnits.errors.join(" / "),
);
check(
  copyMembers.includes("SETUP_CLAUDE_CODE.md") && copyMembers.includes("SETUP_GITHUB_COPILOT.md"),
  "コピー単位に AI ツール設定ガイド（SETUP_CLAUDE_CODE / SETUP_GITHUB_COPILOT）が含まれる",
  `節 ${copyUnits.sections} 件 / 単位 ${copyUnits.units.length} 件 / 文書: ${copyMembers.join(", ") || "-"}`,
);
// SETUP_CLAUDE_CODE.md は heredoc の内外を分ける専用検査（上）が持つ
const copyScan = scanCopyUnits(copyUnits.units, text, expandTemplatePath, (m) => m === "SETUP_CLAUDE_CODE.md");
check(copyScan.broken.length === 0, "「必要時にコピー」の文書のリンクと inline code パスがコピー後の展開先で解決する", copyScan.broken.join(" / "));
check(
  copyScan.outside.length === 0,
  "「必要時にコピー」の文書のリンク先が初期セット・同じコピー単位の中にある（単位の外はコピー元パスの案内テキストで示す）",
  copyScan.outside.join(" / "),
);
check(copyScan.leaks.length === 0, "「必要時にコピー」の文書に展開前のディレクトリ docs-template が残っていない", copyScan.leaks.join(" / "));
check(copyScan.unresolved.length === 0, "「必要時にコピー」の文書の素テキストの docs/ 参照が配布物の実体へ解決できる", copyScan.unresolved.join(" / "));
check(copyScan.guides.length === 0, "「必要時にコピー」の文書が案内するコピー元（`${…_ROOT}/docs-template/<path>`）が配布物に実在する", copyScan.guides.join(" / "));
const copyLinks = copyScan.links;
// 解決検査はリンク 0 件でも緑になる。リンクをまとめて消す退行・対象がまとめて外れる退行を
// 違反 0 件と区別する下限（件数は不等号 — 足すのは正常な変更で、縛りたいのは消える側。
// 現状 19 文書・リンク 77 件。文書は SETUP_CLAUDE_CODE を含み、リンクは専用検査の側で数える同書を除く）
const EXPECTED_COPY_DOCS = 19;
const EXPECTED_COPY_LINKS = 77;
check(
  copyMembers.length >= EXPECTED_COPY_DOCS && copyLinks >= EXPECTED_COPY_LINKS,
  `「必要時にコピー」の文書が ${EXPECTED_COPY_DOCS} 件以上あり、展開先の文書へ ${EXPECTED_COPY_LINKS} 件以上リンクしている`,
  `文書 ${copyMembers.length} 件 / リンク ${copyLinks} 件`,
);

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

// 針ごとの変異は「検査そのものが消される」退化を検出できない（違反が無いツリーでは、
// 判定を true へ書き換えても元々 pass なので緑のまま）。実行された検査の**総数**を
// baseline で縛ると、検査を 1 つ消した時点で違反の有無に関係なく赤になる。
// 数えるのは pass ではなく pass + fail — pass だけだと、赤い検査が 1 件あるときに
// baseline も同時に割れて原因が二重になる。
// 数えるのは**この検査より前に実行された**検査（自分自身は計上前なので含まない）。
// 検査を足したらこの数も同じ PR で上げること（上げ忘れは「増やしたのに赤」で即わかる）。
// 不等号ではなく**完全一致**にする — `>=` だと上げ忘れが緑で通り、baseline が実数より
// 下にずれる。以後は「1 件足して 1 件消す」が検出されず、この針の目的自体が静かに失効する。
const EXPECTED_CHECKS = 80;
const executed = pass + failures.length;
check(
  executed === EXPECTED_CHECKS,
  `実行された検査が baseline（${EXPECTED_CHECKS} 件）と一致する`,
  `実行 ${executed} 件 — 検査が消えたか、追加時に baseline を更新していない`,
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
