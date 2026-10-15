-- Baixas enviadas ao Sienge: cada envio (planilha importada num movimento de Consumo do Sienge) e as baixas
-- que foram nele. Uma baixa só pode estar em UM envio ativo (índice único parcial em movimento_id where ativo).
-- Desfazer um envio não apaga nada: marca o envio como desfeito e os itens como inativos (fica o histórico).
-- Rodar uma vez no Supabase (SQL Editor). Pode rodar de novo sem problema.

create table if not exists public.sienge_envios (
  id                   bigint generated always as identity primary key,
  obra_id              text        not null,
  periodo_de           date,
  periodo_ate          date,
  documento_sienge     text        not null check (length(trim(documento_sienge)) > 0),
  com_marca            boolean     not null default false,
  linhas               integer     not null default 0,
  qtd_baixas           integer     not null default 0,
  criado_por           uuid        default auth.uid(),
  criado_por_nome      text,
  criado_em            timestamptz not null default now(),
  cancelado_em         timestamptz,
  cancelado_por_nome   text,
  motivo_cancelamento  text
);

create table if not exists public.sienge_envio_itens (
  movimento_id  text    not null,
  envio_id      bigint  not null references public.sienge_envios(id),
  ativo         boolean not null default true,
  primary key (envio_id, movimento_id)
);
create unique index if not exists sienge_envio_itens_um_ativo on public.sienge_envio_itens (movimento_id) where ativo;

alter table public.sienge_envios enable row level security;
alter table public.sienge_envio_itens enable row level security;

drop policy if exists "sienge_envios: leitura" on public.sienge_envios;
create policy "sienge_envios: leitura" on public.sienge_envios
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));
drop policy if exists "sienge_envio_itens: leitura" on public.sienge_envio_itens;
create policy "sienge_envio_itens: leitura" on public.sienge_envio_itens
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));
-- Sem INSERT/UPDATE/DELETE direto: só pelas funções abaixo (marcar tudo ou nada; desfazer com motivo).

-- Marca as baixas como enviadas. Recusa se alguma já estiver em outro envio ou não for baixa da obra.
create or replace function public.sienge_marcar_envio(
  p_obra text, p_de date, p_ate date, p_documento text, p_com_marca boolean, p_linhas integer, p_movimentos text[])
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_nome text; v_n integer; v_ja text;
begin
  select nome into v_nome from public.profiles p where p.id = auth.uid() and p.ativo
     and (p.papel = 'admin' or p.setor = 'almoxarifado');
  if not found then raise exception 'Sem permissão para marcar envio ao Sienge.' using errcode = 'P0001'; end if;
  if coalesce(trim(p_documento), '') = '' then raise exception 'Informe o nº do movimento no Sienge.' using errcode = 'P0001'; end if;
  p_movimentos := array(select distinct unnest(p_movimentos));
  v_n := coalesce(array_length(p_movimentos, 1), 0);
  if v_n = 0 then raise exception 'Nenhuma baixa para marcar.' using errcode = 'P0001'; end if;
  if (select count(*) from public.movimentos_estoque m
       where m.id = any(p_movimentos) and m.tipo = 'baixa' and m.obra::text = p_obra) <> v_n then
    raise exception 'Há movimentação que não é baixa desta obra (ou foi excluída). Gere de novo.' using errcode = 'P0001';
  end if;
  select string_agg(distinct e.documento_sienge, ', ') into v_ja
    from public.sienge_envio_itens i join public.sienge_envios e on e.id = i.envio_id
   where i.ativo and i.movimento_id = any(p_movimentos);
  if v_ja is not null then
    raise exception 'Parte destas baixas já foi enviada ao Sienge (%). Gere de novo.', v_ja using errcode = 'P0001';
  end if;
  insert into public.sienge_envios (obra_id, periodo_de, periodo_ate, documento_sienge, com_marca, linhas, qtd_baixas, criado_por_nome)
  values (p_obra, p_de, p_ate, trim(p_documento), coalesce(p_com_marca, false), coalesce(p_linhas, 0), v_n, v_nome)
  returning id into v_id;
  insert into public.sienge_envio_itens (movimento_id, envio_id) select unnest(p_movimentos), v_id;
  return v_id;
end $$;

-- Desfaz um envio (ex.: importação estornada no Sienge): as baixas voltam a ficar pendentes; tudo fica no histórico.
create or replace function public.sienge_desfazer_envio(p_envio bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  select nome into v_nome from public.profiles p where p.id = auth.uid() and p.ativo
     and (p.papel = 'admin' or (p.papel = 'encarregado' and p.setor = 'almoxarifado'));
  if not found then raise exception 'Só administrador ou encarregado do almoxarifado pode desfazer um envio.' using errcode = 'P0001'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo.' using errcode = 'P0001'; end if;
  update public.sienge_envios set cancelado_em = now(), cancelado_por_nome = v_nome, motivo_cancelamento = trim(p_motivo)
   where id = p_envio and cancelado_em is null;
  if not found then raise exception 'Envio não encontrado ou já desfeito.' using errcode = 'P0001'; end if;
  update public.sienge_envio_itens set ativo = false where envio_id = p_envio;
end $$;

revoke all on function public.sienge_marcar_envio(text, date, date, text, boolean, integer, text[]) from public, anon;
revoke all on function public.sienge_desfazer_envio(bigint, text) from public, anon;
grant execute on function public.sienge_marcar_envio(text, date, date, text, boolean, integer, text[]) to authenticated;
grant execute on function public.sienge_desfazer_envio(bigint, text) to authenticated;

-- Limpeza: tabela de uma primeira versão (nunca usada pelo app, vazia).
drop table if exists public.sienge_envio_baixas;
