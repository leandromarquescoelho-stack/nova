-- Rede Chevrolet ativa: camada "Concessionárias Chevrolet" do mapa (fica só no banco, não no GitHub).
-- As coordenadas são preenchidas pela rotina etl/rede_geocodificar.py. Os dados (lista de lojas) são gravados à parte, fora do repositório.
create table if not exists public.bi_rede (
  codigo text primary key,
  nome text not null,
  endereco text,
  cep text,
  uf text,
  local text,
  tipo text,
  lat double precision,
  lon double precision,
  geo_fonte text,
  geo_em timestamptz,
  atualizado_em timestamptz not null default now()
);
alter table public.bi_rede enable row level security;
drop policy if exists bi_rede_ler on public.bi_rede;
create policy bi_rede_ler on public.bi_rede for select to authenticated using (true);
revoke all on public.bi_rede from anon;
grant select on public.bi_rede to authenticated;

