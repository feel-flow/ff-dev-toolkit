# observation-refine-report.awk — 観測台帳の定期整理の候補を算出する（dry-run。read-only）。
#
# scripts/observation-refine.sh report が LC_ALL=C で呼ぶ。単体では実行しない。
# 入力（引数のファイル）は knowledge-lookup.sh --ledger-dump の TSV 1 本:
#   id / status / kind / count / first / last / issue / location / title / text（text の行区切りは 0x1e）
#   末尾の `SUMMARY ` 行は読み飛ばす。
# -v で受ける値:
#   today          基準日（YYYY-MM-DD）
#   stale_days     stale と見なす日数（Last からこの日数を超えたもの）
#   stale_max      stale の対象にする Count の上限
#   threshold      昇格閾値（/retrospective の SKILL.md から入口が導出して渡す）
#   top            紐付け候補として 1 エントリに出す Issue の上限
#   min_link       紐付け候補の最小スコア
#   min_merge      統合候補の最小スコア
#   max_pairs      統合候補として出す組の上限
#   manifest       Issue 一覧の目録（1 行 = repo<TAB>状態<TAB>ファイルまたは理由。状態は ok / unverified）
#   ledger         台帳の表示名（相対パス）
#
# 類似度は「候補を絞る信号」であって判定ではない。同じ主張か・同じ事象の Issue かは、出力を
# 読んだホストが本文まで開いて判定する（スキルの手順が正本）。信号の作り:
#   - 語は ASCII の連続（英数字と _ . / -。3 文字以上）と、非 ASCII 文字の 2 文字連接（bigram）。
#     ひらがな同士の連接と、記号・句読点をまたぐ連接は語にしない
#   - 文書の 2 割を超える文書に現れる語は捨てる（どの文書にも在る語は区別に効かず、転置索引の
#     走査だけを重くする）
#   - 重みは idf = log((N + 1) / df)。N + 1 にするのは、全文書に現れる語の重みを 0 にしないため
#     （文書が 2〜3 件の台帳では共有語がすべて df = N になり、重み 0 のノルムで割ることになる）
#   - 共有語が 3 語に満たない組・数字だけの語は捨てる
#   - (2) 統合のスコアは、共有語の idf² の和を両エントリのノルムで割った余弦。Kind が同じ
#     エントリ同士だけを組にし、archived と「active なのに Issue 列が埋まっている」エントリは入れない
#   - (1) 紐付けのスコアは、共有語の idf² の和を Issue タイトル側のノルムだけで割った包含率
#     （タイトルの情報のうち、どれだけがエントリの主張に含まれるか）。(2) とは尺度が違う
# LC_ALL=C で動かす理由: 文字を UTF-8 の先頭バイトと継続バイトの並びとして切り出すので、
# バイト単位の正規表現が要る。UTF-8 ロケールの awk は実装によって tolower や substr が
# 文字単位になり、切り出しが実装依存になる。

function daynum(d,   y, m, dd) {
  if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return -1
  y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
  if (m < 1 || m > 12 || dd < 1) return -1
  # 暦に無い日（2 月 31 日など）は読めない日付として返す。通算日へ換算すると別の日にずれるため
  if (dd > ((m == 2) ? ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28) : ((m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31))) return -1
  if (m <= 2) { y--; m += 12 }
  return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + dd - 1
}

# 文字種: h = ひらがな / s = 記号・句読点（連接を切る）/ c = それ以外の非 ASCII 文字
function chclass(ch) {
  if (ch ~ /^\343\201[\200-\277]$/ || ch ~ /^\343\202[\200-\237]$/) return "h"
  if (ch ~ /^\342/ || ch ~ /^\343\200/ || ch ~ /^\357\274/ || ch ~ /^\357\275[\200-\240]$/) return "s"
  return "c"
}

# s を語へ分け、集合 TOK（グローバル）へ入れる。戻り値 = 語の種類数。
function tokenize(s,   n, tok, ch, prev, pc, cc) {
  for (tok in TOK) delete TOK[tok]
  s = tolower(s); n = 0; prev = ""; pc = ""
  while (s != "") {
    if (match(s, /^[a-z0-9_.\/-]+/)) {
      tok = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
      gsub(/^[.\/_-]+|[.\/_-]+$/, "", tok)
      if (length(tok) >= 3 && tok !~ /^[0-9.-]+$/ && !(tok in TOK)) { TOK[tok] = 1; n++ }
      prev = ""; continue
    }
    if (match(s, /^[\300-\367][\200-\277]+/)) {
      ch = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
      cc = chclass(ch)
      if (cc == "s") { prev = ""; continue }
      if (prev != "" && !(pc == "h" && cc == "h")) {
        tok = prev ch
        if (!(tok in TOK)) { TOK[tok] = 1; n++ }
      }
      prev = ch; pc = cc; continue
    }
    s = substr(s, 2); prev = ""
  }
  return n
}

# エントリのブロックから、照合に使う文（見出しのタイトルと本文段落）だけを取り出す。
# メタ行（| で始まる）と観測メモ（- YYYY-MM-DD: で始まる）は外す — メモはその回の PR 番号や
# 経緯を持ち、主張の同一性ではなく作業した回の近さを拾ってしまう。
function claim_text(title, text,   n, lines, i, out) {
  out = title
  n = split(text, lines, "\036")
  for (i = 2; i <= n; i++) {
    if (lines[i] ~ /^[ \t]*\|/) continue
    if (lines[i] ~ /^[ \t]*- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]:/) continue
    if (lines[i] ~ /^[ \t]*$/) continue
    out = out " " lines[i]
  }
  return out
}

function short(s, max) {
  # バイト長で切ると文字の途中で切れるので、UTF-8 の文字境界まで戻す
  if (length(s) <= max) return s
  s = substr(s, 1, max)
  while (s != "" && s ~ /[\200-\277]$/) s = substr(s, 1, length(s) - 1)
  if (s ~ /[\300-\367]$/) s = substr(s, 1, length(s) - 1)
  return s "…"
}

BEGIN {
  FS = "\t"
  today_n = daynum(today)
  if (today_n < 0) { printf "基準日を読めません: %s\n", today > "/dev/stderr"; fatal = 1; exit 2 }
  nrepo = 0; nissue = 0
  if (manifest != "") {
    # getline の -1（読めない）を EOF と同じに扱うと、読めなかった一覧が「0 件の ok」に化ける
    while ((grc = (getline row < manifest)) > 0) {
      split(row, p, "\t")
      nrepo++; repo_name[nrepo] = p[1]; repo_state[nrepo] = p[2]; repo_note[nrepo] = p[3]
      if (p[2] != "ok") continue
      while ((irc = (getline irow < p[3])) > 0) {
        if (irow == "") continue
        nf = split(irow, f, "\t")
        nissue++
        is_repo[nissue] = p[1]; is_num[nissue] = f[1]; is_state[nissue] = tolower(f[2])
        t = f[3]; for (k = 4; k <= nf; k++) t = t " " f[k]
        is_title[nissue] = t
        repo_rows[nrepo]++
        if (is_state[nissue] == "open") repo_open[nrepo]++; else repo_closed[nrepo]++
      }
      if (irc < 0 || repo_rows[nrepo] + 0 == 0) { printf "Issue 一覧を読めません: %s\n", p[1] > "/dev/stderr"; fatal = 1; exit 2 }
      close(p[3])
    }
    if (grc < 0) { print "Issue 一覧の目録を読めません" > "/dev/stderr"; fatal = 1; exit 2 }
    close(manifest)
  }
}

/^SUMMARY / { next }
NF < 10 { malformed++; next }
{
  n++
  id[n] = $1; st[n] = $2; kind[n] = $3; cnt[n] = $4; first[n] = $5; last[n] = $6; issue[n] = $7
  loc[n] = $8; title[n] = $9; text[n] = $10
  if ($1 in byid) dup = dup " " $1
  byid[$1] = n
  status_n[$2 == "" ? "(空)" : $2]++
  # check が「メタ行を読めない」として拒否する形は、ここでも候補から外す（承認と適用の後に
  # 初めて止まる形にしない）
  ok[n] = 1
  if (st[n] !~ /^(active|promoted|mitigated|archived)$/) { ok[n] = 0; why[n] = "Status を読めない（" st[n] "）" }
  else if (cnt[n] !~ /^[1-9][0-9]*$/) { ok[n] = 0; why[n] = "Count を読めない（" cnt[n] "）" }
  else if (daynum(first[n]) < 0) { ok[n] = 0; why[n] = "First を読めない（" first[n] "）" }
  else if (daynum(last[n]) < 0) { ok[n] = 0; why[n] = "Last を読めない（" last[n] "）" }
  else if (kind[n] !~ /^(problem|keep)$/) { ok[n] = 0; why[n] = "Kind を読めない（" kind[n] "）" }
  else if (issue[n] == "") { ok[n] = 0; why[n] = "Issue 列が空（未リンクは「なし」と書く）" }
  if (!ok[n]) invalid++
  unlinked[n] = (issue[n] == "なし")
}

END {
  if (fatal) exit 2
  if (malformed > 0) { printf "台帳の出力に列の足りない行が %d 行あります（--ledger-dump の書式変更の可能性）\n", malformed > "/dev/stderr"; exit 2 }
  if (dup != "") { printf "台帳に同じ ID の見出しが複数あります（先に直す。check も同じ台帳を照合できません）:%s\n", dup > "/dev/stderr"; exit 2 }
  if (n == 0) {
    printf "== 観測台帳の定期整理 dry-run（%s） ==\n", ledger
    print "（整理対象なし: 台帳はあるがエントリが無い）"
    printf "SUMMARY entries=0 active=0 link_population=0 link_candidates=0 merge_pairs=0 merge_reach_threshold=0 stale=0 keep_population=0 threshold_unlinked=0 meta_invalid=0 active_linked=0 issues=none today=%s stale_days=%s stale_max_count=%s threshold=%s\n", today, stale_days, stale_max, threshold
    exit 0
  }
  if (invalid == n) { printf "全 %d 件のメタ行（Status / Count / First / Last / Kind / Issue）を読めません（書式変更の可能性）\n", n > "/dev/stderr"; exit 2 }

  # 過去の整理で統合先になったエントリ（archived の統合元が Issue 列で指している先）。統合元に
  # すると既存の統合元が archived を指す連鎖になるので、組の行に印を付けて残す側だと分かるようにする
  ptr = "doc:" ledger "#obs-"
  for (i = 1; i <= n; i++) if (st[i] == "archived" && index(issue[i], ptr) == 1) wastarget["OBS-" toupper(substr(issue[i], length(ptr) + 1))] = 1

  # ── 母集団 ────────────────────────────────────────────────────────────────
  for (i = 1; i <= n; i++) {
    if (!ok[i]) continue
    if (st[i] == "active") {
      n_active++
      if (unlinked[i]) {
        linkpop[++n_linkpop] = i
        if (cnt[i] + 0 >= threshold) reached[++n_reached] = i
        if (kind[i] == "keep" && cnt[i] + 0 < threshold) keeppop[++n_keep] = i
        age = today_n - daynum(last[i])
        if (cnt[i] + 0 <= stale_max && age > stale_days) { stale[++n_stale] = i; stale_age[i] = age }
      } else {
        # active なのに Issue 列が埋まっている。どの操作の母集団にも入らないので、黙って落とさず名指しする
        odd[++n_odd] = i; isodd[i] = 1
      }
    }
  }

  # ── 語の集合と idf（統合: 非 archived のエントリ同士）──────────────────────
  # Issue 列の埋まった active は統合にも入れない（統合元にすると、既存の Issue 参照が
  # 統合先の anchor で上書きされる）。
  ndoc = 0
  for (i = 1; i <= n; i++) {
    if (!ok[i] || st[i] == "archived" || (i in isodd)) continue
    ndoc++
    tokenize(claim_text(title[i], text[i]))
    for (t in TOK) { edoc[i, t] = 1; edf[t]++; etoks[i] = etoks[i] "\037" t }
  }
  cut = ndoc * 0.2; if (cut < 3) cut = 3
  for (i = 1; i <= n; i++) {
    if (etoks[i] == "") continue
    m = split(substr(etoks[i], 2), tk, "\037")
    for (k = 1; k <= m; k++) {
      t = tk[k]
      if (edf[t] > cut || edf[t] < 2) continue
      w = log((ndoc + 1) / edf[t])
      enorm[i] += w * w
      epost[t] = epost[t] " " i
    }
    # df = 1 の語は共有されないが、ノルムには入れる（固有の語が多いエントリほど一致の比率が下がる）
    for (k = 1; k <= m; k++) { t = tk[k]; if (edf[t] == 1) { w = log(ndoc + 1); enorm[i] += w * w } }
  }
  for (t in epost) {
    m = split(substr(epost[t], 2), pl, " ")
    if (m < 2) continue
    w = log((ndoc + 1) / edf[t]); w2 = w * w
    for (a = 1; a < m; a++) for (b = a + 1; b <= m; b++) {
      i = pl[a] + 0; j = pl[b] + 0
      if (st[i] != "active" && st[j] != "active") continue
      if (kind[i] != kind[j]) continue
      pacc[i, j] += w2; pshared[i, j]++
    }
  }
  n_pairs_all = 0; merge_reach = 0
  for (key in pacc) {
    split(key, ij, SUBSEP); i = ij[1] + 0; j = ij[2] + 0
    if (pshared[key] < 3) continue
    if (enorm[i] <= 0 || enorm[j] <= 0) continue
    sc = pacc[key] / sqrt(enorm[i] * enorm[j])
    if (sc < min_merge) continue
    n_pairs_all++
    pair_i[n_pairs_all] = i; pair_j[n_pairs_all] = j; pair_sc[n_pairs_all] = sc
    # 件数は表示の上限（max_pairs）と無関係に全数で数える
    if (st[i] == "active" && st[j] == "active" && cnt[i] + cnt[j] >= threshold) merge_reach++
  }
  # スコア降順（同点は ID の並び順）。挿入ソート — 組の数は閾値で小さく絞られている
  for (a = 2; a <= n_pairs_all; a++) {
    ti = pair_i[a]; tj = pair_j[a]; ts = pair_sc[a]
    for (b = a - 1; b >= 1 && (pair_sc[b] < ts || (pair_sc[b] == ts && (pair_i[b] > ti || (pair_i[b] == ti && pair_j[b] > tj)))); b--) {
      pair_i[b + 1] = pair_i[b]; pair_j[b + 1] = pair_j[b]; pair_sc[b + 1] = pair_sc[b]
    }
    pair_i[b + 1] = ti; pair_j[b + 1] = tj; pair_sc[b + 1] = ts
  }

  # ── 紐付け: 母集団（active・Issue なし）× 渡された Issue のタイトル ──────────
  # none = 一覧なし / ok = 全部照合できた / partial = 一部が未確認 / unverified = 全部が未確認
  issues_state = "none"
  if (nrepo > 0) {
    n_repo_ok = 0
    for (r = 1; r <= nrepo; r++) if (repo_state[r] == "ok") n_repo_ok++
    issues_state = (n_repo_ok == nrepo) ? "ok" : ((n_repo_ok == 0) ? "unverified" : "partial")
  }
  n_link = 0
  if (nissue > 0 && n_linkpop > 0) {
    nd = nissue + n_linkpop
    for (q = 1; q <= nissue; q++) {
      tokenize(is_title[q])
      for (t in TOK) { idf_df[t]++; itoks[q] = itoks[q] "\037" t }
    }
    for (a = 1; a <= n_linkpop; a++) {
      i = linkpop[a]
      tokenize(claim_text(title[i], text[i]))
      for (t in TOK) { idf_df[t]++; qtoks[i] = qtoks[i] "\037" t }
    }
    icut = nd * 0.2; if (icut < 3) icut = 3
    for (q = 1; q <= nissue; q++) {
      if (itoks[q] == "") continue
      m = split(substr(itoks[q], 2), tk, "\037")
      for (k = 1; k <= m; k++) {
        t = tk[k]; if (idf_df[t] > icut) continue
        w = log((nd + 1) / idf_df[t]); inorm[q] += w * w
        if (idf_df[t] >= 2) ipost[t] = ipost[t] " " q
      }
    }
    for (a = 1; a <= n_linkpop; a++) {
      i = linkpop[a]
      if (qtoks[i] == "") continue
      for (key in lacc) delete lacc[key]
      for (key in lshared) delete lshared[key]
      m = split(substr(qtoks[i], 2), tk, "\037")
      for (k = 1; k <= m; k++) {
        t = tk[k]; if (!(t in ipost)) continue
        w = log((nd + 1) / idf_df[t]); w2 = w * w
        pm = split(substr(ipost[t], 2), pl, " ")
        for (b = 1; b <= pm; b++) { lacc[pl[b]] += w2; lshared[pl[b]]++ }
      }
      # Issue タイトルの情報のうち、どれだけがエントリの主張に含まれるか（タイトルは短いので
      # エントリ側のノルムでは割らない。長い本文を持つエントリが不利にならないようにする）
      nb = 0
      for (q in lacc) {
        if (lshared[q] < 3 || inorm[q] <= 0) continue
        sc = lacc[q] / inorm[q]
        if (sc < min_link) continue
        nb++; bq[nb] = q + 0; bs[nb] = sc
      }
      if (nb == 0) continue
      for (x = 2; x <= nb; x++) {
        tq = bq[x]; ts = bs[x]
        for (y = x - 1; y >= 1 && (bs[y] < ts || (bs[y] == ts && bq[y] > tq)); y--) { bq[y + 1] = bq[y]; bs[y + 1] = bs[y] }
        bq[y + 1] = tq; bs[y + 1] = ts
      }
      n_link++; link_entry[n_link] = i; haslink[i] = 1
      lim = (nb < top) ? nb : top
      for (x = 1; x <= lim; x++) link_hit[n_link] = link_hit[n_link] "\037" bq[x] "\036" sprintf("%.2f", bs[x])
      link_more[n_link] = nb - lim
    }
  }

  # ── 出力 ──────────────────────────────────────────────────────────────────
  printf "== 観測台帳の定期整理 dry-run（%s） ==\n", ledger
  printf "対象: %d 件（active %d / promoted %d / mitigated %d / archived %d", n, status_n["active"] + 0, status_n["promoted"] + 0, status_n["mitigated"] + 0, status_n["archived"] + 0
  other = n - (status_n["active"] + status_n["promoted"] + status_n["mitigated"] + status_n["archived"])
  if (other > 0) printf " / その他 %d", other
  printf "）\n"
  printf "基準日: %s / stale = Last から %d 日を超え、かつ Count が %d 以下 / 昇格閾値 = 累計 %d 回\n", today, stale_days, stale_max, threshold
  print "この出力は候補と根拠の提示で、何も書き換えていない。適用は承認の後。"

  if (invalid > 0) {
    printf "\n-- メタ行を読めないエントリ: %d 件（候補から外した。先に書式を直す）--\n", invalid
    for (i = 1; i <= n; i++) if (!ok[i]) printf "%s  %s\n      %s  (%s)\n", id[i], short(title[i], 300), why[i], loc[i]
  }

  if (n_odd > 0) {
    printf "\n-- 状態と Issue 列が食い違うエントリ: %d 件（active なのに Issue 列がある。どの母集団にも入れていない。/retrospective の状態移行で Status を直す）--\n", n_odd
    for (a = 1; a <= n_odd; a++) {
      i = odd[a]
      printf "%s  %s\n      Kind=%s Count=%s Last=%s Issue=%s  (%s)\n", id[i], short(title[i], 300), kind[i], cnt[i], last[i], issue[i], loc[i]
    }
  }

  printf "\n-- (1) 既存 Issue への紐付け: 母集団 %d 件（active・Issue なし）/ 類似の候補あり %d 件 --\n", n_linkpop, n_link
  if (nrepo == 0) {
    print "照合: 未確認（Issue 一覧が渡されていない。--issues owner/repo=<一覧ファイル> を付けて取り直す）"
  } else {
    for (r = 1; r <= nrepo; r++) {
      if (repo_state[r] == "ok") printf "照合先: %s = %d 件（open %d / closed %d）\n", repo_name[r], repo_rows[r] + 0, repo_open[r] + 0, repo_closed[r] + 0
      else printf "照合先: %s = 未確認（%s）\n", repo_name[r], repo_note[r]
    }
  }
  for (a = 1; a <= n_link; a++) {
    i = link_entry[a]
    printf "%s  %s\n      Kind=%s Count=%s Last=%s  (%s)\n", id[i], short(title[i], 300), kind[i], cnt[i], last[i], loc[i]
    m = split(substr(link_hit[a], 2), hh, "\037")
    for (x = 1; x <= m; x++) {
      split(hh[x], hv, "\036"); q = hv[1] + 0
      printf "      類似 %s  %s#%s(%s)  %s\n", hv[2], is_repo[q], is_num[q], is_state[q], short(is_title[q], 300)
    }
    if (link_more[a] > 0) printf "      ほか %d 件（--top で増やせる）\n", link_more[a]
  }
  if (nissue > 0 && n_linkpop > n_link) {
    printf "類似の候補なし: %d 件（機械の信号に出ないだけで、対応 Issue が無いことの確認ではない）\n", n_linkpop - n_link
    line = "     "
    for (a = 1; a <= n_linkpop; a++) {
      i = linkpop[a]
      if (i in haslink) continue
      if (length(line) + length(id[i]) + 1 > 100) { print line; line = "     " }
      line = line " " id[i]
    }
    if (line != "     ") print line
  }

  shown = (n_pairs_all < max_pairs) ? n_pairs_all : max_pairs
  printf "\n-- (2) 統合（同じ主張の疑い）: %d 組", n_pairs_all
  if (shown < n_pairs_all) printf "（上位 %d 組を表示。--max-pairs で増やせる）", shown
  printf " --\n"
  for (a = 1; a <= shown; a++) {
    i = pair_i[a]; j = pair_j[a]; sum = cnt[i] + cnt[j]
    note = ""
    if (st[i] == "active" && st[j] == "active" && sum >= threshold) note = "（採れば合算で昇格閾値に到達）"
    printf "%s × %s  類似 %.2f  合算 Count=%d%s\n", id[i], id[j], pair_sc[a], sum, note
    printf "      %s [%s %s Count=%s Last=%s%s] %s\n", id[i], st[i], kind[i], cnt[i], last[i], ((id[i] in wastarget) ? " 過去の統合先" : ""), short(title[i], 300)
    printf "      %s [%s %s Count=%s Last=%s%s] %s\n", id[j], st[j], kind[j], cnt[j], last[j], ((id[j] in wastarget) ? " 過去の統合先" : ""), short(title[j], 300)
  }

  printf "\n-- (3) stale の archive: %d 件 --\n", n_stale
  for (a = 1; a <= n_stale; a++) {
    i = stale[a]
    printf "%s  %s\n      Kind=%s Count=%s Last=%s（%d 日前）  (%s)\n", id[i], short(title[i], 300), kind[i], cnt[i], last[i], stale_age[i], loc[i]
  }

  printf "\n-- (4) Keep の定着判定: 母集団 %d 件（active・keep・Issue なし・閾値未達）--\n", n_keep
  for (a = 1; a <= n_keep; a++) {
    i = keeppop[a]
    printf "%s  %s\n      Count=%s Last=%s  (%s)\n", id[i], short(title[i], 300), cnt[i], last[i], loc[i]
  }

  printf "\n-- (5) 昇格閾値に到達済みで未リンク: %d 件（整理ではなく /retrospective の昇格判定へ渡す）--\n", n_reached
  for (a = 1; a <= n_reached; a++) {
    i = reached[a]
    printf "%s  %s\n      Kind=%s Count=%s Last=%s  (%s)\n", id[i], short(title[i], 300), kind[i], cnt[i], last[i], loc[i]
  }

  printf "\nSUMMARY entries=%d active=%d link_population=%d link_candidates=%d merge_pairs=%d merge_reach_threshold=%d stale=%d keep_population=%d threshold_unlinked=%d meta_invalid=%d active_linked=%d issues=%s today=%s stale_days=%s stale_max_count=%s threshold=%s\n", n, n_active, n_linkpop, n_link, n_pairs_all, merge_reach, n_stale, n_keep, n_reached, invalid + 0, n_odd + 0, issues_state, today, stale_days, stale_max, threshold
}
