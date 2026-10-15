-- Gravação com conferência de versão do documento compartilhado (app_kv) — rodar uma vez no SQL Editor
-- do projeto Estoque. Pode rodar de novo sem problema.
--
-- O sistema passa a mandar junto a versão (_rev) que ele conhece. Se outra pessoa gravou antes, esta função
-- NÃO grava e devolve {conflito:true}; o sistema então busca a versão atual, junta as alterações e tenta de novo.
-- A gravação em si continua sendo feita pela save_estado (mesmas permissões e mesmo registro na auditoria).
-- Sem esta função o sistema também confere a versão antes de gravar, mas com uma pequena janela de corrida.

create or replace function public.save_estado_cas(p_key text, p_value jsonb, p_label text, p_base_rev bigint)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare v_rev bigint;
begin
  -- uma gravação por vez para a mesma chave (o lock vale até o fim da transação)
  perform pg_advisory_xact_lock(hashtext('app_kv:' || p_key));
  select coalesce(nullif(value->>'_rev', '')::bigint, 0) into v_rev from app_kv where key = p_key;
  if found and v_rev <> coalesce(p_base_rev, 0) then
    return jsonb_build_object('conflito', true, 'rev', v_rev);
  end if;
  perform public.save_estado(p_key, p_value, p_label);
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.save_estado_cas(text, jsonb, text, bigint) to authenticated;
