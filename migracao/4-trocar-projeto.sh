#!/usr/bin/env bash
# Troca o endereço e a chave pública (anon/publishable) do Supabase do Estoque em todos os sistemas que o usam.
# Uso (na pasta migracao):  ./4-trocar-projeto.sh https://NOVO_REF.supabase.co CHAVE_ANON_NOVA [pasta-do-Controle-de-Notas] [pasta-do-Painel]
# Troca em: Estoque (index.html, aprovacoes/, contagem/, notificacoes/), função receber-nota-estoque do Controle de
# Notas e função status-solicitacoes do Painel (essas duas precisam ser publicadas de novo nos respectivos projetos).
set -euo pipefail
NOVO_URL="${1:?informe o endereço novo, ex.: https://abcd.supabase.co}"
NOVA_CHAVE="${2:?informe a chave pública (anon) do projeto novo}"
NOTAS="${3:-}"; PAINEL="${4:-}"
NOVO_REF=$(echo "$NOVO_URL" | sed -E 's#https?://([^.]+)\..*#\1#')
ANTIGO_REF='qjmqburjyqlgwjihvlgp'
ANTIGA_CHAVE='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFqbXFidXJqeXFsZ3dqaWh2bGdwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg4NzU0NzIsImV4cCI6MjEwNDQ1MTQ3Mn0.cOdmVw3W0HCilACqZIVFMCwsr6zxA0g_3CreKIuk9kw'
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
ARQS=("$RAIZ/index.html" "$RAIZ/aprovacoes/index.html" "$RAIZ/contagem/index.html" "$RAIZ/notificacoes/index.html")
[ -n "$NOTAS" ] && ARQS+=("$NOTAS/supabase/functions/receber-nota-estoque/index.ts")
[ -n "$PAINEL" ] && ARQS+=("$PAINEL/supabase/functions/status-solicitacoes/index.ts")
for f in "${ARQS[@]}"; do
  [ -f "$f" ] || { echo "não encontrado: $f"; exit 1; }
  sed -i.bak -e "s#$ANTIGA_CHAVE#$NOVA_CHAVE#g" -e "s#$ANTIGO_REF#$NOVO_REF#g" "$f" && rm -f "$f.bak"
  echo "trocado: $f (restam $(grep -c "$ANTIGO_REF" "$f" || true) referência(s) ao projeto antigo)"
done
echo "Pronto. Confira com git diff e publique (commit + push) cada repositório."
