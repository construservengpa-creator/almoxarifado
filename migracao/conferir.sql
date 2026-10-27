-- Rode no projeto ANTIGO e no NOVO e compare: as quantidades têm de ser iguais.
select tabela, linhas from (
  select 'auth.users' tabela, count(*) linhas from auth.users
  union all select 'storage.objects (' || bucket_id || ')', count(*) from storage.objects group by bucket_id
  union all select 'publicação do tempo real', count(*) from pg_publication_tables where pubname = 'supabase_realtime'
  union all
  select 'public.' || tablename,
         (xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I', tablename), false, true, '')))[1]::text::bigint
    from pg_tables where schemaname = 'public'
) s order by 1;
