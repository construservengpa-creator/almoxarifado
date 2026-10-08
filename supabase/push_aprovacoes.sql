-- Notificação push do app Aprovações: avisa no celular toda vez que uma requisição entra em "pendente".
-- Rodar uma vez no Supabase (SQL Editor) do projeto Estoque. Pode rodar de novo sem problema.
--
-- Antes, publique a Edge Function supabase/functions/notificar-aprovacao (com "Verify JWT" desligado — ela
-- confere tudo sozinha) e cadastre os segredos VAPID_PUBLIC_KEY e VAPID_PRIVATE_KEY (gerados com
-- `npx web-push generate-vapid-keys`). Passo a passo completo em supabase/README.md.

-- 1) Celulares inscritos (um registro por aparelho/navegador)
create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  user_agent text,
  criado_em  timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subscriptions_proprias on public.push_subscriptions;
create policy push_subscriptions_proprias on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());

-- Inscrever / remover o aparelho do usuário logado. Security definer porque o mesmo celular pode trocar de
-- usuário: a inscrição passa a ser do novo usuário (a policy acima não deixaria alterar a linha do outro).
create or replace function public.push_registrar(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Faça login.'; end if;
  insert into public.push_subscriptions(endpoint, user_id, p256dh, auth, user_agent)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, p_user_agent)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, criado_em = now();
end $$;

create or replace function public.push_remover(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

revoke all on function public.push_registrar(text, text, text, text) from public, anon;
revoke all on function public.push_remover(text) from public, anon;
grant execute on function public.push_registrar(text, text, text, text) to authenticated;
grant execute on function public.push_remover(text) to authenticated;

-- 2) Controle de envio (evita notificar a mesma requisição repetidas vezes). Só a Edge Function usa.
create table if not exists public.push_envios (
  requisicao_id bigint primary key,
  enviado_em    timestamptz not null default now()
);
alter table public.push_envios enable row level security;

-- 3) Gatilho: requisição nova pendente (ou que voltou para pendente após edição) → chama a Edge Function.
create extension if not exists pg_net;

create or replace function public.push_requisicao_pendente()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pendente' and (tg_op = 'INSERT' or old.status is distinct from 'pendente') then
    begin
      perform net.http_post(
        url     := 'https://qjmqburjyqlgwjihvlgp.supabase.co/functions/v1/notificar-aprovacao',
        body    := jsonb_build_object('id', new.id),
        headers := '{"Content-Type":"application/json"}'::jsonb
      );
    exception when others then
      -- notificação nunca pode impedir a gravação da requisição
      raise warning 'push_requisicao_pendente: %', sqlerrm;
    end;
  end if;
  return new;
end $$;

drop trigger if exists trg_push_requisicao_pendente on public.requisicoes;
create trigger trg_push_requisicao_pendente
  after insert or update of status on public.requisicoes
  for each row execute function public.push_requisicao_pendente();
