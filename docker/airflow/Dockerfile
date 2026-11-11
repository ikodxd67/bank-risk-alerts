# В базовом образе нет провайдеров Oracle и Telegram (проверено pip list 2026-11-11).
# apache-airflow с той же версией в строке — чтобы pip не обновил сам Airflow.
FROM apache/airflow:3.4.0-python3.12
RUN pip install --no-cache-dir \
    "apache-airflow==3.4.0" \
    "apache-airflow-providers-oracle==4.7.1" \
    "apache-airflow-providers-telegram==4.10.1"
