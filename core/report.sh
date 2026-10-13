#!/usr/bin/env bash
# Выводит хвост лога сборки одной аннотацией ошибки (логи Actions не всегда доступны).
sleep 2
msg=$(grep -v '^+' "$1" | tail -n 40 | awk '{printf "%s%%0A", $0}')
echo "::error::${msg}"
