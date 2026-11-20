-- Central de acessos do Capivara (aba no Painel de Suprimentos) — rodar UMA vez no SQL Editor do projeto do Estoque.
--
-- A central grava o acesso de cada pessoa direto em profiles: papel, setor, ativo, obras_vinculadas e,
-- com esta coluna, a marcação "Aprova requisições" (antes só existia em state.config.aprovadores, no documento
-- do app). Regra do app (index.html e aprovacoes/index.html):
--   admin sempre aprova → aprova_requisicoes (quando preenchida) → marcação antiga do documento → padrão do papel.
-- Coluna vazia (null) = comportamento de antes. Pode rodar de novo.
alter table public.profiles add column if not exists aprova_requisicoes boolean;
comment on column public.profiles.aprova_requisicoes is
  'Aprova requisições (gravado pela Central de acessos do Capivara). null = usa a marcação do documento do app / padrão do papel.';
