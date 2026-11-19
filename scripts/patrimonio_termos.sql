-- Termo de entrega de bem patrimonial (entrega física com comprovação eletrônica)
--   Assinatura na tela, confirmação pelo login de quem recebe, ou termo em papel assinado e digitalizado.
--   O documento assinado (PDF ou foto) fica guardado no armazenamento "comprovantes", pasta patrimonio/.
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.
-- Depois de assinado, o termo não pode ser alterado nem apagado; o arquivo guardado também não.

-- 1) Tabela dos termos (leitura só para quem opera o patrimônio e para o próprio recebedor; gravação só pelas funções abaixo)
create table if not exists public.pat_termos (
  id bigserial primary key,
  numero text generated always as ('TE-' || lpad(id::text, 6, '0')) stored,
  criado_em timestamptz not null default now(),
  criado_por uuid not null default auth.uid(),
  criado_por_nome text,
  empresa_nome text,
  empresa_cnpj text,
  obra_id text,
  obra_nome text,
  setor text,
  recebedor_nome text not null,
  recebedor_doc text,
  recebedor_cargo text,
  recebedor_id uuid,
  itens jsonb not null default '[]'::jsonb,
  obs text,
  tipo text not null check (tipo in ('assinatura','login','papel')),
  assinatura text,
  assinado_em timestamptz,
  assinado_por uuid,
  assinado_por_nome text,
  arquivo_path text,
  arquivo_hash text,
  arquivo_em timestamptz,
  cancelado_em timestamptz,
  cancelado_por_nome text,
  cancelado_motivo text
);
create index if not exists pat_termos_recebedor_idx on public.pat_termos (recebedor_id) where assinado_em is null and cancelado_em is null;
alter table public.pat_termos enable row level security;
revoke insert, update, delete on public.pat_termos from anon, authenticated;
grant select on public.pat_termos to authenticated;

create or replace function public.pat_opera()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p where p.id = auth.uid() and p.ativo
                 and (p.papel in ('admin','encarregado') or p.setor = 'almoxarifado'));
$$;

drop policy if exists "pat_termos: leitura" on public.pat_termos;
create policy "pat_termos: leitura" on public.pat_termos for select to authenticated
  using (public.pat_opera() or recebedor_id = auth.uid());

-- 2) Arquivo dos documentos assinados: mesma pasta privada dos comprovantes de entrega (JPEG e PDF).
--    Pasta patrimonio/: qualquer usuário ativo pode enviar (o recebedor que confirma pelo login gera o PDF),
--    mas só a função pat_termo_anexar liga o arquivo ao termo, e só uma vez. Não há regra de troca nem de exclusão.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 10485760, array['image/jpeg','application/pdf'])
on conflict (id) do nothing;

drop policy if exists "comprovantes: patrimonio leitura" on storage.objects;
create policy "comprovantes: patrimonio leitura" on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes' and name like 'patrimonio/%'
         and exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));

drop policy if exists "comprovantes: patrimonio envio" on storage.objects;
create policy "comprovantes: patrimonio envio" on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes' and name like 'patrimonio/%'
              and exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));

-- 3) Usuários ativos (para escolher quem vai confirmar pelo login)
create or replace function public.pat_termo_usuarios()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', coalesce(nullif(btrim(p.nome), ''), p.email))
                            order by coalesce(nullif(btrim(p.nome), ''), p.email)), '[]'::jsonb)
  from profiles p
  where p.ativo and exists (select 1 from profiles me where me.id = auth.uid() and me.ativo);
$$;

-- 4) Registrar a entrega (cria o termo). Assinatura na tela já sai assinada; login e papel ficam aguardando.
create or replace function public.pat_termo_criar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_eu text; v_tipo text := p->>'tipo'; v_rec uuid; v_nome text; v_id bigint; v_num text;
begin
  select coalesce(nullif(btrim(nome), ''), email) into v_eu from profiles
    where id = auth.uid() and ativo and (papel in ('admin','encarregado') or setor = 'almoxarifado');
  if not found then raise exception 'Seu usuário não tem permissão para registrar entrega de patrimônio.'; end if;
  if coalesce(btrim(p->>'recebedor_nome'), '') = '' and v_tipo <> 'login' then raise exception 'Informe quem está recebendo.'; end if;
  if jsonb_typeof(p->'itens') is distinct from 'array' or jsonb_array_length(p->'itens') = 0 then raise exception 'Nenhum bem no termo.'; end if;
  if v_tipo = 'assinatura' then
    if coalesce(length(p->>'assinatura'), 0) < 30 then raise exception 'Assinatura em branco.'; end if;
    if length(p->>'assinatura') > 60000 then raise exception 'Assinatura grande demais — limpe e assine de novo.'; end if;
  elsif v_tipo = 'login' then
    v_rec := nullif(p->>'recebedor_id', '')::uuid;
    if v_rec is null then raise exception 'Escolha o usuário que vai confirmar o recebimento.'; end if;
    if v_rec = auth.uid() then raise exception 'Quem registra a entrega não pode ser quem confirma o recebimento. Use a assinatura na tela.'; end if;
    select coalesce(nullif(btrim(nome), ''), email) into v_nome from profiles where id = v_rec and ativo;
    if not found then raise exception 'Usuário do recebedor não encontrado ou inativo.'; end if;
  elsif v_tipo <> 'papel' then raise exception 'Tipo de comprovação inválido.';
  end if;
  insert into pat_termos (criado_por, criado_por_nome, empresa_nome, empresa_cnpj, obra_id, obra_nome, setor,
      recebedor_nome, recebedor_doc, recebedor_cargo, recebedor_id, itens, obs, tipo, assinatura, assinado_em, assinado_por, assinado_por_nome)
    values (auth.uid(), v_eu, p->>'empresa_nome', p->>'empresa_cnpj', p->>'obra_id', p->>'obra_nome', p->>'setor',
      coalesce(nullif(btrim(p->>'recebedor_nome'), ''), v_nome), p->>'recebedor_doc', p->>'recebedor_cargo', v_rec, p->'itens', p->>'obs', v_tipo,
      case when v_tipo = 'assinatura' then p->>'assinatura' end,
      case when v_tipo = 'assinatura' then now() end,
      case when v_tipo = 'assinatura' then auth.uid() end,
      case when v_tipo = 'assinatura' then v_eu end)
    returning id, numero into v_id, v_num;
  return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num);
end $$;

-- 5) O recebedor confirma com o próprio login
create or replace function public.pat_termo_confirmar(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t record; v_eu text;
begin
  select coalesce(nullif(btrim(nome), ''), email) into v_eu from profiles where id = auth.uid() and ativo;
  if not found then raise exception 'Usuário inativo.'; end if;
  select * into v_t from pat_termos where id = p_id for update;
  if not found or v_t.cancelado_em is not null then raise exception 'Termo não encontrado ou cancelado pelo almoxarifado.'; end if;
  if v_t.tipo <> 'login' or v_t.recebedor_id is distinct from auth.uid() then raise exception 'Este termo não está aguardando a sua confirmação.'; end if;
  if v_t.assinado_em is not null then return jsonb_build_object('ok', true, 'ja', true); end if;
  update pat_termos set assinado_em = now(), assinado_por = auth.uid(), assinado_por_nome = v_eu where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 6) Liga o documento guardado ao termo (uma vez só). Termo em papel: o arquivo é a própria comprovação.
create or replace function public.pat_termo_anexar(p_id bigint, p_path text, p_hash text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t record; v_eu text; v_op boolean := public.pat_opera();
begin
  select coalesce(nullif(btrim(nome), ''), email) into v_eu from profiles where id = auth.uid() and ativo;
  if not found then raise exception 'Usuário inativo.'; end if;
  select * into v_t from pat_termos where id = p_id for update;
  if not found or v_t.cancelado_em is not null then raise exception 'Termo não encontrado ou cancelado.'; end if;
  if v_t.arquivo_path is not null then raise exception 'Este termo já tem o documento assinado guardado.'; end if;
  if p_path is null or p_path not like 'patrimonio/%' then raise exception 'Arquivo inválido.'; end if;
  if v_t.tipo = 'papel' then
    if not v_op then raise exception 'Só o almoxarifado anexa o termo em papel.'; end if;
    update pat_termos set arquivo_path = p_path, arquivo_hash = p_hash, arquivo_em = now(),
        assinado_em = now(), assinado_por = auth.uid(), assinado_por_nome = v_eu where id = p_id;
  else
    if v_t.assinado_em is null then raise exception 'O termo ainda não foi assinado.'; end if;
    if not (v_op or v_t.recebedor_id = auth.uid()) then raise exception 'Sem permissão para guardar este documento.'; end if;
    update pat_termos set arquivo_path = p_path, arquivo_hash = p_hash, arquivo_em = now() where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 7) Cancelar um termo que ainda não foi assinado (entrega registrada por engano)
create or replace function public.pat_termo_cancelar(p_id bigint, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t record; v_eu text;
begin
  select coalesce(nullif(btrim(nome), ''), email) into v_eu from profiles
    where id = auth.uid() and ativo and (papel in ('admin','encarregado') or setor = 'almoxarifado');
  if not found then raise exception 'Sem permissão.'; end if;
  select * into v_t from pat_termos where id = p_id for update;
  if not found then raise exception 'Termo não encontrado.'; end if;
  if v_t.assinado_em is not null then raise exception 'Termo já assinado não pode ser cancelado.'; end if;
  update pat_termos set cancelado_em = now(), cancelado_por_nome = v_eu, cancelado_motivo = p_motivo where id = p_id and cancelado_em is null;
  return jsonb_build_object('ok', true);
end $$;

-- 8) Termos aguardando a minha confirmação
create or replace function public.pat_termo_pendencias()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t) - 'assinatura' order by t.criado_em), '[]'::jsonb)
  from pat_termos t
  where t.tipo = 'login' and t.recebedor_id = auth.uid() and t.assinado_em is null and t.cancelado_em is null;
$$;

grant execute on function public.pat_opera() to authenticated;
grant execute on function public.pat_termo_usuarios() to authenticated;
grant execute on function public.pat_termo_criar(jsonb) to authenticated;
grant execute on function public.pat_termo_confirmar(bigint) to authenticated;
grant execute on function public.pat_termo_anexar(bigint, text, text) to authenticated;
grant execute on function public.pat_termo_cancelar(bigint, text) to authenticated;
grant execute on function public.pat_termo_pendencias() to authenticated;
notify pgrst, 'reload schema';
