-- Procura outras notas que sumiram do histórico do mesmo jeito: têm entrada no estoque
-- (movimentos_estoque.nota_id), mas não estão no documento compartilhado (app_kv). Só leitura.
select m.nota_id, min(m.doc) as doc, min(m.obra) as obra, count(*) as itens,
       to_timestamp(min(m.ts) / 1000) at time zone 'America/Sao_Paulo' as lancada_em
from movimentos_estoque m
where m.nota_id is not null and m.tipo = 'entrada'
  and m.nota_id not in (
    select n->>'id' from app_kv, jsonb_array_elements(value->'notas') n
    where key = 'controle-estoque-obras-v1')
group by m.nota_id
order by min(m.ts) desc;
