// Service worker do sistema principal (Capivara Estoque — index.html na raiz).
// Existe para o sistema poder ser instalado como aplicativo no PC (Chrome/Edge) e no celular (Android/iPhone).
//
// Cuidados:
// - Fica na raiz, então o escopo dele cobre também /aprovacoes/ e /notificacoes/ (a /contagem/ tem o próprio
//   service worker, que tem prioridade lá). Por isso ele só mexe na abertura da página principal e nos
//   arquivos do próprio app (manifesto e ícones). Todo o resto passa direto para a rede, sem cache.
// - A página principal é sempre buscada na rede primeiro ("network-first"): o aviso de versão nova e as
//   regras de acesso dependem do HTML mais recente. A cópia guardada só é usada sem internet, para o
//   aplicativo abrir mesmo assim.
// - Supabase e CDNs (outras origens) nunca passam por aqui.
const CACHE_NAME = 'capivara-estoque-v1';
const BASE = new URL('./', self.location.href).pathname;            // ex.: "/almoxarifado/"
const PAGINA = new Set([BASE, BASE + 'index.html']);
const ARQUIVOS = ['manifest.webmanifest', 'estoque-icon-192.png', 'estoque-icon-512.png', 'estoque-favicon-32.png'];
const ESTATICOS = new Set(ARQUIVOS.map((a) => BASE + a));

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_NAME).then((c) => c.addAll([BASE, ...ARQUIVOS])).catch(() => {}));
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    // Remove versões antigas deste cache e o cache do service worker antigo da Contagem que ficava na raiz.
    await Promise.all(keys.filter((k) => (k.startsWith('capivara-estoque-') && k !== CACHE_NAME) ||
      k.startsWith('contagem-ameta-v1') || k === 'contagem-ameta-v2').map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Abertura da página principal: rede primeiro, cópia guardada só sem internet.
  if (req.mode === 'navigate' && PAGINA.has(url.pathname)) {
    event.respondWith((async () => {
      try {
        const r = await fetch(req);
        if (r && r.ok) { const copia = r.clone(); caches.open(CACHE_NAME).then((c) => c.put(BASE, copia)).catch(() => {}); }
        return r;
      } catch (e) {
        const cache = await caches.open(CACHE_NAME);
        const guardada = await cache.match(BASE);
        if (guardada) return guardada;
        return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
          '<title>Sem conexão</title><body style="background:#0f1419;color:#e8edf2;font:15px system-ui;padding:32px;text-align:center">' +
          '<p style="font-size:34px">📡</p><p><b>Sem conexão com a internet.</b></p><p>Conecte-se e toque em ' +
          '<a style="color:#f5a623" href="./">tentar de novo</a>.</p></body>', { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  // Manifesto e ícones do app: cópia guardada na hora, atualizada em segundo plano.
  if (!url.search && ESTATICOS.has(url.pathname)) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE_NAME);
      const guardada = await cache.match(req);
      const rede = fetch(req).then((r) => { if (r && r.ok) cache.put(req, r.clone()); return r; }).catch(() => guardada);
      return guardada || rede;
    })());
  }
  // Todo o resto: sem interferência (rede normal).
});
