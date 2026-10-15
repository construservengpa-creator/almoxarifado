-- Diagnóstico da NF 24778 — só leitura. Rode UMA consulta de cada vez (o SQL Editor mostra só o último resultado).

-- A) a nota está no documento agora? e qual a versão do documento?
select (select count(*) from jsonb_array_elements(value->'notas') n where n->>'id' = 'omv8dhhg2gzl') as nota_no_documento,
       value->>'_rev' as versao, jsonb_array_length(value->'notas') as total_notas
from app_kv where key = 'controle-estoque-obras-v1';

-- B) quem gravou o documento nas últimas 3 horas (gravações do sistema aparecem com o texto da alteração)
select criado_em at time zone 'America/Sao_Paulo' as quando, usuario_nome, acao
from audit_log
where criado_em > now() - interval '3 hours'
  and acao not like 'requisicao%' and acao not in ('login','logout','separacao_concluida','entrega_balcao_final','entrega_assinada_tela')
order by criado_em desc limit 40;
