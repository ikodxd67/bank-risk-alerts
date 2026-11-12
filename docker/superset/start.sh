#!/usr/bin/env bash
# Первый запуск и каждый следующий: схема метаданных, админ, дашборды из файлов, сервер.
set -euo pipefail
superset db upgrade
superset fab create-admin --username admin --firstname Admin --lastname Admin \
    --email admin@localhost --password "$SUPERSET_ADMIN_PASSWORD" || true   # уже есть — не ошибка
superset init
# Дашборды как код: YAML из репозитория собирается в архив и импортируется (перезаписывает прежние).
python -c "import shutil; shutil.make_archive('/tmp/bank_assets', 'zip', '/app/assets_src', 'bank_assets')"
superset import-dashboards -p /tmp/bank_assets.zip -u admin
exec /app/docker/entrypoints/run-server.sh
