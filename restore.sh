#!/usr/bin/env bash
set -euo pipefail

PROJECT="barq-assessment"
POSTGRES_CONTAINER="postgres"
BACKUP_FILE="${1:-}"

if [[ -z "${BACKUP_FILE}" ]]; then
    echo "Usage: $0 <backup-file>" >&2
    exit 1
fi

if [[ ! -s "${BACKUP_FILE}" ]]; then
    echo "Backup file does not exist or is empty: ${BACKUP_FILE}" >&2
    exit 1
fi

echo "Restoring PostgreSQL backup..."
echo "Backup: ${BACKUP_FILE}"

docker compose -p "${PROJECT}" exec -T "${POSTGRES_CONTAINER}" \
    pg_restore \
    -U barq_app \
    -d barq_tasks \
    --clean \
    --if-exists \
    --no-owner \
    < "${BACKUP_FILE}"

echo "PostgreSQL restore completed successfully."