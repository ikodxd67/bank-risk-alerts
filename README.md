# bank-risk-alerts

Work in progress. Banking reporting and alerting pipeline: Oracle + PL/SQL packages →
Airflow → StarRocks → Superset dashboards and Grafana alerts. All data is synthetic.

## Run

```bash
cp .env.example .env
docker compose up -d
```

Oracle Free listens on `localhost:1521`, service `FREEPDB1`, schemas `src` and `dwh`.
