# В образе Superset нет драйверов баз (проверено 2026-11-12): добавляем диалект StarRocks.
FROM apache/superset:6.1.0
USER root
RUN . /app/.venv/bin/activate && uv pip install --no-cache "starrocks==1.3.4" pymysql
USER superset
