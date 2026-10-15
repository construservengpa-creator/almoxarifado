-- Recoloca no cadastro (app_kv) produtos que sumiram por gravação concorrente, a partir das movimentações.
-- Por padrão recupera só os da NF 24778 (5933 e 6063). Para incluir outros, acrescente os códigos na lista
-- "codigos" abaixo — confira antes com produtos_sumidos.sql (não recupere produto excluído de propósito).
-- Só inclui código que ainda não está no cadastro; pode rodar de novo sem duplicar.
-- Aumenta a versão do documento (_rev) para que nenhum aparelho com cópia antiga grave por cima.
-- Unidade fica "UN" e mínimo/máximo zerados — ajuste depois em Produtos, se precisar.
with codigos(code) as (values ('5933'), ('6063')),
cad as (
  select p->>'code' as code from app_kv, jsonb_array_elements(value->'products') p
  where key = 'controle-estoque-obras-v1'
),
novos as (
  select jsonb_build_object(
           'code', m.code,
           'desc', (array_agg(m.descricao order by m.ts desc))[1],
           'unit', 'UN', 'aux', '', 'min', 0, 'max', 0,
           'custo', coalesce((array_agg(m.valor_unit order by m.ts desc) filter (where m.tipo = 'entrada'))[1], 0),
           'preco', 0, 'ref', '') as p
  from movimentos_estoque m
  where m.code in (select code from codigos) and m.code not in (select code from cad)
  group by m.code
)
update app_kv
   set value = jsonb_set(
         jsonb_set(value, '{products}', coalesce(value->'products', '[]'::jsonb) || (select jsonb_agg(p) from novos)),
         '{_rev}', to_jsonb(coalesce(nullif(value->>'_rev', '')::bigint, 0) + 1))
 where key = 'controle-estoque-obras-v1'
   and exists (select 1 from novos)
returning 'Produtos recuperados: ' || (select string_agg(p->>'code' || ' ' || (p->>'desc'), ' · ') from novos)
          || ' — versão ' || (value->>'_rev') as resultado;
