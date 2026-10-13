#!/usr/bin/env bash
# Добавляет в дерево sing-box собственные протоколы Orbit. Запуск из корня sing-box.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p protocol/gost
cp "$SRC/gost/outbound.go" protocol/gost/outbound.go
cp "$SRC/option_gost.go" option/gost.go
python3 - <<'PY'
import re
p = "include/registry.go"
s = open(p).read()
if "protocol/gost" not in s:
    s = s.replace('"github.com/sagernet/sing-box/protocol/snell"',
                  '"github.com/sagernet/sing-box/protocol/snell"\n\t"github.com/sagernet/sing-box/protocol/gost"', 1)
    s = re.sub(r"(\n(\s*)snell\.RegisterOutbound\(registry\))",
               r"\1\n\2gost.RegisterOutbound(registry)", s, count=1)
    open(p, "w").write(s)
assert "gost.RegisterOutbound(registry)" in s
PY

# --- Xray рядом с sing-box: один фреймворк, один Go-рантайм ---
XRAY_VERSION="${XRAY_VERSION:-v26.7.28}"
mkdir -p experimental/xraybridge
cp "$SRC/xraybridge/xray.go" experimental/xraybridge/xray.go
go get "github.com/xtls/xray-core@${XRAY_VERSION}"
go get ./experimental/xraybridge
python3 - <<'PY'
p = "cmd/internal/build_libbox/main.go"
s = open(p).read()
needle = 'args = append(args, "./experimental/libbox")'
i = s.rindex(needle)  # последнее вхождение — сборка для Apple
s = s[:i] + 'args = append(args, "./experimental/libbox", "./experimental/xraybridge")' + s[i + len(needle):]
open(p, "w").write(s)
PY
grep -q xraybridge cmd/internal/build_libbox/main.go
