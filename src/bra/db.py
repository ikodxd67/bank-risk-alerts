"""Подключение к Oracle и накат SQL-файлов."""
from __future__ import annotations

import os
import re
from pathlib import Path

import oracledb

ROOT = Path(__file__).resolve().parents[2]

# CREATE PACKAGE / PROCEDURE / ... и анонимные блоки: точка с запятой — часть кода.
_PLSQL = re.compile(
    r"(create\s+(or\s+replace\s+)?(editionable\s+|noneditionable\s+)?"
    r"(package|procedure|function|trigger|type)\b|begin\b|declare\b)",
    re.IGNORECASE,
)


def load_env(path: Path = ROOT / ".env") -> None:
    """Переменные из .env, если их ещё нет в окружении (Airflow задаёт свои)."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.strip().startswith("#"):
            os.environ.setdefault(key.strip(), value.strip())


def connect(schema: str) -> oracledb.Connection:
    dsn = os.environ.get("ORACLE_DSN", "localhost:1521/FREEPDB1")
    return oracledb.connect(user=schema, password=os.environ[f"{schema.upper()}_PASSWORD"], dsn=dsn)


def split_statements(text: str) -> list[str]:
    """Команды разделены строкой из одного «/», как в SQL*Plus.

    Так файл одинаково исполняется и через sqlplus, и отсюда. У обычного SQL
    драйвер не принимает «;» в конце — срезаем; у PL/SQL «END;» обязателен.
    """
    statements, chunk = [], []
    for line in [*text.splitlines(), "/"]:
        if line.strip() != "/":
            chunk.append(line)
            continue
        # комментарии до и после команды срезаем, внутри (в коде пакета) — оставляем
        while chunk and _is_noise(chunk[0]):
            chunk.pop(0)
        while chunk and _is_noise(chunk[-1]):
            chunk.pop()
        if chunk:
            stmt = "\n".join(chunk).strip()
            if not _PLSQL.match(stmt):
                stmt = stmt.rstrip(";").rstrip()
            statements.append(stmt)
        chunk = []
    return statements


def _is_noise(line: str) -> bool:
    s = line.strip()
    return not s or s.startswith("--")


def migrate(conn: oracledb.Connection, folder: Path) -> list[str]:
    """Накатывает новые файлы folder/*.sql по алфавиту, помнит накаченные.

    shortcut: DDL в Oracle коммитится сам, поэтому упавший посреди файл
    оставит часть объектов — чинить руками; для учебного стенда хватает.
    """
    cur = conn.cursor()
    cur.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        " file_name VARCHAR2(200) PRIMARY KEY,"
        " applied_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL)"
    )
    done = {name for (name,) in cur.execute("SELECT file_name FROM schema_migrations")}
    applied = []
    for path in sorted(folder.glob("*.sql")):
        if path.name in done:
            continue
        for stmt in split_statements(path.read_text(encoding="utf-8")):
            cur.execute(stmt)
            if cur.warning:  # PL/SQL с ошибкой компиляции создаётся «успешно», с предупреждением
                raise RuntimeError(f"{path.name}: {cur.warning}\n{stmt[:200]}")
        cur.execute("INSERT INTO schema_migrations (file_name) VALUES (:1)", [path.name])
        conn.commit()
        applied.append(path.name)
    return applied
