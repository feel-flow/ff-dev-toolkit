#!/usr/bin/env bash
# fixture: 素の `trap 'rm -rf ...' EXIT` が途中死を rc=0 へ潰すことを示す。
# case 12 の構造検査が「何を防いでいるのか」を実際に走らせて確かめるための対照。
# ここを rc=0 以外にしてしまうと、case 12 の前提そのものが崩れる。
set -euo pipefail
W="/tmp/ff-exit-guard-probe.$$"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
: "${__ff_undefined_probe}"
echo "unreachable"
