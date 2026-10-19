-- Gravação confiável com internet instável — rodar uma vez no SQL Editor do projeto Estoque.
-- Pode rodar de novo sem problema.
--
-- O sistema agora guarda cada alteração de saldo/lote numa fila no aparelho e só tira da fila quando o banco
-- confirma. Se a rede cai no meio, ele reenvia. O risco do reenvio é aplicar duas vezes (o pedido chegou ao
-- banco, mas a resposta se perdeu). Para isso cada envio leva um código único (p_op_id): o banco registra o
-- código em operacoes_aplicadas e, se o mesmo código chegar de novo, NÃO aplica outra vez — só responde que já
-- estava gravado. As movimentações (movimentos_estoque) já têm id próprio: o reenvio usa "on conflict do
-- nothing", então não precisam de função nova.
-- Sem este script o sistema continua funcionando como antes (sem reenvio automático de saldo/lote).

create table if not exists public.operacoes_aplicadas (
  op_id       text primary key,
  tipo        text not null,
  usuario_id  uuid default auth.uid(),
  aplicada_em timestamptz not null default now()
);
alter table public.operacoes_aplicadas enable row level security; -- só as funções abaixo mexem nela
create index if not exists operacoes_aplicadas_em_idx on public.operacoes_aplicadas (aplicada_em);

create or replace function public.ajustar_saldo_idem(p_op_id text, p_obra text, p_code text, p_delta numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_saldo numeric;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado.'; end if;
  if coalesce(p_op_id, '') = '' then raise exception 'Operação sem código.'; end if;
  insert into operacoes_aplicadas(op_id, tipo) values (p_op_id, 'saldo') on conflict (op_id) do nothing;
  if not found then
    select saldo into v_saldo from saldos_estoque where obra_id = p_obra and code = p_code;
    return jsonb_build_object('repetida', true, 'saldo', v_saldo);
  end if;
  v_saldo := public.ajustar_saldo(p_obra, p_code, p_delta);
  return jsonb_build_object('ok', true, 'saldo', v_saldo);
end $$;

create or replace function public.mover_lote_idem(p_op_id text, p_obra text, p_code text, p_lote text,
  p_validade date, p_fabricacao date, p_delta numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_saldo numeric;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado.'; end if;
  if coalesce(p_op_id, '') = '' then raise exception 'Operação sem código.'; end if;
  insert into operacoes_aplicadas(op_id, tipo) values (p_op_id, 'lote') on conflict (op_id) do nothing;
  if not found then return jsonb_build_object('repetida', true); end if;
  v_saldo := public.mover_lote(p_obra, p_code, p_lote, p_validade, p_fabricacao, p_delta);
  return jsonb_build_object('ok', true, 'saldo', v_saldo);
end $$;

revoke all on function public.ajustar_saldo_idem(text, text, text, numeric) from public, anon;
revoke all on function public.mover_lote_idem(text, text, text, text, date, date, numeric) from public, anon;
grant execute on function public.ajustar_saldo_idem(text, text, text, numeric) to authenticated;
grant execute on function public.mover_lote_idem(text, text, text, text, date, date, numeric) to authenticated;

-- Limpeza opcional (os códigos só importam por alguns dias, enquanto um aparelho pode reenviar):
-- delete from public.operacoes_aplicadas where aplicada_em < now() - interval '60 days';

-- Conferência: operações gravadas hoje, por tipo
-- select tipo, count(*) from public.operacoes_aplicadas where aplicada_em >= current_date group by tipo;
