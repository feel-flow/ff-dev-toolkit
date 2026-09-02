# 振り返り観測台帳（Retrospective Observations）

> **運用の正本**: ff-dev-toolkit プラグインの `skills/retrospective/SKILL.md` の「観測の記録 — 観測台帳（起票の前段バッファ）」。本ファイルは `/retrospective` が記録する Problem / Keep 観測の蓄積バッファであり、手順・閾値・承認境界はスキル側だけが定義する（ここへ複製しない）。
>
> - 記録・畳み込み（同一性の判定）・昇格閾値・特急レーン・archived の条件・コミット規約は、すべてスキル側の規定に従う。**数値や判定基準を本ファイルへ複製しない** — 契約ゲートが固定しているのはスキル側の規定と、下の `Status` 値域行（本体と配布テンプレの一致・所在の接頭辞）だけで、それ以外にここへ写した規則は古くなっても検出されない
> - Frontmatter は付与しない（機械管理の蓄積ファイルで、ACE Playbook の分割ファイルと同じ扱い。`docs/MASTER.md` §Frontmatter の例外注記を参照）
> - 台帳はリポジトリごとに持つ。このファイルが無い場合、`/retrospective` がプラグインの `docs-template/08-knowledge/OBSERVATIONS.md` から作成する

## エントリ形式

新規エントリは次の形式で「エントリ一覧」の末尾へ追記する（ID は `OBS-<3 桁連番>`。既存の最大連番 +1）:

```markdown
<a id="obs-XXX"></a>

### OBS-XXX: [検索可能な主張 1 文のタイトル]

| Kind | problem または keep | Count | 1 |
| First | YYYY-MM-DD | Last | YYYY-MM-DD |
| Status | active | Issue | なし |

[本文 1〜3 文。1 文目 = 主張。problem / keep の文形と Count の意味論はスキル側「記録手順」が正本 — ここへ複製しない]

- YYYY-MM-DD: [1 行の実測メモ]（初回）

---
```

- メタ 3 行は行頭のパイプ区切りで書く（ACE Playbook のコンパクト正準フォーマットと同じ機械可読性の担保）
- `Status` の値域: `active`（蓄積中）/ `promoted`（Issue 昇格済み。`Issue` にリポジトリ修飾の発行番号 `owner/repo#N` を書く）/ `mitigated`（対策済み。対策が別の場所に定義済みのため昇格を見送った。`Issue` に対策の所在を `owner/repo#N` / `skill:<スキル名>` / `doc:<path>#<アンカー>` の書式で書く。条件の正本はスキル側）/ `archived`（休眠。条件の正本はスキル側。再発したら `active` へ戻す）
- 観測メモは再発のたびに 1 行追記する（セッション固有の長い叙述は書かない — 詳細が必要になるのは昇格時で、その時点の Issue 本文に書けばよい）

## エントリ一覧
