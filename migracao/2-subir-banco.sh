#!/usr/bin/env bash
# Sobe o backup (./backup) no projeto NOVO e refaz o que o dump não leva (auth_storage_realtime.sql)
# Uso:  NOVO_DB_URL='postgresql://postgres.NOVO_REF:SENHA@aws-0-REGIAO.pooler.supabase.com:5432/postgres' ./2-subir-banco.sh
set -euo pipefail
: "${NOVO_DB_URL:?defina NOVO_DB_URL com a conexão do projeto novo}"
cd "$(dirname "$0")"
psql --single-transaction --variable ON_ERROR_STOP=1 \
  --file backup/roles.sql \
  --file backup/schema.sql \
  --command 'SET session_replication_role = replica' \
  --file backup/data.sql \
  --dbname "$NOVO_DB_URL"
psql --single-transaction --variable ON_ERROR_STOP=1 --file backup/history_schema.sql --file backup/history_data.sql --dbname "$NOVO_DB_URL" || \
  echo "(aviso) histórico de migrações não restaurado — não afeta o sistema"
psql --variable ON_ERROR_STOP=1 --file auth_storage_realtime.sql --dbname "$NOVO_DB_URL"
echo "Banco restaurado. Confira com: psql \"\$NOVO_DB_URL\" -f conferir.sql (e o mesmo no antigo)"
