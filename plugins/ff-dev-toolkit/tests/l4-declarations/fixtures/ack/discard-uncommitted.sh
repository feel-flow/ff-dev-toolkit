# shellcheck shell=bash
# ACK discard-uncommitted: hooks/guard-checkout-restore.sh。入力: 未コミットの変更がある dirty.txt への
# 区間の先頭の前置での `git checkout -- dirty.txt`。
fx_owners='hooks/guard-checkout-restore.sh'
fx_forms='prefix'
fx_setup() { fx_dirty_repo "$fx_wk/repo"; }
fx_input() { fx_bash_input "${fx_ack_prefix-}git checkout -- dirty.txt" "$fx_wk/repo" > "$fx_wk/in.json"; }
fx_run() { fx_hook hooks/guard-checkout-restore.sh; }
