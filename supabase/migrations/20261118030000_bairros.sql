-- Mapa por bairro.
-- 1) bi_cliente.cep: CEP de cada cliente (a carga grava a partir da planilha; 8 dígitos).
-- 2) bi_cep: bairro e coordenada de cada CEP. Preenchida pela rotina "Bairros (CEP)" do GitHub,
--    que consulta só os CEPs (nunca nomes de clientes). Fica fechada: o site lê pela função abaixo.
-- 3) bi_bairros(f, per, cidades): faturamento por bairro dos municípios pedidos, com os mesmos filtros do painel.
alter table public.bi_cliente add column if not exists cep text;
create index if not exists bi_cliente_cep on public.bi_cliente (cep) where cep is not null;

create table if not exists public.bi_cep (
  cep text primary key,
  bairro text,
  cidade text,
  uf text,
  lat double precision,
  lon double precision,
  distrito text,          -- distrito da cidade de São Paulo (pelo ponto), quando cair na capital
  fonte text,             -- 'cep' (ponto do próprio CEP), 'bairro' (centro do bairro), 'nenhuma'
  geo_em timestamptz not null default now()
);
create index if not exists bi_cep_geo_em on public.bi_cep (geo_em);
alter table public.bi_cep enable row level security;
revoke all on public.bi_cep from anon, authenticated;

-- [bairro, distrito, lat, lon, fat, lb, fat_anterior, clientes_com_compra]; valores em centavos
create or replace function public.bi_bairros(f jsonb, per jsonb, cidades int[])
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '64MB'
as $function$
declare w text; res json; ck text; ver text;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date;
  p1 date := coalesce((per->>'pini')::date, '1900-01-01'); p2 date := coalesce((per->>'pfim')::date, '1900-01-01');
begin
  f := coalesce(f, '{}'::jsonb);
  if cidades is null or cardinality(cidades) = 0 then return '[]'::json; end if;
  w := private.bi_where(f);
  select max(geo_em)::text into ver from public.bi_cep;   -- CEPs novos localizados: a resposta guardada deixa de valer
  ck := md5(concat_ws('|', 'bairros1', w, i1, i2, p1, p2, cidades::text, ver));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with v as (
      select cliente,
             sum(fat) filter (where dia between $1 and $2) ft,
             sum(lb)  filter (where dia between $1 and $2) lt,
             sum(fat) filter (where dia between $3 and $4) fp
      from public.bi_venda
      where %s and cidade = any($5::smallint[]) and (dia between $1 and $2 or dia between $3 and $4)
      group by cliente)
    select coalesce(json_agg(json_build_array(bairro, distrito, round(lat::numeric, 5), round(lon::numeric, 5), ft, lt, fp, n)
                             order by ft desc nulls last), '[]'::json)
    from (select coalesce(nullif(trim(e.bairro), ''), '') bairro, e.distrito,
                 avg(e.lat) lat, avg(e.lon) lon,
                 coalesce(sum(v.ft), 0) ft, coalesce(sum(v.lt), 0) lt, coalesce(sum(v.fp), 0) fp,
                 count(*) filter (where v.ft > 0) n
          from v join public.bi_cliente c on c.id = v.cliente
          left join public.bi_cep e on e.cep = c.cep
          group by 1, 2) x$q$, w)
  into res using i1, i2, p1, p2, cidades;
  if res is not null then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $function$;
revoke all on function public.bi_bairros(jsonb, jsonb, int[]) from public, anon;
grant execute on function public.bi_bairros(jsonb, jsonb, int[]) to authenticated;
