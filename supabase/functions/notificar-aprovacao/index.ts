// Edge Function "notificar-aprovacao" — push de "nova requisição para aprovar" para o app Aprovações.
//
//   GET  → devolve a chave pública VAPID (o app usa para inscrever o celular).
//   POST {"id": <id da requisição>} → chamado pelo gatilho do banco (script supabase/push_aprovacoes.sql)
//        quando uma requisição entra em "pendente". Envia o push para quem pode aprovar aquela obra:
//        admin, encarregado do almoxarifado e encarregados vinculados à obra (mesma regra do app).
//
// Não confia no corpo do pedido: relê a requisição com a service role e só envia se ela estiver pendente,
// no máximo uma vez a cada 5 minutos por requisição. Por isso pode ser publicada com verify_jwt = false.
//
// Segredos (Supabase → Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY e, opcional, VAPID_SUBJECT
// (ex.: mailto:almoxarifado@empresa.com.br). SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem por padrão.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import webpush from 'npm:web-push@3.6.7';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY') ?? '';
const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY') ?? '';
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:almoxarifado@ameta.com.br';
const INTERVALO_MIN_MS = 5 * 60 * 1000;

const reqN = (id: number | string) => 'REQ-' + String(id).padStart(5, '0');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) return json({ error: 'Chaves VAPID não configuradas.' }, 500);
  if (req.method === 'GET') return json({ publicKey: VAPID_PUBLIC_KEY });
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405);

  let id: unknown;
  try { id = (await req.json())?.id; } catch { return json({ error: 'JSON inválido.' }, 400); }
  if (id == null || !/^\d+$/.test(String(id))) return json({ error: 'Informe o id da requisição.' }, 400);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });

  const { data: r, error: eR } = await sb.from('requisicoes')
    .select('id,status,obra_id,obra_nome,ordem_servico,aplicacao_nome,solicitante_id,solicitante_nome,itens,mutuo_estoque_obra_id')
    .eq('id', id).maybeSingle();
  if (eR) return json({ error: eR.message }, 500);
  if (!r || r.status !== 'pendente') return json({ enviados: 0, motivo: 'requisição não está pendente' });

  // Trava contra repetição: no máximo um envio por requisição a cada 5 minutos.
  const { data: ult } = await sb.from('push_envios').select('enviado_em').eq('requisicao_id', r.id).maybeSingle();
  if (ult && Date.now() - new Date(ult.enviado_em).getTime() < INTERVALO_MIN_MS) return json({ enviados: 0, motivo: 'já notificada' });
  await sb.from('push_envios').upsert({ requisicao_id: r.id, enviado_em: new Date().toISOString() });

  // Quem pode aprovar esta obra (mesma regra de podeAprovarObra no app).
  const { data: perfis, error: eP } = await sb.from('profiles')
    .select('id,papel,setor,ativo,obras_vinculadas').eq('ativo', true).in('papel', ['admin', 'encarregado']);
  if (eP) return json({ error: eP.message }, 500);
  const obra = String(r.obra_id);
  const aprovadores = (perfis ?? []).filter((p) =>
    p.id !== r.solicitante_id && (
      p.papel === 'admin' ||
      p.setor === 'almoxarifado' ||
      (Array.isArray(p.obras_vinculadas) && p.obras_vinculadas.map(String).includes(obra))
    )).map((p) => p.id);
  if (!aprovadores.length) return json({ enviados: 0, motivo: 'ninguém para notificar' });

  const { data: subs, error: eS } = await sb.from('push_subscriptions')
    .select('endpoint,p256dh,auth').in('user_id', aprovadores);
  if (eS) return json({ error: eS.message }, 500);

  const nItens = Array.isArray(r.itens) ? r.itens.length : 0;
  const payload = JSON.stringify({
    title: `Nova requisição · ${reqN(r.id)}`,
    body: [
      r.obra_nome,
      [r.ordem_servico ? 'OS ' + r.ordem_servico : '', r.aplicacao_nome].filter(Boolean).join(' · '),
      `${r.solicitante_nome || 'Solicitante'} · ${nItens} ${nItens === 1 ? 'item' : 'itens'}${r.mutuo_estoque_obra_id ? ' · mútuo' : ''}`,
    ].filter(Boolean).join('\n'),
    tag: 'req-' + r.id,
    url: './#r' + r.id,
  });

  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
  let enviados = 0;
  const vencidas: string[] = [];
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
        { TTL: 24 * 60 * 60, urgency: 'high' });
      enviados++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) vencidas.push(s.endpoint); // celular desinstalou o app ou revogou a permissão
      else console.error('push falhou', code, (e as Error).message);
    }
  }));
  if (vencidas.length) await sb.from('push_subscriptions').delete().in('endpoint', vencidas);

  return json({ enviados, removidas: vencidas.length });
});
