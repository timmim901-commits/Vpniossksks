#!/usr/bin/env bash
# Добавляет в дерево sing-box собственные протоколы Orbit. Запуск из корня sing-box.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p protocol/gost
cp "$SRC/gost/outbound.go" protocol/gost/outbound.go
cp "$SRC/option_gost.go" option/gost.go
grep -q 'protocol/gost' include/registry.go || {
  sed -i 's#"github.com/sagernet/sing-box/protocol/snell"#&\n\t"github.com/sagernet/sing-box/protocol/gost"#' include/registry.go
  sed -i 's#^\(\s*\)snell.RegisterOutbound(registry)#&\n\1gost.RegisterOutbound(registry)#' include/registry.go
}
grep -q 'gost.RegisterOutbound' include/registry.go
