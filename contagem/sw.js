// Service worker — Contagem Cíclica AMETA (pasta /contagem/: controla só esta pasta)
// Estratégia: cache "stale-while-revalidate" só para o shell da Contagem. Supabase (outra origem) nunca é cacheado.
const CACHE_NAME = 'contagem-ameta-v6';
const APP_SHELL = ['./', './manifest.webmanifest', '../icon-192.png', '../icon-512.png'];
const SHELL_PATHS = new Set(APP_SHELL.map((p) => new URL(p, self.location.href).pathname));

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).catch(() => {}));
});
self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k.startsWith('contagem-ameta') && k !== CACHE_NAME).map((k) => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', (event) => {
  const req = event.request; const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin || url.search) return;
  const path = url.pathname.endsWith('/index.html') ? url.pathname.slice(0, -10) : url.pathname;
  if (!SHELL_PATHS.has(path)) return;
  event.respondWith(caches.match(req, { ignoreSearch: true }).then((cached) => {
    const net = fetch(req).then((r) => { if (r && r.status === 200) { const c = r.clone(); caches.open(CACHE_NAME).then((cache) => cache.put(req, c)); } return r; }).catch(() => cached);
    return cached || net;
  }));
});
