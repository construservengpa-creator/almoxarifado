// Service worker — app Aprovações AMETA (pasta /aprovacoes/: controla só esta pasta)
// Só recebe as notificações push de "nova requisição para aprovar" e abre o app ao tocar nelas. Nada é cacheado.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { body: event.data ? event.data.text() : '' }; }
  const title = d.title || 'Nova requisição para aprovar';
  event.waitUntil(self.registration.showNotification(title, {
    body: d.body || 'Toque para abrir o app de Aprovações.',
    tag: d.tag || 'aprovacao',            // mesma tag do aviso local do app: não aparece duplicado
    renotify: true,
    icon: '../aprov-icon-192.png',
    badge: '../aprov-icon-96.png',
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const alvo = new URL((event.notification.data && event.notification.data.url) || './', self.registration.scope).href;
  event.waitUntil((async () => {
    const abertas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of abertas) {
      if (c.url.startsWith(self.registration.scope)) { await c.focus(); c.postMessage({ tipo: 'atualizar' }); return; }
    }
    await self.clients.openWindow(alvo);
  })());
});
