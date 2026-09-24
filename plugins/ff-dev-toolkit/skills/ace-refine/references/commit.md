# /ace-refine — claim の最終生成とコミット

本線 `SKILL.md` の R3-e（索引・Frontmatter・Changelog・allowlist の更新と検証ゲート）が exit 0 になった後に読む。PR か直 push かの判断は本線の「コミット」節が持つ。

## 1. claim の最終生成

全編集とゲートの完了後に 1 回だけ実行し、以後は対象文書を変更しない。一時ファイル生成・上書き禁止 hard link での install・3 行完全一致の検証・競合時の rollback は `scripts/update-version-claim.sh` が行い、失敗はすべて停止になる。

```bash
if [[ -d .version-claims ]]; then
  [[ -n "${FF_DEV_TOOLKIT_ROOT:-}" && -x "$FF_DEV_TOOLKIT_ROOT/scripts/update-version-claim.sh" ]] || { echo "FF_DEV_TOOLKIT_ROOT の claim helper を解決できません" >&2; exit 1; }
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || { echo "origin/HEAD を解決できません。git remote set-head origin --auto 後に再実行してください" >&2; exit 1; }
  [[ "$default_ref" == origin/* ]] || { echo "origin/HEAD が不正です" >&2; exit 1; }
  default_branch="${default_ref#origin/}"
  for document in docs/08-knowledge/PLAYBOOK.md docs/03-implementation/PATTERNS.md; do
    if git diff --quiet "origin/${default_branch}" -- "$document"; then diff_rc=0; else diff_rc=$?; fi
    case "$diff_rc" in 0) continue ;; 1) ;; *) echo "文書差分を検査できません: $document" >&2; exit 1 ;; esac
    FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" "${FF_DEV_TOOLKIT_ROOT}/scripts/update-version-claim.sh" --base "origin/${default_branch}" --document "$document" || exit 1
  done
fi
```

claim の content conflict で止まったら（R3 の書き込み後に base が 2 度目に先行した）、適用済みの成果は捨てずに最新 base を取り込み、先に入った整理と重なった分だけ差し引いて作り直す（実測: 161 件中 23 件が先行 → 138 件）。version / `ace_entry_count` / Changelog / claim は最新 base から取り直し、claim の片寄せ・削除で解消しない。

## 2. 既定 — chore PR

```bash
git checkout -b chore/ace-refine-<YYYYMMDD>
git add docs/08-knowledge/ docs/03-implementation/PATTERNS.md || { echo "ACE 変更を stage できません" >&2; exit 1; }
if [[ -d .version-claims ]]; then
  if git diff --cached --quiet -- docs/08-knowledge/PLAYBOOK.md; then playbook_diff_rc=0; else playbook_diff_rc=$?; fi
  case "$playbook_diff_rc" in
    0) ;;
    1) [[ -f .version-claims/docs/08-knowledge/PLAYBOOK.md.claim ]] || { echo "PR 経路に PLAYBOOK version claim がありません" >&2; exit 1; }; git add .version-claims/docs/08-knowledge/PLAYBOOK.md.claim || { echo "PLAYBOOK claim を stage できません" >&2; exit 1; } ;;
    *) echo "PLAYBOOK の staged 差分を検査できません" >&2; exit 1 ;;
  esac
  if git diff --cached --quiet -- docs/03-implementation/PATTERNS.md; then patterns_diff_rc=0; else patterns_diff_rc=$?; fi
  case "$patterns_diff_rc" in
    0) ;;
    1) [[ -f .version-claims/docs/03-implementation/PATTERNS.md.claim ]] || { echo "PATTERNS version claim がありません" >&2; exit 1; }; git add .version-claims/docs/03-implementation/PATTERNS.md.claim || { echo "PATTERNS claim を stage できません" >&2; exit 1; } ;;
    *) echo "PATTERNS の staged 差分を検査できません" >&2; exit 1 ;;
  esac
fi
[[ ! -d .version-claims ]] || FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" "${FF_DEV_TOOLKIT_ROOT}/scripts/check-version-claims.sh" --root "$(git rev-parse --show-toplevel)" || exit 1
git status --short  # 意図したファイルのみが含まれるか確認
git commit \
  -m "knowledge: ace-refine <YYYY-MM-DD> <要約（例: archive 12 件 / compact 5 件）>" \
  -m "Archived: <ID...>" \
  -m "Compacted: <ID...>" \
  -m "Merged: <ID -> ID ...>" \
  -m "Promoted: <ID...>"
git push -u origin chore/ace-refine-<YYYYMMDD>
gh pr create --base <default-branch> --title "knowledge: ace-refine <YYYY-MM-DD> <要約>" --body "..."
```

## 3. 例外 — デフォルトブランチ直 push

直 push でも、commit の前に上の claim block と同じ claim 生成を実行し、変更した文書（PLAYBOOK / PATTERNS）の claim を stage して `check-version-claims.sh` を通す。claim が無い・stale のままなら commit せず停止する。

non-fast-forward で拒否されたら、remote の整理結果を保全して最新 tree からレポート・version・`ace_entry_count`・Changelog を再生成する。**各再試行で**上の claim block と同じ claim 生成を最新 base からやり直し、全ゲートを再実行してから通常 push を**最大 3 回**再試行する。収束しなければ直列化を求めて停止し、force push で上書きしない。
