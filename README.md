# Nova Chevrolet BI

Painel de vendas e estoque da Nova Chevrolet (peças), com login e acesso por perfil.

- **Site:** https://leandromarquescoelho-stack.github.io/nova/
- **Banco e login:** Supabase, projeto `nova-chevrolet-bi` (região São Paulo)

## Como funciona

O painel é uma página única (`index.html`). Ela não contém dados da empresa: depois do login, busca os dados no Supabase, e o próprio banco só devolve as linhas que o perfil do usuário pode ver (Row Level Security).

| Perfil | O que vê |
|---|---|
| BI | Tudo, mais a tela de administração de usuários |
| Diretoria | Tudo |
| Gerência | Só a própria loja (`profiles.loja`) |
| Vendedor | Só os próprios números (`profiles.vendedor_nome`, igual ao nome nos dados) |

Usuário inativo não recebe nenhum dado. Ninguém grava nas tabelas de dados pela página; a carga é feita só pelo administrador do banco.

## Estrutura

```
index.html                         painel (HTML + JS, sem dados)
supabase/migrations/               estrutura do banco, regras de acesso
supabase/functions/admin-invite-user/   função que o perfil BI usa para convidar usuários
.github/workflows/pages.yml        publica o index.html no GitHub Pages a cada push na main
```

### Tabelas

- `profiles`: usuários, papel, loja, vendedor, ativo.
- `bi_produtos`: vendas mensais (jan–set/2026) e estoque por SKU, com uma loja e um vendedor principal por linha.
- `bi_peso_diario`: peso de cada dia dentro do mês (só a proporção, não o faturamento absoluto).
- `bi_meta_vendedor`: meta por vendedor.
- `bi_config`: meses e lojas.

## Usuários

1. Entre com o perfil BI e abra **Usuários** para convidar alguém (e-mail, papel, loja ou vendedor).
2. A pessoa recebe um e-mail do Supabase, clica no link e define a senha no próprio painel.
3. "Esqueci minha senha" na tela de login envia um link para criar uma nova senha.

Para os links dos e-mails abrirem o painel, o Supabase precisa ter este site configurado em **Authentication > URL Configuration** (Site URL e Redirect URLs).

## Atualizar os dados

Todos os números do painel vêm do Supabase. O banco é atualizado pelas planilhas de uma pasta do Google Drive:

1. Salve ou substitua as planilhas (vendas, estoque e, se houver, metas) na pasta do Drive.
2. A cada 30 minutos o workflow **Carga Google Drive -> Supabase** (`.github/workflows/carga-drive.yml`) confere a pasta. Se alguma planilha tiver data de modificação nova, ele roda `etl/carga_drive.py`, recalcula as tabelas `bi_*` e grava tudo numa única transação. Se nada mudou, não faz nada.
3. No painel, o canto superior mostra "Dados até … · carga de …" e o botão **Atualizar** busca a carga nova.

Para rodar na hora: Actions > Carga Google Drive -> Supabase > Run workflow (marque "Recarregar" para forçar).

Onde fica cada coisa:

- Os nomes das planilhas e das colunas ficam no banco, em `bi_config` chave `mapa_colunas`, e não no código.
- O histórico de cada carga (arquivo, data de modificação, status, erro) fica em `bi_carga_controle`, visível só para o administrador do banco.
- Se uma carga falhar, o painel continua com a carga anterior.

Segredos do repositório (Settings > Secrets and variables > Actions):

| Segredo | O que é |
|---|---|
| `GDRIVE_FOLDER_ID` | id da pasta do Drive (o trecho depois de `/folders/` no link) |
| `GOOGLE_SA_JSON` | chave JSON de uma conta de serviço do Google Cloud com a Drive API ativada; a pasta deve ser compartilhada com o e-mail dessa conta como Leitor |
| `SUPABASE_DB_URL` | Supabase > Connect > Session pooler (URI com a senha do banco) |

## Segurança

- Regra do projeto: planilhas e qualquer dado da empresa ficam só na pasta do Google Drive (e na pasta do projeto no Claude). Aqui fica apenas código. A carga lê as planilhas na memória de uma máquina temporária do GitHub Actions, grava no Supabase e não salva nem imprime nenhum dado; os logs mostram só contagens.
- Este repositório é público. Não suba planilhas, exportações nem a chave de serviço (`service_role`). O `.gitignore` já bloqueia os formatos mais comuns.
- A chave que aparece no `index.html` é a chave pública (publishable) do Supabase, feita para ficar no navegador. Quem protege os dados são as regras de acesso do banco.
