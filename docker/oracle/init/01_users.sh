#!/bin/bash
# Две схемы в FREEPDB1: src — учётная система банка (источник), dwh — хранилище.
# Пароли приходят из .env, в репозитории их нет.
set -euo pipefail

sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CONTAINER = FREEPDB1;

CREATE USER src IDENTIFIED BY "${SRC_PASSWORD}" QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW, CREATE TRIGGER TO src;

CREATE USER dwh IDENTIFIED BY "${DWH_PASSWORD}" QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TYPE, CREATE MATERIALIZED VIEW TO dwh;
-- чтение v$-представлений: статистика сессии и фактические планы для замеров (scripts/perf.py)
GRANT SELECT_CATALOG_ROLE TO dwh;
EXIT
SQL
