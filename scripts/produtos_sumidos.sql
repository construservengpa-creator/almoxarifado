-- Produtos que têm movimentação no estoque mas NÃO estão no cadastro (documento compartilhado app_kv).
-- Só leitura. Use a lista para conferir antes de rodar recupera_produtos.sql.
-- Atenção: um produto excluído ou unificado de propósito também pode aparecer aqui se ainda tiver movimentos.
with cad as (
  select p->>'code' as code from app_kv, jsonb_array_elements(value->'products') p
  where key = 'controle-estoque-obras-v1'
)
select m.code,
       (array_agg(m.descricao order by m.ts desc))[1] as descricao,
       (array_agg(m.valor_unit order by m.ts desc) filter (where m.tipo = 'entrada'))[1] as ultimo_custo_entrada,
       count(*) as movimentos,
       sum(m.qty) filter (where m.tipo in ('entrada','devolucao')) as qtd_entradas,
       to_timestamp(min(m.ts) / 1000) at time zone 'America/Sao_Paulo' as primeira_mov,
       to_timestamp(max(m.ts) / 1000) at time zone 'America/Sao_Paulo' as ultima_mov,
       string_agg(distinct m.doc, ' | ') as documentos
from movimentos_estoque m
where m.code is not null and m.code not in (select code from cad)
group by m.code
order by max(m.ts) desc;
