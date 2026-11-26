-- Reservas de material feitas dentro da O.S. RAF.
-- Enquanto a reserva está 'ativa', o Estoque desconta a quantidade do SALDO DISPONÍVEL (aprovação de requisição,
-- saída, transferência, telas). Inventário, ajuste, custo médio e valorização NÃO descontam: o material continua
-- fisicamente no almoxarifado.
--
-- Ciclo de vida:
--   ativa     -> criada pela O.S. (raf_reservar)
--   baixada   -> automático quando a requisição ligada à reserva vira 'separado' (o material saiu do estoque)
--   cancelada -> pela O.S. ou pelo almoxarifado (raf_cancelar_reserva), com motivo
-- Se a requisição ligada for cancelada ou rejeitada, a reserva continua ativa para a O.S., só perde o vínculo.
--
-- Rodar uma vez no Supabase (SQL Editor). Pode rodar de novo sem problema.

create table if not exists public.raf_os_reservas (
  id                   bigint generated always as identity primary key,
  obra_id              text          not null,
  code                 text          not null,
  quantidade           numeric(14,4) not null check (quantidade > 0),
  status               text          not null default 'ativa' check (status in ('ativa','baixada','cancelada')),
  ordem_servico        text,
  requisicao_id        bigint,
  observacao           text,
  criado_por           uuid          default auth.uid(),
  criado_por_nome      text,
  criado_em            timestamptz   not null default now(),
  baixado_em           timestamptz,
  cancelado_em         timestamptz,
  cancelado_por_nome   text,
  motivo_cancelamento  text
);
create index if not exists raf_os_reservas_ativas on public.raf_os_reservas (obra_id, code) where status = 'ativa';
create index if not exists raf_os_reservas_req on public.raf_os_reservas (requisicao_id) where requisicao_id is not null;

alter table public.raf_os_reservas enable row level security;

drop policy if exists "raf_os_reservas: leitura" on public.raf_os_reservas;
create policy "raf_os_reservas: leitura" on public.raf_os_reservas
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));
-- Sem INSERT/UPDATE/DELETE direto: só pelas funções abaixo.

-- Cria uma reserva. Recusa se a quantidade passar do saldo menos as reservas já ativas do mesmo item na obra.
create or replace function public.raf_reservar(
  p_obra text, p_code text, p_quantidade numeric, p_ordem_servico text default null,
  p_requisicao_id bigint default null, p_observacao text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_nome text; v_saldo numeric; v_reservado numeric;
begin
  select nome into v_nome from public.profiles p where p.id = auth.uid() and p.ativo;
  if not found then raise exception 'Sem permissão para reservar material.' using errcode = 'P0001'; end if;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe uma quantidade maior que zero.' using errcode = 'P0001'; end if;
  -- trava o saldo do item: duas reservas ao mesmo tempo não passam do disponível
  select saldo into v_saldo from public.saldos_estoque where obra_id = p_obra and code = p_code for update;
  select coalesce(sum(quantidade), 0) into v_reservado from public.raf_os_reservas
   where obra_id = p_obra and code = p_code and status = 'ativa';
  if coalesce(v_saldo, 0) - v_reservado < p_quantidade then
    raise exception 'Saldo insuficiente para reservar: disponível %.', greatest(coalesce(v_saldo, 0) - v_reservado, 0)
      using errcode = 'P0001';
  end if;
  insert into public.raf_os_reservas (obra_id, code, quantidade, ordem_servico, requisicao_id, observacao, criado_por_nome)
  values (p_obra, p_code, p_quantidade, nullif(trim(p_ordem_servico), ''), p_requisicao_id, nullif(trim(p_observacao), ''), v_nome)
  returning id into v_id;
  return v_id;
end $$;

-- Liga reservas já feitas à requisição gerada pela O.S. (para a aprovação não se bloquear com a própria reserva
-- e para a baixa automática na separação).
create or replace function public.raf_vincular_requisicao(p_reservas bigint[], p_requisicao_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo) then
    raise exception 'Sem permissão.' using errcode = 'P0001';
  end if;
  update public.raf_os_reservas set requisicao_id = p_requisicao_id
   where id = any(p_reservas) and status = 'ativa';
end $$;

-- Cancela uma reserva ativa: quem criou, administrador ou almoxarifado.
create or replace function public.raf_cancelar_reserva(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  select nome into v_nome from public.profiles p where p.id = auth.uid() and p.ativo;
  if not found then raise exception 'Sem permissão.' using errcode = 'P0001'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo.' using errcode = 'P0001'; end if;
  update public.raf_os_reservas r
     set status = 'cancelada', cancelado_em = now(), cancelado_por_nome = v_nome, motivo_cancelamento = trim(p_motivo)
   where r.id = p_id and r.status = 'ativa'
     and (r.criado_por = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo
                                                 and (p.papel = 'admin' or p.setor = 'almoxarifado')));
  if not found then raise exception 'Reserva não encontrada, já encerrada ou sem permissão para cancelar.' using errcode = 'P0001'; end if;
end $$;

revoke all on function public.raf_reservar(text, text, numeric, text, bigint, text) from public, anon;
revoke all on function public.raf_vincular_requisicao(bigint[], bigint) from public, anon;
revoke all on function public.raf_cancelar_reserva(bigint, text) from public, anon;
grant execute on function public.raf_reservar(text, text, numeric, text, bigint, text) to authenticated;
grant execute on function public.raf_vincular_requisicao(bigint[], bigint) to authenticated;
grant execute on function public.raf_cancelar_reserva(bigint, text) to authenticated;

-- Baixa automática: requisição 'separado' encerra as reservas ligadas a ela (o material já saiu do saldo),
-- evitando desconto em dobro. Requisição cancelada/rejeitada: a reserva continua da O.S., sem vínculo.
-- Uma falha aqui NUNCA impede a mudança de status da requisição (só gera aviso no log).
create or replace function public.raf_reservas_por_requisicao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    begin
      if new.status = 'separado' then
        update public.raf_os_reservas set status = 'baixada', baixado_em = now()
         where requisicao_id::text = new.id::text and status = 'ativa';
      elsif new.status in ('cancelada', 'rejeitada') then
        update public.raf_os_reservas set requisicao_id = null
         where requisicao_id::text = new.id::text and status = 'ativa';
      end if;
    exception when others then
      raise warning 'raf_reservas_por_requisicao: %', sqlerrm;
    end;
  end if;
  return new;
end $$;

drop trigger if exists raf_reservas_por_requisicao on public.requisicoes;
create trigger raf_reservas_por_requisicao
  after update of status on public.requisicoes
  for each row execute function public.raf_reservas_por_requisicao();

-- Tempo real: o Estoque atualiza o saldo disponível assim que uma reserva muda.
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'raf_os_reservas') then
    alter publication supabase_realtime add table public.raf_os_reservas;
  end if;
end $$;
