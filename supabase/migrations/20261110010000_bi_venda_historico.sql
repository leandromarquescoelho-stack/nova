-- Arquivo único (infobi) com carga por período e histórico resumido.
--
-- bi_venda passa a ser uma visão sobre duas tabelas:
--   bi_venda_det   vendas linha a linha a partir de 2026 (com NF e índices, como antes)
--   bi_venda_hist  anos anteriores resumidos por dia x dimensões x produto x cliente, sem NF e sem índices
--                  (ocupa bem menos espaço; no histórico a contagem de notas fica aproximada)
-- As funções do painel continuam lendo public.bi_venda e não mudam.

alter table public.bi_venda rename to bi_venda_det;
alter index if exists public.bi_venda_produto rename to bi_venda_det_produto;
alter index if exists public.bi_venda_cliente rename to bi_venda_det_cliente;
alter index if exists public.bi_venda_nf rename to bi_venda_det_nf;
alter table public.bi_venda_det add constraint bi_venda_det_periodo check (dia >= date '2026-01-01');

create table if not exists public.bi_venda_hist (
  dia date not null,
  mes smallint not null,
  loja smallint not null, canal smallint not null, emitente smallint not null, origem smallint not null,
  vendedor smallint not null, linha smallint not null, marca smallint not null, categoria smallint not null,
  montadora smallint not null, classificacao smallint not null, tipo_cliente smallint not null, cidade smallint not null,
  produto int not null, cliente int not null,
  qtd int not null, fat int not null, custo int not null, lb int not null,
  subcategoria smallint not null default 0,
  constraint bi_venda_hist_periodo check (dia < date '2026-01-01')
);
create index if not exists bi_venda_hist_dia on public.bi_venda_hist using brin (dia);

alter table public.bi_venda_hist enable row level security;
revoke all on public.bi_venda_det, public.bi_venda_hist from anon, authenticated;

-- mesma ordem de colunas da tabela antiga; o histórico entra com nf = 0
create or replace view public.bi_venda with (security_invoker = true) as
  select dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora, classificacao,
         tipo_cliente, cidade, produto, cliente, nf, qtd, fat, custo, lb, subcategoria
    from public.bi_venda_det
  union all
  select dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora, classificacao,
         tipo_cliente, cidade, produto, cliente, 0, qtd, fat, custo, lb, subcategoria
    from public.bi_venda_hist;
revoke all on public.bi_venda from anon, authenticated;

-- um só link (arquivo infobi com todas as abas); metas continua possível para o futuro
alter table public.bi_fonte drop constraint if exists bi_fonte_papel_check;
alter table public.bi_fonte add constraint bi_fonte_papel_check check (papel in ('infobi','vendas','estoque','metas'));
