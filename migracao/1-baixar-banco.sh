#!/usr/bin/env bash
# Baixa o banco do Estoque (estrutura + dados + usuários) para a pasta ./backup
# Uso:  ANTIGO_DB_URL='postgresql://postgres.qjmqburjyqlgwjihvlgp:SENHA@aws-0-us-west-2.pooler.supabase.com:5432/postgres' ./1-baixar-banco.sh
# (copie a "Session pooler" em Connect, no painel do projeto antigo; a senha é a do banco)
set -euo pipefail
: "${ANTIGO_DB_URL:?defina ANTIGO_DB_URL com a conexão do projeto antigo}"
mkdir -p backup && cd backup
supabase db dump --db-url "$ANTIGO_DB_URL" -f roles.sql --role-only
supabase db dump --db-url "$ANTIGO_DB_URL" -f schema.sql
supabase db dump --db-url "$ANTIGO_DB_URL" -f data.sql --use-copy --data-only -x "storage.buckets_vectors" -x "storage.vector_indexes"
supabase db dump --db-url "$ANTIGO_DB_URL" -f history_schema.sql --schema supabase_migrations
supabase db dump --db-url "$ANTIGO_DB_URL" -f history_data.sql --use-copy --data-only --schema supabase_migrations
ls -lh
echo "Pronto: backup em $(pwd). Guarde esta pasta — ela tem os dados e as senhas (criptografadas) dos usuários."
