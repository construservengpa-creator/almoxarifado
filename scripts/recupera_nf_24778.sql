-- Recupera a NF 24778 (M.M. BAURU) no histórico de notas do Estoque.
-- A nota foi lançada em 14/10/2026 14:17 por erikalima em 2000 - INVENTÁRIO; as entradas no estoque
-- (movimentos_estoque, nota_id = omv8dhhg2gzl) ficaram gravadas, mas o registro da nota sumiu do documento
-- compartilhado (app_kv) — sobrescrito por uma gravação de outro computador com cópia antiga (17:19:12).
-- Monta a nota de novo a partir dos movimentos + dados enviados ao Controle de Notas.
-- Só insere se a nota ainda não estiver no documento. Pode rodar mais de uma vez sem duplicar.
-- Rodar no SQL Editor do projeto Estoque, de preferência com pouca gente usando o sistema,
-- e pedir para todos recarregarem a página depois.

with mov as (
  select m.*, p.elem as prod
  from movimentos_estoque m
  left join app_kv kv on kv.key = 'controle-estoque-obras-v1'
  left join lateral (select e as elem from jsonb_array_elements(kv.value->'products') e where e->>'code' = m.code limit 1) p on true
  where m.nota_id = 'omv8dhhg2gzl' and m.tipo = 'entrada'
),
autor as (
  select id::text as id, coalesce(nullif(btrim(nome), ''), email) as nome from profiles
  where nome ilike 'erikalima%' or email ilike 'erikalima%' limit 1
),
nota as (
  select jsonb_strip_nulls(jsonb_build_object(
    'id', 'omv8dhhg2gzl',
    'numero', '24778',
    'forn', 'M.M. BAURU COM. E ASSIST. TEC. LT. EPP',
    'dataEmissao', '2026-10-01',
    'cnpjTomador', '04.101.986/0001-47',
    'cnpjEmit', '64056930000140',
    'obra', min(mov.obra),
    'valor', round(sum(mov.qty * mov.valor_unit)::numeric, 2),
    'valorNF', 513,
    'freteCteValor', 281.32,
    'chave', '35261064056930000140550020000247781332247329',
    'destinatario', 'AMETA ENGENHARIA LTDA',
    'ts', min(mov.ts),
    'porId', (select id from autor),
    'porNome', coalesce((select nome from autor), 'erikalima'),
    'recuperada', 'Registro recuperado em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' a partir das movimentações (sumiu do documento por gravação concorrente em 14/10 17:19)',
    'controle', jsonb_build_object('obraId', '5', 'vencimento', '2026-10-21', 'frete', 'sim', 'freteCte', '746079', 'freteValor', '281.32', 'prioridade', 'media'),
    'itens', jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'code', mov.code,
      'desc', coalesce(mov.prod->>'desc', mov.descricao),
      'qty', mov.qty,
      'custo', mov.valor_unit,
      'unit', mov.prod->>'unit')) order by mov.code)
  )) as n
  from mov
  having count(*) > 0
)
update app_kv
   set value = jsonb_set(value, '{notas}', jsonb_build_array((select n from nota)) || coalesce(value->'notas', '[]'::jsonb))
 where key = 'controle-estoque-obras-v1'
   and exists (select 1 from nota)
   and not exists (select 1 from jsonb_array_elements(value->'notas') x where x->>'id' = 'omv8dhhg2gzl')
returning 'NF 24778 recuperada — notas no documento: ' || jsonb_array_length(value->'notas') as resultado;
