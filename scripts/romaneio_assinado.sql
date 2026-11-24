-- Romaneio de transferência assinado (foto ou PDF anexado à transferência entre obras)
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.
-- O arquivo fica no armazenamento "comprovantes" (pasta transferencias/), o mesmo do canhoto do despacho.
-- Depois de anexado, o registro não pode ser alterado; só o administrador pode excluir (anexo errado).

create table if not exists public.romaneio_anexos (
  id                bigint generated always as identity primary key,
  romaneio_id       text        not null,
  seq               integer,
  obra_origem       text,
  obra_destino      text,
  path              text        not null unique,
  nome_arquivo      text,
  hash              text,
  enviado_por       uuid        not null default auth.uid(),
  enviado_por_nome  text,
  enviado_em        timestamptz not null default now()
);

create index if not exists romaneio_anexos_romaneio_idx on public.romaneio_anexos (romaneio_id);

alter table public.romaneio_anexos enable row level security;

-- Leitura: qualquer usuário ativo
drop policy if exists "romaneio_anexos: leitura" on public.romaneio_anexos;
create policy "romaneio_anexos: leitura" on public.romaneio_anexos
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo));

-- Anexar: administrador, encarregado e almoxarifado (mesma regra do envio ao bucket "comprovantes")
drop policy if exists "romaneio_anexos: anexar" on public.romaneio_anexos;
create policy "romaneio_anexos: anexar" on public.romaneio_anexos
  for insert to authenticated
  with check (
    enviado_por = auth.uid()
    and path like 'transferencias/%'
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo
                and (p.papel in ('admin','encarregado') or p.setor = 'almoxarifado'))
  );

-- Excluir: só administrador (o arquivo continua guardado no armazenamento)
drop policy if exists "romaneio_anexos: excluir" on public.romaneio_anexos;
create policy "romaneio_anexos: excluir" on public.romaneio_anexos
  for delete to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ativo and p.papel = 'admin'));

-- Sem regra de alteração: o anexo não pode ser trocado depois de enviado.

-- Garante que o bucket aceita foto e PDF (já vale se o script canhoto_pdf.sql foi rodado)
update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'application/pdf'],
       file_size_limit    = 10485760
 where id = 'comprovantes';

-- Conferência
select count(*) as anexos from public.romaneio_anexos;
