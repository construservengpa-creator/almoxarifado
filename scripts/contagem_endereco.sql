-- Contagem: endereço do produto (ex.: "Corredor B, Prateleira 3") informado durante a contagem.
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.
--
-- O endereço fica no cadastro do produto (campo "endereco" do documento compartilhado app_kv), o mesmo
-- campo "Endereço" da tela de Produtos do sistema de estoque. A gravação segue a regra do save_estado_cas:
-- uma gravação por vez e a versão (_rev) sobe 1, então as abas abertas recebem só a diferença pelo tempo real.
-- No item fora da lista, o endereço fica no próprio registro (contagem_extras.endereco) e vai para o cadastro
-- quando o ajuste do inventário é lançado no estoque.

-- 1) leitura: endereço e localização de todos os produtos que têm um dos dois preenchido
create or replace function public.produtos_endereco()
returns table (code text, localizacao text, endereco text)
language sql stable security definer set search_path = public as $$
  select p->>'code', nullif(btrim(p->>'localizacao'), ''), nullif(btrim(p->>'endereco'), '')
    from app_kv, jsonb_array_elements(coalesce(value->'products', '[]'::jsonb)) p
   where key = 'controle-estoque-obras-v1'
     and exists (select 1 from profiles pr where pr.id = auth.uid() and pr.ativo)
     and (coalesce(btrim(p->>'localizacao'), '') <> '' or coalesce(btrim(p->>'endereco'), '') <> '')
$$;
grant execute on function public.produtos_endereco() to authenticated;

-- 2) gravação: define (ou apaga, se vazio) o endereço de um produto
create or replace function public.produto_definir_endereco(p_code text, p_endereco text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc jsonb; v_idx int; v_rev bigint;
  v_end text := nullif(btrim(coalesce(p_endereco, '')), '');
begin
  if not exists (select 1 from profiles pr where pr.id = auth.uid() and pr.ativo
                 and (pr.papel in ('admin', 'encarregado') or pr.setor = 'almoxarifado')) then
    raise exception 'Sem permissão para alterar o endereço do produto' using errcode = '42501';
  end if;
  if v_end is not null and length(v_end) > 80 then
    raise exception 'Endereço muito longo (máximo 80 caracteres)' using errcode = '22001';
  end if;

  perform pg_advisory_xact_lock(hashtext('app_kv:controle-estoque-obras-v1'));
  select value into v_doc from app_kv where key = 'controle-estoque-obras-v1' for update;
  if not found then raise exception 'Cadastro de produtos não encontrado' using errcode = 'P0002'; end if;

  select (t.i - 1)::int into v_idx
    from jsonb_array_elements(coalesce(v_doc->'products', '[]'::jsonb)) with ordinality t(p, i)
   where t.p->>'code' = p_code limit 1;
  if v_idx is null then raise exception 'Produto % não existe mais no cadastro', p_code using errcode = 'P0002'; end if;

  if coalesce(v_doc->'products'->v_idx->>'endereco', '') = coalesce(v_end, '') then
    return jsonb_build_object('ok', true, 'alterado', false);
  end if;

  v_rev := coalesce(nullif(v_doc->>'_rev', '')::bigint, 0) + 1;
  v_doc := jsonb_set(v_doc, array['products', v_idx::text, 'endereco'], to_jsonb(coalesce(v_end, '')), true);
  v_doc := jsonb_set(v_doc, '{_rev}', to_jsonb(v_rev), true);
  update app_kv set value = v_doc where key = 'controle-estoque-obras-v1';

  begin
    perform public.log_event('produto_endereco_contagem', 'produtos', p_code);
  exception when others then null;   -- auditoria nunca impede a gravação
  end;
  return jsonb_build_object('ok', true, 'alterado', true, 'rev', v_rev);
end $$;
grant execute on function public.produto_definir_endereco(text, text) to authenticated;

-- 3) item fora da lista: endereço informado na contagem
alter table public.contagem_extras add column if not exists endereco text;

-- Conferência
select count(*) as produtos_com_endereco from public.produtos_endereco();
