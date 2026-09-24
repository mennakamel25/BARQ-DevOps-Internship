#!/usr/bin/env bash
set -euo pipefail

PROJECT="barq-assessment"
POSTGRES_CONTAINER="postgres"
BACKUP_DIR="backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/postgres_${TIMESTAMP}.dump"

mkdir -p "${BACKUP_DIR}"

echo "Creating PostgreSQL backup..."
echo "Container: ${POSTGRES_CONTAINER}"
echo "Output: ${BACKUP_FILE}"

docker compose -p "${PROJECT}" exec -T "${POSTGRES_CONTAINER}" \
  pg_dump \
  -U barq_app \
  -d barq_tasks \
  -Fc \
  > "${BACKUP_FILE}"

test -s "${BACKUP_FILE}"

echo "Backup created successfully:"
ls -lh "${BACKUP_FILE}"