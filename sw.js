// Service worker antigo da Contagem, que ficava na raiz e controlava o site inteiro (inclusive o sistema e o app de
// Aprovações). A Contagem agora tem o próprio service worker em /contagem/sw.js. Este arquivo só existe para os
// aparelhos que ainda têm o antigo registrado: ao atualizar, ele apaga o cache antigo e se desregistra.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('contagem-ameta-v1') || k === 'contagem-ameta-v2').map((k) => caches.delete(k)));
    await self.registration.unregister();
  })());
});
