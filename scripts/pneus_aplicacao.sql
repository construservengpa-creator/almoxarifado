-- Controle de aplicação de pneus (insumos dos grupos marcados como "controle de pneu" na configuração do Estoque).
--
-- Depois que a requisição é entregue (balcão: entrega registrada; despacho: recebida na obra), frotas ou
-- oficina informa, para CADA pneu entregue: nº de fogo, DOT, se é recapado (e o modelo da banda), eixo, lado e
-- posição em que foi montado no equipamento da requisição.
--
-- Ao montar um pneu numa posição, o pneu que saiu dela é registrado com o destino (estoque, recapagem, sucata,
-- garantia, outro). Destino "estoque" fica AGUARDANDO APROVAÇÃO do encarregado do almoxarifado; quando ele
-- aprova, o Estoque dá entrada do pneu no saldo (o lançamento do saldo é feito pelo app, como na devolução de
-- requisição).
--
-- Códigos de posição (coluna codigo_posicao, montada pelo banco):
--   <eixo><lado>[I|E]   eixo 1 = dianteiro, contando para trás; lado E = esquerdo (motorista), D = direito;
--                       I = interno, E = externo (só em rodado duplo). Ex.: 1E, 1D, 2EI, 2EE, 2DI, 2DE.
--   EST<n>              estepe nº n. Ex.: EST1.
--
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.

-- 0) Perfil "Encarregado da Oficina": libera o setor 'oficina' em profiles, se houver uma regra (check) de setor.
do $$
declare c record; v_lista text;
begin
  for c in select con.conname, pg_get_constraintdef(con.oid) as def
             from pg_constraint con
            where con.conrelid = 'public.profiles'::regclass and con.contype = 'c'
              and pg_get_constraintdef(con.oid) ilike '%setor%'
              and pg_get_constraintdef(con.oid) not ilike '%oficina%'
  loop
    select string_agg(quote_literal(s), ', ') into v_lista from (
      select distinct setor as s from public.profiles where setor is not null
      union select unnest(array['almoxarifado','compras','frotas','oficina'])) x;
    execute format('alter table public.profiles drop constraint %I', c.conname);
    execute format('alter table public.profiles add constraint %I check (setor is null or setor in (%s))', c.conname, v_lista);
    raise notice 'Regra % de profiles.setor atualizada para aceitar oficina.', c.conname;
  end loop;
end $$;

-- 1) Pneus aplicados (um registro por pneu montado)
create table if not exists public.pneus_aplicacoes (
  id                  bigint generated always as identity primary key,
  requisicao_id       bigint        not null,
  item_code           text          not null,
  descricao           text,
  obra_id             text,
  obra_nome           text,
  aplicacao_id        text          not null,
  aplicacao_nome      text,
  ordem_servico       text,
  numero_fogo         text          not null,
  dot                 text          not null check (dot ~ '^[0-9]{4}$'),
  recapado            boolean       not null default false,
  modelo_recapagem    text,
  eixo                int           not null check (eixo between 1 and 20),
  lado                text          check (lado in ('E','D')),
  posicao             text          not null check (posicao in ('UNICO','INTERNO','EXTERNO','ESTEPE')),
  codigo_posicao      text          generated always as (
                        case when posicao = 'ESTEPE' then 'EST' || eixo::text
                             else eixo::text || coalesce(lado,'') || case posicao when 'INTERNO' then 'I' when 'EXTERNO' then 'E' else '' end end) stored,
  status              text          not null default 'ativo' check (status in ('ativo','substituido','cancelado')),
  observacao          text,
  informado_por       uuid          default auth.uid(),
  informado_por_nome  text,
  aplicado_em         timestamptz   not null default now(),
  removido_em         timestamptz,
  cancelado_em        timestamptz,
  cancelado_por_nome  text,
  motivo_cancelamento text,
  check (recapado = false or coalesce(trim(modelo_recapagem),'') <> ''),
  check ((posicao = 'ESTEPE') = (lado is null))
);
create index if not exists pneus_aplicacoes_req on public.pneus_aplicacoes (requisicao_id);
create index if not exists pneus_aplicacoes_aplic on public.pneus_aplicacoes (aplicacao_id, status);
-- uma posição do equipamento só tem um pneu ativo; um nº de fogo só está montado em um lugar
create unique index if not exists pneus_aplicacoes_posicao_ativa on public.pneus_aplicacoes (aplicacao_id, eixo, coalesce(lado,''), posicao) where status = 'ativo';
create unique index if not exists pneus_aplicacoes_fogo_ativo on public.pneus_aplicacoes (upper(numero_fogo)) where status = 'ativo';

-- 2) Pneus retirados do equipamento e o destino de cada um
create table if not exists public.pneus_retirados (
  id                  bigint generated always as identity primary key,
  aplicacao_pneu_id   bigint        references public.pneus_aplicacoes(id),   -- pneu que estava na posição (se cadastrado)
  substituido_por_id  bigint        references public.pneus_aplicacoes(id),   -- pneu novo que entrou no lugar
  requisicao_id       bigint,
  aplicacao_id        text,
  aplicacao_nome      text,
  obra_id             text,
  obra_nome           text,
  eixo                int,
  lado                text,
  posicao             text,
  codigo_posicao      text,
  numero_fogo         text,
  dot                 text,
  item_code           text,
  descricao           text,
  destino             text          not null check (destino in ('estoque','recapagem','sucata','garantia','outro')),
  observacao          text,
  status              text          not null default 'registrado'
                        check (status in ('registrado','aguardando_aprovacao','reintegrado','rejeitado','cancelado')),
  -- reintegração ao estoque (destino = 'estoque')
  reint_code          text,
  reint_descricao     text,
  reint_obra_id       text,
  reint_obra_nome     text,
  reint_valor_unit    numeric(14,4),
  movimento_id        text,
  decidido_por        uuid,
  decidido_por_nome   text,
  decidido_em         timestamptz,
  motivo_rejeicao     text,
  registrado_por      uuid          default auth.uid(),
  registrado_por_nome text,
  registrado_em       timestamptz   not null default now()
);
create index if not exists pneus_retirados_status on public.pneus_retirados (status);
create index if not exists pneus_retirados_aplic on public.pneus_retirados (aplicacao_id);

alter table public.pneus_aplicacoes enable row level security;
alter table public.pneus_retirados  enable row level security;
drop policy if exists "pneus_aplicacoes: leitura" on public.pneus_aplicacoes;
create policy "pneus_aplicacoes: leitura" on public.pneus_aplicacoes for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));
drop policy if exists "pneus_retirados: leitura" on public.pneus_retirados;
create policy "pneus_retirados: leitura" on public.pneus_retirados for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));
-- Sem INSERT/UPDATE/DELETE direto: só pelas funções abaixo.

-- Quem informa aplicação: administrador, encarregado do almoxarifado ou qualquer usuário ativo do setor
-- Frotas ou Oficina (inclusive operador).
create or replace function public.pneu_pode_informar()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(p.nome, p.email) from public.profiles p
   where p.id = auth.uid() and p.ativo
     and (p.papel = 'admin' or (p.papel = 'encarregado' and p.setor = 'almoxarifado') or p.setor in ('frotas','oficina'));
$$;
-- Quem aprova a reintegração ao estoque: administrador ou encarregado do almoxarifado.
create or replace function public.pneu_pode_aprovar()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(p.nome, p.email) from public.profiles p
   where p.id = auth.uid() and p.ativo
     and (p.papel = 'admin' or (p.papel = 'encarregado' and p.setor = 'almoxarifado'));
$$;

-- Quantidade de um item da requisição que já pode receber aplicação: o que foi entregue, menos o devolvido.
create or replace function public.pneu_qtd_liberada(p_requisicao_id bigint, p_code text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v_status text; v_q numeric := 0; v_dev numeric := 0;
begin
  select status into v_status from public.requisicoes where id = p_requisicao_id;
  select coalesce(sum(case when v_status in ('retirado','recebido')
                           then greatest(coalesce(quantidade_entregue,0), coalesce(quantidade_separada,0))
                           else coalesce(quantidade_entregue,0) end), 0)
    into v_q from public.requisicao_itens_status where requisicao_id = p_requisicao_id and code = p_code;
  if to_regclass('public.devolucoes_requisicao') is not null then
    execute 'select coalesce(sum(quantidade),0) from public.devolucoes_requisicao where requisicao_id = $1 and item_code = $2'
      into v_dev using p_requisicao_id, p_code;
  end if;
  return greatest(v_q - v_dev, 0);
end $$;

-- Registra a montagem de um pneu e (se havia) o pneu retirado da mesma posição, tudo de uma vez.
-- p: { requisicao_id, item_code, descricao, obra_id, obra_nome, aplicacao_id, aplicacao_nome, ordem_servico,
--      numero_fogo, dot, recapado, modelo_recapagem, eixo, lado, posicao, observacao,
--      retirado: null | { numero_fogo, dot, item_code, descricao, destino, observacao,
--                         reint_code, reint_descricao, reint_obra_id, reint_obra_nome } }
create or replace function public.pneu_registrar_aplicacao(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_nome text; v_req bigint := (p->>'requisicao_id')::bigint; v_code text := p->>'item_code';
  v_lib numeric; v_usados int; v_dot text := trim(p->>'dot'); v_sem int; v_ano int;
  v_eixo int := (p->>'eixo')::int; v_lado text := nullif(upper(trim(p->>'lado')),''); v_pos text := upper(trim(p->>'posicao'));
  v_ant record; v_novo bigint; v_ret jsonb := p->'retirado'; v_ret_id bigint; v_dest text;
begin
  v_nome := public.pneu_pode_informar();
  if v_nome is null then raise exception 'Sem permissão para informar aplicação de pneu.' using errcode = 'P0001'; end if;
  perform 1 from public.requisicoes where id = v_req for update;   -- serializa por requisição
  if not found then raise exception 'Requisição não encontrada.' using errcode = 'P0001'; end if;
  if coalesce(trim(p->>'aplicacao_id'),'') = '' then raise exception 'A requisição não tem equipamento (aplicação).' using errcode = 'P0001'; end if;
  if coalesce(trim(p->>'numero_fogo'),'') = '' then raise exception 'Informe o nº de fogo.' using errcode = 'P0001'; end if;
  if v_dot !~ '^[0-9]{4}$' then raise exception 'DOT inválido: use 4 dígitos, semana e ano (ex.: 2324 = semana 23 de 2024).' using errcode = 'P0001'; end if;
  v_sem := substr(v_dot,1,2)::int; v_ano := 2000 + substr(v_dot,3,2)::int;
  if v_sem < 1 or v_sem > 53 or v_ano > extract(year from now())::int then
    raise exception 'DOT inválido: semana 01 a 53 e ano que não seja futuro.' using errcode = 'P0001'; end if;
  if coalesce((p->>'recapado')::boolean,false) and coalesce(trim(p->>'modelo_recapagem'),'') = '' then
    raise exception 'Pneu recapado: informe o modelo da banda.' using errcode = 'P0001'; end if;

  v_lib := public.pneu_qtd_liberada(v_req, v_code);
  select count(*) into v_usados from public.pneus_aplicacoes where requisicao_id = v_req and item_code = v_code and status <> 'cancelado';
  if v_usados + 1 > v_lib then
    raise exception 'Todos os pneus entregues deste item já foram informados (% de %).', v_usados, v_lib using errcode = 'P0001'; end if;

  if v_pos = 'ESTEPE' then v_lado := null; end if;
  -- pneu ativo que estava nessa posição sai como "substituído"
  select * into v_ant from public.pneus_aplicacoes
   where aplicacao_id = p->>'aplicacao_id' and eixo = v_eixo and coalesce(lado,'') = coalesce(v_lado,'') and posicao = v_pos and status = 'ativo'
   for update;
  if found then update public.pneus_aplicacoes set status = 'substituido', removido_em = now() where id = v_ant.id; end if;

  insert into public.pneus_aplicacoes (requisicao_id, item_code, descricao, obra_id, obra_nome, aplicacao_id, aplicacao_nome,
      ordem_servico, numero_fogo, dot, recapado, modelo_recapagem, eixo, lado, posicao, observacao, informado_por_nome)
  values (v_req, v_code, p->>'descricao', p->>'obra_id', p->>'obra_nome', p->>'aplicacao_id', p->>'aplicacao_nome',
      nullif(trim(p->>'ordem_servico'),''), upper(trim(p->>'numero_fogo')), v_dot, coalesce((p->>'recapado')::boolean,false),
      nullif(trim(p->>'modelo_recapagem'),''), v_eixo, v_lado, v_pos, nullif(trim(p->>'observacao'),''), v_nome)
  returning id into v_novo;

  -- pneu retirado: obrigatório quando havia um ativo cadastrado na posição
  if v_ant.id is not null and (v_ret is null or jsonb_typeof(v_ret) = 'null') then
    raise exception 'Informe o destino do pneu retirado da posição (nº de fogo %).', v_ant.numero_fogo using errcode = 'P0001'; end if;
  if v_ret is not null and jsonb_typeof(v_ret) = 'object' then
    v_dest := v_ret->>'destino';
    if v_dest not in ('estoque','recapagem','sucata','garantia','outro') then raise exception 'Destino do pneu retirado inválido.' using errcode = 'P0001'; end if;
    if v_dest = 'outro' and coalesce(trim(v_ret->>'observacao'),'') = '' then raise exception 'Destino "outro": descreva na observação.' using errcode = 'P0001'; end if;
    if v_dest = 'estoque' and (coalesce(v_ret->>'reint_code','') = '' or coalesce(v_ret->>'reint_obra_id','') = '') then
      raise exception 'Retorno ao estoque: informe o produto e o estoque (obra) de destino.' using errcode = 'P0001'; end if;
    insert into public.pneus_retirados (aplicacao_pneu_id, substituido_por_id, requisicao_id, aplicacao_id, aplicacao_nome, obra_id, obra_nome,
        eixo, lado, posicao, codigo_posicao, numero_fogo, dot, item_code, descricao, destino, observacao, status,
        reint_code, reint_descricao, reint_obra_id, reint_obra_nome, registrado_por_nome)
    select v_ant.id, v_novo, v_req, n.aplicacao_id, n.aplicacao_nome, n.obra_id, n.obra_nome, n.eixo, n.lado, n.posicao, n.codigo_posicao,
        coalesce(v_ant.numero_fogo, nullif(upper(trim(v_ret->>'numero_fogo')),'')), coalesce(v_ant.dot, nullif(trim(v_ret->>'dot'),'')),
        coalesce(v_ant.item_code, nullif(v_ret->>'item_code','')), coalesce(v_ant.descricao, nullif(v_ret->>'descricao','')),
        v_dest, nullif(trim(v_ret->>'observacao'),''), case when v_dest = 'estoque' then 'aguardando_aprovacao' else 'registrado' end,
        nullif(v_ret->>'reint_code',''), nullif(v_ret->>'reint_descricao',''), nullif(v_ret->>'reint_obra_id',''), nullif(v_ret->>'reint_obra_nome',''), v_nome
      from public.pneus_aplicacoes n where n.id = v_novo
    returning id into v_ret_id;
  end if;
  return jsonb_build_object('id', v_novo, 'retirado_id', v_ret_id, 'substituido_id', v_ant.id);
end $$;

-- Cancela uma aplicação informada errada. O pneu que ela tinha substituído volta a ficar ativo na posição e o
-- registro de retirada ligado a ela é cancelado (não pode cancelar se o retirado já foi reintegrado ao estoque).
create or replace function public.pneu_cancelar_aplicacao(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_nome text; v_a record; v_r record;
begin
  v_nome := public.pneu_pode_informar();
  if v_nome is null then raise exception 'Sem permissão.' using errcode = 'P0001'; end if;
  if coalesce(trim(p_motivo),'') = '' then raise exception 'Informe o motivo.' using errcode = 'P0001'; end if;
  select * into v_a from public.pneus_aplicacoes where id = p_id for update;
  if not found or v_a.status <> 'ativo' then raise exception 'Só dá para cancelar um pneu que ainda está ativo na posição.' using errcode = 'P0001'; end if;
  select * into v_r from public.pneus_retirados where substituido_por_id = p_id and status <> 'cancelado' for update;
  if found and v_r.status = 'reintegrado' then
    raise exception 'O pneu retirado nesta troca já voltou ao estoque — desfaça pelo ajuste de saldo antes de cancelar.' using errcode = 'P0001'; end if;
  update public.pneus_aplicacoes set status = 'cancelado', cancelado_em = now(), cancelado_por_nome = v_nome, motivo_cancelamento = trim(p_motivo) where id = p_id;
  if v_r.id is not null then
    update public.pneus_retirados set status = 'cancelado' where id = v_r.id;
    if v_r.aplicacao_pneu_id is not null then
      update public.pneus_aplicacoes set status = 'ativo', removido_em = null where id = v_r.aplicacao_pneu_id and status = 'substituido';
    end if;
  end if;
end $$;

-- Novo destino para um retirado (ex.: reintegração rejeitada → manda para recapagem ou sucata).
create or replace function public.pneu_definir_destino(p_id bigint, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_nome text; v_dest text := p->>'destino';
begin
  v_nome := public.pneu_pode_informar();
  if v_nome is null then raise exception 'Sem permissão.' using errcode = 'P0001'; end if;
  if v_dest not in ('estoque','recapagem','sucata','garantia','outro') then raise exception 'Destino inválido.' using errcode = 'P0001'; end if;
  if v_dest = 'outro' and coalesce(trim(p->>'observacao'),'') = '' then raise exception 'Destino "outro": descreva na observação.' using errcode = 'P0001'; end if;
  if v_dest = 'estoque' and (coalesce(p->>'reint_code','') = '' or coalesce(p->>'reint_obra_id','') = '') then
    raise exception 'Retorno ao estoque: informe o produto e o estoque (obra) de destino.' using errcode = 'P0001'; end if;
  update public.pneus_retirados
     set destino = v_dest, observacao = nullif(trim(p->>'observacao'),''),
         status = case when v_dest = 'estoque' then 'aguardando_aprovacao' else 'registrado' end,
         reint_code = nullif(p->>'reint_code',''), reint_descricao = nullif(p->>'reint_descricao',''),
         reint_obra_id = nullif(p->>'reint_obra_id',''), reint_obra_nome = nullif(p->>'reint_obra_nome','')
         -- decidido_* e motivo_rejeicao ficam como histórico da rejeição anterior
   where id = p_id and status in ('registrado','rejeitado');
  if not found then raise exception 'Só dá para mudar o destino de um retirado registrado ou com reintegração rejeitada.' using errcode = 'P0001'; end if;
end $$;

-- Aprovação (ou rejeição) da volta do pneu retirado ao estoque, pelo encarregado do almoxarifado.
-- Aprovado: grava produto, obra, valor e o id do movimento; o app lança o saldo com esse mesmo id.
create or replace function public.pneu_decidir_reintegracao(p_id bigint, p_aprovar boolean, p_motivo text default null,
  p_code text default null, p_descricao text default null, p_obra_id text default null, p_obra_nome text default null,
  p_valor_unit numeric default null, p_movimento_id text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  v_nome := public.pneu_pode_aprovar();
  if v_nome is null then raise exception 'Só o encarregado do almoxarifado (ou administrador) aprova a volta ao estoque.' using errcode = 'P0001'; end if;
  if p_aprovar then
    if coalesce(p_code,'') = '' or coalesce(p_obra_id,'') = '' or coalesce(p_valor_unit,0) <= 0 or coalesce(p_movimento_id,'') = '' then
      raise exception 'Informe produto, estoque (obra) e valor unitário maior que zero.' using errcode = 'P0001'; end if;
    update public.pneus_retirados
       set status = 'reintegrado', reint_code = p_code, reint_descricao = p_descricao, reint_obra_id = p_obra_id, reint_obra_nome = p_obra_nome,
           reint_valor_unit = p_valor_unit, movimento_id = p_movimento_id, decidido_por = auth.uid(), decidido_por_nome = v_nome, decidido_em = now()
     where id = p_id and status = 'aguardando_aprovacao';
  else
    if coalesce(trim(p_motivo),'') = '' then raise exception 'Informe o motivo da rejeição.' using errcode = 'P0001'; end if;
    update public.pneus_retirados
       set status = 'rejeitado', motivo_rejeicao = trim(p_motivo), decidido_por = auth.uid(), decidido_por_nome = v_nome, decidido_em = now()
     where id = p_id and status = 'aguardando_aprovacao';
  end if;
  if not found then raise exception 'Este pneu não está mais aguardando aprovação (outra pessoa já decidiu?).' using errcode = 'P0001'; end if;
end $$;

revoke all on function public.pneu_pode_informar() from public, anon;
revoke all on function public.pneu_pode_aprovar() from public, anon;
revoke all on function public.pneu_qtd_liberada(bigint, text) from public, anon;
revoke all on function public.pneu_registrar_aplicacao(jsonb) from public, anon;
revoke all on function public.pneu_cancelar_aplicacao(bigint, text) from public, anon;
revoke all on function public.pneu_definir_destino(bigint, jsonb) from public, anon;
revoke all on function public.pneu_decidir_reintegracao(bigint, boolean, text, text, text, text, text, numeric, text) from public, anon;
grant execute on function public.pneu_pode_informar() to authenticated;
grant execute on function public.pneu_pode_aprovar() to authenticated;
grant execute on function public.pneu_qtd_liberada(bigint, text) to authenticated;
grant execute on function public.pneu_registrar_aplicacao(jsonb) to authenticated;
grant execute on function public.pneu_cancelar_aplicacao(bigint, text) to authenticated;
grant execute on function public.pneu_definir_destino(bigint, jsonb) to authenticated;
grant execute on function public.pneu_decidir_reintegracao(bigint, boolean, text, text, text, text, text, numeric, text) to authenticated;

-- Tempo real: a fila e o contador atualizam quando alguém informa ou aprova.
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pneus_aplicacoes') then
    alter publication supabase_realtime add table public.pneus_aplicacoes;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pneus_retirados') then
    alter publication supabase_realtime add table public.pneus_retirados;
  end if;
end $$;
