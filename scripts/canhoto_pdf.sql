-- Canhoto do despacho em PDF: libera o bucket "comprovantes" para aceitar PDF (além da foto JPG)
-- e aumenta o limite por arquivo para 10 MB. Rodar uma vez no Supabase (SQL Editor) do projeto Estoque.
update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'application/pdf'],
       file_size_limit    = 10485760
 where id = 'comprovantes';

-- Conferência: deve mostrar {image/jpeg,application/pdf} e 10485760
select id, allowed_mime_types, file_size_limit from storage.buckets where id = 'comprovantes';
