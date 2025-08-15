#!/bin/bash
set -e

HOST="${PGHOST:-db}"
PORT="${PGPORT:-5432}"

until pg_isready -h "$HOST" -p "$PORT"; do
  echo "Waiting for PostgreSQL at $HOST:$PORT..."
  sleep 2
done

exec "$@"
