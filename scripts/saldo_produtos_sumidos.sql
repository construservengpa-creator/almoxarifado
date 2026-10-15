-- Saldo REAL (tabela saldos_estoque) dos códigos que estão sem cadastro. Só leitura.
-- Saldo diferente de zero = material contado no estoque sem produto no cadastro.
with cad as (
  select p->>'code' as code from app_kv, jsonb_array_elements(value->'products') p where key = 'controle-estoque-obras-v1'
)
select s.code,
       (select m.descricao from movimentos_estoque m where m.code = s.code order by m.ts desc limit 1) as descricao,
       s.obra_id, s.saldo
from saldos_estoque s
where s.code not in (select code from cad) and s.saldo <> 0
order by s.code, s.obra_id;
