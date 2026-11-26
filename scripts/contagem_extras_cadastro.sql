-- Contagem: dados de cadastro do produto novo informados na aprovação de um item fora do cadastro.
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.
--
-- Quando o encarregado escolhe "Cadastrar como produto novo", além de código, descrição, unidade e custo,
-- passa a informar: código auxiliar (outro sistema), código de barras do fabricante, grupo do insumo e
-- estoque (localização). Os valores ficam no próprio registro e vão para o cadastro do produto quando o
-- ajuste do inventário é lançado no sistema de estoque (campos aux, fab, grupo e localizacao).

alter table public.contagem_extras add column if not exists aux_final   text;
alter table public.contagem_extras add column if not exists fab_final   text;
alter table public.contagem_extras add column if not exists grupo_final text;
alter table public.contagem_extras add column if not exists local_final text;

-- Conferência
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'contagem_extras'
   and column_name in ('aux_final', 'fab_final', 'grupo_final', 'local_final');
