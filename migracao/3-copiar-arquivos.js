// Copia as fotos (bucket "produtos") e os comprovantes (bucket "comprovantes") do projeto antigo para o novo.
// Uso (na pasta migracao):
//   npm init -y && npm install @supabase/supabase-js@2
//   ANTIGO_URL=https://qjmqburjyqlgwjihvlgp.supabase.co ANTIGO_SERVICE_KEY=... \
//   NOVO_URL=https://NOVO_REF.supabase.co NOVO_SERVICE_KEY=... node 3-copiar-arquivos.js
// As chaves "service_role" (ou "secret") ficam em Project Settings → API Keys de cada projeto. Não as publique.
// Pode rodar de novo: arquivos já copiados são regravados (mesmo caminho).
const { createClient } = require('@supabase/supabase-js');
const env = (k) => { if (!process.env[k]) { console.error('Defina ' + k); process.exit(1); } return process.env[k]; };
const antigo = createClient(env('ANTIGO_URL'), env('ANTIGO_SERVICE_KEY'), { auth: { persistSession: false } });
const novo = createClient(env('NOVO_URL'), env('NOVO_SERVICE_KEY'), { auth: { persistSession: false } });
const BUCKETS = ['produtos', 'comprovantes'];

async function listar(bucket, pasta = '') {
  let arquivos = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await antigo.storage.from(bucket).list(pasta, { limit: 1000, offset });
    if (error) throw new Error(`listar ${bucket}/${pasta}: ${error.message}`);
    for (const item of data || []) {
      const caminho = pasta ? `${pasta}/${item.name}` : item.name;
      if (!item.metadata) arquivos = arquivos.concat(await listar(bucket, caminho));   // pasta
      else arquivos.push({ caminho, tipo: item.metadata.mimetype });
    }
    if (!data || data.length < 1000) return arquivos;
  }
}

async function copiar(bucket, arq) {
  for (let tentativa = 1; tentativa <= 3; tentativa++) {
    const { data, error } = await antigo.storage.from(bucket).download(arq.caminho);
    if (!error) {
      const up = await novo.storage.from(bucket).upload(arq.caminho, data, { upsert: true, contentType: arq.tipo });
      if (!up.error) return null;
      if (tentativa === 3) return up.error.message;
    } else if (tentativa === 3) return error.message;
    await new Promise((r) => setTimeout(r, 1000 * tentativa));
  }
}

(async () => {
  const falhas = [];
  for (const bucket of BUCKETS) {
    const { data: cfg } = await antigo.storage.getBucket(bucket);
    const { data: existe } = await novo.storage.getBucket(bucket);
    if (!existe && cfg) {
      const { error } = await novo.storage.createBucket(bucket, { public: cfg.public, fileSizeLimit: cfg.file_size_limit, allowedMimeTypes: cfg.allowed_mime_types });
      if (error) throw new Error(`criar bucket ${bucket}: ${error.message}`);
    }
    const arquivos = await listar(bucket);
    console.log(`${bucket}: ${arquivos.length} arquivo(s)`);
    let feitos = 0;
    for (let i = 0; i < arquivos.length; i += 10) {
      const lote = arquivos.slice(i, i + 10);
      const res = await Promise.all(lote.map((a) => copiar(bucket, a)));
      res.forEach((erro, j) => { if (erro) falhas.push(`${bucket}/${lote[j].caminho}: ${erro}`); });
      feitos += lote.length;
      process.stdout.write(`\r  ${feitos}/${arquivos.length}`);
    }
    console.log('');
  }
  if (falhas.length) { console.log(`\n${falhas.length} falha(s):\n` + falhas.join('\n')); process.exit(1); }
  console.log('\nTodos os arquivos copiados.');
})().catch((e) => { console.error('Erro:', e.message); process.exit(1); });
