---
name: sweep-orphan-transcripts
description: "既存の孤児 Claude Code トランスクリプト（~/.claude/projects 配下で cwd がすべて現存しないもの）を一覧・アーカイブ回収する。既定は dry-run。破壊は --apply 明示時のみ。「孤児をまとめて掃除」「~/.claude が肥大」「worktree 消し残しの履歴回収」で使う"
allowed-tools: ["Bash"]
---

# /sweep-orphan-transcripts — 既存の孤児トランスクリプト回収

`/merge-cleanup` の Step 5.5 は「その実行で削除した worktree の分」だけを回収する。本スキルは **すでに溜まっている孤児** を `<config>/projects/` 全体から探す。

## プラグインルートの解決

`${FF_DEV_TOOLKIT_ROOT}` を `merge-cleanup` と同じ規則で解決する（Claude Code では `${CLAUDE_PLUGIN_ROOT}`、他ホストではこの SKILL.md の絶対パスから `../..`）。

## 実行

```bash
# 既定: dry-run（削除しない。候補と見込み容量だけ表示）
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/sweep-orphan-transcripts.sh"

# 回収を実行（tar.gz アーカイブ → 検証 → 元ディレクトリ削除）
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/sweep-orphan-transcripts.sh" --apply
```

`$ARGUMENTS` に `--apply` が含まれるときだけ apply を付ける。それ以外は dry-run。

```bash
case " $ARGUMENTS " in
  *" --apply "*)
    bash "${FF_DEV_TOOLKIT_ROOT}/scripts/sweep-orphan-transcripts.sh" --apply
    ;;
  *)
    bash "${FF_DEV_TOOLKIT_ROOT}/scripts/sweep-orphan-transcripts.sh"
    ;;
esac
```

## 判定（fail-closed）

上から順に評価し、最初に当たった行で確定する。保護（触らない）を先に置く多層防御。

| 状況 | 扱い |
| --- | --- |
| 候補が symlink / projects 直下に解決されない | 触らない |
| **ディレクトリ名が現存パスへ解決される**（名前→実FSを貪欲に辿れる） | 触らない（プロジェクトのルートが生存中。`cwd` の判定より優先） |
| **名前解決が判定不能**（探索予算超過） | 触らない + 失敗として報告（「判定できない」を「非現存」に降格しない） |
| **空でない `memory/` が同居する** | 触らない（次回セッションが読む永続資産。`cwd` の判定より優先） |
| **`memory/` はあるが走査に失敗**（読み取り不可） | 触らない + 失敗として報告 |
| jsonl の `cwd` が 1 件以上あり、**いずれも現存しない** | 孤児候補（dry-run で列挙 / `--apply` で回収） |
| `cwd` のうち **1 つでも現存する** | 触らない（稼働中の可能性） |
| `cwd` を記録した jsonl が無い | 触らない（所有証拠なし） |
| jsonl 走査エラー | 触らない + 失敗として報告 |

名前に `worktree` が含まれることだけを根拠にはしない（`/merge-cleanup` Step 5.5 と同じ思想）。

### 名前解決ガードが「名前ベース削除の禁止」と矛盾しない理由

`/merge-cleanup` の設計（feel-flow/ff-dev-toolkit#8）では「候補名は削除対象パスから機械的に導出したものなので、名前へのパターン照合は入力の言い換えにすぎない」として、**削除の根拠**を名前に置く経路を全廃した。ここで足すのは真逆で、**保護の根拠**として名前を使う。しかも照合先は名前パターンではなく**実ファイルシステム**（対象から独立した外部世界）で、「名前が指すパスが今この瞬間に現存するか」は OS へ問い合わせて初めて分かる事実であり入力の再表示ではない。

ディレクトリ名のエンコードは非可逆（`/` `.` `-` がいずれも `-` になり得る）で、実測では `.claude` が `-.claude`（ドット保持）と `--claude`（ドットも `-` 化）の両綴りで現れる。そのため `tr '-' '/'` では戻せず、「先頭 `-` を `/` 起点にし、残りを実FS上の現存ディレクトリへ最長優先＋バックトラックで辿る」探索で解決する（両綴りを試す）。

**三値判定（fail-closed の要）**: 破壊的ツールなので「解決できない（＝非現存の証拠）」と「判定できなかった（探索予算超過 / `memory/` 読み取り不可）」を分ける。前者は従来 `cwd` 判定へ委ね、後者は**保護したうえで失敗として報告**する（削除経路へは落とさない）。探索は総ステップ予算で必ず停止する。

**既知の制約**: セグメント内部のドット（例 `Finder.app` → `Finder-app`）は復元しない。ドット補完はセグメント先頭のドット始まりディレクトリ（`.claude` 等）に限る。内部ドットを含むプロジェクトは名前解決では守れないが、その場合も `memory/` ガードや従来 `cwd` 判定へ委ねる fail-closed 側に倒れるだけで、削除方向の誤りにはならない。逆に、通常名 `plain` を隠しディレクトリ `.plain` の存在だけで生存扱いする過剰保護も避けている（ドット補完を無条件には試さない）。

## アーカイブ

既定で `<config>/transcript-archives/<名前>-<日時>.tar.gz`。件数検証・アーカイブ中変更検出・削除直前の再確認は merge-cleanup と同じ。

## subagents/（Issue #281）

孤児と判定した**プロジェクトディレクトリ全体**を回収するため、配下の `subagents/` も一緒にアーカイブされる。

**稼働中プロジェクト内**の `subagents/` だけを年齢ベースで消すことはしない。セッション所有の証拠が `cwd` 単位では切れず、誤削除のリスクがあるため。Claude Code 本体の `cleanupPeriodDays` が `subagents/` を対象外にしている観察は upstream 側の挙動として扱い、本ツールでは孤児プロジェクト単位でのみ回収する。

## 環境変数

| 変数 | 既定 | 用途 |
| --- | --- | --- |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | 設定ルート |
| `FF_SWEEP_PROJECTS_DIR` | `<config>/projects` | 走査対象 |
| `FF_SWEEP_ARCHIVE_DIR` | `<config>/transcript-archives` | アーカイブ先 |
