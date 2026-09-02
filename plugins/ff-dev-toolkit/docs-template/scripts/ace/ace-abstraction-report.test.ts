import { describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  CANDIDATE_SCORE_THRESHOLD,
  MIN_JACCARD,
  MIN_SHARED_KEYS,
  type AbstractionEntry,
  PlaybookInputError,
  analyzeMergeCandidates,
  buildAbstractionReport,
  findMergeCandidateGroups,
  formatAbstractionReport,
  main,
  parseAbstractionEntries,
  parseArgs,
} from "./ace-abstraction-report";

/**
 * 固有名シグナルの検出・legacy 分離・メタ行除外・統合候補の組を 1 本で覆う fixture。
 *
 * - ACE-900-1: 散文に Issue 参照・ファイルパス・複数のコードスパンを持つ（候補になる）
 * - ACE-900-2: 固有名を一切持たない上位主張（候補にならない negative control）
 * - ACE-901-1: 旧テーブル形式。`**Context**:` 段落にだけ固有名がある（段落ごと除外される）
 * - ACE-902-1 / ACE-902-2: **別カテゴリ**で識別子とタイトル語彙を共有する（統合候補の組）
 * - ACE-903-1: 固有名は Origin メタセルと ACE 相互参照リンクにしか無い（メタ行除外の負の対照）
 * - ACE-905-1（legacy）/ ACE-905-2（compact）: 形式をまたぐ組（legacy も組の対象になる）
 * - ACE-906-1: **本文中の通常テーブル**に固有名がある（メタ行除外が本文へ及ばないことの対照）
 * - ACE-907-1: 同一識別子の 5 回反復（正規化後の重複排除で 1 件に畳まれる）
 * - ACE-908-1: コードフェンス内にだけ固有名がある（例示は数えない）
 */
const PLAYBOOK_FIXTURE = `# ACE Playbook

<!-- 追記例:
### ACE-001: コメント内の偽エントリ
-->

<a id="ace-900-1"></a>

### ACE-900-1: pipeline-abstraction-probe の件数照合

| Category | tooling | Origin | PR #900 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

PR #900 で踏んだ事象。\`scripts/ace/probe.ts\` が \`find\` と \`wc -l\` と \`grep -c\` と \`jq length\` を
そのまま繋いでいたため、上流の失敗が 0 件として下流へ流れた。件数は raw で受けてから照合する。

---

<a id="ace-900-2"></a>

### ACE-900-2: 件数を出す外部コマンドの失敗は 0 件と区別できない

| Category | coding | Origin | PR #900 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

件数を出す外部コマンドは、失敗しても 0 を出す。件数の入力は生の出力として受け取り、
終了コードと非空をどちらも確認してから使う。

---

<a id="ace-901-1"></a>

### ACE-901-1: 旧テーブル形式のエントリ

| Category | process | Origin | PR #901 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

**Insight**: 実行前提が分岐する検査は、前提を作ってから測る。
**Context**: PR #901 の調査で \`docs/06-reference/DECISIONS.md\` と \`scripts/ace/legacy.ts\` を突き合わせた。実測は PR #901 のログに残っている。
**Action**: 前提を作る側に寄せる。

---

<a id="ace-902-1"></a>

### ACE-902-1: bash 3.2 の変数展開は直後のマルチバイト文字を変数名に取り込む

| Category | tooling | Origin | PR #902 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

bash 3.2 では \`$VAR\` の直後に日本語を書くと変数名の一部として解釈される。
\`\${VAR}\` で閉じる。PR #902 の \`scripts/ace/run.sh\` で踏んだ。

---

<a id="ace-902-2"></a>

### ACE-902-2: bash 3.2 の変数展開を日本語文中で閉じる

| Category | testing | Origin | PR #902 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

失敗報告の文言で \`$VAR\` の直後に日本語が続くと bash 3.2 が変数名に取り込む。
\`\${VAR}\` で閉じる。PR #902 の \`scripts/ace/report.sh\` で再発した。

---

<a id="ace-903-1"></a>

### ACE-903-1: 固有名を持たない上位主張

| Category | architecture | Origin | PR #903 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

配布物の一部を変えたら、その配布物のメタデータを同じコミットで同期する。
関連: [ACE-900-2](./coding.md#ace-900-2)。

---

<a id="ace-905-1"></a>

### ACE-905-1: failopen guard は反転する

| Category | architecture | Origin | PR #905 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

**Insight**: \`failopen\` と \`failclosed\` は同一リポジトリ内で反転する。
**Action**: 壊れたとき誰の何が止まるかで決める。

---

<a id="ace-905-2"></a>

### ACE-905-2: failopen guard の緩い側が検出力の穴になる

| Category | coding | Origin | PR #905 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

同じ前提を検査する 2 つの入口が \`failopen\` と \`failclosed\` で割れていると、緩い側が穴になる。

---

<a id="ace-906-1"></a>

### ACE-906-1: 本文の表に書いた固有名も測る

| Category | documentation-quality | Origin | PR #906 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

判定材料は次の表のとおり。

| 種別 | 例 |
| --- | --- |
| 参照 | PR #906 の調査ログ |
| パス | \`docs/06-reference/GLOSSARY.md\` |

---

<a id="ace-907-1"></a>

### ACE-907-1: 同じ識別子の繰り返しは 1 件として数える

| Category | testing | Origin | PR #907 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

\`sortuniq\` を使い、\`sortuniq\` の出力を \`sortuniq\` で数え、
\`sortuniq\` を再確認し、\`sortuniq\` を最後に見る。

---

<a id="ace-908-1"></a>

### ACE-908-1: フェンス内の例示は固有名に数えない

| Category | coding | Origin | PR #908 |
| Date | 2026-09-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

例示は常に許される。

\`\`\`bash
# PR #908 で踏んだ
cat scripts/ace/fence.ts
jq length report.json
tail -n 3 out.txt
\`\`\`
`;

function parse(content: string): AbstractionEntry[] {
  return parseAbstractionEntries(content, () => {});
}

/** メタ行 4 行つきのエントリを 1 件だけ持つ最小 PLAYBOOK を組む（スコア境界の検証用） */
function singleEntryPlaybook(id: string, category: string, title: string, body: string): string {
  return [
    "# ACE Playbook",
    "",
    `<a id="${id.toLowerCase()}"></a>`,
    "",
    `### ${id}: ${title}`,
    "",
    `| Category | ${category} | Origin | PR #700 |`,
    "| Date | 2026-09-01 |",
    "| Helpful | 0 | Harmful | 0 |",
    "| Status | active |",
    "",
    body,
    "",
  ].join("\n");
}

/** `keys` を直接与えたエントリ（組み立てロジックだけを測るための最小構成） */
function makeEntry(
  id: string,
  keys: readonly string[],
  overrides: Partial<AbstractionEntry> = {},
): AbstractionEntry {
  return {
    id,
    title: `${id} のタイトル`,
    category: "testing",
    format: "compact",
    signals: { issueRefs: [], paths: [], identifiers: [] },
    score: 0,
    keys,
    ...overrides,
  };
}

/** A~B・B~C は成立するが A~C は不成立、という三角形が閉じない形 */
const TRIANGLE_ENTRIES: AbstractionEntry[] = [
  makeEntry("ACE-801-1", ["shared-ab-1", "shared-ab-2", "only-a-1", "only-a-2"]),
  makeEntry("ACE-802-1", ["shared-ab-1", "shared-ab-2", "shared-bc-1", "shared-bc-2"]),
  makeEntry("ACE-803-1", ["shared-bc-1", "shared-bc-2", "only-c-1", "only-c-2"]),
];

describe("parseAbstractionEntries", () => {
  it("固有名シグナル（Issue 参照 / パス / 識別子）を持つエントリを候補として検出する", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-900-1");
    expect(target).toBeDefined();
    expect(target?.signals.issueRefs.length).toBeGreaterThan(0);
    expect(target?.signals.paths.length).toBeGreaterThan(0);
    expect(target?.signals.identifiers.length).toBeGreaterThanOrEqual(3);
    expect(target?.score).toBeGreaterThanOrEqual(CANDIDATE_SCORE_THRESHOLD);
  });

  it("固有名を持たない上位主張は候補にならない（負の対照）", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-900-2");
    expect(target?.score).toBe(0);
    expect(target?.signals.issueRefs).toEqual([]);
    expect(target?.signals.paths).toEqual([]);
  });

  it("メタ行（Origin セル）の PR 番号と ACE 相互参照リンクはシグナルに数えない", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-903-1");
    expect(target?.signals.issueRefs).toEqual([]);
    expect(target?.signals.paths).toEqual([]);
    expect(target?.score).toBe(0);
  });

  it("メタ行の除外は見出し直後のブロックに限り、本文中の通常テーブルはシグナルに数える", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-906-1");
    expect(target?.category).toBe("documentation-quality");
    expect(target?.signals.issueRefs).toEqual(["PR #906"]);
    expect(target?.signals.paths).toEqual(["docs/06-reference/GLOSSARY.md"]);
    expect(target?.score).toBeGreaterThanOrEqual(CANDIDATE_SCORE_THRESHOLD);
  });

  it("旧テーブル形式の `**Context**:` 段落はシグナルから外す（書式の冗長性を測らない）", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-901-1");
    expect(target?.format).toBe("legacy");
    // Context 段落にしか無い PR 参照・パスは 1 件も拾わない
    expect(target?.signals.issueRefs).toEqual([]);
    expect(target?.signals.paths).toEqual([]);
    expect(target?.score).toBe(0);
  });

  it("同じ識別子の繰り返しは正規化して 1 件に畳む（閾値の水増しを防ぐ）", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-907-1");
    expect(target?.signals.identifiers).toEqual(["sortuniq"]);
    expect(target?.score).toBe(0);
  });

  it("コードフェンス内の Issue 参照・パス・識別子はシグナルに数えない", () => {
    const target = parse(PLAYBOOK_FIXTURE).find((entry) => entry.id === "ACE-908-1");
    expect(target?.signals.issueRefs).toEqual([]);
    expect(target?.signals.paths).toEqual([]);
    expect(target?.signals.identifiers).toEqual([]);
    expect(target?.score).toBe(0);
  });

  it("legacy を分離集計し、compact と混ぜない", () => {
    const entries = parse(PLAYBOOK_FIXTURE);
    expect(entries.find((entry) => entry.id === "ACE-901-1")?.format).toBe("legacy");
    expect(entries.find((entry) => entry.id === "ACE-900-1")?.format).toBe("compact");
    const report = buildAbstractionReport(entries, analyzeMergeCandidates(entries));
    const processRow = report.categories.find((row) => row.category === "process");
    expect(processRow?.legacyTotal).toBe(1);
    expect(processRow?.compactTotal).toBe(0);
    expect(report.legacyEntries).toBe(2); // ACE-901-1 / ACE-905-1
    expect(report.compactEntries).toBe(report.totalEntries - 2);
  });

  it("カテゴリを Category メタ行から取り、HTML コメント内の偽エントリを数えない", () => {
    const entries = parse(PLAYBOOK_FIXTURE);
    expect(entries.map((entry) => entry.id)).toEqual([
      "ACE-900-1",
      "ACE-900-2",
      "ACE-901-1",
      "ACE-902-1",
      "ACE-902-2",
      "ACE-903-1",
      "ACE-905-1",
      "ACE-905-2",
      "ACE-906-1",
      "ACE-907-1",
      "ACE-908-1",
    ]);
    expect(entries.find((entry) => entry.id === "ACE-902-2")?.category).toBe("testing");
  });
});

describe("エントリ範囲の打ち切り（Changelog 混入）", () => {
  const withChangelog = [
    singleEntryPlaybook("ACE-710-1", "process", "最終エントリ", "固有名を持たない主張。"),
    "## Changelog",
    "",
    "### [1.0.0] - 2026-09-02",
    "",
    "- ACE-710-1: 追加（PR #999 / Issue #998）。`scripts/ace/changelog.ts` を更新",
    "",
  ].join("\n");

  it("最終エントリが Changelog 配下の PR 番号・パスを吸収しない", () => {
    const entries = parse(withChangelog);
    expect(entries.length).toBe(1);
    expect(entries[0].signals.issueRefs).toEqual([]);
    expect(entries[0].signals.paths).toEqual([]);
    expect(entries[0].score).toBe(0);
  });
});

describe("コードフェンスの処理順", () => {
  const fencedPseudoHeading = [
    singleEntryPlaybook(
      "ACE-720-1",
      "coding",
      "フェンス内の疑似見出し",
      [
        "例示は数えない。",
        "",
        "```markdown",
        "### ACE-999-9: フェンス内の偽エントリ",
        "",
        "PR #999 と `scripts/ace/pseudo.ts` を含む例示本文。",
        "```",
      ].join("\n"),
    ),
  ].join("\n");

  it("閉じたフェンス内の正準形見出しをエントリとして数えない", () => {
    const warnings: string[] = [];
    const entries = parseAbstractionEntries(fencedPseudoHeading, (message) => {
      warnings.push(message);
    });
    expect(entries.map((entry) => entry.id)).toEqual(["ACE-720-1"]);
    // 黙って除外せず名指しする（件数ゲートが拒否する状態のため）
    expect(warnings.join("\n")).toContain("ACE-999-9");
  });

  it("フェンス内の固有名は実エントリのスコアに入らない", () => {
    const entries = parseAbstractionEntries(fencedPseudoHeading, () => {});
    expect(entries[0].signals.issueRefs).toEqual([]);
    expect(entries[0].signals.paths).toEqual([]);
    expect(entries[0].score).toBe(0);
  });

  it("未閉フェンスは黙って原文へ退避せず PlaybookInputError を投げる", () => {
    const unclosed = [
      singleEntryPlaybook("ACE-721-1", "coding", "未閉フェンス", "本文。\n\n```bash\necho hi"),
    ].join("\n");
    expect(() => parseAbstractionEntries(unclosed, () => {})).toThrow(PlaybookInputError);
  });
});

describe("legacy 判定は check-entry-format と共有する", () => {
  const legacyBody = (meta: readonly string[], body: string): string =>
    ["# ACE Playbook", "", "### ACE-730-1: 判定対象", "", ...meta, "", body, ""].join("\n");

  it("メタ表ヘッダ行（`| フィールド | 値 |`）だけでも legacy と判定する", () => {
    const entries = parse(
      legacyBody(["| フィールド | 値 |", "| Category | tooling |"], "本文だけの主張。"),
    );
    expect(entries[0].format).toBe("legacy");
  });

  it("テーブル区切り行だけでも legacy と判定する", () => {
    const entries = parse(
      legacyBody(
        ["| Category | tooling | Origin | PR #700 |", "| --- | --- |", "| Date | 2026-09-01 |"],
        "本文だけの主張。",
      ),
    );
    expect(entries[0].format).toBe("legacy");
  });

  it("Insight ブロックだけでも legacy と判定する（ハイブリッド）", () => {
    const entries = parse(
      legacyBody(
        [
          "| Category | tooling | Origin | PR #700 |",
          "| Date | 2026-09-01 |",
          "| Helpful | 0 | Harmful | 0 |",
          "| Status | active |",
        ],
        "**Insight**: 本文だけの主張。",
      ),
    );
    expect(entries[0].format).toBe("legacy");
  });

  it("マーカーが 1 つも無ければ compact（負の対照）", () => {
    const entries = parse(
      legacyBody(
        [
          "| Category | tooling | Origin | PR #700 |",
          "| Date | 2026-09-01 |",
          "| Helpful | 0 | Harmful | 0 |",
          "| Status | active |",
        ],
        "本文だけの主張。",
      ),
    );
    expect(entries[0].format).toBe("compact");
  });
});

describe("スコア閾値の境界", () => {
  const scoreOf = (body: string): number =>
    parse(singleEntryPlaybook("ACE-700-9", "process", "境界の検証", body))[0].score;
  const signalsOf = (body: string) =>
    parse(singleEntryPlaybook("ACE-700-9", "process", "境界の検証", body))[0].signals;
  const identifiers = (count: number): string =>
    Array.from({ length: count }, (_, index) => `\`ident${String(index)}\``).join(" と ") + " を使う。";

  it("Issue 参照だけで 2（+2 の寄与を完全一致で固定）", () => {
    expect(signalsOf("PR #123 を参照する。").issueRefs).toEqual(["PR #123"]);
    expect(scoreOf("PR #123 を参照する。")).toBe(2);
  });

  it("パスだけで 1（+1 の寄与）", () => {
    expect(signalsOf("`docs/x/y.md` を見る。").paths).toEqual(["docs/x/y.md"]);
    expect(scoreOf("`docs/x/y.md` を見る。")).toBe(1);
  });

  it("識別子は 2 件で 0、3 件で 1、5 件で 1、6 件で 2（両段の加点を分離して固定）", () => {
    expect(scoreOf(identifiers(2))).toBe(0);
    expect(scoreOf(identifiers(3))).toBe(1);
    expect(scoreOf(identifiers(5))).toBe(1);
    expect(scoreOf(identifiers(6))).toBe(2);
  });

  it("パス + 識別子 3 件で 2（加点が加算されている）", () => {
    expect(scoreOf(`\`docs/x/y.md\` を見る。${identifiers(3)}`)).toBe(2);
  });

  it("シグナルが 1 つも無ければ 0", () => {
    expect(scoreOf("固有名を持たない主張。")).toBe(0);
  });

  it("score がちょうど CANDIDATE_SCORE_THRESHOLD なら候補、1 なら非候補", () => {
    const candidate = parse(
      singleEntryPlaybook("ACE-700-1", "process", "参照だけを持つ主張", "PR #123 を参照する。"),
    );
    expect(candidate[0].score).toBe(CANDIDATE_SCORE_THRESHOLD);
    expect(buildAbstractionReport(candidate, analyzeMergeCandidates(candidate)).candidateEntries).toBe(1);

    const below = parse(
      singleEntryPlaybook("ACE-700-2", "process", "パスだけを持つ主張", "`docs/x/y.md` を見る。"),
    );
    expect(below[0].score).toBe(CANDIDATE_SCORE_THRESHOLD - 1);
    expect(buildAbstractionReport(below, analyzeMergeCandidates(below)).candidateEntries).toBe(0);
  });
});

describe("findMergeCandidateGroups / analyzeMergeCandidates", () => {
  it("カテゴリを跨いで識別子とタイトル語彙を共有する 2 件を 1 組として提示する", () => {
    const groups = findMergeCandidateGroups(parse(PLAYBOOK_FIXTURE));
    const group = groups.find((candidate) =>
      candidate.members.some((member) => member.id === "ACE-902-1"),
    );
    expect(group).toBeDefined();
    expect(group?.members.map((member) => member.id).slice().sort()).toEqual([
      "ACE-902-1",
      "ACE-902-2",
    ]);
    expect(new Set(group?.members.map((member) => member.category)).size).toBe(2);
    expect(group?.sharedKeys.length).toBeGreaterThanOrEqual(2);
    expect(group?.crossCategory).toBe(true);
  });

  it("legacy エントリは組の対象にしない（ADR-047 決定 4: 行き先は R3-b）", () => {
    const entries = parse(PLAYBOOK_FIXTURE);
    // ACE-905-1（legacy）と ACE-905-2（compact）は同じ識別子とタイトル語彙を共有する。
    // 形式で除外していなければ必ず組になる形なので、これは有効な負の対照である。
    const legacy = entries.find((entry) => entry.id === "ACE-905-1");
    const compact = entries.find((entry) => entry.id === "ACE-905-2");
    expect(legacy?.format).toBe("legacy");
    expect(compact?.format).toBe("compact");
    expect(legacy?.keys.filter((key) => compact?.keys.includes(key)).length).toBeGreaterThanOrEqual(
      MIN_SHARED_KEYS,
    );

    const groups = findMergeCandidateGroups(entries);
    const grouped = new Set(groups.flatMap((group) => group.members.map((member) => member.id)));
    expect(grouped.has("ACE-905-1")).toBe(false);
    // 相手が legacy だけだった compact 側も、結果として組を作れない
    expect(grouped.has("ACE-905-2")).toBe(false);
    expect(groups.every((group) => group.members.every((member) => member.format === "compact"))).toBe(
      true,
    );
  });

  it("共有シグナルの無いエントリを組にしない", () => {
    const groups = findMergeCandidateGroups(parse(PLAYBOOK_FIXTURE));
    const ids = new Set(groups.flatMap((group) => group.members.map((member) => member.id)));
    expect(ids.has("ACE-903-1")).toBe(false);
  });

  it("三角形が閉じない対では推移閉包にならず、どの組も 2 件に留まる", () => {
    // A~B・B~C は成立するが A~C は共有キー 0 で不成立。極大クリークなら {A,B,C} にはならず、
    // {A,B} と {B,C} の 2 組になる（B は両方に現れる）。
    const analysis = analyzeMergeCandidates(TRIANGLE_ENTRIES);
    expect(analysis.qualifyingPairs).toBe(2);
    expect(analysis.groups.length).toBe(2);
    expect(analysis.groups.every((group) => group.members.length === 2)).toBe(true);
    expect(
      analysis.groups.map((group) => group.members.map((member) => member.id).join("+")).sort(),
    ).toEqual(["ACE-801-1+ACE-802-1", "ACE-802-1+ACE-803-1"]);
  });

  it("極大クリークはすべての候補対を覆うので、組にできなかった対は 0 になる", () => {
    const analysis = analyzeMergeCandidates(TRIANGLE_ENTRIES);
    expect(analysis.pairedEntries).toBe(3);
    expect(analysis.ungroupedEntries).toBe(0);
    expect(analysis.ungroupedPairs).toEqual([]);
  });

  it("1 つのエントリが複数の組に現れることを許す（共有頂点）", () => {
    const analysis = analyzeMergeCandidates(TRIANGLE_ENTRIES);
    const appearances = analysis.groups.filter((group) =>
      group.members.some((member) => member.id === "ACE-802-1"),
    );
    expect(appearances.length).toBe(2);
  });

  it("組が重なるときは延べ件数と実数が食い違い、両方を報告する", () => {
    const report = buildAbstractionReport(
      TRIANGLE_ENTRIES,
      analyzeMergeCandidates(TRIANGLE_ENTRIES),
    );
    // {A,B} と {B,C} の 2 組。延べ 4 件だが実数は 3 件（B が 2 度現れる）。
    expect(report.groupedEntries).toBe(4);
    expect(report.groupedEntryCount).toBe(3);
  });

  it("組が重ならなければ延べ件数と実数は一致する", () => {
    const entries = [
      makeEntry("ACE-861-1", ["duo-1", "duo-2", "duo-only-a"]),
      makeEntry("ACE-862-1", ["duo-1", "duo-2", "duo-only-b"]),
    ];
    const report = buildAbstractionReport(entries, analyzeMergeCandidates(entries));
    expect(report.groupedEntries).toBe(2);
    expect(report.groupedEntryCount).toBe(2);
  });

  it("全対が成立する 4 件は 1 つの組にまとまる（4-clique を分断しない）", () => {
    const common = ["quad-1", "quad-2", "quad-3"];
    const entries = ["ACE-841-1", "ACE-842-1", "ACE-843-1", "ACE-844-1"].map((id, index) =>
      makeEntry(id, [...common, `only-${String(index)}`]),
    );
    const analysis = analyzeMergeCandidates(entries);
    expect(analysis.qualifyingPairs).toBe(6);
    expect(analysis.groups.length).toBe(1);
    expect(analysis.groups[0].members.map((member) => member.id)).toEqual([
      "ACE-841-1",
      "ACE-842-1",
      "ACE-843-1",
      "ACE-844-1",
    ]);
    expect(analysis.ungroupedPairs).toEqual([]);
  });

  it("live 相当の fixture でも、閾値を満たした対はすべていずれかの組に含まれる", () => {
    const entries = parse(PLAYBOOK_FIXTURE);
    const analysis = analyzeMergeCandidates(entries);
    expect(analysis.ungroupedPairs).toEqual([]);
    expect(analysis.ungroupedEntries).toBe(0);
  });

  it("共有キー数の下限: shared=1 は組にならず、shared=2 でなる", () => {
    const oneShared = [
      makeEntry("ACE-804-1", ["k-common", "only-a-1", "only-a-2"]),
      makeEntry("ACE-805-1", ["k-common", "only-b-1", "only-b-2"]),
    ];
    expect(MIN_SHARED_KEYS).toBe(2);
    expect(analyzeMergeCandidates(oneShared).groups.length).toBe(0);
    expect(analyzeMergeCandidates(oneShared).qualifyingPairs).toBe(0);

    const twoShared = [
      makeEntry("ACE-804-1", ["k-common", "k-common-2", "only-a-1"]),
      makeEntry("ACE-805-1", ["k-common", "k-common-2", "only-b-1"]),
    ];
    expect(analyzeMergeCandidates(twoShared).groups.length).toBe(1);
  });

  it("Jaccard の下限: ちょうど 0.12 で成立し、それを下回ると不成立", () => {
    const shared = ["k-1", "k-2", "k-3"];
    const fill = (prefix: string, count: number): string[] =>
      Array.from({ length: count }, (_, index) => `${prefix}-${String(index)}`);
    // 共有 3 / 和集合 25 = ちょうど 0.12
    const exact = [
      makeEntry("ACE-806-1", [...shared, ...fill("a", 11)]),
      makeEntry("ACE-807-1", [...shared, ...fill("b", 11)]),
    ];
    expect(MIN_JACCARD).toBe(0.12);
    expect(analyzeMergeCandidates(exact).groups.length).toBe(1);

    // 共有 3 / 和集合 26 ≈ 0.115 → 下限未満
    const below = [
      makeEntry("ACE-806-1", [...shared, ...fill("a", 11)]),
      makeEntry("ACE-807-1", [...shared, ...fill("b", 12)]),
    ];
    expect(analyzeMergeCandidates(below).groups.length).toBe(0);
  });

  it("MergeCandidateOptions で閾値を上書きできる", () => {
    const oneShared = [
      makeEntry("ACE-804-1", ["k-common", "only-a-1", "only-a-2"]),
      makeEntry("ACE-805-1", ["k-common", "only-b-1", "only-b-2"]),
    ];
    expect(analyzeMergeCandidates(oneShared, { minSharedKeys: 1 }).groups.length).toBe(1);
    expect(
      analyzeMergeCandidates(oneShared, { minSharedKeys: 1, minJaccard: 0.9 }).groups.length,
    ).toBe(0);
  });
});

describe("組み立ての決定性", () => {
  /**
   * X~Y と X~Z が成立し Y~Z は不成立、という形。極大クリークなら**どちらの対も残る**
   * （貪欲な完全連結では先に組を作った側だけが残り、もう片方が消えていた）。
   * 出力順は「件数 → 最大 Jaccard → 先頭 ID」で決まる。
   */
  const buildTie = (firstId: string, secondId: string): AbstractionEntry[] => [
    makeEntry("ACE-809-1", ["pair-a-1", "pair-a-2", "pair-b-1", "pair-b-2"]),
    makeEntry(firstId, ["pair-a-1", "pair-a-2", "tie-1", "tie-2"]),
    makeEntry(secondId, ["pair-b-1", "pair-b-2", "tie-3", "tie-4"]),
  ];

  it("同点の 2 組はどちらも残り、先頭 ID の昇順で並ぶ", () => {
    const analysis = analyzeMergeCandidates(buildTie("ACE-810-1", "ACE-820-1"));
    expect(analysis.qualifyingPairs).toBe(2);
    expect(analysis.groups.length).toBe(2);
    expect(analysis.groups.map((group) => group.members.map((member) => member.id).join("+"))).toEqual([
      "ACE-809-1+ACE-810-1",
      "ACE-809-1+ACE-820-1",
    ]);
    expect(analysis.ungroupedPairs).toEqual([]);
  });

  it("ID を入れ替えると並び順も入れ替わる（先頭 ID のタイブレークが効いている）", () => {
    const analysis = analyzeMergeCandidates(buildTie("ACE-830-1", "ACE-811-1"));
    expect(analysis.groups.map((group) => group.members.map((member) => member.id).join("+"))).toEqual([
      "ACE-809-1+ACE-811-1",
      "ACE-809-1+ACE-830-1",
    ]);
  });

  it("件数の多い組が先に来る", () => {
    const entries = [
      ...["ACE-851-1", "ACE-852-1", "ACE-853-1"].map((id, index) =>
        makeEntry(id, ["trio-1", "trio-2", `trio-only-${String(index)}`]),
      ),
      makeEntry("ACE-861-1", ["duo-1", "duo-2", "duo-only-a"]),
      makeEntry("ACE-862-1", ["duo-1", "duo-2", "duo-only-b"]),
    ];
    const groups = analyzeMergeCandidates(entries).groups;
    expect(groups[0].members.length).toBe(3);
    expect(groups[1].members.length).toBe(2);
  });

  it("同じ入力を 2 回処理しても出力が一致する", () => {
    const entries = parse(PLAYBOOK_FIXTURE);
    const first = buildAbstractionReport(entries, analyzeMergeCandidates(entries));
    const second = buildAbstractionReport(
      parse(PLAYBOOK_FIXTURE),
      analyzeMergeCandidates(parse(PLAYBOOK_FIXTURE)),
    );
    expect(JSON.stringify(second)).toBe(JSON.stringify(first));
    expect(formatAbstractionReport(second)).toBe(formatAbstractionReport(first));
  });
});

describe("formatAbstractionReport", () => {
  it("対象件数・候補件数・カテゴリ別内訳（compact / legacy）・候補組を出力する", () => {
    const entries = parse(PLAYBOOK_FIXTURE);
    const text = formatAbstractionReport(
      buildAbstractionReport(entries, analyzeMergeCandidates(entries)),
    );
    expect(text).toContain("対象エントリ");
    expect(text).toContain("compact");
    expect(text).toContain("legacy");
    expect(text).toContain("統合候補");
    expect(text).toContain("ACE-902-1");
  });

  it("候補対の集計を出し、未配置対が無ければ 0 対と明示する", () => {
    const text = formatAbstractionReport(
      buildAbstractionReport(TRIANGLE_ENTRIES, analyzeMergeCandidates(TRIANGLE_ENTRIES)),
    );
    expect(text).toContain("## 組にできなかった候補対");
    expect(text).toContain("統合候補: 2 組（延べ 4 件 / 実数 3 件）");
    expect(text).toContain("候補対: 2 対 / 3 件");
    expect(text).toContain("組にできなかった対 0 対");
    expect(text).toContain("該当なし。");
  });

  it("未配置対があれば専用の節に出す（表示打ち切りとは別勘定）", () => {
    // 実装が対を落とすようになった状態を模したレポート入力（極大クリークでは起きない形）。
    const analysis = analyzeMergeCandidates(TRIANGLE_ENTRIES);
    const degraded = {
      ...analysis,
      groups: analysis.groups.slice(0, 1),
      ungroupedPairs: [
        {
          members: [
            { id: "ACE-802-1", category: "testing", format: "compact" as const, title: "B" },
            { id: "ACE-803-1", category: "coding", format: "compact" as const, title: "C" },
          ] as const,
          sharedKeys: ["shared-bc-1", "shared-bc-2"],
          jaccard: 0.5,
          crossCategory: true,
        },
      ],
      ungroupedEntries: 1,
    };
    const text = formatAbstractionReport(buildAbstractionReport(TRIANGLE_ENTRIES, degraded));
    expect(text).toContain("組にできなかった対 1 対");
    expect(text).toContain("どの組にも入らなかったエントリ 1 件");
    expect(text).toContain("ACE-803-1");
  });
});

describe("parseArgs", () => {
  it("PLAYBOOK パスと各オプションを受ける", () => {
    const parsed = parseArgs([
      "docs/08-knowledge/PLAYBOOK.md",
      "--json",
      "--max-groups=5",
      "--max-candidates=7",
      "--max-ungrouped-pairs=9",
    ]);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.playbookPath).toBe("docs/08-knowledge/PLAYBOOK.md");
      expect(parsed.json).toBe(true);
      expect(parsed.maxGroups).toBe(5);
      expect(parsed.maxCandidates).toBe(7);
      expect(parsed.maxUngroupedPairs).toBe(9);
    }
  });

  it("数値でない上限を拒否する", () => {
    const parsed = parseArgs(["PLAYBOOK.md", "--max-groups=abc"]);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) {
      expect(parsed.message).toContain("--max-groups");
    }
  });

  it("0 以下の上限を拒否する", () => {
    const parsed = parseArgs(["PLAYBOOK.md", "--max-candidates=0"]);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) {
      expect(parsed.message).toContain("--max-candidates");
    }
  });

  it("不明なオプションを拒否する（catch-all）", () => {
    const parsed = parseArgs(["PLAYBOOK.md", "--fix"]);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) {
      expect(parsed.message).toContain("不明なオプション");
    }
  });

  it("PLAYBOOK パスの二重指定を拒否する", () => {
    const parsed = parseArgs(["a/PLAYBOOK.md", "b/PLAYBOOK.md"]);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) {
      expect(parsed.message).toContain("1 つだけ");
    }
  });

  it("パス未指定を拒否する", () => {
    const parsed = parseArgs(["--json"]);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) {
      expect(parsed.message).toContain("指定されていません");
    }
  });
});

describe("main", () => {
  const withCapturedLog = (run: () => number): { rc: number; logs: string } => {
    const logs: string[] = [];
    const originalLog = console.log;
    console.log = (...args: unknown[]) => {
      logs.push(args.map((value) => String(value)).join(" "));
    };
    try {
      return { rc: run(), logs: logs.join("\n") };
    } finally {
      console.log = originalLog;
    }
  };

  const writeFixture = (prefix: string): { dir: string; playbook: string } => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(playbook, PLAYBOOK_FIXTURE);
    return { dir, playbook };
  };

  it("dry-run 既定: 実行しても入力ファイルを書き換えず exit 0 を返す", () => {
    const { dir, playbook } = writeFixture("ace-abstraction-dryrun-");
    const before = fs.readFileSync(playbook, "utf8");
    const beforeNames = fs.readdirSync(dir).slice().sort();

    const { rc, logs } = withCapturedLog(() => main([playbook]));

    expect(rc).toBe(0);
    expect(fs.readFileSync(playbook, "utf8")).toBe(before);
    expect(fs.readdirSync(dir).slice().sort()).toEqual(beforeNames);
    expect(logs).toContain("対象エントリ");
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("--json で機械可読な集計を全フィールド出す", () => {
    const { dir, playbook } = writeFixture("ace-abstraction-json-");
    const { rc, logs } = withCapturedLog(() => main([playbook, "--json"]));
    expect(rc).toBe(0);

    const parsed = JSON.parse(logs) as Record<string, unknown>;
    expect(Object.keys(parsed).slice().sort()).toEqual([
      "candidateEntries",
      "candidates",
      "categories",
      "compactCandidates",
      "compactEntries",
      "groupedEntries",
      "groupedEntryCount",
      "groups",
      "legacyCandidates",
      "legacyEntries",
      "pairedEntries",
      "qualifyingPairs",
      "strongCandidates",
      "totalEntries",
      "ungroupedEntries",
      "ungroupedPairs",
    ]);

    const entries = parse(PLAYBOOK_FIXTURE);
    expect(parsed.totalEntries).toBe(entries.length);
    expect(parsed.compactEntries).toBe(entries.length - 2);
    expect(parsed.legacyEntries).toBe(2);
    expect(parsed.candidateEntries).toBeGreaterThan(0);
    expect(typeof parsed.strongCandidates).toBe("number");
    expect(typeof parsed.qualifyingPairs).toBe("number");
    expect(typeof parsed.pairedEntries).toBe("number");
    expect(typeof parsed.ungroupedEntries).toBe("number");
    expect(Array.isArray(parsed.ungroupedPairs)).toBe(true);

    const categories = parsed.categories as Record<string, unknown>[];
    expect(categories.length).toBeGreaterThan(0);
    expect(Object.keys(categories[0]).slice().sort()).toEqual([
      "category",
      "compactCandidates",
      "compactTotal",
      "legacyCandidates",
      "legacyTotal",
      "total",
    ]);

    const candidates = parsed.candidates as Record<string, unknown>[];
    expect(candidates.length).toBeGreaterThan(0);
    expect(Object.keys(candidates[0]).slice().sort()).toEqual([
      "category",
      "format",
      "id",
      "keys",
      "score",
      "signals",
      "title",
    ]);
    expect(Object.keys(candidates[0].signals as object).slice().sort()).toEqual([
      "identifiers",
      "issueRefs",
      "paths",
    ]);

    const groups = parsed.groups as Record<string, unknown>[];
    expect(groups.length).toBeGreaterThan(0);
    expect(Object.keys(groups[0]).slice().sort()).toEqual([
      "crossCategory",
      "members",
      "sharedKeys",
      "topJaccard",
    ]);
    expect(parsed.groupedEntries).toBe(
      groups.reduce((sum, group) => sum + (group.members as unknown[]).length, 0),
    );
    expect(parsed.groupedEntryCount).toBe(
      new Set(
        groups.flatMap((group) =>
          (group.members as { readonly id: string }[]).map((member) => member.id),
        ),
      ).size,
    );
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("入力不備は非 0（使用方法エラー）で返す", () => {
    const originalError = console.error;
    console.error = () => {};
    try {
      expect(main([])).toBe(2);
      expect(main([path.join(os.tmpdir(), "ace-abstraction-missing-file.md")])).toBe(2);
      const { dir, playbook } = writeFixture("ace-abstraction-usage-");
      expect(main([playbook, "--max-groups=0"])).toBe(2);
      expect(main([playbook, "--unknown"])).toBe(2);
      fs.rmSync(dir, { recursive: true, force: true });
    } finally {
      console.error = originalError;
    }
  });

  it("読み込み・集計が例外を投げたら実行時エラー（1）で返す", () => {
    const { dir, playbook } = writeFixture("ace-abstraction-runtime-");
    const originalError = console.error;
    const errors: string[] = [];
    console.error = (...args: unknown[]) => {
      errors.push(args.map((value) => String(value)).join(" "));
    };
    try {
      const rc = main([playbook], {
        readFile: () => {
          throw new Error("読み込みに失敗しました（注入）");
        },
      });
      expect(rc).toBe(1);
      expect(errors.join("\n")).toContain("レポート生成に失敗しました");
    } finally {
      console.error = originalError;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("分割レイアウトでも、直前ファイルの最終エントリが次ファイルの前書きを吸収しない", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-abstraction-split-"));
    fs.writeFileSync(path.join(dir, "PLAYBOOK.md"), "# ACE Playbook\n\n索引のみ。\n");
    const subDir = path.join(dir, "playbook");
    fs.mkdirSync(subDir);
    fs.writeFileSync(
      path.join(subDir, "a-coding.md"),
      singleEntryPlaybook("ACE-740-1", "coding", "A の最終エントリ", "固有名を持たない主張。"),
    );
    fs.writeFileSync(
      path.join(subDir, "b-testing.md"),
      [
        "# testing",
        "",
        "この前書きには PR #777 と `scripts/ace/next-file.ts` がある。",
        "",
        singleEntryPlaybook("ACE-741-1", "testing", "B のエントリ", "固有名を持たない主張。"),
      ].join("\n"),
    );

    const { rc, logs } = withCapturedLog(() => main([path.join(dir, "PLAYBOOK.md"), "--json"]));
    expect(rc).toBe(0);
    const parsed = JSON.parse(logs) as {
      candidates: readonly { readonly id: string }[];
      totalEntries: number;
    };
    expect(parsed.totalEntries).toBe(2);
    // 前書きの固有名を吸収していれば ACE-740-1 が候補になる
    expect(parsed.candidates.map((candidate) => candidate.id)).toEqual([]);
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("ACE エントリ 0 件はレポートを出さず usage error（2）で止める", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-abstraction-empty-"));
    const notPlaybook = path.join(dir, "README.md");
    fs.writeFileSync(notPlaybook, "# 普通の Markdown\n\nACE エントリは 1 件も無い。\n");
    const logs: string[] = [];
    const errors: string[] = [];
    const originalLog = console.log;
    const originalError = console.error;
    console.log = (...args: unknown[]) => {
      logs.push(args.map((value) => String(value)).join(" "));
    };
    console.error = (...args: unknown[]) => {
      errors.push(args.map((value) => String(value)).join(" "));
    };
    try {
      expect(main([notPlaybook])).toBe(2);
    } finally {
      console.log = originalLog;
      console.error = originalError;
    }
    expect(logs.join("\n")).toBe("");
    expect(errors.join("\n")).toContain("ACE エントリが 0 件");
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("未閉フェンスはレポートを出さず usage error（2）で止める", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-abstraction-fence-"));
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      singleEntryPlaybook("ACE-742-1", "coding", "未閉フェンス", "本文。\n\n```bash\necho hi"),
    );
    const logs: string[] = [];
    const errors: string[] = [];
    const originalLog = console.log;
    const originalError = console.error;
    console.log = (...args: unknown[]) => {
      logs.push(args.map((value) => String(value)).join(" "));
    };
    console.error = (...args: unknown[]) => {
      errors.push(args.map((value) => String(value)).join(" "));
    };
    try {
      expect(main([playbook])).toBe(2);
    } finally {
      console.log = originalLog;
      console.error = originalError;
    }
    expect(logs.join("\n")).toBe("");
    expect(errors.join("\n")).toContain("コードフェンスが閉じていません");
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("報告のみなので、候補が出ても終了コードは 0 のまま（ゲートにしない）", () => {
    const { dir, playbook } = writeFixture("ace-abstraction-exit-");
    const { rc } = withCapturedLog(() => main([playbook]));
    expect(rc).toBe(0);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
