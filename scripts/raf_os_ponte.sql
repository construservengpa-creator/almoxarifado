-- Ponte O.S. RAF -> Capivara (a O.S. RAF não tem login: chama como anon, autenticada por um token de integração).
-- Rodar DEPOIS de scripts/raf_os_reservas.sql, no SQL Editor do Supabase. Pode rodar de novo sem problema.
--
-- Mantém os nomes e parâmetros que a O.S. RAF já usa:
--   raf_os_bridge_health(token)
--   raf_os_criar_requisicao_bridge_v2(token, obra_id, obra_nome, code, descricao, unidade, quantidade,
--                                     solicitante_nome, os, prefixo, modelo, observacao)
--   raf_os_consultar_requisicoes_bridge(token, os, prefixo)
--
-- Segurança (sem login, qualquer um que tenha a página da O.S. RAF consegue chamar):
--   * o token NÃO fica escrito nas funções: só o hash fica na tabela raf_integracao (sem acesso por anon/authenticated);
--     para gerar/trocar: rodar  select public.raf_gerar_token();  aqui no SQL Editor e copiar o valor UMA vez;
--   * a requisição nasce PENDENTE: passa pelo app de Aprovações antes de qualquer separação;
--   * a reserva só é criada se houver saldo (saldo − reservas já ativas); requisição e reserva na mesma transação;
--   * trava contra duplicidade (mesma O.S. / prefixo / item com reserva ativa) e limite de 200 pedidos por hora;
--   * requisição rejeitada ou cancelada cancela a reserva criada pela ponte (não fica estoque preso).

-- 1) Marcações nas reservas
alter table public.raf_os_reservas add column if not exists origem  text not null default 'capivara';
alter table public.raf_os_reservas add column if not exists prefixo text;
create index if not exists raf_os_reservas_ponte on public.raf_os_reservas (ordem_servico, prefixo, code) where origem = 'raf_ponte';

-- 2) Token de integração (só o hash; ninguém lê esta tabela pela API)
create table if not exists public.raf_integracao (
  id            integer primary key default 1 check (id = 1),
  token_sha256  text        not null,
  trocado_em    timestamptz not null default now()
);
alter table public.raf_integracao enable row level security;
revoke all on public.raf_integracao from anon, authenticated;

create or replace function public.raf_gerar_token()
returns text language plpgsql security definer set search_path = public, pg_catalog as $$
declare v text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  insert into public.raf_integracao (id, token_sha256, trocado_em)
  values (1, encode(sha256(convert_to(v, 'UTF8')), 'hex'), now())
  on conflict (id) do update set token_sha256 = excluded.token_sha256, trocado_em = now();
  return v;  -- aparece só agora; o banco guarda apenas o hash
end $$;
revoke all on function public.raf_gerar_token() from public, anon, authenticated;

create or replace function public._raf_token_ok(p_token text)
returns boolean language sql stable security definer set search_path = public, pg_catalog as $$
  select exists (select 1 from public.raf_integracao
                  where token_sha256 = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex'));
$$;
revoke all on function public._raf_token_ok(text) from public, anon, authenticated;

-- 3) Reserva: lógica única, usada pela função com login (raf_reservar) e pela ponte
create or replace function public._raf_reservar_interno(
  p_obra text, p_code text, p_quantidade numeric, p_ordem_servico text, p_requisicao_id bigint,
  p_observacao text, p_nome text, p_origem text, p_prefixo text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_saldo numeric; v_reservado numeric;
begin
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe uma quantidade maior que zero.' using errcode = 'P0001'; end if;
  -- trava o saldo do item: duas reservas ao mesmo tempo não passam do disponível
  select saldo into v_saldo from public.saldos_estoque where obra_id = p_obra and code = p_code for update;
  select coalesce(sum(quantidade), 0) into v_reservado from public.raf_os_reservas
   where obra_id = p_obra and code = p_code and status = 'ativa';
  if coalesce(v_saldo, 0) - v_reservado < p_quantidade then
    raise exception 'Saldo insuficiente para reservar: disponível %.', greatest(coalesce(v_saldo, 0) - v_reservado, 0)
      using errcode = 'P0001';
  end if;
  insert into public.raf_os_reservas (obra_id, code, quantidade, ordem_servico, requisicao_id, observacao, criado_por_nome, origem, prefixo)
  values (p_obra, p_code, p_quantidade, nullif(trim(p_ordem_servico), ''), p_requisicao_id, nullif(trim(p_observacao), ''),
          p_nome, coalesce(p_origem, 'capivara'), nullif(trim(p_prefixo), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public._raf_reservar_interno(text, text, numeric, text, bigint, text, text, text, text) from public, anon, authenticated;

-- raf_reservar (com login) continua igual por fora, agora usando a lógica única
create or replace function public.raf_reservar(
  p_obra text, p_code text, p_quantidade numeric, p_ordem_servico text default null,
  p_requisicao_id bigint default null, p_observacao text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  select nome into v_nome from public.profiles p where p.id = auth.uid() and p.ativo;
  if not found then raise exception 'Sem permissão para reservar material.' using errcode = 'P0001'; end if;
  return public._raf_reservar_interno(p_obra, p_code, p_quantidade, p_ordem_servico, p_requisicao_id, p_observacao,
                                      v_nome, 'capivara', null);
end $$;

-- 4) Gatilho da requisição: reservas da ponte são canceladas se a requisição for rejeitada/cancelada
create or replace function public.raf_reservas_por_requisicao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    begin
      if new.status = 'separado' then
        update public.raf_os_reservas set status = 'baixada', baixado_em = now()
         where requisicao_id::text = new.id::text and status = 'ativa';
      elsif new.status in ('cancelada', 'rejeitada') then
        update public.raf_os_reservas
           set status = 'cancelada', cancelado_em = now(), cancelado_por_nome = 'automático',
               motivo_cancelamento = 'Requisição ' || new.status
         where requisicao_id::text = new.id::text and status = 'ativa' and origem = 'raf_ponte';
        update public.raf_os_reservas set requisicao_id = null
         where requisicao_id::text = new.id::text and status = 'ativa' and origem <> 'raf_ponte';
      end if;
    exception when others then
      raise warning 'raf_reservas_por_requisicao: %', sqlerrm;
    end;
  end if;
  return new;
end $$;

-- 5) Funções chamadas pela O.S. RAF
create or replace function public.raf_os_bridge_health(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_catalog as $$
begin
  if not public._raf_token_ok(p_token) then raise exception 'Integração RAF não autorizada.' using errcode = 'P0001'; end if;
  return jsonb_build_object('ok', true, 'versao', 'capivara-ponte-1', 'status_inicial', 'pendente');
end $$;

create or replace function public.raf_os_criar_requisicao_bridge_v2(
  p_token text, p_obra_id text, p_obra_nome text, p_code text, p_descricao text, p_unidade text,
  p_quantidade numeric, p_solicitante_nome text, p_os text, p_prefixo text,
  p_modelo text default null, p_observacao text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare
  v_req_id bigint; v_res_id bigint; v_uid uuid; v_aplicacao text; v_nome text; v_obs text; v_itens jsonb;
begin
  if not public._raf_token_ok(p_token) then raise exception 'Integração RAF não autorizada.' using errcode = 'P0001'; end if;

  p_obra_id := btrim(coalesce(p_obra_id, ''));          p_obra_nome := btrim(coalesce(p_obra_nome, ''));
  p_code := btrim(coalesce(p_code, ''));                p_descricao := btrim(coalesce(p_descricao, ''));
  p_unidade := btrim(coalesce(p_unidade, ''));          p_solicitante_nome := btrim(coalesce(p_solicitante_nome, ''));
  p_os := btrim(coalesce(p_os, ''));                    p_prefixo := upper(btrim(coalesce(p_prefixo, '')));
  p_modelo := btrim(coalesce(p_modelo, ''));            p_observacao := btrim(coalesce(p_observacao, ''));

  if p_obra_id = '' then raise exception 'Informe o estoque/obra.' using errcode = 'P0001'; end if;
  if p_code = '' then raise exception 'Item inválido.' using errcode = 'P0001'; end if;
  if p_descricao = '' then raise exception 'Descrição não informada.' using errcode = 'P0001'; end if;
  if p_quantidade is null or p_quantidade <= 0 or p_quantidade > 100000 then raise exception 'Quantidade inválida.' using errcode = 'P0001'; end if;
  if p_solicitante_nome = '' then raise exception 'Informe o solicitante.' using errcode = 'P0001'; end if;
  if p_os = '' then raise exception 'Número da O.S. não informado.' using errcode = 'P0001'; end if;
  if p_prefixo = '' then raise exception 'Prefixo não informado.' using errcode = 'P0001'; end if;
  if length(p_obra_id) > 80 or length(p_code) > 60 or length(p_descricao) > 300 or length(p_unidade) > 20
     or length(p_solicitante_nome) > 120 or length(p_os) > 60 or length(p_prefixo) > 60 or length(p_modelo) > 120
     or length(p_observacao) > 1000 or length(p_obra_nome) > 200 then
    raise exception 'Algum campo passou do tamanho permitido.' using errcode = 'P0001';
  end if;

  -- limite de volume (sem login, protege contra uso indevido em massa)
  if (select count(*) from public.raf_os_reservas where origem = 'raf_ponte' and criado_em > now() - interval '1 hour') >= 200 then
    raise exception 'Muitas solicitações na última hora. Tente mais tarde ou fale com o almoxarifado.' using errcode = 'P0001';
  end if;

  -- duplicidade: mesma O.S. / prefixo / item com reserva ainda ativa (trava evita dois cliques simultâneos)
  perform pg_advisory_xact_lock(hashtext('raf_ponte|' || p_os || '|' || p_prefixo || '|' || p_code));
  if exists (select 1 from public.raf_os_reservas
              where origem = 'raf_ponte' and status = 'ativa' and ordem_servico = p_os and prefixo = p_prefixo and code = p_code) then
    raise exception 'Já existe solicitação aberta deste item para O.S. % / %.', p_os, p_prefixo using errcode = 'P0001';
  end if;

  v_aplicacao := p_prefixo || case when p_modelo <> '' then ' · ' || p_modelo else '' end;
  v_nome := p_solicitante_nome || ' (O.S. RAF)';
  v_obs := concat_ws(' · ', 'Solicitação originada na O.S. RAF', 'Prefixo: ' || p_prefixo,
                     case when p_modelo <> '' then 'Modelo: ' || p_modelo end, nullif(p_observacao, ''));
  v_itens := jsonb_build_array(jsonb_build_object('code', p_code, 'desc', p_descricao, 'unit', p_unidade, 'qty', p_quantidade));

  -- requisição PENDENTE (passa pela aprovação). Sem login, não há solicitante_id; se a coluna for obrigatória,
  -- usa um administrador/almoxarife só para satisfazer o campo (o nome real fica em solicitante_nome).
  begin
    insert into public.requisicoes (obra_id, obra_nome, solicitante_id, solicitante_nome, itens, observacao,
                                    ordem_servico, aplicacao_id, aplicacao_nome, status, tipo_envio)
    values (p_obra_id, nullif(p_obra_nome, ''), null, v_nome, v_itens, v_obs, p_os, null, v_aplicacao, 'pendente', null)
    returning id into v_req_id;
  exception when not_null_violation then
    select p.id into v_uid from public.profiles p
     where p.ativo and (p.papel = 'admin' or p.setor = 'almoxarifado')
     order by case when p.setor = 'almoxarifado' then 0 else 1 end, p.id limit 1;
    insert into public.requisicoes (obra_id, obra_nome, solicitante_id, solicitante_nome, itens, observacao,
                                    ordem_servico, aplicacao_id, aplicacao_nome, status, tipo_envio)
    values (p_obra_id, nullif(p_obra_nome, ''), v_uid, v_nome, v_itens, v_obs, p_os, null, v_aplicacao, 'pendente', null)
    returning id into v_req_id;
  end;

  -- reserva já ligada à requisição; sem saldo, desfaz tudo (requisição inclusive)
  v_res_id := public._raf_reservar_interno(p_obra_id, p_code, p_quantidade, p_os, v_req_id, null, v_nome, 'raf_ponte', p_prefixo);

  return jsonb_build_object(
    'ok', true,
    'requisicao_id', v_req_id,
    'requisicao', 'REQ-' || lpad(v_req_id::text, 5, '0'),
    'status', 'pendente',
    'reserva_ids', jsonb_build_array(v_res_id::text));
end $$;

create or replace function public.raf_os_consultar_requisicoes_bridge(p_token text, p_os text, p_prefixo text default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_catalog as $$
begin
  if not public._raf_token_ok(p_token) then raise exception 'Integração RAF não autorizada.' using errcode = 'P0001'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'requisicao', 'REQ-' || lpad(q.id::text, 5, '0'), 'status', q.status, 'tipo_envio', q.tipo_envio,
      'obra_id', q.obra_id, 'obra_nome', q.obra_nome, 'solicitante_nome', q.solicitante_nome,
      'ordem_servico', q.ordem_servico, 'aplicacao_nome', q.aplicacao_nome, 'itens', q.itens, 'criado_em', q.criado_em,
      'reserva_status', r.status
    ) order by q.criado_em desc)
    from public.raf_os_reservas r
    join public.requisicoes q on q.id::text = r.requisicao_id::text
    where r.origem = 'raf_ponte'
      and r.ordem_servico = btrim(coalesce(p_os, ''))
      and (coalesce(btrim(p_prefixo), '') = '' or r.prefixo = upper(btrim(p_prefixo)))
  ), '[]'::jsonb);
end $$;

revoke all on function public.raf_os_bridge_health(text) from public;
revoke all on function public.raf_os_criar_requisicao_bridge_v2(text, text, text, text, text, text, numeric, text, text, text, text, text) from public;
revoke all on function public.raf_os_consultar_requisicoes_bridge(text, text, text) from public;
grant execute on function public.raf_os_bridge_health(text) to anon, authenticated;
grant execute on function public.raf_os_criar_requisicao_bridge_v2(text, text, text, text, text, text, numeric, text, text, text, text, text) to anon, authenticated;
grant execute on function public.raf_os_consultar_requisicoes_bridge(text, text, text) to anon, authenticated;
