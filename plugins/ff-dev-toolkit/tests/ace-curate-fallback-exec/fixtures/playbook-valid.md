---
title: "PLAYBOOK"
version: "1.0.0"
status: "draft"
created: "2026-01-01"
updated: "2026-01-02"
changeImpact: medium
owner: "@fixture"
ace_entry_count: 2
tags: [ace, playbook, knowledge-management]
references:
  - docs/05-operations/deployment/ace-cycle.md
---

# ACE Playbook

正常系 fixture。正準フォーマット 2 件 + frontmatter/Changelog 整合。3 本とも exit 0 が期待値。

## エントリ一覧

<a id="ace-001-1"></a>

### ACE-001-1: fixture のエントリは正準フォーマットで書く

| Category | tooling | Origin | PR #1 |
| Date | 2026-01-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

メタ 4 行を行頭のパイプ区切りで書くと集計スクリプトがフィールドを読み取れる。ヘッダ行と
区切り行を持たない形が正準で、旧テーブル形式は新規追記に使わない。

---

<a id="ace-001-2"></a>

### ACE-001-2: 検証対象は同梱スクリプトの到達可能性である

| Category | tooling | Origin | PR #1 |
| Date | 2026-01-01 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

プロジェクトへ `scripts/ace/` を導入していなくても、プラグイン同梱のテンプレートを直接
指定すればゲートは動く。到達できるパスを手順書に書くこと。

---

## Changelog

### [1.0.0] - 2026-01-02

#### 追加

- ACE-001-1 / ACE-001-2: fixture の初期エントリ
