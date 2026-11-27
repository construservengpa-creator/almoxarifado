-- Ponte O.S. RAF -> Capivara: pedido com VÁRIOS itens e consulta com status de entrega (versão segura da "V6.31").
-- Rodar DEPOIS de scripts/raf_os_reservas.sql e scripts/raf_os_ponte.sql, no SQL Editor do Supabase (projeto Estoque).
-- Pode rodar de novo sem problema.
--
-- Mantém os nomes e parâmetros que a O.S. RAF usa:
--   raf_os_criar_requisicao_batch_v31(token, obra_id, obra_nome, itens jsonb, solicitante_nome, os, prefixo, modelo, observacao)
--     itens = [{ "code": "...", "desc": "...", "unit": "UN", "quantidade": 2 }, ...]   ("qty" também é aceito)
--   raf_os_consultar_requisicoes_bridge(token, os, prefixo)   (agora devolve itens_status, quantidade entregue e entregas)
--
-- Mesmas proteções da ponte de um item (raf_os_criar_requisicao_bridge_v2):
--   * token validado pelo hash da tabela raf_integracao (nada de token escrito no código);
--     para gerar/trocar:  select public.raf_gerar_token();  e atualizar na página da O.S. RAF;
--   * requisição nasce PENDENTE (passa pelo app de Aprovações);
--   * reserva de cada item só com saldo; requisição e todas as reservas na mesma transação (falta saldo em um item,
--     nada é gravado e a mensagem diz qual item);
--   * trava contra duplicidade por O.S. / prefixo / item, item repetido no mesmo pedido é recusado,
--     limites de tamanho, até 30 itens por pedido e 200 reservas por hora;
--   * requisição rejeitada/cancelada cancela as reservas (gatilho já criado em raf_os_ponte.sql).
-- Novo: o prefixo é ligado ao equipamento cadastrado em Aplicações (pela placa/tag), preenchendo aplicacao_id
-- — necessário para a Aplicação de Pneus e para o consumo por aplicação. Vale também para a ponte de um item.

-- 0) Remove as funções auxiliares da V6.31 original, se ela chegou a ser rodada (não exigiam token e ficavam
--    expostas pela API).
drop function if exists public.raf_os_reservar_um_v31(text, text, numeric, text);
drop function if exists public.raf_os_vincular_ids_v31(jsonb, bigint);

-- 1) Prefixo -> equipamento (Aplicações ficam no documento principal do Estoque, em app_kv).
--    Compara só letras e números ("CB-12" = "CB 12" = "cb12"). Devolve null se não achar ou se houver mais de um.
create or replace function public._raf_aplicacao_por_prefixo(p_prefixo text)
returns text language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_norm text := regexp_replace(upper(coalesce(p_prefixo, '')), '[^A-Z0-9]', '', 'g'); v_ids text[];
begin
  if v_norm = '' then return null; end if;
  select array_agg(distinct a->>'id') into v_ids
    from public.app_kv k, jsonb_array_elements(coalesce(k.value->'aplicacoes', '[]'::jsonb)) a
   where k.key = 'controle-estoque-obras-v1'
     and coalesce(a->>'id', '') <> ''
     and regexp_replace(upper(coalesce(a->>'tag', '')), '[^A-Z0-9]', '', 'g') = v_norm;
  if coalesce(array_length(v_ids, 1), 0) = 1 then return v_ids[1]; end if;
  return null;
end $$;
revoke all on function public._raf_aplicacao_por_prefixo(text) from public, anon, authenticated;

-- Gatilho: requisição vinda da O.S. RAF sem aplicacao_id recebe o equipamento do prefixo.
-- Nunca impede a gravação da requisição (falha vira só aviso no log).
create or replace function public._raf_req_aplicacao()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.aplicacao_id is null and coalesce(new.observacao, '') like 'Solicitação originada na O.S. RAF%' then
    begin
      new.aplicacao_id := public._raf_aplicacao_por_prefixo(split_part(coalesce(new.aplicacao_nome, ''), ' · ', 1));
    exception when others then
      raise warning '_raf_req_aplicacao: %', sqlerrm;
    end;
  end if;
  return new;
end $$;
revoke all on function public._raf_req_aplicacao() from public, anon, authenticated;
drop trigger if exists raf_req_aplicacao on public.requisicoes;
create trigger raf_req_aplicacao before insert on public.requisicoes
  for each row execute function public._raf_req_aplicacao();

-- 2) Pedido com vários itens
create or replace function public.raf_os_criar_requisicao_batch_v31(
  p_token text, p_obra_id text, p_obra_nome text, p_itens jsonb, p_solicitante_nome text,
  p_os text, p_prefixo text, p_modelo text default null, p_observacao text default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_el jsonb; v_code text; v_desc text; v_unit text; v_qty numeric;
  v_itens jsonb := '[]'::jsonb; v_codes text[] := '{}'; v_res_ids jsonb := '[]'::jsonb;
  v_req_id bigint; v_res_id bigint; v_uid uuid; v_aplicacao text; v_nome text; v_obs text; v_n int;
begin
  if not public._raf_token_ok(p_token) then raise exception 'Integração RAF não autorizada.' using errcode = 'P0001'; end if;

  p_obra_id := btrim(coalesce(p_obra_id, ''));          p_obra_nome := btrim(coalesce(p_obra_nome, ''));
  p_solicitante_nome := btrim(coalesce(p_solicitante_nome, ''));
  p_os := btrim(coalesce(p_os, ''));                    p_prefixo := upper(btrim(coalesce(p_prefixo, '')));
  p_modelo := btrim(coalesce(p_modelo, ''));            p_observacao := btrim(coalesce(p_observacao, ''));

  if p_obra_id = '' then raise exception 'Informe o estoque/obra.' using errcode = 'P0001'; end if;
  if p_solicitante_nome = '' then raise exception 'Informe o solicitante.' using errcode = 'P0001'; end if;
  if p_os = '' then raise exception 'Número da O.S. não informado.' using errcode = 'P0001'; end if;
  if p_prefixo = '' then raise exception 'Prefixo não informado.' using errcode = 'P0001'; end if;
  if length(p_obra_id) > 80 or length(p_solicitante_nome) > 120 or length(p_os) > 60 or length(p_prefixo) > 60
     or length(p_modelo) > 120 or length(p_observacao) > 1000 or length(p_obra_nome) > 200 then
    raise exception 'Algum campo passou do tamanho permitido.' using errcode = 'P0001';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Nenhum item informado.' using errcode = 'P0001'; end if;
  v_n := jsonb_array_length(p_itens);
  if v_n > 30 then raise exception 'No máximo 30 itens por pedido.' using errcode = 'P0001'; end if;

  -- valida e monta os itens (código repetido no mesmo pedido é recusado)
  for v_el in select value from jsonb_array_elements(p_itens) loop
    if jsonb_typeof(v_el) <> 'object' then raise exception 'Item inválido no carrinho.' using errcode = 'P0001'; end if;
    v_code := btrim(coalesce(v_el->>'code', ''));  v_desc := btrim(coalesce(v_el->>'desc', v_el->>'descricao', ''));
    v_unit := btrim(coalesce(v_el->>'unit', v_el->>'unidade', ''));
    begin v_qty := nullif(btrim(coalesce(v_el->>'quantidade', v_el->>'qty', '')), '')::numeric;
    exception when others then raise exception 'Quantidade inválida no item %.', v_code using errcode = 'P0001'; end;
    if v_code = '' or v_desc = '' then raise exception 'Item sem código ou descrição no carrinho.' using errcode = 'P0001'; end if;
    if length(v_code) > 60 or length(v_desc) > 300 or length(v_unit) > 20 then
      raise exception 'Item %: algum campo passou do tamanho permitido.', v_code using errcode = 'P0001'; end if;
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'Quantidade inválida no item %.', v_code using errcode = 'P0001'; end if;
    if v_code = any(v_codes) then raise exception 'Item % repetido no pedido — junte as quantidades numa linha só.', v_code using errcode = 'P0001'; end if;
    v_codes := v_codes || v_code;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('code', v_code, 'desc', v_desc, 'unit', v_unit, 'qty', v_qty));
  end loop;

  -- limite de volume (sem login, protege contra uso indevido em massa)
  if (select count(*) from public.raf_os_reservas where origem = 'raf_ponte' and criado_em > now() - interval '1 hour') + v_n > 200 then
    raise exception 'Muitas solicitações na última hora. Tente mais tarde ou fale com o almoxarifado.' using errcode = 'P0001';
  end if;

  -- duplicidade: trava cada O.S./prefixo/item (em ordem fixa, sem risco de travamento cruzado) e confere reserva ativa
  for v_code in select unnest(v_codes) order by 1 loop
    perform pg_advisory_xact_lock(hashtext('raf_ponte|' || p_os || '|' || p_prefixo || '|' || v_code));
    if exists (select 1 from public.raf_os_reservas
                where origem = 'raf_ponte' and status = 'ativa' and ordem_servico = p_os and prefixo = p_prefixo and code = v_code) then
      raise exception 'Já existe solicitação aberta do item % para O.S. % / %.', v_code, p_os, p_prefixo using errcode = 'P0001';
    end if;
  end loop;

  v_aplicacao := p_prefixo || case when p_modelo <> '' then ' · ' || p_modelo else '' end;
  v_nome := p_solicitante_nome || ' (O.S. RAF)';
  v_obs := concat_ws(' · ', 'Solicitação originada na O.S. RAF', 'Prefixo: ' || p_prefixo,
                     case when p_modelo <> '' then 'Modelo: ' || p_modelo end, nullif(p_observacao, ''));

  -- requisição PENDENTE (passa pela aprovação); aplicacao_id é preenchido pelo gatilho raf_req_aplicacao
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

  -- uma reserva por item, já ligada à requisição; sem saldo em qualquer item, desfaz tudo
  for v_el in select value from jsonb_array_elements(v_itens) loop
    begin
      v_res_id := public._raf_reservar_interno(p_obra_id, v_el->>'code', (v_el->>'qty')::numeric, p_os, v_req_id, null,
                                               v_nome, 'raf_ponte', p_prefixo);
    exception when sqlstate 'P0001' then
      raise exception 'Item % (%): %', v_el->>'code', v_el->>'desc', sqlerrm using errcode = 'P0001';
    end;
    v_res_ids := v_res_ids || jsonb_build_array(v_res_id::text);
  end loop;

  return jsonb_build_object(
    'ok', true,
    'requisicao_id', v_req_id,
    'requisicao', 'REQ-' || lpad(v_req_id::text, 5, '0'),
    'status', 'pendente',
    'itens', jsonb_array_length(v_itens),
    'reservas', jsonb_array_length(v_res_ids),
    'reserva_ids', v_res_ids);
end $$;

-- 3) Consulta para a O.S.: requisições da ponte com status, itens, quantidade separada/entregue e entregas.
--    Uma linha por requisição (pedido com vários itens tem várias reservas).
create or replace function public.raf_os_consultar_requisicoes_bridge(p_token text, p_os text, p_prefixo text default null)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if not public._raf_token_ok(p_token) then raise exception 'Integração RAF não autorizada.' using errcode = 'P0001'; end if;
  if coalesce(btrim(p_os), '') = '' then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'requisicao', 'REQ-' || lpad(q.id::text, 5, '0'), 'status', q.status, 'tipo_envio', q.tipo_envio,
      'obra_id', q.obra_id, 'obra_nome', q.obra_nome, 'solicitante_nome', q.solicitante_nome,
      'ordem_servico', q.ordem_servico, 'aplicacao_nome', q.aplicacao_nome, 'itens', q.itens, 'criado_em', q.criado_em,
      'atualizado_em', coalesce(to_jsonb(q)->>'atualizado_em', q.criado_em::text),
      'reserva_status', rs.reserva_status,
      'reservas', rs.reservas,
      'itens_status', coalesce((
        select jsonb_agg(jsonb_build_object(
          'code', s.code, 'descricao', s.descricao, 'unidade', s.unidade,
          'quantidade_solicitada', s.quantidade_solicitada, 'quantidade_separada', s.quantidade_separada,
          'quantidade_entregue', coalesce(nullif(to_jsonb(s)->>'quantidade_entregue', '')::numeric, 0),
          'status', s.status) order by s.id)
        from public.requisicao_itens_status s where s.requisicao_id = q.id), '[]'::jsonb),
      'entregas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'data_retirada', to_jsonb(t)->>'data_retirada',
          'colaborador_nome', to_jsonb(t)->>'colaborador_nome',
          'parcial', coalesce((to_jsonb(t)->>'parcial')::boolean, false),
          'itens', coalesce(to_jsonb(t)->'itens', '[]'::jsonb))
          order by to_jsonb(t)->>'data_retirada' nulls last)
        from public.retiradas_internas t where t.requisicao_id = q.id), '[]'::jsonb)
    ) order by q.criado_em desc)
    from (
      select r.requisicao_id::bigint as req_id,
             case when bool_or(r.status = 'ativa') then 'ativa' when bool_or(r.status = 'baixada') then 'baixada' else 'cancelada' end as reserva_status,
             jsonb_agg(jsonb_build_object('code', r.code, 'quantidade', r.quantidade, 'status', r.status) order by r.id) as reservas
        from public.raf_os_reservas r
       where r.origem = 'raf_ponte' and r.requisicao_id is not null
         and r.ordem_servico = btrim(p_os)
         and (coalesce(btrim(p_prefixo), '') = '' or r.prefixo = upper(btrim(p_prefixo)))
       group by r.requisicao_id
    ) rs
    join public.requisicoes q on q.id = rs.req_id
  ), '[]'::jsonb);
end $$;

revoke all on function public.raf_os_criar_requisicao_batch_v31(text, text, text, jsonb, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.raf_os_consultar_requisicoes_bridge(text, text, text) from public, anon, authenticated;
grant execute on function public.raf_os_criar_requisicao_batch_v31(text, text, text, jsonb, text, text, text, text, text) to anon, authenticated;
grant execute on function public.raf_os_consultar_requisicoes_bridge(text, text, text) to anon, authenticated;
