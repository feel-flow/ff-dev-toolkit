#!/usr/bin/env bash
# Google Antigravity 向けプラグイン・MCP 展開（scripts/antigravity/sync-plugins.sh）の契約を固定する。
#
# 一時ディレクトリへ展開し、単一プラグイン展開・skills symlink 維持（SKILL.md 非複製）・
# plugin.json メタデータ選別・mcp_config.json 名前空間化と ${CLAUDE_PLUGIN_ROOT} 展開・
# --project-root 付与・--check 判定・marketplace 一括展開と外部ソーススキップ・
# 異常系 fail-closed・$ と空白を含むパス・node による MCP stdio 実応答を検証する。
#
# run-all-required: no — jq 不在では検証本体を実行できないため suite 全体を skip する
# 空振り検出: 0件同期時に終了0を返すように sync-plugins.sh を緩めると、対象不在・空 plugins 配列・外部のみの marketplace を与えた (6) が赤になる（2026-11-13 実測）。
# 変異検出: sync-plugins.sh の ${CLAUDE_PLUGIN_ROOT} 展開を外すと (3)(8)(9) が、author.email 除外を外すと (2) が、--check を常に 0 終了にすると (5) が赤になる（2026-11-13 実測）。
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
PLUGIN_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"
SYNC_SH="$PLUGIN_ROOT/scripts/antigravity/sync-plugins.sh"

[ -f "$SYNC_SH" ] || { echo "✗ sync-plugins.sh が見つかりません: $SYNC_SH" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が無いため antigravity-plugins-sync は未検査"
  exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1" >&2; }

TMP_WORK="$(mktemp -d)"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP_WORK"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ antigravity-plugins-sync: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

OUT_SINGLE="$TMP_WORK/out-single"

# (1) 単一プラグイン展開と skills symlink（SKILL.md コピーを作らない）
if bash "$SYNC_SH" --out-dir "$OUT_SINGLE" >/dev/null 2>&1 \
  && [ -f "$OUT_SINGLE/ff-dev-toolkit/plugin.json" ] \
  && [ -f "$OUT_SINGLE/ff-dev-toolkit/mcp_config.json" ] \
  && [ -L "$OUT_SINGLE/ff-dev-toolkit/skills" ] \
  && [ "$(readlink "$OUT_SINGLE/ff-dev-toolkit/skills")" = "$PLUGIN_ROOT/skills" ] \
  && [ -z "$(find "$OUT_SINGLE/ff-dev-toolkit" -maxdepth 2 -type f -name 'SKILL.md')" ]; then
  ok "(1) 単一プラグイン展開・skills symlink・SKILL.md 非複製"
else
  bad "(1) 単一プラグイン展開または skills symlink が不整合"
fi

# (2) plugin.json は Antigravity 対応メタデータのみ保持し、email / keywords / license を除外
pj="$OUT_SINGLE/ff-dev-toolkit/plugin.json"
if jq -e '
  .name == "ff-dev-toolkit"
  and (.version | length > 0)
  and (.description | length > 0)
  and (.author.name == "FeelFlow Inc.")
  and (.author | has("email") | not)
  and (has("license") | not)
  and (has("keywords") | not)
  and (has("$schema") | not)
' "$pj" >/dev/null 2>&1; then
  ok "(2) plugin.json は対応キーのみを保持し email/license/keywords を除外"
else
  bad "(2) plugin.json のキー選別が不整合: $(cat "$pj" 2>/dev/null || true)"
fi

# (3) mcp_config.json の名前空間化・${CLAUDE_PLUGIN_ROOT} 実パス展開・未指定時 env 不在
mc="$OUT_SINGLE/ff-dev-toolkit/mcp_config.json"
resolved_entry="$(jq -r '.mcpServers["ff-dev-toolkit-spec-docs"].args[0] // empty' "$mc" 2>/dev/null || true)"
if jq -e --arg exp "$PLUGIN_ROOT/mcp/dist/index.js" '
  (.mcpServers | keys) == ["ff-dev-toolkit-spec-docs"]
  and .mcpServers["ff-dev-toolkit-spec-docs"].command == "node"
  and .mcpServers["ff-dev-toolkit-spec-docs"].args[0] == $exp
  and (.mcpServers["ff-dev-toolkit-spec-docs"].env? == null)
  and (tostring | contains("${CLAUDE_PLUGIN_ROOT}") | not)
' "$mc" >/dev/null 2>&1 && [ -f "$resolved_entry" ]; then
  ok "(3) mcp_config.json が名前空間化・絶対パス展開・未展開プレースホルダーなし"
else
  bad "(3) mcp_config.json が不正: $(cat "$mc" 2>/dev/null || true)"
fi

# (4) --project-root 指定時は spec-docs へ SPEC_DOCS_PROJECT_ROOT が付与される
PROJ_DIR="$TMP_WORK/sample-project"
mkdir -p "$PROJ_DIR/docs"
printf '# Guide\n\nhello\n' > "$PROJ_DIR/docs/README.md"
PROJ_CANON="$(CDPATH='' cd -P -- "$PROJ_DIR" && pwd -P)"
OUT_PROJ="$TMP_WORK/out-proj"
if bash "$SYNC_SH" --project-root "$PROJ_DIR" --out-dir "$OUT_PROJ" >/dev/null 2>&1 \
  && jq -e --arg p "$PROJ_CANON" '
    .mcpServers["ff-dev-toolkit-spec-docs"].env.SPEC_DOCS_PROJECT_ROOT == $p
  ' "$OUT_PROJ/ff-dev-toolkit/mcp_config.json" >/dev/null 2>&1; then
  ok "(4) --project-root で SPEC_DOCS_PROJECT_ROOT が付与される"
else
  bad "(4) --project-root が SPEC_DOCS_PROJECT_ROOT に反映されない"
fi

# (5) --check 判定（最新で 0、各改変で 1、既存ファイルを書き換えない）
check_ok=1
bash "$SYNC_SH" --out-dir "$OUT_SINGLE" --check >/dev/null 2>&1 || check_ok=0
cp "$pj" "$TMP_WORK/pj.bak"
printf '{"name":"tampered"}\n' > "$pj"
if bash "$SYNC_SH" --out-dir "$OUT_SINGLE" --check >/dev/null 2>&1; then
  check_ok=0
fi
[ "$(jq -r .name "$pj")" = "tampered" ] || check_ok=0
mv "$TMP_WORK/pj.bak" "$pj"

cp "$mc" "$TMP_WORK/mc.bak"
rm -f "$mc"
if bash "$SYNC_SH" --out-dir "$OUT_SINGLE" --check >/dev/null 2>&1; then
  check_ok=0
fi
mv "$TMP_WORK/mc.bak" "$mc"

rm -f "$OUT_SINGLE/ff-dev-toolkit/skills"
ln -s "$TMP_WORK" "$OUT_SINGLE/ff-dev-toolkit/skills"
if bash "$SYNC_SH" --out-dir "$OUT_SINGLE" --check >/dev/null 2>&1; then
  check_ok=0
fi
rm -f "$OUT_SINGLE/ff-dev-toolkit/skills"
ln -s "$PLUGIN_ROOT/skills" "$OUT_SINGLE/ff-dev-toolkit/skills"

if [ "$check_ok" -eq 1 ]; then
  ok "(5) --check が最新 0・各不整合 1 を返し非破壊"
else
  bad "(5) --check の判定または非破壊性が不正"
fi

# (6) 合成 marketplace でローカル 2 件展開 + 外部 source skip + --plugin 絞り込み + 残存 mcp_config 掃除
MKT="$TMP_WORK/mkt"
mkdir -p "$MKT/.claude-plugin" \
  "$MKT/plugins/alpha/.claude-plugin" "$MKT/plugins/alpha/skills/hello" "$MKT/plugins/alpha/bin" \
  "$MKT/plugins/beta/.claude-plugin" "$MKT/plugins/beta/skills/world"
printf '{"name":"alpha","version":"1.0.0","description":"a","author":"FeelFlow"}\n' > "$MKT/plugins/alpha/.claude-plugin/plugin.json"
printf '# hi\n' > "$MKT/plugins/alpha/skills/hello/SKILL.md"
printf '#!/usr/bin/env bash\necho ok\n' > "$MKT/plugins/alpha/bin/srv.sh"
printf '{"mcpServers":{"srv":{"command":"bash","args":["${CLAUDE_PLUGIN_ROOT}/bin/srv.sh"]},"alpha-srv":{"command":"bash","args":["${CLAUDE_PLUGIN_ROOT}/bin/srv.sh"]}}}\n' > "$MKT/plugins/alpha/.mcp.json"

printf '{"name":"beta","version":"0.2.0","description":"b"}\n' > "$MKT/plugins/beta/.claude-plugin/plugin.json"
printf '# world\n' > "$MKT/plugins/beta/skills/world/SKILL.md"

cat > "$MKT/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "test-mkt",
  "plugins": [
    {"name": "alpha", "source": "./plugins/alpha"},
    {"name": "ext", "source": {"source": "github", "repo": "feel-flow/ext"}},
    {"name": "beta", "source": "./plugins/beta"}
  ]
}
EOF

OUT_MKT="$TMP_WORK/out-mkt"
mkdir -p "$OUT_MKT/beta"
printf '{"mcpServers":{"stale":{}}}\n' > "$OUT_MKT/beta/mcp_config.json"

mkt_stderr="$TMP_WORK/mkt.stderr"
if bash "$SYNC_SH" --marketplace-root "$MKT" --out-dir "$OUT_MKT" >/dev/null 2>"$mkt_stderr" \
  && jq -e '.mcpServers | has("alpha-srv") and has("alpha-alpha-srv")' "$OUT_MKT/alpha/mcp_config.json" >/dev/null 2>&1 \
  && [ -L "$OUT_MKT/beta/skills" ] \
  && [ ! -e "$OUT_MKT/beta/mcp_config.json" ] \
  && [ ! -e "$OUT_MKT/ext" ] \
  && grep -F '外部ソースのためスキップ: ext' "$mkt_stderr" >/dev/null 2>&1; then
  OUT_FILTER="$TMP_WORK/out-filter"
  mkt_check_err="$TMP_WORK/mkt-check.stderr"
  if bash "$SYNC_SH" --marketplace-root "$MKT" --out-dir "$OUT_MKT" --check >/dev/null 2>&1 \
    && ln -s "$TMP_WORK/nonexistent-mcp" "$OUT_MKT/beta/mcp_config.json" \
    && ! bash "$SYNC_SH" --marketplace-root "$MKT" --plugin beta --out-dir "$OUT_MKT" --check >/dev/null 2>"$mkt_check_err" \
    && ! grep -F '0 件' "$mkt_check_err" >/dev/null 2>&1 \
    && ! grep -F '同期されませんでした' "$mkt_check_err" >/dev/null 2>&1 \
    && rm -f "$OUT_MKT/beta/mcp_config.json" \
    && bash "$SYNC_SH" --marketplace-root "$MKT" --plugin beta --out-dir "$OUT_FILTER" >/dev/null 2>&1 \
    && [ -d "$OUT_FILTER/beta" ] && [ ! -e "$OUT_FILTER/alpha" ]; then
    # 0 件同期（該当なし / 外部のみ指定 / 空 plugins 配列）は非 0
    MKT_EMPTY="$TMP_WORK/mkt-empty"
    mkdir -p "$MKT_EMPTY/.claude-plugin"
    printf '{"name":"empty","plugins":[]}\n' > "$MKT_EMPTY/.claude-plugin/marketplace.json"
    if ! bash "$SYNC_SH" --marketplace-root "$MKT" --plugin ext --out-dir "$OUT_FILTER" >/dev/null 2>&1 \
      && ! bash "$SYNC_SH" --marketplace-root "$MKT" --plugin missing --out-dir "$OUT_FILTER" >/dev/null 2>&1 \
      && ! bash "$SYNC_SH" --marketplace-root "$MKT_EMPTY" --out-dir "$OUT_FILTER" >/dev/null 2>&1; then
      ok "(6) marketplace 一括展開・外部 skip・--plugin 絞り込み・不要 mcp 削除"
    else
      bad "(6) 0 件同期または外部のみ指定が 0 終了した"
    fi
  else
    bad "(6) --plugin 絞り込みが不整合"
  fi
else
  bad "(6) marketplace 展開または不要 mcp_config.json 削除に失敗: $(cat "$mkt_stderr" 2>/dev/null || true)"
fi

# (7) 異常系 fail-closed
fail_closed_ok=1
OUT_ERR="$TMP_WORK/out-err"
# 7a: plugin.json 不在
mkdir -p "$TMP_WORK/no-manifest/skills"
if bash "$SYNC_SH" --plugin-root "$TMP_WORK/no-manifest" --out-dir "$OUT_ERR" >/dev/null 2>&1; then
  fail_closed_ok=0
fi
# 7b: .mcp.json 参照先不在で出力先を作らない
mkdir -p "$TMP_WORK/bad-mcp/.claude-plugin" "$TMP_WORK/bad-mcp/skills"
printf '{"name":"bad-mcp","version":"0.1.0","description":"x"}\n' > "$TMP_WORK/bad-mcp/.claude-plugin/plugin.json"
printf '{"mcpServers":{"spec-docs":{"command":"node","args":["${CLAUDE_PLUGIN_ROOT}/missing/index.js"]}}}\n' > "$TMP_WORK/bad-mcp/.mcp.json"
if bash "$SYNC_SH" --plugin-root "$TMP_WORK/bad-mcp" --out-dir "$OUT_ERR" >/dev/null 2>&1 || [ -e "$OUT_ERR/bad-mcp" ]; then
  fail_closed_ok=0
fi
# 7c: 出力先 skills が通常ディレクトリなら破壊せず中断
mkdir -p "$OUT_ERR/beta/skills"
printf 'keep-me\n' > "$OUT_ERR/beta/skills/user.txt"
if bash "$SYNC_SH" --plugin-root "$MKT/plugins/beta" --out-dir "$OUT_ERR" >/dev/null 2>&1 \
  || [ "$(cat "$OUT_ERR/beta/skills/user.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_closed_ok=0
fi
# 7d: source のパストラバーサル拒否
MKT_TRAV="$TMP_WORK/mkt-trav"
mkdir -p "$MKT_TRAV/.claude-plugin"
printf '{"name":"trav","plugins":[{"name":"beta","source":"../plugins/beta"}]}\n' > "$MKT_TRAV/.claude-plugin/marketplace.json"
if bash "$SYNC_SH" --marketplace-root "$MKT_TRAV" --out-dir "$OUT_ERR" >/dev/null 2>&1; then
  fail_closed_ok=0
fi
# 7e: 未知オプション・同時指定は rc=2
rc_unknown=0
bash "$SYNC_SH" --unknown-flag >/dev/null 2>&1 || rc_unknown=$?
rc_conflict=0
bash "$SYNC_SH" --plugin-root "$PLUGIN_ROOT" --marketplace-root "$MKT" >/dev/null 2>&1 || rc_conflict=$?
if [ "$rc_unknown" -ne 2 ] || [ "$rc_conflict" -ne 2 ]; then
  fail_closed_ok=0
fi
# 7f: marketplace 展開時の書き込み失敗が return 0 へ落ちずに非 0 終了すること
mkdir -p "$OUT_ERR"
: > "$OUT_ERR/alpha"
write_fail_out="$TMP_WORK/write-fail.stdout"
if bash "$SYNC_SH" --marketplace-root "$MKT" --plugin alpha --out-dir "$OUT_ERR" >"$write_fail_out" 2>/dev/null \
  || grep -F '同期完了' "$write_fail_out" >/dev/null 2>&1; then
  fail_closed_ok=0
fi
# 7g: --help が 0 終了しスクリプト本体行（set -euo pipefail）を出力しないこと
help_out="$TMP_WORK/help.stdout"
if ! bash "$SYNC_SH" --help >"$help_out" 2>/dev/null \
  || grep -F 'set -euo pipefail' "$help_out" >/dev/null 2>&1; then
  fail_closed_ok=0
fi
if [ "$fail_closed_ok" -eq 1 ]; then
  ok "(7) 異常系（manifest 不在・MCP 参照不在・非 symlink 防護・traversal・usage）で fail-closed"
else
  bad "(7) 異常系 fail-closed のいずれかが抜けた"
fi

# (8) $ と空白を含むプラグインパスでもシェル展開されずリテラル展開される
SPECIAL_SRC="$TMP_WORK/dir with \$HOME space"
mkdir -p "$SPECIAL_SRC/.claude-plugin" "$SPECIAL_SRC/skills/s1" "$SPECIAL_SRC/mcp"
SPECIAL_CANON="$(CDPATH='' cd -P -- "$SPECIAL_SRC" && pwd -P)"
printf '{"name":"special-path","version":"0.1.0","description":"s"}\n' > "$SPECIAL_SRC/.claude-plugin/plugin.json"
printf '# s\n' > "$SPECIAL_SRC/skills/s1/SKILL.md"
printf '// ok\n' > "$SPECIAL_SRC/mcp/index.js"
printf '{"mcpServers":{"spec-docs":{"command":"node","args":["${CLAUDE_PLUGIN_ROOT}/mcp/index.js"]}}}\n' > "$SPECIAL_SRC/.mcp.json"
OUT_SPECIAL="$TMP_WORK/out-special"
if bash "$SYNC_SH" --plugin-root "$SPECIAL_SRC" --out-dir "$OUT_SPECIAL" >/dev/null 2>&1 \
  && jq -e --arg exp "$SPECIAL_CANON/mcp/index.js" '
    .mcpServers["special-path-spec-docs"].args[0] == $exp
  ' "$OUT_SPECIAL/special-path/mcp_config.json" >/dev/null 2>&1; then
  ok "(8) \$HOME と空白を含むパスでもリテラルに展開される"
else
  bad "(8) 特殊文字パスで展開が壊れた"
fi

# (9) node による spec-docs MCP stdio 疎通検査（list_docs 応答）
if command -v node >/dev/null 2>&1; then
  if node -e '
    const fs = require("fs");
    const { spawn } = require("child_process");
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const srv = cfg.mcpServers["ff-dev-toolkit-spec-docs"];
    const child = spawn(srv.command, srv.args, {
      env: { ...process.env, ...(srv.env || {}) },
      stdio: ["pipe", "pipe", "pipe"]
    });
    let buf = "";
    let stage = 0;
    let finished = false;
    const timer = setTimeout(() => {
      console.error("MCP timeout");
      child.kill("SIGKILL");
      process.exit(1);
    }, 8000);
    function send(obj) { child.stdin.write(JSON.stringify(obj) + "\n"); }
    child.stdout.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const lines = buf.split("\n");
      buf = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        if (msg.id === 1 && stage === 0) {
          stage = 1;
          send({ jsonrpc: "2.0", method: "notifications/initialized" });
          send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
        } else if (msg.id === 2 && stage === 1) {
          const names = (msg.result && msg.result.tools || []).map((t) => t.name);
          if (!names.includes("list_docs")) {
            console.error("missing list_docs:", names);
            process.exit(1);
          }
          stage = 2;
          send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_docs", arguments: {} } });
        } else if (msg.id === 3 && stage === 2) {
          const txt = msg.result && msg.result.content && msg.result.content[0] && msg.result.content[0].text || "";
          if (!txt.includes("docs/README.md") || msg.result.isError) {
            console.error("unexpected list_docs result:", JSON.stringify(msg));
            process.exit(1);
          }
          finished = true;
          clearTimeout(timer);
          child.kill();
          process.exit(0);
        }
      }
    });
    child.on("exit", (code) => {
      if (!finished) {
        console.error("unexpected child exit before completion:", code, "stage:", stage);
        clearTimeout(timer);
        process.exit(1);
      }
    });
    send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "sync-verify", version: "1.0.0" } }
    });
  ' "$OUT_PROJ/ff-dev-toolkit/mcp_config.json" >/dev/null 2>&1; then
    ok "(9) 生成された mcp_config.json で spec-docs MCP stdio (tools/list + list_docs) が応答する"
  else
    bad "(9) 生成された mcp_config.json で MCP stdio 疎通に失敗"
  fi
else
  echo "  ○ skip: node が無いため MCP stdio 疎通は未検査"
fi

echo "=== antigravity-plugins-sync: $PASS passed, $FAIL failed ==="
REACHED_END=1
[ "$FAIL" -eq 0 ]
