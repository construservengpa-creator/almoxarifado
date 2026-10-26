-- Documento principal (app_kv): tempo real e abertura do app só com o que mudou.
-- O documento tem perto de 1 MB. Cada gravação mandava o documento inteiro pelo tempo real a todas as abas
-- conectadas, e cada abertura do app o baixava inteiro — o que estourou a cota de tráfego (egress) do Supabase.
-- Agora cada gravação gera em app_kv_patches só a diferença (app_kv_diff), e é esta tabela, não app_kv, que vai
-- pelo tempo real. O app aplica as diferenças em ordem (_rev); se faltar alguma, baixa o documento inteiro.
--
-- Formato da diferença (o app aplica com aplicarPatchDoc):
--   set    : chaves do topo trocadas inteiras            del : chaves do topo removidas
--   objs   : objetos do topo, um nível abaixo  {set, del}
--   listas : listas de objetos com id/código   {up: itens novos ou alterados, del: chaves removidas, ordem?}
-- Nunca impede a gravação: se algo falhar aqui, grava {"completo": true} e o app baixa o documento inteiro.
-- Pode rodar de novo.

create table if not exists public.app_kv_patches (
  id        bigint generated always as identity primary key,
  key       text not null,
  base_rev  bigint not null,
  rev       bigint not null,
  patch     jsonb not null,
  criado_em timestamptz not null default now()
);
create index if not exists app_kv_patches_key_rev on public.app_kv_patches (key, rev);

-- mesma regra de leitura de app_kv
alter table public.app_kv_patches enable row level security;
do $$
declare p record; comando text;
begin
  for p in select * from pg_policies where schemaname = 'public' and tablename = 'app_kv' and pg_policies.cmd in ('SELECT', 'ALL') loop
    execute format('drop policy if exists %I on public.app_kv_patches', p.policyname);
    comando := format('create policy %I on public.app_kv_patches as %s for select to %s', p.policyname, p.permissive,
                  (select string_agg(case when r = 'public' then 'public' else quote_ident(r) end, ', ') from unnest(p.roles) r));
    if p.qual is not null then comando := comando || ' using (' || p.qual || ')'; end if;
    execute comando;
  end loop;
end $$;
grant select on public.app_kv_patches to authenticated;

-- chave de um item de lista (igual a _chaveItem do app): id, senão code
create or replace function public.app_kv_chave_item(x jsonb) returns text
language sql immutable set search_path to 'public' as $$
  select case when jsonb_typeof(x) <> 'object' then null
              when x ? 'id' and jsonb_typeof(x->'id') <> 'null' then 'id:' || (x->>'id')
              when x ? 'code' and jsonb_typeof(x->'code') <> 'null' then 'code:' || (x->>'code')
         end
$$;

-- lista em que todo item tem chave e nenhuma chave se repete
create or replace function public.app_kv_lista_chaveada(a jsonb) returns boolean
language sql immutable set search_path to 'public' as $$
  select coalesce(bool_and(c is not null) and count(distinct c) = count(*), true)
    from (select public.app_kv_chave_item(e) c from jsonb_array_elements(a) e) s
$$;

create or replace function public.app_kv_diff_lista(o jsonb, n jsonb) returns jsonb
language sql immutable set search_path to 'public' as $$
  with ov as (select public.app_kv_chave_item(e) c, e, i from jsonb_array_elements(o) with ordinality t(e, i)),
       nv as (select public.app_kv_chave_item(e) c, e, i from jsonb_array_elements(n) with ordinality t(e, i)),
       -- ordem que o app obtém aplicando up/del: os que ficam, na ordem antiga, e os novos no fim
       esperada as (
         select c, row_number() over (order by grupo, i) pos from (
           select c, 1 grupo, i from ov where c in (select c from nv)
           union all
           select c, 2 grupo, i from nv where c not in (select c from ov)) s),
       real as (select c, row_number() over (order by i) pos from nv)
  select jsonb_build_object(
    'up',  coalesce((select jsonb_agg(nv.e order by nv.i) from nv left join ov on ov.c = nv.c where ov.e is distinct from nv.e), '[]'::jsonb),
    'del', coalesce((select jsonb_agg(ov.c order by ov.i) from ov where ov.c not in (select c from nv)), '[]'::jsonb))
    || case when exists (select 1 from esperada e join real r on r.c = e.c where r.pos <> e.pos)
            then jsonb_build_object('ordem', (select jsonb_agg(c order by i) from nv))
            else '{}'::jsonb end
$$;

create or replace function public.app_kv_diff(o jsonb, n jsonb) returns jsonb
language plpgsql immutable set search_path to 'public' as $$
declare
  k text; ov jsonb; nv jsonb;
  sets jsonb := '{}'; dels jsonb := '[]'; objs jsonb := '{}'; listas jsonb := '{}';
  sub text; oset jsonb; odel jsonb;
begin
  for k in select jsonb_object_keys(o) union select jsonb_object_keys(n) loop
    continue when k = '_rev';
    ov := o -> k; nv := n -> k;
    if nv is null then dels := dels || to_jsonb(k); continue; end if;
    continue when ov is not distinct from nv;
    if ov is not null and jsonb_typeof(ov) = 'array' and jsonb_typeof(nv) = 'array'
       and public.app_kv_lista_chaveada(ov) and public.app_kv_lista_chaveada(nv) then
      listas := listas || jsonb_build_object(k, public.app_kv_diff_lista(ov, nv));
    elsif ov is not null and jsonb_typeof(ov) = 'object' and jsonb_typeof(nv) = 'object' then
      oset := '{}'; odel := '[]';
      for sub in select jsonb_object_keys(ov) union select jsonb_object_keys(nv) loop
        if not nv ? sub then odel := odel || to_jsonb(sub);
        elsif (ov -> sub) is distinct from (nv -> sub) then oset := oset || jsonb_build_object(sub, nv -> sub); end if;
      end loop;
      objs := objs || jsonb_build_object(k, jsonb_build_object('set', oset, 'del', odel));
    else
      sets := sets || jsonb_build_object(k, nv);
    end if;
  end loop;
  return jsonb_build_object('set', sets, 'del', dels, 'objs', objs, 'listas', listas);
end $$;

create or replace function public.app_kv_gerar_patch() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare p jsonb;
begin
  begin
    p := public.app_kv_diff(coalesce(old.value, '{}'::jsonb), new.value);
  exception when others then
    p := jsonb_build_object('completo', true);
  end;
  insert into public.app_kv_patches (key, base_rev, rev, patch)
    values (new.key, coalesce(nullif(old.value ->> '_rev', '')::bigint, 0), coalesce(nullif(new.value ->> '_rev', '')::bigint, 0), p);
  delete from public.app_kv_patches where criado_em < now() - interval '3 days';
  return null;
exception when others then
  return null;   -- nunca impede a gravação do documento
end $$;

drop trigger if exists app_kv_patch on public.app_kv;
create trigger app_kv_patch after update on public.app_kv
  for each row when (old.value is distinct from new.value) execute function public.app_kv_gerar_patch();

-- tempo real: a diferença (pequena) no lugar do documento inteiro
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'app_kv_patches') then
    alter publication supabase_realtime add table public.app_kv_patches;
  end if;
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'app_kv') then
    alter publication supabase_realtime drop table public.app_kv;
  end if;
end $$;
