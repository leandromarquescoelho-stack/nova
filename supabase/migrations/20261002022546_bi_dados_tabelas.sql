create schema if not exists private;
grant usage on schema private to authenticated;

create table public.bi_produtos (
  id text primary key,
  nome text not null,
  marca text, categoria text, montadora text,
  loja text not null,
  vendedor text not null,
  canal text, origem text,
  fat numeric not null default 0,
  qtd numeric not null default 0,
  custo numeric not null default 0,
  lb numeric not null default 0,
  mfat numeric[] not null,
  mqtd numeric[] not null,
  est_fis numeric, est_custo numeric, est_min numeric,
  dias_sem_giro numeric,
  parado boolean not null default false,
  status text,
  is_bucket boolean not null default false,
  bucket_count integer,
  carregado_em timestamptz not null default now()
);
comment on table public.bi_produtos is 'Vendas (mensais) e estoque por SKU do painel Nova Chevrolet BI. Cada linha tem 1 loja e 1 vendedor principal.';
create index bi_produtos_loja_idx on public.bi_produtos(loja);
create index bi_produtos_vendedor_idx on public.bi_produtos(vendedor);

create table public.bi_peso_diario (
  d date primary key,
  w_fat numeric not null,
  w_qtd numeric not null
);
comment on table public.bi_peso_diario is 'Participação de cada dia no faturamento/quantidade do seu mês (curva diária da empresa, normalizada).';

create table public.bi_meta_vendedor (
  vendedor text primary key,
  meta numeric not null
);

create table public.bi_config (
  chave text primary key,
  valor jsonb not null
);

alter table public.bi_produtos enable row level security;
alter table public.bi_peso_diario enable row level security;
alter table public.bi_meta_vendedor enable row level security;
alter table public.bi_config enable row level security;

revoke all on public.bi_produtos, public.bi_peso_diario, public.bi_meta_vendedor, public.bi_config from anon;
revoke insert, update, delete, truncate on public.bi_produtos, public.bi_peso_diario, public.bi_meta_vendedor, public.bi_config from authenticated;
grant select on public.bi_produtos, public.bi_peso_diario, public.bi_meta_vendedor, public.bi_config to authenticated;
