-- Recoloca no histórico TODAS as notas que têm entrada no estoque (movimentos_estoque.nota_id) mas sumiram
-- do documento compartilhado (app_kv) por gravação concorrente — e os produtos criados por elas que também
-- sumiram do cadastro. Monta tudo a partir das movimentações:
--   número e fornecedor vêm do documento do movimento ("NF 108181 · DAN DISTRIBUIDORA LTDA"),
--   obra, itens, quantidades e custos vêm das entradas, quem lançou vem da auditoria ("Entrada NF ... em ...").
-- Data de emissão, CNPJs e chave de acesso não ficaram guardados em lugar nenhum — ficam em branco.
-- Produto recuperado entra com unidade "UN" e mínimo/máximo zerados (ajuste depois em Produtos, se precisar).
-- Só inclui o que ainda falta; pode rodar de novo sem duplicar. Aumenta a versão do documento (_rev).
with cad_notas as (
  select n->>'id' as id from app_kv, jsonb_array_elements(value->'notas') n where key = 'controle-estoque-obras-v1'
),
prods as (
  select p from app_kv, jsonb_array_elements(value->'products') p where key = 'controle-estoque-obras-v1'
),
mov as (
  select m.* from movimentos_estoque m
  where m.nota_id is not null and m.tipo = 'entrada' and m.nota_id not in (select id from cad_notas)
),
notas_novas as (
  select jsonb_strip_nulls(jsonb_build_object(
    'id', mov.nota_id,
    'numero', substring(min(mov.doc) from '^NF (\S+)'),
    'forn', nullif(substring(min(mov.doc) from ' · (.*)$'), ''),
    'obra', min(mov.obra),
    'valor', round(sum(mov.qty * mov.valor_unit)::numeric, 2),
    'ts', min(mov.ts),
    'porNome', (select a.usuario_nome from audit_log a
                 where a.acao like 'Entrada NF ' || substring(min(mov.doc) from '^NF (\S+)') || ' em %'
                 order by abs(extract(epoch from a.criado_em) * 1000 - min(mov.ts)) limit 1),
    'recuperada', 'Registro recuperado em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' a partir das movimentações (sumiu do documento por gravação concorrente)',
    'itens', jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'code', mov.code,
      'desc', mov.descricao,
      'qty', mov.qty,
      'custo', mov.valor_unit,
      'unit', coalesce((select p->>'unit' from prods where p->>'code' = mov.code limit 1), 'UN'))) order by mov.code)
  )) as n
  from mov group by mov.nota_id
),
prod_novos as (
  select jsonb_build_object(
           'code', mov.code,
           'desc', (array_agg(mov.descricao order by mov.ts desc))[1],
           'unit', 'UN', 'aux', '', 'min', 0, 'max', 0,
           'custo', (array_agg(mov.valor_unit order by mov.ts desc))[1],
           'preco', 0, 'ref', '') as p
  from mov
  where mov.code is not null and mov.code not in (select p->>'code' from prods)
  group by mov.code
)
update app_kv
   set value = jsonb_set(jsonb_set(jsonb_set(value,
         '{notas}', (select jsonb_agg(x order by coalesce((x->>'ts')::bigint, 0) desc)
                       from (select n as x from notas_novas
                             union all select e from jsonb_array_elements(value->'notas') e) t)),
         '{products}', coalesce(value->'products', '[]'::jsonb) || coalesce((select jsonb_agg(p) from prod_novos), '[]'::jsonb)),
         '{_rev}', to_jsonb(coalesce(nullif(value->>'_rev', '')::bigint, 0) + 1))
 where key = 'controle-estoque-obras-v1'
   and exists (select 1 from notas_novas)
returning 'Notas recuperadas: ' || (select string_agg(n->>'numero' || coalesce(' · ' || (n->>'forn'), ''), ' | ') from notas_novas)
       || ' — produtos recuperados: ' || coalesce((select string_agg((p->>'code') || ' ' || (p->>'desc'), ' | ') from prod_novos), 'nenhum')
       || ' — versão ' || (value->>'_rev') as resultado;
