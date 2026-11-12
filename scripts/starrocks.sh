#!/usr/bin/env bash
# StarRocks без клиента на хосте: SQL идёт в mysql внутри контейнера.
#   scripts/starrocks.sh init                          каталог на Oracle, таблицы, MV
#   scripts/starrocks.sh export 2026-05-01 2026-11-10  выгрузка дней из Oracle
#   scripts/starrocks.sh check                         сверка с Oracle
#   scripts/starrocks.sh sql "SELECT ..."              произвольный запрос
set -euo pipefail
cd "$(dirname "$0")/.."
sr() { docker exec -i bra-starrocks mysql -h127.0.0.1 -P9030 -uroot --table "$@"; }

case "${1:-}" in
  init)
    pw=$(grep '^DWH_PASSWORD=' .env | cut -d= -f2)
    sed "s/\${DWH_PASSWORD}/$pw/" sql/starrocks/schema.sql | sr ;;
  export)
    [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "${3:-$2}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      || { echo "нужны даты YYYY-MM-DD: export FROM [TO]" >&2; exit 1; }
    sed "s/{{ d1 }}/$2/g; s/{{ d2 }}/${3:-$2}/g" sql/starrocks/export.sql | sr ;;
  check) sr < sql/starrocks/check.sql ;;
  sql) sr -e "$2" ;;
  *) echo "usage: $0 init | export FROM [TO] | check | sql \"...\"" >&2; exit 1 ;;
esac
