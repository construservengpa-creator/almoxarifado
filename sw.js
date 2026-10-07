// Service worker — Contagem Cíclica AMETA
// Estratégia: cache "stale-while-revalidate" SÓ para o shell da Contagem (contagem.html, manifest, ícones).
// O sistema principal (index.html) e qualquer outra URL passam direto para a rede: este arquivo fica na raiz
// do site e, sem esse filtro, controlava também o index.html — entregava a versão antiga guardada depois de
// cada publicação (o aviso "Existe uma versão mais nova" voltava logo após atualizar) e guardava uma cópia
// do sistema a cada verificação de versão (?_v=...).
// Chamadas ao Supabase (outra origem) nunca são cacheadas — sempre vão direto pra rede.

const CACHE_NAME = 'contagem-ameta-v2'; // v2: descarta o cache antigo, que tinha cópias do index.html
const APP_SHELL = [
  './contagem.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
];
const SHELL_PATHS = new Set(APP_SHELL.map((p) => new URL(p, self.location.href).pathname));

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).catch(() => {})
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Só cuida de GET do mesmo domínio, sem parâmetros, e apenas dos arquivos da Contagem. Todo o resto passa direto.
  if (req.method !== 'GET' || url.origin !== self.location.origin || url.search || !SHELL_PATHS.has(url.pathname)) return;

  event.respondWith(
    caches.match(req).then((cached) => {
      const fetchPromise = fetch(req)
        .then((networkResponse) => {
          if (networkResponse && networkResponse.status === 200) {
            const clone = networkResponse.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
          }
          return networkResponse;
        })
        .catch(() => cached);
      return cached || fetchPromise;
    })
  );
});
