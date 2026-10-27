-- Partes que o dump do banco NÃO leva (ou que a documentação do Supabase manda refazer à mão)
-- Rode no projeto NOVO depois de 2-subir-banco.sh. Pode rodar de novo.

-- 1) Gatilho que cria o perfil (public.profiles) quando um usuário é cadastrado
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) Pastas de arquivos (buckets) com as mesmas regras do projeto antigo
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('produtos', 'produtos', true, 122880, array['image/jpeg']),
  ('comprovantes', 'comprovantes', false, 10485760, array['image/jpeg', 'application/pdf'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 3) Permissões dos arquivos
drop policy if exists "comprovantes: leitura" on storage.objects;
create policy "comprovantes: leitura" on storage.objects as permissive for select to authenticated
  using (bucket_id = 'comprovantes' and exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));
drop policy if exists "comprovantes: envio" on storage.objects;
create policy "comprovantes: envio" on storage.objects as permissive for insert to authenticated
  with check (bucket_id = 'comprovantes' and exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo
    and (p.papel = any (array['admin', 'encarregado']) or p.setor = 'almoxarifado')));
drop policy if exists "produtos: envio" on storage.objects;
create policy "produtos: envio" on storage.objects as permissive for insert to authenticated
  with check (bucket_id = 'produtos' and public.prod_pode_editar());
drop policy if exists "produtos: exclusao" on storage.objects;
create policy "produtos: exclusao" on storage.objects as permissive for delete to authenticated
  using (bucket_id = 'produtos' and public.prod_pode_editar());

-- 4) Tempo real: as mesmas tabelas do projeto antigo
do $$
declare t text;
begin
  foreach t in array array['app_kv_patches', 'lotes_estoque', 'movimentos_estoque', 'reposicoes_estoque',
                           'requisicao_itens_status', 'requisicoes', 'saldos_estoque'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
