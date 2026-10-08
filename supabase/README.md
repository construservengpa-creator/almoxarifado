# Notificação push do app Aprovações

Com isto instalado, o celular de quem aprova recebe uma notificação **toda vez que uma requisição entra em
"pendente"**, mesmo com o app fechado. Recebem: administradores, o encarregado do almoxarifado e os
encarregados vinculados à obra da requisição (quem criou a requisição não é avisado da própria).

Sem estes passos o app continua funcionando, e avisa apenas enquanto está aberto (ou em segundo plano).

## Instalação (uma vez, no projeto Estoque do Supabase)

1. **Gerar as chaves VAPID** (em qualquer computador com Node):

   ```
   npx web-push generate-vapid-keys
   ```

2. **Cadastrar os segredos**: Supabase → *Edge Functions* → *Secrets*:
   - `VAPID_PUBLIC_KEY` = a *Public Key* gerada
   - `VAPID_PRIVATE_KEY` = a *Private Key* gerada (não compartilhe)
   - `VAPID_SUBJECT` = `mailto:` + um e-mail de contato da empresa (opcional)

3. **Publicar a Edge Function** `notificar-aprovacao` (código em `functions/notificar-aprovacao/index.ts`),
   com **Verify JWT desligado**: ela relê a requisição com a service role, só envia se estiver pendente e no
   máximo uma vez a cada 5 minutos por requisição.
   - Pelo painel: *Edge Functions* → *Deploy a new function* → *Via Editor*, nome `notificar-aprovacao`,
     cole o código e, em *Settings*, desligue *Enforce JWT Verification*.
   - Ou pela CLI: `supabase functions deploy notificar-aprovacao --no-verify-jwt`

4. **Rodar o script** `push_aprovacoes.sql` no *SQL Editor* (cria a tabela de inscrições, as funções
   `push_registrar`/`push_remover` e o gatilho na tabela `requisicoes`).

## No celular

Abra o app Aprovações e toque em **Ativar** (ou no sino 🔕 do topo) e permita as notificações.
O sino fica 🔔 quando está ativo.

- **Android**: funciona no Chrome, instalado ou não.
- **iPhone (iOS 16.4+)**: só funciona com o app adicionado à Tela de Início (Compartilhar → Adicionar à Tela
  de Início) e aberto por lá.

Ao tocar em **Sair**, o aparelho deixa de receber os avisos daquele usuário.
