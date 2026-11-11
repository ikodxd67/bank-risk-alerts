from bra.db import split_statements


def test_sql_loses_semicolon_plsql_keeps_it():
    text = """
-- шапка файла
CREATE TABLE t (id NUMBER);
/
CREATE OR REPLACE PACKAGE p AS
  -- внутренний комментарий остаётся
  PROCEDURE x;
END p;
/
begin null; end;
/
"""
    assert split_statements(text) == [
        "CREATE TABLE t (id NUMBER)",
        "CREATE OR REPLACE PACKAGE p AS\n  -- внутренний комментарий остаётся\n  PROCEDURE x;\nEND p;",
        "begin null; end;",
    ]


def test_last_statement_without_slash_and_empty_chunks():
    assert split_statements("/\n\n/\nSELECT 1 FROM dual;\n-- хвост\n") == ["SELECT 1 FROM dual"]
