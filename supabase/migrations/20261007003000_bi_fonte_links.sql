-- Links das planilhas usados pela carga (fora do código). Só o administrador do banco lê ou altera.
create table if not exists public.bi_fonte (
  papel text primary key check (papel in ('vendas','estoque','metas')),
  link text not null,
  ativo boolean not null default true,
  observacao text,
  atualizado_em timestamptz not null default now()
);
alter table public.bi_fonte enable row level security;
revoke all on public.bi_fonte from anon, authenticated;
