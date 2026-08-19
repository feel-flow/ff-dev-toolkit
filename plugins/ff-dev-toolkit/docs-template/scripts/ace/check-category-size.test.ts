import { afterEach, describe, expect, it, vi } from "vitest";
import {
  analyzePlaybookMarkdown,
  blankCodeRegions,
  countBudgetExceptions,
  countHeaderLines,
  countPlaybookLines,
  DEFAULT_MAX_ENTRIES_PER_CATEGORY,
  DEFAULT_WARN_ENTRIES_PER_CATEGORY,
  deriveMaxLines,
  discoverPlaybookSubfiles,
  findFencedCanonicalHeadings,
  isDirectExecution,
  isOverLineThreshold,
  main,
  mergeAnalyses,
  parsePositiveIntEnv,
  scanUnclosedFence,
  splitEntrySegments,
} from "./check-category-size";
import { measureEntryLines } from "./ace-refine-report";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

describe("analyzePlaybookMarkdown", () => {
  it("HTML コメント内の ACE 見出しは無視し、実エントリのみ数える", () => {
    const md = `
<!-- 追記例:
### ACE-001: コメント内の偽エントリ

| フィールド | 値 |
| Category | security |
-->

### ACE-001: 実エントリ

| フィールド | 値 |
| Category | coding |
| Origin | PR #1 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("コンパクト正準フォーマット（相乗りセルの Category 行）も集計される", () => {
    // PLAYBOOK.md §エントリテンプレート（1.62.0）の正準形式。
    // `| Category | coding | Origin | PR #24 |` の第 2 セルが Category 値として捕捉されること。
    const md = `
<a id="ace-24-1"></a>

### ACE-24-1: コンパクト形式のエントリ

| Category | coding | Origin | PR #24 |
| Date | 2026-07-31 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

本文 2〜4 文。

---
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.coding).toBe(1);
    }
  });

  it("ACE-1000 のように 4 桁以上の ID もエントリとして扱う", () => {
    const md = `
### ACE-1000: 将来の連番

| フィールド | 値 |
| Category | process |
| Origin | PR #999 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.process).toBe(1);
    }
  });

  it("PRスコープ式 ID（ACE-438-1）と Issue 式（ACE-i425-1）もエントリとして扱う", () => {
    const md = `
### ACE-438-1: PRスコープ式エントリ

| フィールド | 値 |
| Category | coding |
| Origin | PR #438 |

### ACE-438-2: 同一PRの2件目

| フィールド | 値 |
| Category | testing |
| Origin | PR #438 |

### ACE-i425-1: Issue 由来エントリ

| フィールド | 値 |
| Category | process |
| Origin | Issue #425 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(3);
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.testing).toBe(1);
      expect(result.histogram.process).toBe(1);
    }
  });

  it("プレースホルダ見出し（ACE-XXX / ACE-NNN）と i の後が非数字（ACE-iabc）は集計しない", () => {
    const md = `
### ACE-XXX: [タイトル]

| フィールド | 値 |
| Category | coding / architecture / testing |

### ACE-NNN: 別プレースホルダ

| フィールド | 値 |
| Category | testing |

### ACE-iabc: i の後が数字でないため実IDではない

| フィールド | 値 |
| Category | security |

### ACE-001: 実エントリ

| フィールド | 値 |
| Category | coding |
| Origin | PR #1 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.testing).toBeUndefined();
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("ACE 見出しが無い場合は error を返す", () => {
    const result = analyzePlaybookMarkdown("# 見出しのみ\n");
    expect(result.kind).toBe("error");
  });

  it("ヘッダ領域（最初のエントリより前）の未閉フェンスも error にする", () => {
    // 従来の検査は split(...).slice(1) の後のセグメントにしか効かず、ヘッダ側の
    // 打ち間違いは素通りしていた。ヘッダの未閉フェンスは blankCodeRegions が
    // ファイル全体を走査するため後続の全エントリへ波及し、行数バジェット例外の
    // 判定が黙って効かなくなる。
    const md = [
      "# Header",
      "```markdown",
      "閉じ忘れたフェンス",
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding |",
      "",
    ].join("\n");

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("ヘッダ領域");
    }
  });

  it("allowEmpty:true なら見出し0件でも error にせず空の ok を返す（分割レイアウトの索引ファイル向け）", () => {
    const result = analyzePlaybookMarkdown("# 索引のみ\n", { allowEmpty: true });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(0);
      expect(result.histogram).toEqual({});
    }
  });

  it("allowEmpty:true でも Category 行が解析できないブロックは依然 error", () => {
    const md = "### ACE-1-1: 実エントリだが Category 行が壊れている\n\n| Origin | PR #1 |\n";
    const result = analyzePlaybookMarkdown(md, { allowEmpty: true });
    expect(result.kind).toBe("error");
  });

  it("Category の値が空（| Category |  |）は error（空文字キーで集計しない）", () => {
    const md = `
### ACE-002-1: 空

| Category |  |

### ACE-002-2: 正常

| Category | testing |
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("Category の値が空");
    }
  });

  it("allowEmpty:true でも空 Category は error", () => {
    const md = "### ACE-1-1: 空\n\n| Category |   |\n";
    const result = analyzePlaybookMarkdown(md, { allowEmpty: true });
    expect(result.kind).toBe("error");
  });

  it("見出しとして認識されないブロックが直前エントリへ吸収されたら error（件数が静かに減らない）", () => {
    // Issue #340: 中央のブロックだけ ID が正準形を外れると、そのブロックは直前の
    // セグメントへ吸収される。修正前は kind:"ok" / histogram {coding:2} を返し、
    // testing の 1 件は histogram から丸ごと消えたままエラーにもならなかった。
    const md = `
### ACE-1-1: 正常なエントリ

| Category | coding | Origin | PR #1 |

---

### ACE-abc-1: ID を打ち間違えて見出しと認識されないエントリ

| Category | testing | Origin | PR #1 |

---

### ACE-1-2: 正常なエントリ

| Category | coding | Origin | PR #1 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("吸収");
      // 「該当箇所の特定方法」= 認識されなかった見出しそのものを名指しできること。
      expect(result.message).toContain("ACE-abc-1");
      // 検出した Category 値は**全件**挙げる（先頭だけに縮退させない）。
      expect(result.message).toContain("coding");
      expect(result.message).toContain("testing");
    }
  });

  it("吸収エラーの見出し候補に本文の小見出しを混ぜない", () => {
    const md = `
### ACE-4-1: 正常なエントリ

| Category | coding | Origin | PR #4 |

#### 補足の小見出し

### ACE-abc-1: ID を打ち間違えたエントリ

| Category | testing | Origin | PR #4 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("ACE-abc-1");
      expect(result.message).not.toContain("補足の小見出し");
      // セグメント自身の見出しは「認識された」側なので候補に出さない。
      // splitEntrySegments が見出し行を保持するようになった（Issue #353）ので、
      // 呼び出し側で 1 行目を落とさないと正しい見出しが候補の先頭に立つ。
      expect(result.message).not.toContain("正常なエントリ");
    }
  });

  it("ACE を含まない見出しでも候補として名指しする（プレフィックスごと書き忘れた形）", () => {
    // 候補は「ACE を含む行があればそれだけに絞る」が、1 本も無ければ見出し全体を返す。
    // fixture の見出し文字列に "ACE" を混ぜるとフォールバック側を通らず、絞り込みだけを
    // 検査したことになる（この形で一度偽の緑になった）。
    const md = `
### ACE-4-2: 正常なエントリ

| Category | coding | Origin | PR #4 |

### 340-1: 接頭辞ごと書き忘れた見出し

| Category | testing | Origin | PR #4 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("340-1");
    }
  });

  it("見出し候補にフェンス内のテンプレート見出しを混ぜない（空白化後を読む）", () => {
    // 候補の抽出をフェンス空白化**前**のセグメントで行うと、本文が例示している
    // テンプレート見出しまで「認識されなかった見出し」として提示され、
    // 直すべき箇所として正しい本文を指してしまう。
    const fence = "```";
    const md = `
### ACE-4-5: 追記テンプレートを例示するエントリ

| Category | coding | Origin | PR #4 |

${fence}markdown
### ACE-XXX: [タイトル]
${fence}

### ACE-abc-1: ID を打ち間違えたエントリ

| Category | testing | Origin | PR #4 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("ACE-abc-1");
      expect(result.message).not.toContain("ACE-XXX");
    }
  });

  it("見出しが 1 本も無い吸収では候補節そのものを出さない", () => {
    const md = `
### ACE-4-3: Category 行が 2 本並んだエントリ

| Category | coding | Origin | PR #4 |
| Category | testing | Origin | PR #4 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("Category 行が 2 本");
      expect(result.message).not.toContain("見出し候補");
    }
  });

  it("吸収された側の値が空でも、2 本あることを先に報告する（空値チェックより前）", () => {
    const md = `
### ACE-4-4: 正常なエントリ

| Category | coding | Origin | PR #4 |

### ACE-abc-1: ID を打ち間違えたエントリ

| Category |  |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("吸収");
      // 空値も欠落させず「（空）」として数に合わせて挙げる。
      expect(result.message).toContain("（空）");
      expect(result.message).not.toContain("Category の値が空の ACE ブロック");
    }
  });

  it("コードフェンス内に Category 表を例示するエントリは ok のまま（偽陽性を出さない）", () => {
    // live / docs-template の PLAYBOOK.md はテンプレート断片をフェンスで囲って載せている。
    // フェンスを空白化せずに Category 行を数えると、この正常なエントリが吸収扱いになる。
    const fence = "```";
    const md = `
### ACE-2-1: 追記テンプレートを本文で例示するエントリ

| Category | coding | Origin | PR #2 |
| Date | 2026-08-09 |

追記は次の形で行う。

${fence}markdown
### ACE-XXX: [検索可能な主張 1 文のタイトル]

| Category | coding | Origin | PR #XXX |
${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.coding).toBe(1);
    }
  });

  it("Category 行がフェンス内にしか無いエントリは error（フェンス内の例示を値として採らない）", () => {
    // 抽出とカウントを同じテキスト（フェンス空白化後）で行うことの担保。
    // 片方だけ空白化すると、実 Category 行が無いのに例示の値で集計され、
    // 「2 本以上」にも当たらないため静かに誤ったカテゴリへ 1 件加算される。
    const fence = "~~~";
    const md = `
### ACE-2-2: 実 Category 行が欠けているエントリ

${fence}markdown
| Category | coding |
${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("Category 行を解析できない");
    }
  });

  it("インデントしたフェンスも空白化の対象（インデント許容だけを固定する）", () => {
    // フェンス行だけインデントし、中身は行頭から始まる形。Category 行の正規表現は
    // 行頭 `|` を要求するので、フェンス行のインデントを見落とすと**この形だけ**が
    // 偽陽性へ抜ける。情報文字列の扱いは他のテストが既に通しているので、ここが単独で
    // 守っているのは開始行・終了行のインデント許容のみ。
    const fence = "```";
    const md = `
### ACE-2-3: インデントしたフェンスで例示するエントリ

| Category | tooling | Origin | PR #2 |

  ${fence}md title="追記例"
| Category | testing |
  ${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.tooling).toBe(1);
      expect(result.histogram.testing).toBeUndefined();
    }
  });

  it("リスト項目内の 4 スペースフェンスも空白化する（CommonMark の 3 まで規則を採らない）", () => {
    // リスト内容カラム基準では有効なフェンス。トップレベル基準の「インデント 3 まで」で
    // 実装すると取りこぼし、**正常なエントリが吸収エラーになる**（偽陽性）。
    const fence = "```";
    const md = `
### ACE-2-4: リスト項目の中で例示するエントリ

| Category | tooling | Origin | PR #2 |

- 例:

    ${fence}markdown
| Category | testing |
    ${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.histogram.tooling).toBe(1);
      expect(result.histogram.testing).toBeUndefined();
    }
  });

  it("フェンス例示の後ろに実 Category 行があるとき、例示の値を採らない", () => {
    // 抽出とカウントを同じテキストで行うことの担保（値の側）。カウントだけ空白化して
    // 抽出を生セグメントから行うと、先に現れる例示の値（testing）が採用される。
    const fence = "```";
    const md = `
### ACE-3-1: 説明のあとにメタ行を置くエントリ

書式は次のとおり。

${fence}markdown
| Category | testing |
${fence}

| Category | coding | Origin | PR #3 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.testing).toBeUndefined();
    }
  });

  it("閉じ忘れフェンスがあっても後続の吸収ブロックを見逃さない（fail-closed）", () => {
    // 閉じないフェンスは以降を末尾まで空白化するため、吸収ブロックの Category 行だけが
    // 消えて本数が 1 本へ戻る。偽陽性ガードが検出器の証拠を消す形なので、
    // 「閉じていない」こと自体をエラーにする。
    const fence = "```";
    const md = `
### ACE-5-1: 閉じ忘れフェンスを含むエントリ

| Category | coding | Origin | PR #5 |

${fence}text
閉じ忘れ

### ACE-abc-1: ID を打ち間違えたエントリ

| Category | testing | Origin | PR #5 |

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("閉じていないコードフェンス");
    }
  });

  it("フェンス内に正準形の見出しがあるとき、幻のエントリを静かに増やさない", () => {
    // 閉じたフェンス内の正準形 ID は fail-loud で拒否する（Issue #342）。境界を
    // フェンス空白化側へ付け替える案は採らない — セグメント跨ぎで偶然対になる
    // 閉じ忘れ（#353 の曖昧形）で実エントリが引用として静かに吸収されるため、
    // 例示を ACE-XXX へ直させる。
    const fence = "```";
    const md = `
### ACE-6-1: 悪い書き方を引用するエントリ

| Category | documentation-quality | Origin | PR #6 |

${fence}markdown
### ACE-9-9: 悪い例

| Category | coding |
${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("ACE-9-9");
      expect(result.message).toContain("ACE-XXX");
    }
  });

  it("``` フェンス内の ~~~ 行では閉じない（終端記号の種別）", () => {
    const fence = "```";
    const tilde = "~~~";
    const md = `
### ACE-3-2: フェンス内に別記号の区切りを含むエントリ

| Category | coding | Origin | PR #3 |

${fence}markdown
${tilde}
| Category | security |
${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("4 本フェンス内の 3 本行では閉じない（終端記号の本数）", () => {
    const fence = "```";
    const outer = "````";
    const md = `
### ACE-3-3: 入れ子フェンスを例示するエントリ

| Category | coding | Origin | PR #3 |

${outer}markdown
${fence}
| Category | security |
${fence}
${outer}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("情報文字列付きの行は終端にならない（終端は記号だけの行）", () => {
    const fence = "```";
    const md = `
### ACE-3-4: フェンス内で別のフェンス開始行を例示するエントリ

| Category | coding | Origin | PR #3 |

${fence}markdown
${fence}js
| Category | security |
${fence}

---
`;
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("CRLF でも吸収を検出する（終端フェンス判定が \\r で崩れない）", () => {
    // split("\n") 後に残る \r を落とさないと全フェンスが閉じなくなり、以降が
    // 丸ごと空白化されて吸収検出が黙る。docs-template は Windows チェックアウトを
    // 含む他プロジェクトへ配布されるため、LF 前提にはできない。
    const fence = "```";
    const md = [
      "### ACE-7-1: 正常なエントリ",
      "",
      "| Category | coding | Origin | PR #7 |",
      "",
      `${fence}markdown`,
      "| Category | example |",
      fence,
      "",
      "### ACE-abc-1: ID を打ち間違えたエントリ",
      "",
      "| Category | testing | Origin | PR #7 |",
      "",
    ].join("\r\n");
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("吸収");
    }
  });

  it("CRLF の正常なエントリを偽陽性で落とさない", () => {
    const fence = "```";
    const md = [
      "### ACE-7-2: フェンスで例示する正常なエントリ",
      "",
      "| Category | coding | Origin | PR #7 |",
      "",
      `${fence}markdown`,
      "| Category | testing |",
      fence,
      "",
      "---",
      "",
    ].join("\r\n");
    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.testing).toBeUndefined();
    }
  });
});

describe("mergeAnalyses", () => {
  it("複数ファイルの histogram / totalEntries を合算する", () => {
    const merged = mergeAnalyses([
      { kind: "ok", histogram: { coding: 2, process: 1 }, totalEntries: 3 },
      { kind: "ok", histogram: { process: 4 }, totalEntries: 4 },
      { kind: "ok", histogram: {}, totalEntries: 0 },
    ]);
    expect(merged.kind).toBe("ok");
    if (merged.kind !== "ok") return;
    expect(merged.totalEntries).toBe(7);
    expect(merged.histogram).toEqual({ coding: 2, process: 5 });
  });

  it("空配列は totalEntries 0 の ok を返す", () => {
    const merged = mergeAnalyses([]);
    expect(merged.kind).toBe("ok");
    if (merged.kind !== "ok") return;
    expect(merged.totalEntries).toBe(0);
    expect(merged.histogram).toEqual({});
  });

  it("histogram に undefined が混ざっていたら error を返す（silent に捨てない）", () => {
    const merged = mergeAnalyses([
      {
        kind: "ok",
        totalEntries: 200,
        histogram: { testing: undefined, process: 5 },
      },
    ]);

    expect(merged.kind).toBe("error");
    if (merged.kind !== "error") return;
    expect(merged.message).toContain("testing");
  });

  it("histogram に NaN が混ざっていたら error を返す（silent に捨てない）", () => {
    const merged = mergeAnalyses([
      { kind: "ok", totalEntries: 200, histogram: { coding: Number.NaN } },
    ]);

    expect(merged.kind).toBe("error");
    if (merged.kind !== "error") return;
    expect(merged.message).toContain("coding");
  });

  it("負数・小数の件数は有限でも error（131 + (-2) で閾値を静かに回避させない）", () => {
    const negative = mergeAnalyses([
      { kind: "ok", totalEntries: 2, histogram: { coding: 4, testing: -2 } },
    ]);
    expect(negative.kind).toBe("error");
    if (negative.kind === "error") expect(negative.message).toContain("testing");

    const fractional = mergeAnalyses([
      { kind: "ok", totalEntries: 1, histogram: { coding: 1.5 } },
    ]);
    expect(fractional.kind).toBe("error");
    if (fractional.kind === "error") expect(fractional.message).toContain("coding");
  });

  it("カテゴリ別件数の合計が総エントリ数と一致しなければ error（キーごと脱落した形）", () => {
    // 値の検査では届かない破れ方。Object.entries に現れないキーは per-value 判定に
    // 到達しないので、合計との突き合わせだけが検出できる。
    const merged = mergeAnalyses([
      { kind: "ok", totalEntries: 5, histogram: { coding: 1 } },
    ]);

    expect(merged.kind).toBe("error");
    if (merged.kind !== "error") return;
    expect(merged.message).toContain("一致しません");
  });
});

describe("discoverPlaybookSubfiles", () => {
  let tmpDir = "";

  afterEach(() => {
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  it("playbook/ ディレクトリが無い場合は空配列（旧レイアウト）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# no subfiles\n");

    expect(discoverPlaybookSubfiles(playbookPath)).toEqual([]);
  });

  it("playbook/ 配下の .md ファイルをソート済みで返す（.md 以外は無視）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    const subDir = path.join(tmpDir, "playbook");
    fs.mkdirSync(subDir);
    fs.writeFileSync(path.join(subDir, "tooling.md"), "");
    fs.writeFileSync(path.join(subDir, "coding.md"), "");
    fs.writeFileSync(path.join(subDir, "README.txt"), "");

    expect(discoverPlaybookSubfiles(playbookPath)).toEqual([
      path.join(subDir, "coding.md"),
      path.join(subDir, "tooling.md"),
    ]);
  });

  it("playbook/archive/ 配下（/ace-refine の退避先）は検出しない（非再帰の仕様固定）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    const subDir = path.join(tmpDir, "playbook");
    const archiveDir = path.join(subDir, "archive");
    fs.mkdirSync(archiveDir, { recursive: true });
    fs.writeFileSync(path.join(subDir, "coding.md"), "");
    fs.writeFileSync(
      path.join(archiveDir, "coding.md"),
      "### ACE-1-1: アーカイブ済みエントリ\n\n| Category | coding |\n",
    );

    // archive 配下がここに混ざると ace_entry_count・カテゴリ件数ゲート・reuse 集計へ
    // 二重計上される。/ace-refine のアーカイブ設計はこの非再帰走査に依存している。
    expect(discoverPlaybookSubfiles(playbookPath)).toEqual([path.join(subDir, "coding.md")]);
  });
});

describe("countPlaybookLines", () => {
  it("末尾に改行がある場合は改行数を数える（wc -l 準拠）", () => {
    expect(countPlaybookLines("a\nb\nc\n")).toBe(3);
  });

  it("末尾に改行が無い最終行は数えない（wc -l 準拠）", () => {
    expect(countPlaybookLines("a\nb\nc")).toBe(2);
  });

  it("空文字は 0 行", () => {
    expect(countPlaybookLines("")).toBe(0);
  });

  it("改行のみは 1 行", () => {
    expect(countPlaybookLines("\n")).toBe(1);
  });
});

describe("isOverLineThreshold", () => {
  it("閾値ちょうどは超過しない（境界は > 判定）", () => {
    expect(isOverLineThreshold(800, 800)).toBe(false);
  });

  it("閾値+1 は超過する", () => {
    expect(isOverLineThreshold(801, 800)).toBe(true);
  });

  it("閾値未満は超過しない", () => {
    expect(isOverLineThreshold(10, 800)).toBe(false);
  });
});

describe("countHeaderLines", () => {
  it("最初のエントリ見出しより前の行数を返す", () => {
    const md = [
      "# PLAYBOOK — コーディング (coding)",
      "",
      "> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md)",
      "",
      "---",
      "",
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding |",
      "",
    ].join("\n");

    expect(countHeaderLines(md)).toBe(8);
  });

  it("HTML コメント内の見出しはヘッダ境界にせず、行オフセットも壊さない", () => {
    // コメントは「除去」ではなく「同じ行数の空白へ置換」する必要がある。
    // 除去すると総行数との基準がずれ、ヘッダを過小に測って上限が不当に厳しくなる。
    const md = [
      "# h",
      "",
      "<!-- 追記例:",
      "### ACE-001: コメント内の偽エントリ",
      "-->",
      "",
      "### ACE-1-1: 実エントリ",
      "",
      "| Category | coding |",
      "",
    ].join("\n");

    expect(countHeaderLines(md)).toBe(6);
  });

  it("エントリ見出しが無ければ総行数を返す（ヘッダしかないファイル）", () => {
    expect(countHeaderLines("# h\n\nbody\n")).toBe(3);
  });
});

describe("countBudgetExceptions", () => {
  it("宣言のあるエントリ数を数える（マーカーの出現数ではない）", () => {
    // 2 番目のエントリは 2 本宣言しているが 1 件へ丸める。素の出現数を数える実装なら 3。
    const md = [
      "### ACE-1-1: a",
      "<!-- ace-line-budget-exception: 反直感的な詳細 -->",
      "---",
      "### ACE-1-2: b",
      "<!-- ace-line-budget-exception: 別の理由 -->",
      "<!-- ace-line-budget-exception: さらに別の理由 -->",
      "---",
      "### ACE-1-3: c",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(2);
    expect(countBudgetExceptions(md).occurrences).toBe(3);
  });

  it("マーカーが無ければ 0", () => {
    expect(countBudgetExceptions("### ACE-1-1: a\n").declared).toBe(0);
    expect(countBudgetExceptions("### ACE-1-1: a\n").occurrences).toBe(0);
  });

  it("エントリ見出しより前（ヘッダ）のマーカーは加算しない", () => {
    const md = [
      "# Header",
      "<!-- ace-line-budget-exception: 書式例 1 -->",
      "<!-- ace-line-budget-exception: 書式例 2 -->",
      "<!-- ace-line-budget-exception: 書式例 3 -->",
      "",
      "### ACE-1-1: a",
      "| Category | coding |",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
  });

  it("同一エントリ内に複数の宣言があっても 1 件に丸める", () => {
    const md = [
      "### ACE-1-1: a",
      "| Category | coding |",
      "<!-- ace-line-budget-exception: 理由 A -->",
      "<!-- ace-line-budget-exception: 理由 B -->",
      "<!-- ace-line-budget-exception: 理由 C -->",
      "---",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
  });

  it("終端 --- が無くても、ブロック末尾に置いた宣言は範囲外へ押し出さない（ファイル末尾。公開 Issue #12）", () => {
    // 終端フォールバック（末尾空行の切り詰め）が空白化後の行で判定すると、
    // マーカー自身が HTML コメント＝空白化済みのため空行扱いで飛び越され declared=0 になる。
    const md = [
      "### ACE-1-1: a",
      "",
      "| Category | coding |",
      "",
      "**Action**: 本文",
      "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
    ].join("\n");

    const tally = countBudgetExceptions(md);
    expect(tally.declared).toBe(1);
    expect(tally.occurrences).toBe(1);
  });

  it("終端 --- が無いブロック末尾の複数行コメント内の宣言も落とさない", () => {
    // 切り詰めは原文の最終非空行（コメント終端の -->）で止まり、ブロックは
    // コメント全体を含む。span 走査は複数行コメントもまたいで一致する。
    const md = [
      "### ACE-1-1: a",
      "",
      "| Category | coding |",
      "",
      "**Action**: 本文",
      "<!--",
      "ace-line-budget-exception: 複数行で書いた理由",
      "-->",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
  });

  it("終端 --- が無くても、ブロック末尾の宣言は落とさない（後続エントリあり。最終エントリ限定ではない）", () => {
    // フォールバックは終端 --- が見つからないブロックすべてで走るため、
    // 後続エントリがあるケースも同じ形で declared=0 になる（公開 Issue #12 の実測表 3 行目）。
    const md = [
      "### ACE-1-1: a",
      "",
      "| Category | coding |",
      "",
      "**Action**: 本文",
      "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
      "",
      "### ACE-1-2: b",
      "",
      "| Category | coding |",
      "本文のみ",
    ].join("\n");

    const tally = countBudgetExceptions(md);
    expect(tally.declared).toBe(1);
    expect(tally.occurrences).toBe(1);
    // refine 側と同じ規則で範囲を切っていること（相互一致）もこの形で固定する。
    // 件数だけでなく所属エントリを ID 単位で見る — 境界計算がずれて宣言が
    // 隣のエントリへ移っても件数は 1 のままなので、件数照合では検出できない。
    const refineSide = measureEntryLines(md).measurements;
    expect(refineSide.map((m) => [m.id, m.hasException])).toEqual([
      ["ACE-1-1", true],
      ["ACE-1-2", false],
    ]);
  });

  it("HTML コメントとして書かれていない言及は宣言として数えない", () => {
    const md = [
      "### ACE-1-1: a",
      "| Category | coding |",
      "運用ルール: 例外は ace-line-budget-exception マーカーで宣言する。",
      "記法は `ace-line-budget-exception` （コードスパン内の言及）。",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
  });

  it("ace-refine-report の hasException 件数と一致する（期待値は正準形の実値でも固定）", () => {
    // ACE-337-1: 相互一致だけを測ると「両者が揃って取りこぼす」変異に盲目になるため、
    // 実値（2）と相互一致の両方を assert する。
    const md = [
      "# Header",
      "<!-- ace-line-budget-exception: ヘッダの書式例（エントリ外） -->",
      "",
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: 例外を 1 件だけ宣言したエントリ",
      "",
      "| Category | coding | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
      "本文",
      "",
      "---",
      "",
      '<a id="ace-1-2"></a>',
      "",
      "### ACE-1-2: 同じ例外を 3 回書き分けたエントリ",
      "",
      "| Category | coding | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: 理由 A -->",
      "<!-- ace-line-budget-exception: 理由 B -->",
      "<!-- ace-line-budget-exception: 理由 C -->",
      "本文",
      "",
      "---",
      "",
      '<a id="ace-1-3"></a>',
      "",
      "### ACE-1-3: 散文で言及するだけのエントリ",
      "",
      "| Category | coding | Origin | PR #1 |",
      "例外は ace-line-budget-exception マーカーで宣言する（これは宣言ではない）。",
      "",
      "---",
      "",
      '<a id="ace-1-4"></a>',
      "<!-- ace-line-budget-exception: anchor 行と見出し行の間 -->",
      "### ACE-1-4: anchor 領域で宣言したエントリ",
      "",
      "| Category | coding | Origin | PR #1 |",
      "本文",
      "",
      "---",
      "<!-- ace-line-budget-exception: 終端 --- の後（どちらの範囲でもない） -->",
      "",
      "## Changelog",
      "",
      "<!-- ace-line-budget-exception: 後続セクション（どちらの範囲でもない） -->",
      "",
    ].join("\n");

    const refineSide = measureEntryLines(md).measurements.filter((m) => m.hasException).length;
    expect(countBudgetExceptions(md).declared).toBe(3);
    expect(refineSide).toBe(3);
    expect(countBudgetExceptions(md).declared).toBe(refineSide);
    // 採用しなかった 4 件（ヘッダ 1 + 重複 2 + 終端後 1 + 後続セクション 1 − 散文 0）も見える。
    expect(countBudgetExceptions(md).occurrences).toBe(9);
  });

  it("コメント内に非 BMP 文字があってもブロック境界がずれない", () => {
    // 空白化は `u` 無しでコードユニット単位に行うので UTF-16 の長さが保たれる。
    // `u` 付き（サロゲートペアを空白 1 個へ潰す）だと以下がヘッダの宣言を拾って 1 になる。
    const md = [
      "# Header",
      `<!-- ${"🎉".repeat(80)} -->`,
      "<!-- ace-line-budget-exception: 書式例（エントリ外） -->",
      "",
      "### ACE-1-1: a",
      "| Category | coding |",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
  });

  it("エントリ内の宣言は非 BMP 文字があっても落とさない", () => {
    const md = [
      "### ACE-1-1: a",
      "| Category | coding |",
      "<!-- 🎉🎉🎉🎉🎉 -->",
      "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
      "---",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
  });

  it("HTML コメント内のエントリ見出しは偽のブロック境界を作らない", () => {
    // 境界を原文（空白化前）から取ると、コメント内の追記例で分割されて 2 になる。
    const md = [
      "### ACE-1-1: real",
      "| Category | coding | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: 理由 A -->",
      "<!--",
      "### ACE-1-2: 追記例（コメント内の偽エントリ）",
      "-->",
      "<!-- ace-line-budget-exception: 理由 B -->",
      "本文",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
  });

  it("無関係なコメントに挟まれた散文の言及は跨いで拾わない（span は非貪欲）", () => {
    const md = [
      "### ACE-1-1: a",
      "| Category | coding | Origin | PR #1 |",
      "<!-- 無関係なコメント -->",
      "例外は ace-line-budget-exception マーカーで宣言する（これは宣言ではない）。",
      "<!-- もう一つ無関係なコメント -->",
      "本文",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
  });

  it("エントリの外側（終端 --- の後・後続 ## セクション）にある宣言は数えない", () => {
    // ここを数えると「この機能を説明した Changelog 行」で直前エントリの上限が伸びる。
    // measureEntryLines と同じ規則（終端 `---` で切り、`##` で打ち切る）でそろえている。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "本文",
      "",
      "---",
      "",
      "エントリ間のメモ <!-- ace-line-budget-exception: 終端の後 -->",
      "",
      "## Changelog",
      "",
      "- 例外マーカー <!-- ace-line-budget-exception: Changelog の説明 --> を追加した",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(0);
    expect(countBudgetExceptions(md).occurrences).toBe(2);

    // 終端 `---` を欠いたエントリでは、`##` の打ち切りだけが Changelog を締め出す。
    const withoutTerminator = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "本文",
      "",
      "## Changelog",
      "",
      "- 例外マーカー <!-- ace-line-budget-exception: Changelog の説明 --> を追加した",
      "",
    ].join("\n");

    expect(countBudgetExceptions(withoutTerminator).declared).toBe(0);
    expect(measureEntryLines(withoutTerminator).measurements.filter((m) => m.hasException).length).toBe(
      0,
    );
  });

  it("コードスパン内のマーカー完全形は宣言として数えない（refine 側も同じ）", () => {
    // live PLAYBOOK.md §運用ルールはこの書き方でマーカーを説明しており、
    // 同じ書き方がエントリ本文へ入ると上限が黙って伸びていた（Issue #347）。
    const md = [
      "# Header",
      "",
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "例外は `<!-- ace-line-budget-exception: 理由 -->` を添えて宣言する。",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(0);
  });

  it("例示と宣言が別エントリにあるとき、宣言のあるエントリだけに紐づく", () => {
    // refine 側の照合が span の範囲を見ずに「以降すべて」を見る形へ縮むと、
    // 例示のある ACE-1-1 にも例外が付く。件数だけでは両者 1 で一致してしまうので、
    // **どのエントリに付いたか**を assert する。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: 書式を例示するだけのエントリ",
      "",
      "| Category | coding | Origin | PR #1 |",
      "例外は `<!-- ace-line-budget-exception: 理由 -->` を添えて宣言する。",
      "",
      "---",
      "",
      '<a id="ace-1-2"></a>',
      "",
      "### ACE-1-2: 実際に宣言したエントリ",
      "",
      "| Category | coding | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
      "本文",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).map((m) => m.id)).toEqual([
      "ACE-1-2",
    ]);
  });

  it("コードスパン内に非 BMP 文字があっても宣言の紐づけがずれない", () => {
    // refine は原文オフセットで空白化後テキストを参照するため、空白化が長さを
    // 保存しなくなると宣言を黙って落とす。40 個は `<!-- ` + マーカー名を越える量。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "`" + "🎉".repeat(40) + "`",
      "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
      "本文",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(1);
  });

  it("4 スペースのインデントコードブロックは宣言として数える（既知の限界・両側で同じ）", () => {
    // フェンスでもコードスパンでもないため空白化の対象外。check・refine が
    // そろって数えるので相互一致テストでは検出できない。書式を例示するときは
    // インデントではなくフェンスかコードスパンを使うこと。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "",
      "    <!-- ace-line-budget-exception: インデントによる例示 -->",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(1);
  });

  it("コードフェンス内のマーカー完全形は宣言として数えない（refine 側も同じ）", () => {
    const fence = "```";
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      `${fence}markdown`,
      "<!-- ace-line-budget-exception: 理由 -->",
      fence,
      "本文",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(0);
  });

  it("正当な宣言は理由にコードスパンを含んでいても数える", () => {
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: `execFileSync` の非対称を書き切るため -->",
      "本文",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(1);
  });

  it("長さの合わないバックティック列は対にせず、同じ行の宣言を落とさない", () => {
    // `(`+)…\1` の後方参照は「同じ文字列」までしか保証せず、`+` がバックトラックで
    // 縮むため 3 連と 2 連の一部どうしを組にして、間の宣言を空白化して落とす。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "prefix ``` <!-- ace-line-budget-exception: 理由 --> ``",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(1);
  });

  it("同じ行に対にならないバックティックと宣言があっても落とさない", () => {
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "`x <!-- ace-line-budget-exception: 理由 --> ``",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(1);
  });

  it("二重バックティック内に単一を含むコードスパンも列ごと空白化する", () => {
    // 列の一部だけを空白化すると、残ったバックティックが後続の列と誤って対になる。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "``<!-- ace-line-budget-exception: 例示 -->`b`` の説明",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(0);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(0);
  });

  it("対にならないバックティックがある行は空白化せず、宣言を落とさない（fail-open）", () => {
    // 対を判定できない行まで空白化すると、正当な宣言が消えて偽の密度警告になる。
    // refine 側は例外扱いのままなので「check だけが警告し refine の候補は空」になる。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "対にならない ` バックティック",
      "<!-- ace-line-budget-exception: 理由 -->",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(measureEntryLines(md).measurements.filter((m) => m.hasException).length).toBe(1);
  });

  /**
   * これは**純粋関数レベル**の意味論のピン留めで、利用者から見える契約ではない。
   * CLI としては両者ともこの入力を拒否する（refine は unclosedFence で exit 1、check は
   * analyzePlaybookMarkdown と countBudgetExceptions の 2 経路のいずれかで exit 2。
   * この fixture が踏むのは前者）。fail-open のまま値を返すこと自体は変わらないが、
   * 「値が返る」と同時に「信用できないと分かる」ことまで含めて固定する（Issue #349 / #354）。
   * 診断のアサートを外すと、以後の変更で握りつぶしが再発しても検出できない。
   */
  it("閉じていないフェンス以降は空白化しない（fail-open）が、診断フラグで検出できる", () => {
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "```markdown",
      "<!-- ace-line-budget-exception: 理由 -->",
      "",
      "---",
      "",
    ].join("\n");

    expect(countBudgetExceptions(md).declared).toBe(1);
    expect(countBudgetExceptions(md).unclosedFence).toBe(true);
    const measured = measureEntryLines(md);
    expect(measured.measurements.filter((m) => m.hasException).length).toBe(1);
    expect(measured.unclosedFence).toBe(true);
  });

  /**
   * Issue #354: 診断（unclosedFence）を戻り値へ載せる前は、この 2 方向の誤りが
   * `declared` の数値としてしか出てこず、正常な計数と区別がつかなかった。
   * `declared` の値そのものは fail-open の設計どおりで**変えない**（変えると
   * ace-refine-report の hasException との相互一致が崩れる）。固定するのは
   * 「誤りうる状態だと呼び出し側が知れること」。
   */
  it("未閉フェンス内の例示マーカーを宣言に数えた（緩む側）ことを診断で示す", () => {
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "```markdown",
      "<!-- ace-line-budget-exception: フェンス内の例示（閉じ忘れ） -->",
      "",
      "---",
      "",
    ].join("\n");

    const tally = countBudgetExceptions(md);
    // 例示を宣言として数えている（fail-open）。診断が無ければ 1 件の正当な宣言と区別できない。
    expect(tally.declared).toBe(1);
    expect(tally.unclosedFence).toBe(true);
  });

  it("未閉フェンスが正当な宣言を巻き込んで落とした（厳しい側）ことを診断で示す", () => {
    // 閉じ忘れた ```markdown の後ろで最初に現れる**記号だけのフェンス行**が終端として
    // 消費され、間にある実宣言がまとめて空白化される。残った ```markdown は情報文字列付きで
    // 終端になれないため、そこから EOF までが未閉のまま残る。
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "```markdown",
      "閉じ忘れたフェンスの中",
      "<!-- ace-line-budget-exception: 本物の宣言 -->",
      "```",
      "```markdown",
      "後続の例示ブロック（閉じられない）",
      "",
      "---",
      "",
    ].join("\n");

    const tally = countBudgetExceptions(md);
    // 正当な宣言が消えている（偽の密度警告になる側の誤り）。
    expect(tally.declared).toBe(0);
    expect(tally.unclosedFence).toBe(true);
  });

  it("フェンスが閉じている正常な入力では診断が立たない", () => {
    const md = [
      '<a id="ace-1-1"></a>',
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding | Origin | PR #1 |",
      "```markdown",
      "<!-- ace-line-budget-exception: 例示 -->",
      "```",
      "<!-- ace-line-budget-exception: 本物の宣言 -->",
      "",
      "---",
      "",
    ].join("\n");

    const tally = countBudgetExceptions(md);
    expect(tally.declared).toBe(1);
    expect(tally.unclosedFence).toBe(false);
  });

  /**
   * **測った範囲だけを固定する**（ACE-352-4）。「ファイル全体走査が未閉を見たなら
   * analyze も必ず拒否する」という全称は**偽**で、下の「反例」テストが実測で示している。
   * ここで押さえるのは代表 4 形（本文 / ヘッダ / チルダ / 本数不足）だけ。
   * `allowEmpty: true` も併せて通すのは、main が分割レイアウトで実際に渡す形だから
   * （ヘッダ領域のフェンス検査が `segments.length === 0` の早期 return より**前**にある、
   * という順序に依存している。順序が入れ替わればここが赤くなる）。
   */
  it("代表 4 形（本文 / ヘッダ / チルダ / 本数不足）の未閉フェンスは analyze も拒否する", () => {
    const fixtures = [
      // エントリ本文で閉じ忘れ
      "### ACE-1-1: t\n\n| Category | coding |\n```markdown\n<!-- ace-line-budget-exception: 例示 -->\n",
      // ヘッダ領域で閉じ忘れ
      "# Header\n```markdown\n\n### ACE-1-1: t\n\n| Category | coding |\n",
      // チルダフェンスの閉じ忘れ
      "### ACE-1-1: t\n\n| Category | coding |\n~~~\n本文\n",
      // 終端が短くて閉じない（4 本開始・3 本終端）
      "### ACE-1-1: t\n\n| Category | coding |\n````\n本文\n```\n",
    ];

    for (const md of fixtures) {
      expect(countBudgetExceptions(md).unclosedFence).toBe(true);
      expect(analyzePlaybookMarkdown(md).kind).toBe("error");
      expect(analyzePlaybookMarkdown(md, { allowEmpty: true }).kind).toBe("error");
    }
  });

  /**
   * かつて包含が破れていた形（Issue #354 で発見 → Issue #353 / #357 で解消）。
   *
   * 旧分割は `### ACE-1-1:` の接頭辞だけを消費していたため、見出しタイトルの残骸が
   * セグメントの 1 行目になり、タイトルが 3 連バックティックで始まると**セグメント走査
   * だけが偽のフェンス開始を見た**。当時この入力は analyze が ok を返し、
   * countBudgetExceptions の診断だけが true（＝ main のガードが唯一の停止点）だった。
   *
   * splitEntrySegments が見出し行を保持するようになり、`###` 始まりの行はどちらの走査でも
   * フェンスにならない。残る未閉フェンスは本文の裸の ``` だけで、**両者がそろって**拒否する。
   * 3 つを同時に固定しておくと、分割規則を旧実装へ戻す変異が必ず赤くなる。
   */
  it("見出しタイトルが ``` で始まっても、実際の閉じ忘れは両者そろって拒否する", () => {
    const md = [
      "# Header",
      "",
      "### ACE-1-1: ```markdown の説明",
      "",
      "本文",
      "```",
      "| Category | tooling | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: 本物の宣言 -->",
      "",
      "---",
      "",
    ].join("\n");

    expect(analyzePlaybookMarkdown(md).kind).toBe("error");
    expect(countBudgetExceptions(md).unclosedFence).toBe(true);
    expect(measureEntryLines(md).unclosedFence).toBe(true);
  });

  /**
   * 同じ見出しでフェンスが**正しく対になっている**形。旧実装ではタイトルの偽 open が
   * 1 本目の ``` で閉じ、2 本目が開いたまま残るため analyze だけが拒否していた
   * （Issue #353 の向き）。見出し行を保持する分割では、このファイルは単に正常。
   */
  it("見出しタイトル中の ``` があっても、対になったフェンスは誰も拒否しない", () => {
    const md = [
      "# Header",
      "",
      "### ACE-1-1: ```markdown の説明",
      "",
      "| Category | tooling | Origin | PR #1 |",
      "```",
      "本文",
      "```",
      "<!-- ace-line-budget-exception: 本物の宣言 -->",
      "",
      "---",
      "",
    ].join("\n");

    expect(analyzePlaybookMarkdown(md).kind).toBe("ok");
    expect(countBudgetExceptions(md).unclosedFence).toBe(false);
    expect(measureEntryLines(md).unclosedFence).toBe(false);
    // 宣言はフェンスの外にあるので通常どおり 1 件
    expect(countBudgetExceptions(md).declared).toBe(1);
  });

  /**
   * **総当たりを主張ではなくテストとして着地させる**（ACE-356-3）。「N 通り試して 0 件」と
   * コメントへ書いても、生成器が残っていなければ再実行も拡張もできず、実際に取りこぼして
   * いた（Issue #354 の「到達不能」が偽だった経緯）。固定する不変条件は 2 つ:
   * (1) 合成判定が立つ入力は analyze も必ず拒否する（check 内の 2 ゲートの包含）、
   * (2) check と refine の診断が全ケースで一致する（Issue #353 の drift 検出源）。
   */
  it("フェンス断片の総当たりで、合成判定 ⊆ analyze の拒否・check と refine の診断一致が保たれる", () => {
    const tokens = [
      "",
      "```",
      "~~~",
      "```markdown",
      "````",
      "<!-- ace-line-budget-exception: x -->",
    ];
    let cases = 0;
    for (const header of tokens) {
      for (const title of tokens) {
        for (const body1 of tokens) {
          for (const body2 of tokens) {
            for (const between of tokens) {
              const md = [
                "# ACE Playbook",
                "",
                header,
                "",
                `### ACE-1-1: タイトル ${title}`,
                "",
                "| Category | coding |",
                body1,
                "本文",
                body2,
                "",
                "---",
                "",
                "### ACE-1-2: 次",
                "",
                "| Category | tooling |",
                // between をエントリ 2 の本文に置くのは、エントリ 1 で開きエントリ 2 で
                // 閉じる同値類（= Issue #353 の非対称そのもの）を生成器に含めるため。
                // エントリ 1 側へ置くと、分割境界が見出しオフセットなので全スロットが
                // 同一セグメントへ落ち、この形に一度も到達しない。
                between,
                "",
                "---",
                "",
              ].join("\n");
              cases += 1;
              const scan = scanUnclosedFence(md);
              if (scan.found) {
                expect(analyzePlaybookMarkdown(md, { allowEmpty: true }).kind).toBe("error");
              }
              // 包含の固定: ファイル全体走査が未閉を見たなら、セグメント単位も必ず見る
              // （`scope === "both"`）。この向きが崩れると、分割規則が変わったときに
              // 合成の片側だけが検出している状態へ黙って戻る。
              if (blankCodeRegions(md).unclosedFence) {
                expect(scan.found === true && scan.scope).toBe("both");
              }
              expect(countBudgetExceptions(md).unclosedFence).toBe(
                measureEntryLines(md).unclosedFence,
              );
            }
          }
        }
      }
    }
    // 生成器が縮んで空回りしていないこと（6^5）
    expect(cases).toBe(7776);
  }, 30_000); // 6 トークン × 5 重ループ = 7,776 ケースの総当たり。
  // 実測: このファイル単独なら 127 件で ~1 秒。ところが run-all.sh からスイート全体を
  // 走らせると同じテストが 5.7〜6.2 秒かかり、既定の 5 秒を超えて赤くなった
  // （vitest の並列ワーカーと他スイートが同時に走るため）。つまり「常に遅い」のでは
  // なく「並列負荷で 5 秒を超えうる」。組合せを削れば速くなるが、この総当たりは
  // 全パターンでの一致を担保するためのもので、削ると検査が弱くなる。削らずに
  // 余裕を与える。値は単独実測の約 30 倍で、退行の検出力は保てる範囲。
});

/**
 * 分割規則の単一源（Issue #353 / #357）。
 * 旧実装は `split(ACE_ENTRY_HEADER_PATTERN)` で**見出しの接頭辞だけ**を消費していたため、
 * タイトル残骸がセグメントの 1 行目になり、セグメント走査だけが偽の FENCE_OPEN を見ていた。
 * 見出し行を丸ごと保持すれば、セグメント走査とファイル全体走査が同じ行集合を見る。
 */
describe("splitEntrySegments", () => {
  const md = [
    "# Header",
    "",
    "索引本文",
    "",
    "### ACE-1-1: 最初のエントリ",
    "",
    "| Category | coding |",
    "",
    "### ACE-1-2: 次のエントリ",
    "",
    "| Category | tooling |",
    "",
  ].join("\n");

  it("セグメントは見出し行を含む（分割の境界で行が消えない）", () => {
    const { entries } = splitEntrySegments(md);

    expect(entries).toHaveLength(2);
    expect(entries[0].text.split("\n")[0]).toBe("### ACE-1-1: 最初のエントリ");
    expect(entries[1].text.split("\n")[0]).toBe("### ACE-1-2: 次のエントリ");
  });

  it("ヘッダは最初の見出しより前・開始行を 0-origin で返す", () => {
    const { header, entries } = splitEntrySegments(md);

    expect(header.text).toBe("# Header\n\n索引本文\n\n");
    expect(header.startLine).toBe(0);
    expect(entries[0].startLine).toBe(4);
    expect(entries[1].startLine).toBe(8);
  });

  it("見出しが 1 件も無ければ全体がヘッダ", () => {
    const { header, entries } = splitEntrySegments("# Header\n本文\n");

    expect(entries).toHaveLength(0);
    expect(header.text).toBe("# Header\n本文\n");
  });

  it("行を 1 行も失わない（ヘッダ + 全セグメントで原文を再構成できる）", () => {
    const { header, entries } = splitEntrySegments(md);

    expect(header.text + entries.map((e) => e.text).join("")).toBe(md);
  });
});

/**
 * 未閉フェンスの合成判定（Issue #353）。
 * `blankCodeRegions.unclosedFence`（ファイル全体）はそのままの意味を保ち、
 * 「どちらの走査単位で見ても対にならないか」はこの関数だけが答える。
 * check / refine の両方がこれを使うことで、拒否する入力集合が一致する。
 */
describe("scanUnclosedFence", () => {
  it("セグメント跨ぎで対になる形は、真因（フェンス内の正準形見出し）の診断へ譲る（Issue #342）", () => {
    // ヘッダで開いたフェンスが、エントリ本文の裸の ``` と対になる形。
    // ファイル全体走査では「閉じている」。かつては scanUnclosedFence がセグメント単位で
    // 「未閉」と報告したが、本文を見ると対になって見えるため利用者の調査が空回りする。
    // この形の観測可能な真因は「フェンス内に正準形の見出しがある」ことなので、
    // scanUnclosedFence は譲り、findFencedCanonicalHeadings と analyze の拒否が名指しする
    // （例示なら ACE-XXX へ、実エントリならフェンスの対応を確認、の両対処を案内）。
    const md = [
      "# ACE Playbook",
      "",
      "追記例:",
      "```markdown",
      "| Category | coding |",
      "",
      "### ACE-80-1: 実エントリ",
      "",
      "| Category | coding |",
      "<!-- ace-line-budget-exception: 本物の宣言 -->",
      "本文。",
      "```",
      "",
      "---",
      "",
    ].join("\n");

    expect(blankCodeRegions(md).unclosedFence).toBe(false);
    // 真因の検出: フェンス内の正準形見出しとして名指しされる
    const fenced = findFencedCanonicalHeadings(md);
    expect(fenced.map((h) => h.id)).toEqual(["ACE-80-1"]);
    // scanUnclosedFence は真因側へ譲る（「未閉」と言わない）
    const scan = scanUnclosedFence(md);
    expect(scan.found).toBe(false);
    // 入力そのものは analyze が fail-loud に拒否する（黙って通しはしない）
    const analyzed = analyzePlaybookMarkdown(md);
    expect(analyzed.kind).toBe("error");
    if (analyzed.kind === "error") {
      expect(analyzed.message).toContain("ACE-80-1");
    }
    // **合成は判定だけに効かせ、空白化には持ち込まない**（この PR の中心的な制約）。
    // 空白化はファイル全体走査のままなので、9 行目のマーカーはフェンス内として空白化され
    // declared は 0。合成を空白化へ配線し直すと、ヘッダセグメントが未閉 → fail-open →
    // マーカーが生き残って declared が 1 へ動く。occurrences を併記するのは、
    // 「マーカーがそもそも無い fixture」との区別が付かないまま空回りしないため。
    const tally = countBudgetExceptions(md);
    expect(tally.declared).toBe(0);
    expect(tally.occurrences).toBe(1);
  });

  it("エントリ本文の素直な閉じ忘れは両方の走査が見る（scope は both）", () => {
    const md = "### ACE-1-1: t\n\n| Category | coding |\n```markdown\n閉じ忘れ\n";

    expect(blankCodeRegions(md).unclosedFence).toBe(true);
    const scan = scanUnclosedFence(md);
    expect(scan.found).toBe(true);
    expect(scan.found === true && scan.line).toBe(3);
    // scope は包含関係の唯一の観測点。ここを assert しないと、ファイル全体走査の項を
    // 落とす変異が「found は同じ」なので緑のまま通る。
    expect(scan.found === true && scan.scope).toBe("both");
  });

  /**
   * #357 の偽陽性が合成判定へ持ち込まれないこと。見出し行を保持する分割にしたので、
   * `### ACE-1-1: ```md …` はどちらの走査でもフェンス開始にならない。
   * ここが false でないと、実フェンスが 1 本も無いファイルを refine まで拒否し始める。
   */
  it("見出しタイトル中の ``` はフェンス開始にしない（実フェンスが無いファイルを拒否しない）", () => {
    const md = [
      "# Header",
      "",
      "### ACE-1-1: ```markdown の説明",
      "",
      "| Category | tooling |",
      "本文（フェンスは 1 本も無い）",
      "",
      "---",
      "",
    ].join("\n");

    expect(scanUnclosedFence(md).found).toBe(false);
    expect(analyzePlaybookMarkdown(md).kind).toBe("ok");
    expect(measureEntryLines(md).unclosedFence).toBe(false);
  });

  it("見出しタイトル中の ``` があっても本物の閉じ忘れは見逃さない", () => {
    const md = [
      "# Header",
      "",
      "### ACE-1-1: ```markdown の説明",
      "",
      "| Category | tooling |",
      "```markdown",
      "閉じ忘れ",
      "",
    ].join("\n");

    expect(scanUnclosedFence(md).found).toBe(true);
    expect(analyzePlaybookMarkdown(md).kind).toBe("error");
    expect(measureEntryLines(md).unclosedFence).toBe(true);
  });

  it("フェンスが無い / 閉じているファイルでは found が false", () => {
    expect(scanUnclosedFence("### ACE-1-1: t\n\n| Category | coding |\n").found).toBe(false);
    expect(
      scanUnclosedFence("### ACE-1-1: t\n\n| Category | coding |\n```md\n例\n```\n").found,
    ).toBe(false);
  });

  /**
   * CRLF は**偽陽性の方向**を固定する（検出方向は既存テストが押さえている）。
   * \r の除去は 2 つの走査それぞれに入っており、片側だけの退行は「正常なファイルが
   * 拒否される」形で出る。check と refine の一致 assertion では捕まらない
   * （両者とも同じ関数へ委譲しているため）。
   */
  it("CRLF の正常なファイルを拒否しない（\\r 処理の片側退行を検出する）", () => {
    const md = [
      "# Header",
      "",
      "追記例:",
      "```markdown",
      "| Category | example |",
      "```",
      "",
      "### ACE-1-1: t",
      "",
      "| Category | coding |",
      "```md",
      "本文の例示",
      "```",
      "",
      "---",
      "",
    ].join("\r\n");

    expect(scanUnclosedFence(md).found).toBe(false);
    expect(analyzePlaybookMarkdown(md).kind).toBe("ok");
    expect(measureEntryLines(md).unclosedFence).toBe(false);
  });

  /**
   * ヘッダ領域のフェンス検査は `entries.length === 0` / `allowEmpty` の分岐より**前**に
   * 走る。分割レイアウトの索引ファイル（0 件が正常）でもヘッダの閉じ忘れは止まる、を固定する。
   * 順序を入れ替える変異は、これが無いと全て緑で通る。
   */
  it("allowEmpty でもヘッダ領域の閉じ忘れは止める（検査の順序を固定する）", () => {
    const md = "# 索引\n\n```markdown\n閉じ忘れ\n";

    const result = analyzePlaybookMarkdown(md, { allowEmpty: true });
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("ヘッダ領域");
      expect(result.message).toContain("3 行目");
    }
  });

  /**
   * ヘッダ境界を求める実装は splitEntrySegments と countHeaderLines の 2 箇所ある
   * （正規表現の源は entryHeadingSource で単一）。ずれると deriveMaxLines のヘッダ項が
   * 誤り、導出上限が黙って動く。安いので両方向を固定する。
   */
  it("countHeaderLines は splitEntrySegments のヘッダ境界と一致する", () => {
    const md = "# H\n\n本文\n\n### ACE-1-1: t\n\n| Category | coding |\n";
    expect(countHeaderLines(md)).toBe(splitEntrySegments(md).entries[0].startLine);

    const noEntries = "# H\n本文\n";
    expect(countHeaderLines(noEntries)).toBe(
      countPlaybookLines(splitEntrySegments(noEntries).header.text),
    );
  });

  it("HTML コメント内のフェンスは走査対象にしない（分割前のマスクと同じ規則）", () => {
    const md = "# H\n<!--\n```markdown\n-->\n\n### ACE-1-1: t\n\n| Category | coding |\n";

    expect(scanUnclosedFence(md).found).toBe(false);
  });
});

describe("blankCodeRegions", () => {
  // 呼び出し側（countBudgetExceptions の行スライス / maskCommentSpans の
  // scannable.slice(start, start + span.length)）は原文と同じオフセットで参照する。
  // 長さか改行位置が変わった時点でどちらも静かにずれる。
  const samples = [
    "ふつうの本文\n",
    "絵文字 🎉 と `code` を含む行\n次の行\n",
    // 非 BMP は**空白化される領域の内側**に置く。外側だと blankNonNewline に `u` を
    // 足す変異（サロゲートペアを空白 1 個へ潰す）が長さを変えず、検査が空振りする。
    "コードスパン `🎉𝔘` の中に非 BMP\n",
    "```md\n🎉𝔘 をフェンスの中に\n```\n",
    "```markdown\n<!-- ace-line-budget-exception: 例示 -->\n```\n本文\n",
    "閉じないフェンス\n```markdown\n<!-- ace-line-budget-exception: 理由 -->\n",
    "CRLF の行\r\n```md\r\n例示\r\n```\r\n",
    "~~~\nチルダフェンス\n~~~\n",
    "対にならない ` バックティックと `pair` あり\n",
  ];

  it("UTF-16 の長さを保存する", () => {
    for (const sample of samples) {
      expect(blankCodeRegions(sample).text.length).toBe(sample.length);
    }
  });

  it("CRLF でもフェンス内が空白化される（長さ保存だけでは検出できない）", () => {
    // 終端フェンスの判定は行末アンカーなので、`\r` を落とさないと全フェンスが
    // 閉じない扱いになる。長さ・改行位置はどちらでも保存されるため内容で固定する。
    const crlf = ["```markdown", "<!-- ace-line-budget-exception: 例示 -->", "```", ""].join("\r\n");
    expect(blankCodeRegions(crlf).text).not.toContain("ace-line-budget-exception");
    expect(blankCodeRegions(crlf).unclosedFence).toBe(false);
  });

  it("終端フェンスは開始と同種・同数以上でなければ閉じない", () => {
    // 早く閉じると、フェンス内の例示マーカーが空白化されず上限が黙って 2 倍になる。
    const tilde = ["~~~", "```", "<!-- ace-line-budget-exception: 例示 -->", "~~~", ""].join("\n");
    expect(blankCodeRegions(tilde).text).not.toContain("ace-line-budget-exception");

    const quad = ["````", "```", "<!-- ace-line-budget-exception: 例示 -->", "````", ""].join("\n");
    expect(blankCodeRegions(quad).text).not.toContain("ace-line-budget-exception");
  });

  it("閉じていないフェンスを結果で報告する（呼び出し側が消費できる）", () => {
    expect(blankCodeRegions("```md\n本文\n").unclosedFence).toBe(true);
    expect(blankCodeRegions("```md\n本文\n```\n").unclosedFence).toBe(false);
    expect(blankCodeRegions("フェンスなし\n").unclosedFence).toBe(false);
  });

  it("HTML コメント内のフェンス開始行を本文の実フェンスと対にしない", () => {
    // コメント内のテンプレート説明が本文の実フェンスと対になると、間にある
    // 正当な宣言までまとめて空白化されて落ちる（実測で declared 1 → 0）。
    const md = ["<!-- 追記例:", "```markdown", "-->", "本文 `code` あり", "```md", "例", "```"].join("\n");
    const blanked = blankCodeRegions(md);
    expect(blanked.unclosedFence).toBe(false);
    expect(blanked.text.split("\n")[3]).toBe("本文        あり");
  });

  it("改行の位置をすべて保存する", () => {
    for (const sample of samples) {
      const offsets = (text: string): number[] => {
        const result: number[] = [];
        for (let i = 0; i < text.length; i++) {
          if (text[i] === "\n") result.push(i);
        }
        return result;
      };
      expect(offsets(blankCodeRegions(sample).text)).toEqual(offsets(sample));
    }
  });
});

describe("deriveMaxLines", () => {
  it("上限 = ヘッダ行数 + 件数 × (エントリ行数バジェット + 1)", () => {
    // ブロック間の空行 1 行を含めて 1 件 16 行。playbook/testing.md（ヘッダ 12 行 / 65 件）相当。
    expect(
      deriveMaxLines({
        headerLines: 12,
        entryCount: 65,
        exceptionCount: 0,
        maxEntryLines: 15,
      }),
    ).toBe(1052);
  });

  it("例外宣言エントリはバジェット 1 本分（例外上限 = 2 倍）の余裕を加算する", () => {
    expect(
      deriveMaxLines({
        headerLines: 12,
        entryCount: 65,
        exceptionCount: 2,
        maxEntryLines: 15,
      }),
    ).toBe(1082);
  });

  it("エントリ 0 件ならヘッダ行数そのもの（密度を測る対象が無い）", () => {
    expect(
      deriveMaxLines({
        headerLines: 40,
        entryCount: 0,
        exceptionCount: 0,
        maxEntryLines: 15,
      }),
    ).toBe(40);
  });
});

describe("parsePositiveIntEnv", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("未設定・空文字・空白のみは既定値", () => {
    expect(parsePositiveIntEnv(undefined, 800, "X")).toBe(800);
    expect(parsePositiveIntEnv("", 800, "X")).toBe(800);
    expect(parsePositiveIntEnv("   ", 800, "X")).toBe(800);
  });

  it("正の整数はそのまま採用（前後空白は無視）", () => {
    expect(parsePositiveIntEnv("5000", 800, "X")).toBe(5000);
    expect(parsePositiveIntEnv("  900  ", 800, "X")).toBe(900);
  });

  it("数字以外を含む値は既定値へフォールバックし警告する", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(parsePositiveIntEnv("800abc", 800, "ACE_MAX_PLAYBOOK_LINES")).toBe(800);
    expect(parsePositiveIntEnv("1e3", 800, "ACE_MAX_PLAYBOOK_LINES")).toBe(800);
    expect(parsePositiveIntEnv("abc", 800, "ACE_MAX_PLAYBOOK_LINES")).toBe(800);
    expect(warn).toHaveBeenCalled();
  });

  it("0 以下・負数は既定値へフォールバックし警告する", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(parsePositiveIntEnv("0", 800, "X")).toBe(800);
    expect(parsePositiveIntEnv("-5", 800, "X")).toBe(800);
    expect(warn).toHaveBeenCalled();
  });

  it("Number.MAX_SAFE_INTEGER を超える巨大整数は既定値へフォールバックし警告する", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    // 数字のみだが安全整数外 → 精度喪失で閾値が壊れる
    expect(
      parsePositiveIntEnv("999999999999999999999", 800, "ACE_MAX_PLAYBOOK_LINES"),
    ).toBe(800);
    expect(warn).toHaveBeenCalled();
  });
});

describe("isDirectExecution", () => {
  let tmpDir = "";

  afterEach(() => {
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  it("完全一致する argv path だけを直接実行扱いする", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-direct-"));
    const scriptPath = path.join(tmpDir, "check-category-size.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, scriptPath)).toBe(true);
  });

  it("上位ディレクトリ名に .test. があっても、スクリプト本体なら直接実行扱いする", () => {
    // 旧実装は argv の部分一致で .test. を除外していたため、
    // /tmp/my.test.project/... から実行すると silent no-op になっていた。
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "my.test.project-"));
    const scriptPath = path.join(tmpDir, "check-category-size.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, scriptPath)).toBe(true);
  });

  it("別名スクリプト（部分一致）や argv 無しは直接実行扱いしない", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-direct-"));
    const scriptPath = path.join(tmpDir, "check-category-size.ts");
    const wrapperPath = path.join(tmpDir, "wrapper-check-category-size.ts");
    const testPath = path.join(tmpDir, "check-category-size.test.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, wrapperPath)).toBe(false);
    expect(isDirectExecution(pathToFileURL(scriptPath).href, testPath)).toBe(false);
    expect(isDirectExecution(pathToFileURL(scriptPath).href, undefined)).toBe(false);
  });
});

describe("main（行数警告のみ・exit code 不変）", () => {
  const originalArgv = process.argv;
  let tmpDir = "";

  afterEach(() => {
    process.argv = originalArgv;
    delete process.env.ACE_MAX_PLAYBOOK_LINES;
    delete process.env.ACE_MAX_ENTRIES_PER_CATEGORY;
    delete process.env.ACE_WARN_ENTRIES_PER_CATEGORY;
    delete process.env.ACE_MAX_ENTRY_LINES;
    vi.restoreAllMocks();
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  function writePlaybook(body: string): string {
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-line-"));
    const file = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(file, body);
    return file;
  }

  function compactEntries(count: number, category = "coding"): string {
    return Array.from({ length: count }, (_, index) => {
      const id = `1-${String(index + 1)}`;
      return [
        `<a id="ace-${id}"></a>`,
        "",
        `### ACE-${id}: t`,
        "",
        `| Category | ${category} | Origin | PR #1 |`,
        "| Date | 2026-08-14 |",
        "| Helpful | 0 | Harmful | 0 |",
        "| Status | active |",
        "",
        "body",
        "",
        "---",
        "",
      ].join("\n");
    }).join("\n");
  }

  it("行数のみ超過なら exit 0・stderr に警告・行数は常時出力", () => {
    const body =
      "### ACE-1-1: t\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "x\n".repeat(20);
    const file = writePlaybook(body);
    process.env.ACE_MAX_PLAYBOOK_LINES = "5";
    process.argv = ["node", "check-category-size.ts", file];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(log.mock.calls.flat().join("\n")).toContain("総行数:");
    expect(err.mock.calls.flat().join("\n")).toContain("行数が閾値を超過");
  });

  /**
   * 見出しタイトルに ``` を含むエントリ + 本文の閉じ忘れ。Issue #354 の時点では
   * `analyzePlaybookMarkdown` が ok を返し、countBudgetExceptions のゲートだけが
   * 止めていた（旧分割では見出しの接頭辞だけが消費され、タイトル残骸がセグメント走査
   * だけで偽のフェンス開始になっていたため）。Issue #353 / #357 で分割規則を単一源に
   * 揃えたので、いまは analyze が先に拒否する。**どちらのゲートが働いても止まること**
   * ＝ 例外項が導出上限へ乗らないことを利用者から見える形で固定する。
   */
  it("見出しタイトルに ``` を含むエントリの閉じ忘れも usage error で止める", () => {
    const body = [
      "# Header",
      "",
      "### ACE-1-1: ```markdown の説明",
      "",
      "本文",
      "```",
      "| Category | coding | Origin | PR #1 |",
      "<!-- ace-line-budget-exception: 宣言 -->",
      "",
      "---",
      "",
    ].join("\n");
    const file = writePlaybook(body);
    process.argv = ["node", "check-category-size.ts", file];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(2);
    const stderr = err.mock.calls.flat().join("\n");
    expect(stderr).toContain("閉じていないコードフェンス");
    // 位置を名指しする。6 行目 = 本文の裸の ```（1-origin）。見出し行（3 行目）は
    // `###` 始まりなのでどちらの走査でもフェンスにならない。
    expect(stderr).toContain("6 行目");
    // どちらのゲートも外れると exit 0 で導出上限に例外項が乗る（実測: 上限 18 → 33）。
    // 数値ではなく「例外項が出ていないこと」を見るのは、既定バジェットの変更で
    // 壊れないようにするため。exit 2 を上で陽性に固定済みなので、この not 側が
    // 単独で無音になることはない。
    expect(log.mock.calls.flat().join("\n")).not.toContain("+ 例外");
  });

  /**
   * 実フェンスが 1 本も無いのに止めない（Issue #357）。見出しタイトルにインラインコードを
   * 書くのは PLAYBOOK では日常的で、旧分割ではこの形が「フェンスを閉じてください」の
   * usage error になり、閉じるべきフェンスが存在しないため利用者に直しようがなかった。
   */
  it("見出しタイトル中の ``` だけでは止めない（閉じるべきフェンスが無い）", () => {
    const body = [
      "# Header",
      "",
      "### ACE-1-1: ```markdown の説明",
      "",
      "| Category | coding | Origin | PR #1 |",
      "本文（フェンスは 1 本も無い）",
      "",
      "---",
      "",
    ].join("\n");
    const file = writePlaybook(body);
    process.argv = ["node", "check-category-size.ts", file];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    expect(main()).toBe(0);
    expect(log.mock.calls.flat().join("\n")).toContain("coding: 1");
  });

  it("カテゴリ件数超過なら exit 1（既存ゲートは不変）", () => {
    const body =
      "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "### ACE-1-2: b\n\n| Category | coding |\n| Origin | PR #1 |\n";
    const file = writePlaybook(body);
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY = "1";
    process.argv = ["node", "check-category-size.ts", file];
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
  });

  it("既定は refine 目安 130・ブロック上限 180（ADR-029）", () => {
    expect(DEFAULT_WARN_ENTRIES_PER_CATEGORY).toBe(130);
    expect(DEFAULT_MAX_ENTRIES_PER_CATEGORY).toBe(180);
    expect(DEFAULT_WARN_ENTRIES_PER_CATEGORY).toBeLessThan(
      DEFAULT_MAX_ENTRIES_PER_CATEGORY,
    );
  });

  it("env 未設定の既定配線: 目安ちょうどは黙り、目安+1 は警告のみ", () => {
    const atWarn = writePlaybook(compactEntries(DEFAULT_WARN_ENTRIES_PER_CATEGORY));
    process.argv = ["node", "check-category-size.ts", atWarn];
    const silentErr = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main()).toBe(0);
    expect(silentErr.mock.calls.flat().join("\n")).not.toContain("refine 目安");
    expect(silentErr.mock.calls.flat().join("\n")).not.toContain("閾値超過カテゴリ");
    vi.restoreAllMocks();

    const overWarn = writePlaybook(
      compactEntries(DEFAULT_WARN_ENTRIES_PER_CATEGORY + 1),
    );
    process.argv = ["node", "check-category-size.ts", overWarn];
    const warnErr = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main()).toBe(0);
    const warnOut = warnErr.mock.calls.flat().join("\n");
    expect(warnOut).toContain("refine 目安");
    expect(warnOut).toContain(
      `coding (${String(DEFAULT_WARN_ENTRIES_PER_CATEGORY + 1)} > ${String(DEFAULT_WARN_ENTRIES_PER_CATEGORY)} / ブロック上限 ${String(DEFAULT_MAX_ENTRIES_PER_CATEGORY)})`,
    );
    expect(warnOut).not.toContain("閾値超過カテゴリ");
  });

  it("env 未設定の既定配線: 上限ちょうどは警告のみ、上限+1 で exit 1", () => {
    const atMax = writePlaybook(compactEntries(DEFAULT_MAX_ENTRIES_PER_CATEGORY));
    process.argv = ["node", "check-category-size.ts", atMax];
    const warnErr = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main()).toBe(0);
    const warnOut = warnErr.mock.calls.flat().join("\n");
    expect(warnOut).toContain("refine 目安");
    expect(warnOut).not.toContain("閾値超過カテゴリ");
    vi.restoreAllMocks();

    const overMax = writePlaybook(
      compactEntries(DEFAULT_MAX_ENTRIES_PER_CATEGORY + 1),
    );
    process.argv = ["node", "check-category-size.ts", overMax];
    const blockErr = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    expect(main()).toBe(1);
    const blockOut = blockErr.mock.calls.flat().join("\n");
    expect(blockOut).toContain("閾値超過カテゴリ");
    expect(blockOut).toContain(
      `coding (${String(DEFAULT_MAX_ENTRIES_PER_CATEGORY + 1)} > ${String(DEFAULT_MAX_ENTRIES_PER_CATEGORY)})`,
    );
  });

  it("ACE_MAX=130 の旧挙動は警告段を出さず 131 で exit 1", () => {
    const file = writePlaybook(compactEntries(DEFAULT_WARN_ENTRIES_PER_CATEGORY + 1));
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY = String(
      DEFAULT_WARN_ENTRIES_PER_CATEGORY,
    );
    process.argv = ["node", "check-category-size.ts", file];
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});

    expect(main()).toBe(1);
    const out = err.mock.calls.flat().join("\n");
    expect(out).toContain("閾値超過カテゴリ");
    expect(out).toContain(
      `coding (${String(DEFAULT_WARN_ENTRIES_PER_CATEGORY + 1)} > ${String(DEFAULT_WARN_ENTRIES_PER_CATEGORY)})`,
    );
    expect(out).not.toContain("refine 目安");
  });

  it("refine 目安超過・ブロック上限以下なら exit 0 で警告する", () => {
    const body =
      "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "### ACE-1-2: b\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "### ACE-1-3: c\n\n| Category | coding |\n| Origin | PR #1 |\n";
    const file = writePlaybook(body);
    process.env.ACE_WARN_ENTRIES_PER_CATEGORY = "2";
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY = "10";
    process.argv = ["node", "check-category-size.ts", file];
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(err.mock.calls.flat().join("\n")).toContain("refine 目安");
    expect(err.mock.calls.flat().join("\n")).toContain("coding (3 > 2 / ブロック上限 10)");
  });

  it("ブロック上限超過なら exit 1（警告段を越えたハードゲート）", () => {
    const body =
      "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "### ACE-1-2: b\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "### ACE-1-3: c\n\n| Category | coding |\n| Origin | PR #1 |\n";
    const file = writePlaybook(body);
    process.env.ACE_WARN_ENTRIES_PER_CATEGORY = "2";
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY = "2";
    process.argv = ["node", "check-category-size.ts", file];
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    const out = err.mock.calls.flat().join("\n");
    expect(out).toContain("閾値超過カテゴリ");
    expect(out).toContain("coding (3 > 2)");
    expect(out).not.toContain("refine 目安");
  });

  describe("導出上限（エントリ密度）— ACE_MAX_PLAYBOOK_LINES 未設定時", () => {
    /**
     * 指定した wc -l 行数ちょうどのコンパクト正準エントリブロックを作る。
     * 固定 9 行 + 本文 b 行 + 終端 3 行（`---` + 空行 + ブロック間セパレータ）で
     * 11 + b 行になる。密度の境界を実測するテストなので行数は式から導出し、
     * マジックナンバーを 2 箇所に置かない。
     */
    function entryBlockOfLines(id: string, totalLines: number): string {
      const fixed = [
        `<a id="ace-${id}"></a>`,
        "",
        `### ACE-${id}: t`,
        "",
        "| Category | coding | Origin | PR #1 |",
        "| Date | 2026-08-07 |",
        "| Helpful | 0 | Harmful | 0 |",
        "| Status | active |",
        "",
      ];
      const tail = ["---", "", ""];
      const bodyCount = totalLines - (fixed.length + tail.length - 1);
      if (bodyCount < 0) {
        throw new Error(`totalLines=${String(totalLines)} は固定部より短く表現できません`);
      }
      const body = Array.from({ length: bodyCount }, (_, i) => `本文 ${String(i)}`);
      return [...fixed, ...body, ...tail].join("\n");
    }

    function writeEntries(count: number, linesPerEntry: number): string {
      const body = Array.from({ length: count }, (_, i) =>
        entryBlockOfLines(`1-${String(i + 1)}`, linesPerEntry),
      ).join("");
      return writePlaybook(body);
    }

    it("ヘッダが例外マーカーの書式を説明していても導出上限は伸びない（密度警告を殺さない）", () => {
      // §運用ルールにマーカーの書式を書くのは PLAYBOOK として自然な操作。
      // これで上限が伸びると「警告が出ない＝正常」と見分けがつかなくなる。
      const header = [
        "# Header",
        "<!-- ace-line-budget-exception: 書式例 1 -->",
        "<!-- ace-line-budget-exception: 書式例 2 -->",
        "<!-- ace-line-budget-exception: 書式例 3 -->",
        "",
      ].join("\n");
      const body = Array.from({ length: 3 }, (_, i) =>
        entryBlockOfLines(`1-${String(i + 1)}`, 20),
      ).join("");
      // 64 行（ヘッダ 4 + 20 行/件 × 3 件）。導出上限 = ヘッダ 6 + 3 件 × 16 = 54 行。
      const file = writePlaybook(header + body);
      process.argv = ["node", "check-category-size.ts", file];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      expect(log.mock.calls.flat().join("\n")).toContain("導出上限 54");
      // 上限に反映しないことと、落としたことを黙らないことの両方を固定する。
      expect(log.mock.calls.flat().join("\n")).not.toContain("+ 例外");
      expect(log.mock.calls.flat().join("\n")).toContain(
        "例外マーカー 3 件中 0 件を宣言として採用",
      );
      expect(err.mock.calls.flat().join("\n")).toContain("エントリ密度が行数バジェットを超過");
    });

    it("1 エントリの行数バジェットを超える密度なら警告する（旧テーブル形式の残存を名指しできる）", () => {
      // 20 行/件 × 3 件 = 60 行。導出上限 = ヘッダ 2 + 3 × 16 = 50 行。
      const file = writeEntries(3, 20);
      process.argv = ["node", "check-category-size.ts", file];
      vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const errOut = err.mock.calls.flat().join("\n");
      expect(errOut).toContain("エントリ密度が行数バジェットを超過");
      expect(errOut).toContain("/ace-refine");
    });

    it("総行数が旧既定 800 を超えても、密度が予算内なら警告しない（refine 直後に余裕が生まれる）", () => {
      // 14 行/件 × 60 件 = 840 行（旧既定 800 超）。導出上限 = 2 + 60 × 16 = 962 行。
      const file = writeEntries(60, 14);
      process.argv = ["node", "check-category-size.ts", file];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      expect(log.mock.calls.flat().join("\n")).toContain("導出上限");
      expect(err.mock.calls.flat().join("\n")).not.toContain("超過");
    });

    it("報告される上限が件数に比例して伸びる（curate 1 件で警告へ戻らない）", () => {
      // 同じ密度（14 行/件）でも上限は件数由来で動く。固定上限ならこの値は変化しない。
      const few = writeEntries(10, 14);
      process.argv = ["node", "check-category-size.ts", few];
      const logFew = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});
      expect(main()).toBe(0);
      // ヘッダ 2 + 10 × 16 = 162
      expect(logFew.mock.calls.flat().join("\n")).toContain("導出上限 162");

      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
      const many = writeEntries(60, 14);
      process.argv = ["node", "check-category-size.ts", many];
      const logMany = vi.spyOn(console, "log").mockImplementation(() => {});
      expect(main()).toBe(0);
      // ヘッダ 2 + 60 × 16 = 962
      expect(logMany.mock.calls.flat().join("\n")).toContain("導出上限 962");
    });

    it("ACE_MAX_PLAYBOOK_LINES を明示設定したときは固定上限として尊重する（後方互換）", () => {
      // 導出上限なら緑になる 840 行を、明示 800 で赤にできること。
      const file = writeEntries(60, 14);
      process.env.ACE_MAX_PLAYBOOK_LINES = "800";
      process.argv = ["node", "check-category-size.ts", file];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      expect(log.mock.calls.flat().join("\n")).toContain("閾値 800");
      expect(err.mock.calls.flat().join("\n")).toContain("行数が閾値を超過");
    });

    it("ヘッダ内の複数行 HTML コメントも上限の基準に含める（コメント除去だとヘッダを過小に測る）", () => {
      // ヘッダ 8 行（うち 3 行が HTML コメント）+ 13 行のエントリ 1 件。
      // 上限 = 8 + 1 × 16 = 24。コメントを「除去」して測ると 5 + 16 = 21 になり、
      // 総行数 21 と一致して境界の偶然で緑になる。上限の値そのものを固定して区別する。
      const header = [
        "# PLAYBOOK — コーディング (coding)",
        "",
        "<!-- 追記例:",
        "### ACE-001: コメント内の偽エントリ",
        "-->",
        "",
      ].join("\n");
      const file = writePlaybook(`${header}\n${entryBlockOfLines("1-1", 13)}`);
      process.argv = ["node", "check-category-size.ts", file];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      expect(log.mock.calls.flat().join("\n")).toContain("導出上限 24 = ヘッダ 8 + 1 件 × 16");
      expect(err.mock.calls.flat().join("\n")).not.toContain("超過");
    });

    it("ACE_MAX_ENTRY_LINES を上げると同じファイルが緑へ転じる（バジェットが上限の由来）", () => {
      const file = writeEntries(3, 20);
      process.env.ACE_MAX_ENTRY_LINES = "19";
      process.argv = ["node", "check-category-size.ts", file];
      vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      expect(err.mock.calls.flat().join("\n")).not.toContain("超過");
    });
  });

  describe("分割レイアウト（playbook/ サブディレクトリ検出）", () => {
    function writeSplitPlaybook(indexBody: string, subfiles: Record<string, string>): string {
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-main-"));
      const indexPath = path.join(tmpDir, "PLAYBOOK.md");
      fs.writeFileSync(indexPath, indexBody);
      const subDir = path.join(tmpDir, "playbook");
      fs.mkdirSync(subDir);
      for (const [name, content] of Object.entries(subfiles)) {
        fs.writeFileSync(path.join(subDir, name), content);
      }
      return indexPath;
    }

    it("ファイルごとの解析結果・ヘッダ行数・例外件数が取り違わらない（部分移行中の索引 + カテゴリファイル）", () => {
      // 1 ファイル 1 レコードへ統合した箇所の回帰。別々の配列を添字で突き合わせる形へ
      // 戻すと、ここで指標が入れ替わって導出上限が両方とも別の値になる。
      // 索引側にもエントリを残す（＝索引も監視対象）ことで 2 ファイル分の内訳を比較できる。
      const indexPath = writeSplitPlaybook(
        [
          "# 索引",
          "ヘッダ 2 行目",
          "ヘッダ 3 行目",
          "",
          "### ACE-1-1: 索引に残っているエントリ",
          "| Category | coding |",
          "本文",
          "---",
          "",
        ].join("\n"),
        {
          "testing.md": [
            "# testing",
            "",
            "### ACE-1-2: 例外を宣言したエントリ",
            "| Category | testing |",
            "<!-- ace-line-budget-exception: 反直感的な詳細のため -->",
            "本文",
            "---",
            "",
          ].join("\n"),
        },
      );
      process.argv = ["node", "check-category-size.ts", indexPath];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();
      const out = log.mock.calls.flat().join("\n");

      expect(code).toBe(0);
      // 索引: ヘッダ 4 行 / 1 件 / 例外 0 件。カテゴリ: ヘッダ 2 行 / 1 件 / 例外 1 件。
      expect(out).toContain("導出上限 20 = ヘッダ 4 + 1 件 × 16");
      expect(out).toContain("導出上限 33 = ヘッダ 2 + 1 件 × 16 + 例外 1 × 15");
    });

    it("吸収が起きたサブファイルを名指しして exit 2（ゲートが exit 0 へ縮退しない）", () => {
      // 分割レイアウトでは 7 ファイルのどれを直せばよいかを伝えるのは
      // `${filePath}:` 接頭辞だけで、analyzePlaybookMarkdown の戻り値には含まれない。
      // CI が消費するのは exit code なので、この経路が 0 へ落ちるとユニットは全部緑の
      // ままゲートだけが消える（isDirectExecution のコメントが警戒する silent-gate と同型）。
      const indexPath = writeSplitPlaybook("# 索引のみ、エントリ見出しなし\n", {
        "coding.md": "### ACE-1-1: a\n\n| Category | coding |\n",
        "testing.md":
          "### ACE-1-2: b\n\n| Category | testing |\n\n" +
          "### ACE-abc-1: ID を打ち間違えたエントリ\n\n| Category | testing |\n",
      });
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(2);
      const errOut = err.mock.calls.flat().join("\n");
      expect(errOut).toContain("testing.md");
      expect(errOut).toContain("吸収");
    });

    it("索引(0件) + サブファイルを合算し、総件数・カテゴリ別件数に反映する", () => {
      const indexPath = writeSplitPlaybook("# 索引のみ、エントリ見出しなし\n", {
        "coding.md": "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
        "process.md":
          "### ACE-1-2: b\n\n| Category | process |\n| Origin | PR #1 |\n" +
          "### ACE-1-3: c\n\n| Category | process |\n| Origin | PR #1 |\n",
      });
      process.argv = ["node", "check-category-size.ts", indexPath];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const out = log.mock.calls.flat().join("\n");
      expect(out).toContain("総エントリ数: 3");
      expect(out).toContain("coding: 1");
      expect(out).toContain("process: 2");
      expect(out).toContain("分割レイアウト検出");
    });


    it("分割レイアウトでは索引 PLAYBOOK.md の行数超過を警告しない（カテゴリ側のみ監視）", () => {
      const indexPath = writeSplitPlaybook("# 索引\n" + "y\n".repeat(30), {
        "coding.md":
          "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
      });
      process.env.ACE_MAX_PLAYBOOK_LINES = "5";
      process.argv = ["node", "check-category-size.ts", indexPath];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const out = log.mock.calls.flat().join("\n");
      expect(out).toContain("索引ファイル・行数閾値の監視対象外");
      // coding.md は閾値内なので警告なし
      expect(err.mock.calls.flat().join("\n")).not.toContain("行数が閾値を超過");
    });

    it("分割レイアウトでも索引側にエントリが残る部分移行中は索引の行数超過を警告する", () => {
      const indexPath = writeSplitPlaybook(
        [
          "# 索引 + 未移行エントリ",
          "### ACE-9-1: still on index",
          "",
          "| Category | process |",
          "| Origin | PR #9 |",
          "",
          "body",
          "",
        ].join("\n") + "\n" + "y\n".repeat(30),
        {
          "coding.md":
            "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
        },
      );
      process.env.ACE_MAX_PLAYBOOK_LINES = "5";
      process.argv = ["node", "check-category-size.ts", indexPath];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const out = log.mock.calls.flat().join("\n");
      expect(out).not.toContain("索引ファイル・行数閾値の監視対象外");
      expect(err.mock.calls.flat().join("\n")).toContain("行数が閾値を超過");
    });

    it("サブファイル側の行数超過も個別に警告する（exit code は不変）", () => {
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md":
          "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n" + "x\n".repeat(20),
      });
      process.env.ACE_MAX_PLAYBOOK_LINES = "5";
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const errOut = err.mock.calls.flat().join("\n");
      expect(errOut).toContain("coding.md");
      expect(errOut).toContain("行数が閾値を超過");
    });

    it("エントリ 0 件のカテゴリファイル（新規作成直後）は密度の監視対象外にする", () => {
      // PLAYBOOK.md §新規カテゴリファイルのテンプレートが作れと言う状態そのもの。
      // 0 件では測る密度が存在しない。導出上限 = ヘッダ行数 と一致する境界の偶然に
      // 頼らず、対象外であることを明示する（境界の off-by-one で偽赤にしない）。
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md": "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
        "security.md":
          "# PLAYBOOK — セキュリティ (security)\n\n> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md)\n\n---\n\n## エントリ一覧\n",
      });
      process.argv = ["node", "check-category-size.ts", indexPath];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const out = log.mock.calls.flat().join("\n");
      expect(out).toContain("security.md");
      expect(out).toContain("エントリ 0 件・密度の監視対象外");
      expect(err.mock.calls.flat().join("\n")).not.toContain("超過");
    });

    it("索引・サブファイルの全てが0件なら usage error（exit 2）", () => {
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md": "# まだ空\n",
      });
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(2);
    });

    it("カテゴリ件数ゲートは分割レイアウトでも合算値で判定する", () => {
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md": "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
        "coding2.md": "### ACE-1-2: b\n\n| Category | coding |\n| Origin | PR #1 |\n",
      });
      process.env.ACE_MAX_ENTRIES_PER_CATEGORY = "1";
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(1);
    });
  });
});
