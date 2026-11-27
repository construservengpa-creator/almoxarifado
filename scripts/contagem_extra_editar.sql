-- Contagem: editar um item fora da lista já enviado, enquanto ele ainda aguarda a análise do encarregado.
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.
--
-- O contador (ou admin/encarregado) pode corrigir descrição, código lido, unidade, endereço e observação.
-- A QUANTIDADE NÃO É EDITÁVEL: continua a que foi contada. Depois de aprovado, rejeitado ou lançado,
-- o registro não muda mais.

alter table public.contagem_extras add column if not exists endereco text;

create or replace function public.contagem_extra_editar(
  p_id text, p_descricao text, p_code_lido text, p_unidade text, p_obs text, p_endereco text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_desc text := btrim(coalesce(p_descricao, ''));
  v_n int;
begin
  if length(v_desc) < 3 or length(v_desc) > 120 then
    raise exception 'Descrição inválida (de 3 a 120 caracteres)' using errcode = '22023';
  end if;
  update contagem_extras x
     set descricao = v_desc,
         code_lido = nullif(left(btrim(coalesce(p_code_lido, '')), 60), ''),
         unidade   = coalesce(nullif(upper(left(btrim(coalesce(p_unidade, '')), 10)), ''), 'UN'),
         obs       = nullif(left(btrim(coalesce(p_obs, '')), 200), ''),
         endereco  = case when p_endereco is null then x.endereco else nullif(left(btrim(p_endereco), 80), '') end
   where x.id::text = p_id
     and x.status = 'pendente'
     and exists (select 1 from profiles pr where pr.id = auth.uid() and pr.ativo
                 and (x.contador = auth.uid() or pr.papel in ('admin', 'encarregado')));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Este item já foi analisado pelo encarregado ou você não tem permissão para editá-lo' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.contagem_extra_editar(text, text, text, text, text, text) to authenticated;
