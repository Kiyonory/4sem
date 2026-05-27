#!/usr/bin/env bash
# Только Postgres + pgAdmin для лабы 7. Django/сайт не трогаем.
set -e
cd "$(dirname "$0")/.."
docker compose up -d
echo ""
echo "pgAdmin:  http://localhost:5050  (admin@local.dev / admin)"
echo "БД:       localhost:5434  shop / shop  база shop_lab7"
echo "SQL:      в pgAdmin открыть sql/lab7_all.sql"
