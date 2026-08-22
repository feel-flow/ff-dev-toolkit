---
title: "PLAYBOOK"
version: "1.0.0"
status: "draft"
created: "2026-01-01"
updated: "2026-01-02"
changeImpact: medium
owner: "@fixture"
ace_entry_count: 1
tags: [ace, playbook, knowledge-management]
references:
  - docs/05-operations/deployment/ace-cycle.md
---

# ACE Playbook

負側 fixture。allowlist に無い旧テーブル形式のエントリを 1 件だけ持つ。
形式ゲート（check-entry-format）が非 0 で落ちることの期待値。

## エントリ一覧

<a id="ace-002-1"></a>

### ACE-002-1: 旧テーブル形式は新規追記に使わない

| フィールド | 値      |
| ---------- | ------- |
| Category   | tooling |
| Origin     | PR #2   |
| Date       | 2026-01-01 |
| Helpful    | 0       |
| Harmful    | 0       |
| Status     | active  |

**Insight**: 旧テーブル形式は読み取り互換のためだけに残す。

**Context**: 形式ゲートの検出力を実測するための fixture。

**Action**: 新規追記はコンパクト正準フォーマットで書く。

---

## Changelog

### [1.0.0] - 2026-01-02

#### 追加

- ACE-002-1: 旧形式の fixture エントリ
