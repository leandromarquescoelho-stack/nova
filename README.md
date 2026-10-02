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

Os dados atuais são uma foto até 25/09/2026, gerada a partir de `vendas.xlsb` e `estoque.xlsb`. Para atualizar, carregue as novas linhas nas tabelas `bi_*` pelo SQL Editor do Supabase (ou por um processo de carga com a chave de serviço, que nunca deve ir para este repositório).

## Segurança

- Este repositório é público. Não suba planilhas, exportações nem a chave de serviço (`service_role`). O `.gitignore` já bloqueia os formatos mais comuns.
- A chave que aparece no `index.html` é a chave pública (publishable) do Supabase, feita para ficar no navegador. Quem protege os dados são as regras de acesso do banco.
