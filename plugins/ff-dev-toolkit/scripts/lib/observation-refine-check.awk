# observation-refine-check.awk — 観測台帳の整理（適用）が履歴を消していないことを照合する。
#
# scripts/observation-refine.sh check が LC_ALL=C で呼ぶ。単体では実行しない。
# -v で受ける値:
#   before      適用前の台帳（入口が一時領域へ写したファイル）
#   after       適用後の台帳（同上）
#   ledger_rel  台帳のリポジトリ相対パス（統合元が統合先を指すポインタ `doc:<ledger_rel>#obs-nnn` の照合用）
#   threshold   昇格閾値（適用後に閾値へ到達した未リンクの active を列挙するため）
#
# 照合する不変条件（スキル observation-refine の「適用」が正本。ここは機械で確かめられる分）:
#   A. 適用前の行は、適用後にも同じ順で全部残っている。値が変わってよいのは、4 セルちょうどの
#      メタ行の Count / First / Last / Status / Issue だけ（見出し・anchor・本文・観測メモ・Kind・
#      メタ行のセルの数は不変）
#   B. 足された行は、エントリの中の `- YYYY-MM-DD: 状態移行（再発ではない）` で始まる行だけ。
#      メタが何も変わらないエントリ（統合先を除く）へは足さない
#   C. Status の移行は active → promoted / mitigated / archived だけで、移行できるのは適用前の
#      Issue 列が `なし` のエントリだけ（既存の Issue 参照を上書きしない）。移行したエントリは B の行を持つ
#   D. promoted は Issue 列に `owner/repo#N` を持つ。mitigated は Kind が keep で、対策の所在
#      （`owner/repo#N` / `skill:` / `doc:`）を持つ
#   E. archived で Issue 列が変わるのは統合元だけで、値は台帳自身の統合先 anchor。統合先は
#      実在し、自分ではなく、archived でなく、統合元と Kind が同じで、統合元の ID を名指す B の行を持つ。
#      適用前からの統合元が指す先も、今回の適用で archived にしない（過去の統合をまたぐ連鎖）
#   F. Count / First / Last が変わるのは統合先だけで、Count は統合元との合算、First は最小、
#      Last は最大に一致する（統合元を持つのに合算していない場合も違反）。Count は 1 以上の整数
# 照合しないもの: archive したエントリが stale の基準に当たっていたか（基準は実行時の引数で、
# 承認で外したものもあるため）、同じ主張か・同じ事象の Issue か（ホストの判定）。
# 終了コード: 0 = 違反なし / 1 = 違反あり / 2 = 判定不能（読めない・適用前にエントリが無い）

function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

# メタ行（| key | value | key | value |）から key の値を返す。無ければ "\001"（空値と区別する）
function meta_of(line, key,   nf, f, i) {
  nf = split(line, f, "|")
  for (i = 2; i < nf; i++) if (trim(f[i]) == key) return trim(f[i + 1])
  return "\001"
}

# 4 セルちょうどで、キーが k1 / k2 の順に並ぶメタ行か。余分なセルを足した行は、値の差し替えを
# 許す正規化の対象にしない（足したセルが照合から見えなくなるため）
function exact_meta(line, k1, k2,   nf, f) {
  nf = split(line, f, "|")
  return nf == 6 && trim(f[1]) == "" && trim(f[6]) == "" && trim(f[2]) == k1 && trim(f[4]) == k2
}

function is_fence(line) { return line ~ /^[ \t]*(```|~~~)/ }

# 1 ファイルを読み、行・行の所属エントリ・エントリのメタを side（"b" / "a"）の配列へ入れる。
# 値の差し替えを許すメタ行は、エントリ ID を含む印へ正規化する（ID を入れないと、書き換えた
# Kind 行が後ろの別エントリの行へ対応してしまい、違反の名指しが無関係な行へずれる）
function load(file, side,   line, nl, cur, infence, v, rc) {
  nl = 0; cur = ""; infence = 0
  while ((rc = (getline line < file)) > 0) {
    sub(/\r$/, "", line)
    nl++
    L[side, nl] = line
    if (is_fence(line)) { infence = !infence; E[side, nl] = cur; N[side, nl] = line; continue }
    if (!infence) {
      if (line ~ /^### OBS-[0-9A-Za-z-]+:/) {
        cur = line; sub(/^### /, "", cur); sub(/:.*$/, "", cur)
        if ((side, cur) in SEEN) DUP[side] = DUP[side] " " cur
        SEEN[side, cur] = 1
        ORDER[side, ++NE[side]] = cur
      } else if (cur != "" && (line ~ /^---[ \t]*$/ || line ~ /^<a id=/ || line ~ /^## / || line ~ /^### /)) {
        cur = ""
      }
    }
    E[side, nl] = cur
    N[side, nl] = line
    if (cur != "" && !infence && line ~ /^[ \t]*\|/) {
      v = meta_of(line, "Kind")
      if (v != "\001" && !((side, cur, "Kind") in M)) {
        M[side, cur, "Kind"] = v; M[side, cur, "Count"] = meta_of(line, "Count")
        if (exact_meta(line, "Kind", "Count")) N[side, nl] = "\002meta " cur " Kind=" v
        continue
      }
      v = meta_of(line, "First")
      if (v != "\001" && !((side, cur, "First") in M)) {
        M[side, cur, "First"] = v; M[side, cur, "Last"] = meta_of(line, "Last")
        if (exact_meta(line, "First", "Last")) N[side, nl] = "\002meta " cur " FirstLast"
        continue
      }
      v = meta_of(line, "Status")
      if (v != "\001" && !((side, cur, "Status") in M)) {
        M[side, cur, "Status"] = v; M[side, cur, "Issue"] = meta_of(line, "Issue")
        if (exact_meta(line, "Status", "Issue")) N[side, nl] = "\002meta " cur " StatusIssue"
        continue
      }
    }
  }
  if (rc < 0) return -1
  close(file)
  NL[side] = nl
  return nl
}

function ng(id, msg) { nviol++; printf "NG %s: %s\n", (id == "" ? "(台帳)" : id), msg }

function unread(v) { return v == "" || v == "\001" }
function has_issue_ref(s) { return s ~ /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+/ }
function has_location(s) { return has_issue_ref(s) || s ~ /(^|[ \/])(skill|doc):[^ ]/ }

# note が id を名指しているか。直後が英数字・ハイフンの出現は別の ID（OBS-100 に対する OBS-1000）
function names(note, id,   rest, p, c) {
  rest = note
  while ((p = index(rest, id)) > 0) {
    c = substr(rest, p + length(id), 1)
    if (c !~ /[0-9A-Za-z-]/) return 1
    rest = substr(rest, p + length(id))
  }
  return 0
}

BEGIN {
  if (load(before, "b") < 0) { print "適用前の台帳を読めません" > "/dev/stderr"; exit 2 }
  if (load(after, "a") < 0) { print "適用後の台帳を読めません" > "/dev/stderr"; exit 2 }
  if (NE["b"] + 0 == 0) { print "適用前の台帳にエントリ見出し（### OBS-NNN:）を 1 件も認識できません" > "/dev/stderr"; exit 2 }
  if (DUP["b"] != "") { printf "適用前の台帳に同じ ID の見出しが複数あります:%s\n", DUP["b"] > "/dev/stderr"; exit 2 }
  nviol = 0
  if (DUP["a"] != "") ng("", "適用後の台帳に同じ ID の見出しが複数ある:" DUP["a"])

  # ── A / B: 適用前の行が順序どおり残っているか。足された行はどれか ───────────
  j = 1; lost = 0
  for (k = 1; k <= NL["b"]; k++) {
    while (j <= NL["a"] && N["a", j] != N["b", k]) { INS[j] = 1; j++ }
    if (j > NL["a"]) {
      if (index(N["b", k], "\002meta ") == 1) ng(E["b", k], "適用前の " k " 行目のメタ行が適用後に見つからない（行の削除・Kind の書き換え・セルの書き足し・並べ替えのいずれか）: " substr(L["b", k], 1, 120))
      else ng(E["b", k], "適用前の " k " 行目が適用後に見つからない（削除・書き換え・並べ替えのいずれか）: " substr(L["b", k], 1, 120))
      lost = 1
      break
    }
    j++
  }
  if (!lost) for (; j <= NL["a"]; j++) INS[j] = 1
  if (lost) {
    printf "CHECK entries=%d violations=%d（行の対応が取れないため、エントリごとの照合は行っていない）\n", NE["b"], nviol
    exit 1
  }
  for (j = 1; j <= NL["a"]; j++) {
    if (!(j in INS)) continue
    line = L["a", j]
    if (E["a", j] == "") { ng("", "エントリの外に行が足されている（" j " 行目）: " substr(line, 1, 120)); continue }
    if (line !~ /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]: 状態移行（再発ではない）/) {
      ng(E["a", j], "足された行が状態移行の観測メモではない（" j " 行目）: " substr(line, 1, 120))
      continue
    }
    NOTE[E["a", j]] = NOTE[E["a", j]] "\n" line
    nnote[E["a", j]]++
  }
  if (NE["a"] != NE["b"]) ng("", "エントリ数が変わっている（適用前 " NE["b"] " / 適用後 " NE["a"] "）")

  # ── 統合の対応（統合元 → 統合先）を適用後の Issue 列から組み立てる ──────────
  for (x = 1; x <= NE["b"]; x++) {
    id = ORDER["b", x]
    bs = M["b", id, "Status"]; as = M["a", id, "Status"]
    bi = M["b", id, "Issue"]; ai = M["a", id, "Issue"]
    if (as == "archived" && bs != "archived" && ai != bi) {
      prefix = "doc:" ledger_rel "#obs-"
      if (index(ai, prefix) == 1) {
        tgt = "OBS-" toupper(substr(ai, length(prefix) + 1))
        MERGE_TO[id] = tgt
        SRC[tgt] = SRC[tgt] " " id
      } else {
        MERGE_BAD[id] = 1
      }
    }
  }

  # ── C〜F: エントリごとの照合 ─────────────────────────────────────────────
  for (x = 1; x <= NE["b"]; x++) {
    id = ORDER["b", x]
    if (!(("a", id) in SEEN)) { ng(id, "適用後にエントリが無い"); continue }
    bs = M["b", id, "Status"]; as = M["a", id, "Status"]
    bi = M["b", id, "Issue"]; ai = M["a", id, "Issue"]
    bc = M["b", id, "Count"]; ac = M["a", id, "Count"]
    bf = M["b", id, "First"]; af = M["a", id, "First"]
    bl = M["b", id, "Last"]; al = M["a", id, "Last"]
    # 適用前を先に見る（元からの書式不備を、適用の違反として報告しない）
    if (unread(bs) || unread(bi) || unread(bc) || unread(bf) || unread(bl)) { ng(id, "適用前のメタ行（Count / First / Last / Status / Issue）を読めない（適用の違反ではなく元からの書式不備。先に直す）"); continue }
    if (unread(as) || unread(ai) || unread(ac) || unread(af) || unread(al)) { ng(id, "適用後のメタ行（Count / First / Last / Status / Issue）を読めない"); continue }
    if (ac !~ /^[1-9][0-9]*$/) { ng(id, "Count が 1 以上の整数ではない（" ac "）" (ac == bc ? "。適用の違反ではなく元からの書式不備。先に直す" : "")); continue }
    moved = (as != bs || ai != bi)
    touched = (moved || ac != bc || af != bf || al != bl)
    if (touched) nchanged++

    if (as != bs) {
      if (bs != "active") ng(id, "整理が扱う移行は active からだけ（" bs " → " as "）")
      else if (as != "promoted" && as != "mitigated" && as != "archived") ng(id, "移行先の Status が値域外（" as "）")
      else if (bi != "なし") ng(id, "Issue 列が埋まった active は整理の対象外（既存の参照 " bi " を上書きしない。/retrospective の状態移行で直す）")
    } else if (ai != bi) {
      ng(id, "Status が " bs " のまま Issue 列だけが変わっている（" bi " → " ai "）")
    }
    if (moved && nnote[id] + 0 == 0) ng(id, "状態・Issue 列が変わったのに、状態移行の観測メモが足されていない")
    if (!touched && nnote[id] + 0 > 0) ng(id, "状態移行の観測メモを足したのに、メタ行が何も変わっていない（適用が途中で止まっている）")

    if (as != bs && bs == "active") {
      if (as == "promoted") {
        npromoted++
        if (!has_issue_ref(ai)) ng(id, "promoted の Issue 列に owner/repo#N が無い（" ai "）")
      } else if (as == "mitigated") {
        nmitigated++
        if (M["b", id, "Kind"] != "keep") ng(id, "整理が mitigated にするのは Kind が keep のエントリだけ（" M["b", id, "Kind"] "。problem の見送りは /retrospective が書き戻す）")
        if (!has_location(ai)) ng(id, "mitigated の Issue 列に対策の所在（owner/repo#N / skill: / doc:）が無い（" ai "）")
        if (index(ai, "doc:" ledger_rel "#obs-") > 0) ng(id, "mitigated の所在に台帳自身のエントリを書いている（統合は archived で表す）")
      } else if (as == "archived") {
        if (id in MERGE_BAD) ng(id, "archived で Issue 列を変えられるのは統合元だけ（値は doc:" ledger_rel "#obs-nnn）: " ai)
        else if (id in MERGE_TO) {
          nmerged++
          tgt = MERGE_TO[id]
          if (!(("a", tgt) in SEEN)) ng(id, "統合先 " tgt " が台帳に無い")
          else if (tgt == id) ng(id, "統合先が自分自身")
          else if (M["a", tgt, "Status"] == "archived") ng(id, "統合先 " tgt " が archived（統合先は残る側。連鎖させない）")
          else if (M["b", tgt, "Kind"] != M["b", id, "Kind"]) ng(id, "統合元と統合先 " tgt " の Kind が違う（" M["b", id, "Kind"] " / " M["b", tgt, "Kind"] "。統合は同じ Kind 同士だけ）")
          else if (!names(NOTE[tgt], id) || index(NOTE[tgt], "統合") == 0) ng(id, "統合先 " tgt " に、この統合元を名指す状態移行の観測メモが無い")
        } else nstale++
      }
    }

    # F. Count / First / Last
    if (id in SRC) {
      m = split(substr(SRC[id], 2), ss, " ")
      sum = bc + 0; mn = bf; mx = bl
      for (y = 1; y <= m; y++) {
        s = ss[y]
        sum += M["b", s, "Count"] + 0
        if (M["b", s, "First"] < mn) mn = M["b", s, "First"]
        if (M["b", s, "Last"] > mx) mx = M["b", s, "Last"]
      }
      if (ac + 0 != sum) ng(id, "統合先の Count が合算と一致しない（期待 " sum " / 実際 " ac "。統合元:" SRC[id] "）")
      if (af != mn) ng(id, "統合先の First が最小と一致しない（期待 " mn " / 実際 " af "）")
      if (al != mx) ng(id, "統合先の Last が最大と一致しない（期待 " mx " / 実際 " al "）")
    } else {
      if (ac != bc) ng(id, "Count が変わっている（" bc " → " ac "）。変えてよいのは統合先だけ")
      if (af != bf) ng(id, "First が変わっている（" bf " → " af "）。変えてよいのは統合先だけ")
      if (al != bl) ng(id, "Last が変わっている（" bl " → " al "）。変えてよいのは統合先だけ")
    }
  }

  # ── E（過去の統合）: 既存の統合元が指す先が、今回の適用で archived になっていないか ──
  # 今回 archived にしたエントリの統合先は上で見た。ここは適用前から archived の統合元を見る
  # （過去の統合先を今回の統合元にすると、001 → 002 → 003 の連鎖が上の照合を通る）。
  for (x = 1; x <= NE["b"]; x++) {
    id = ORDER["b", x]
    if (M["b", id, "Status"] != "archived") continue
    ai = M["a", id, "Issue"]
    prefix = "doc:" ledger_rel "#obs-"
    if (index(ai, prefix) != 1) continue
    tgt = "OBS-" toupper(substr(ai, length(prefix) + 1))
    if (("a", tgt) in SEEN && M["a", tgt, "Status"] == "archived" && M["b", tgt, "Status"] != "archived") ng(tgt, "既存の統合元 " id " が指す統合先が archived になった（連鎖。過去の統合先は統合元にしない）")
  }

  # ── 適用後に昇格閾値へ到達している未リンクの active（昇格判定へ渡す）────────
  for (x = 1; x <= NE["a"]; x++) {
    id = ORDER["a", x]
    if (M["a", id, "Status"] == "active" && M["a", id, "Issue"] == "なし" && M["a", id, "Count"] ~ /^[1-9][0-9]*$/ && M["a", id, "Count"] + 0 >= threshold) {
      nreach++
      printf "THRESHOLD %s Count=%s（未リンクの active。/retrospective の昇格判定へ渡す）\n", id, M["a", id, "Count"]
    }
  }

  printf "CHECK entries=%d changed=%d promoted=%d mitigated=%d archived_stale=%d merged=%d threshold_unlinked=%d violations=%d\n", NE["b"], nchanged + 0, npromoted + 0, nmitigated + 0, nstale + 0, nmerged + 0, nreach + 0, nviol
  exit (nviol > 0 ? 1 : 0)
}
