-- Totais reais por mês x loja x canal x vendedor (sem atribuição a um vendedor/loja "principal")
create table if not exists public.bi_resumo_mes (
  mes text not null,
  loja text,
  canal text,
  vendedor text,
  fat numeric not null default 0,
  qtd numeric not null default 0,
  custo numeric not null default 0,
  lb numeric not null default 0,
  skus integer not null default 0
);
create index if not exists bi_resumo_mes_idx on public.bi_resumo_mes (mes, loja, vendedor);
alter table public.bi_resumo_mes enable row level security;
revoke all on public.bi_resumo_mes from anon, authenticated;
grant select on public.bi_resumo_mes to authenticated;
create policy bi_resumo_mes_leitura on public.bi_resumo_mes for select to authenticated
  using (private.bi_pode_ver(loja, vendedor));
