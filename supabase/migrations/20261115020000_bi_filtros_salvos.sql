-- Filtros salvos ("Personalizado 2"): uma linha por usuário com a lista de combinações de filtros.
-- Cada usuário lê e grava só a própria linha.
create table if not exists public.bi_filtros_salvos (
  user_id uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  lista jsonb not null default '[]'::jsonb check (jsonb_typeof(lista) = 'array' and pg_column_size(lista) < 200000),
  atualizado_em timestamptz not null default now()
);
alter table public.bi_filtros_salvos enable row level security;
drop policy if exists bi_filtros_salvos_own on public.bi_filtros_salvos;
create policy bi_filtros_salvos_own on public.bi_filtros_salvos
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.bi_filtros_salvos to authenticated;
revoke all on public.bi_filtros_salvos from anon;
