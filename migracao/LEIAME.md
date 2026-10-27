# Migração do Estoque para outro projeto Supabase (conta da Ameta)

Leva o banco (tabelas, funções, regras de acesso), os **usuários com as mesmas senhas**, as fotos e os
comprovantes do projeto atual (`qjmqburjyqlgwjihvlgp`) para um projeto novo e troca o endereço nos
sistemas que usam o Estoque. Os usuários só precisam **entrar de novo** (o login antigo deixa de valer).

O que o Estoque usa hoje: 29 tabelas e 57 funções em `public`, 19 usuários (login por e-mail e senha),
2 pastas de arquivos (`produtos`, pública, ~1.700 fotos; `comprovantes`, privada), 7 tabelas no tempo real,
gatilho que cria o perfil ao cadastrar usuário. Não usa Edge Functions, cron nem segredos do Vault.

## Antes de começar

No computador que vai fazer a migração (Windows, Mac ou Linux):

- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) e
  [Docker Desktop](https://www.docker.com) aberto (o `supabase db dump` usa o Docker);
- `psql` (vem com o [PostgreSQL](https://www.postgresql.org/download/));
- [Node.js](https://nodejs.org) 18 ou mais novo;
- este repositório baixado (`git clone`), e também os do Controle de Notas e do Painel.

No Windows, rode os `.sh` pelo Git Bash (vem com o Git).

## Passo a passo

### 1. Criar o projeto novo
Na conta da Ameta: **New project**. Região sugerida: **South America (São Paulo)**. Anote a **senha do banco**.

### 2. Combinar uma janela sem uso
O que for lançado no sistema depois do passo 3 **não vai para o projeto novo**. Avise os usuários e faça
os passos 3 a 7 num horário sem movimento (leva de 30 a 60 minutos).

### 3. Baixar o banco do projeto atual
No painel do projeto **atual**: botão **Connect** → **Session pooler** → copie a conexão e troque
`[YOUR-PASSWORD]` pela senha do banco (se não souber, redefina em *Database → Settings*).

```bash
cd migracao
ANTIGO_DB_URL='postgresql://postgres.qjmqburjyqlgwjihvlgp:SENHA@aws-0-....pooler.supabase.com:5432/postgres' ./1-baixar-banco.sh
```

Cria a pasta `migracao/backup/` (não suba essa pasta para o GitHub: tem os dados e os usuários).

### 4. Subir no projeto novo
Mesma coisa no projeto **novo** (Connect → Session pooler):

```bash
NOVO_DB_URL='postgresql://postgres.NOVO_REF:SENHA@aws-0-....pooler.supabase.com:5432/postgres' ./2-subir-banco.sh
```

Restaura estrutura, dados e usuários, e roda `auth_storage_realtime.sql` (gatilho de novos usuários, pastas
de arquivos e suas permissões, tabelas do tempo real), que o dump não leva.
Se der erro de permissão com `supabase_admin` ou `cli_login_postgres`, veja *Troubleshooting* em
[Backup and Restore using the CLI](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore).

### 5. Copiar fotos e comprovantes
Pegue a chave **service_role** (ou *secret*) de cada projeto em *Project Settings → API Keys*. Não publique essas chaves.

```bash
npm init -y && npm install @supabase/supabase-js@2
ANTIGO_URL=https://qjmqburjyqlgwjihvlgp.supabase.co ANTIGO_SERVICE_KEY=... \
NOVO_URL=https://NOVO_REF.supabase.co NOVO_SERVICE_KEY=... node 3-copiar-arquivos.js
```

### 6. Conferir
Rode `conferir.sql` no SQL Editor dos **dois** projetos: as quantidades (usuários, arquivos, linhas de cada
tabela, tabelas do tempo real) têm de ser iguais.

### 7. Configurar o login no projeto novo (à mão, no painel)
Copie do projeto atual para o novo, em **Authentication**:
- **URL Configuration**: *Site URL* e *Redirect URLs*;
- **Sign In / Providers → Email**: as mesmas opções (confirmação de e-mail etc.);
- **Emails** (modelos e SMTP), se tiverem sido personalizados.

### 8. Trocar o endereço nos sistemas
Pegue no projeto novo o **Project URL** e a chave **anon / publishable** (*Project Settings → API Keys*):

```bash
./4-trocar-projeto.sh https://NOVO_REF.supabase.co CHAVE_ANON ../../controlenotasfiscais ../../Painel-suprimentos
```

Troca em: Estoque (`index.html`, `aprovacoes/`, `contagem/`, `notificacoes/`), função `receber-nota-estoque`
do Controle de Notas e função `status-solicitacoes` do Painel. Depois:

1. confira com `git diff` e publique os três repositórios (commit + push);
2. publique de novo as duas funções, cada uma no seu projeto (elas conferem o login no Estoque):
   ```bash
   supabase functions deploy receber-nota-estoque --project-ref kygainafarusnsstvvhc --no-verify-jwt   # na pasta do Controle de Notas
   supabase functions deploy status-solicitacoes --project-ref xuukjnpkltvgzjfgivnd --no-verify-jwt    # na pasta do Painel
   ```

### 9. Depois
- Todos entram de novo com o mesmo e-mail e senha.
- Teste: login, consulta de produto (com foto), uma baixa, abrir um comprovante, a TV de notificações,
  entrada de NF pelo Controle de Notas e o selo "Solicitada" (situação do Sienge, via Painel).
- Deixe o projeto antigo **pausado** (não apague) por alguns dias, como garantia; depois apague.
