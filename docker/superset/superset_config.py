"""Настройки Superset для локального стенда."""
import os

import pymysql
from superset.security import SupersetSecurityManager

# Диалект starrocks ищет драйвер MySQLdb (mysqlclient, собирается компилятором).
# pymysql — чистый Python и умеет подменять его.
pymysql.install_as_MySQLdb()

SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]
# shortcut: метаданные Superset в SQLite внутри тома — хватает одному пользователю; в проде Postgres.
SQLALCHEMY_DATABASE_URI = "sqlite:////app/superset_home/superset.db"


class LocalAdminSecurityManager(SupersetSecurityManager):
    """Локальный стенд без входа: каждый запрос идёт от пользователя admin
    (нужно и для скриншотов без браузера с паролем). Только для своей машины —
    в проде здесь обычный вход или SSO."""

    def request_loader(self, request):
        return self.find_user(username="admin")


CUSTOM_SECURITY_MANAGER = LocalAdminSecurityManager
