-- Histórico das cargas Google Drive -> Supabase (usado só pelo processo de carga, com a chave de serviço)
create table if not exists public.bi_carga_controle (
  id bigserial primary key,
  arquivo_id text not null,
  arquivo_nome text not null,
  modificado_em timestamptz not null,
  md5 text,
  status text not null default 'processando' check (status in ('processando','ok','erro','ignorado')),
  linhas integer,
  mensagem text,
  iniciado_em timestamptz not null default now(),
  concluido_em timestamptz
);
create index if not exists bi_carga_controle_arquivo_idx on public.bi_carga_controle (arquivo_id, modificado_em desc);
alter table public.bi_carga_controle enable row level security;
revoke all on public.bi_carga_controle from anon, authenticated;
revoke all on sequence public.bi_carga_controle_id_seq from anon, authenticated;

-- status (visível a usuários logados) da última carga: data de corte e quando foi carregado
insert into public.bi_config (chave, valor)
values ('carga', jsonb_build_object('carregado_em', '2026-10-02T02:28:00Z', 'dados_ate', '2026-09-25', 'origem', 'carga inicial (vendas.xlsb + estoque.xlsb)'))
on conflict (chave) do nothing;
