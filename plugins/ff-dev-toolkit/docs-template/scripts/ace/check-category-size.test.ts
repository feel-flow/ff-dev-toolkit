import { afterEach, describe, expect, it, vi } from "vitest";
import {
  analyzePlaybookMarkdown,
  countBudgetExceptions,
  countHeaderLines,
  countPlaybookLines,
  deriveMaxLines,
  discoverPlaybookSubfiles,
  isDirectExecution,
  isOverLineThreshold,
  main,
  mergeAnalyses,
  parsePositiveIntEnv,
} from "./check-category-size";
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
    // 分割はフェンス空白化より前に走るので、正準形 ID の例示は split の境界になる
    // （Issue #342）。少なくとも静かには通さないこと — フェンスが対にならないため
    // 閉じ忘れとして落ちる。
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
    expect(merged.totalEntries).toBe(7);
    expect(merged.histogram).toEqual({ coding: 2, process: 5 });
  });

  it("空配列は totalEntries 0 の ok を返す", () => {
    const merged = mergeAnalyses([]);
    expect(merged.kind).toBe("ok");
    expect(merged.totalEntries).toBe(0);
    expect(merged.histogram).toEqual({});
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
  it("ace-line-budget-exception マーカーの出現数を数える", () => {
    const md = [
      "### ACE-1-1: a",
      "<!-- ace-line-budget-exception: 反直感的な詳細 -->",
      "### ACE-1-2: b",
      "<!-- ace-line-budget-exception: 別の理由 -->",
      "### ACE-1-3: c",
    ].join("\n");

    expect(countBudgetExceptions(md)).toBe(2);
  });

  it("マーカーが無ければ 0", () => {
    expect(countBudgetExceptions("### ACE-1-1: a\n")).toBe(0);
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
    delete process.env.ACE_MAX_ENTRY_LINES;
    vi.restoreAllMocks();
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  function writePlaybook(body: string): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-line-"));
    const file = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(file, body);
    return file;
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
