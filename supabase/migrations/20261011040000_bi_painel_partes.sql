-- bi_painel em três partes pedidas em paralelo pelo painel (cada uma cabe no limite de tempo do Supabase)
-- e cache dos resultados até a próxima carga.
create unlogged table if not exists public.bi_cache (chave text primary key, valor json not null, criado timestamptz not null default now());
alter table public.bi_cache enable row level security;
revoke all on public.bi_cache from anon, authenticated;

-- parte 'a': série diária e resumo mês x loja x canal x vendedor; 'c': totais por dimensão no período; 'b': produtos
-- (o painel pede as três ao mesmo tempo; resultados ficam em cache até a próxima carga)
create or replace function public.bi_painel(f jsonb, per jsonb, parte text)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $$
declare w text; res json; ck text;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; q1 date := (per->>'pini')::date; q2 date := (per->>'pfim')::date;
  s1 date := (per->>'s7i')::date; s2 date := (per->>'s7f')::date; t1 date := (per->>'p7i')::date; t2 date := (per->>'p7f')::date;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'painel', parte, w, i1, i2, q1, q2, s1, s2, t1, t2));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  if parte = 'a' then
    execute format($q$
      with g as materialized (
        select dia, mes, loja, canal, vendedor, grouping(dia) gd, sum(fat) ft, sum(qtd) qt, sum(lb) lt, sum(custo) ct
        from public.bi_venda where %s
        group by grouping sets ((dia),(mes,loja,canal,vendedor)))
      select json_build_object(
        'd', (select coalesce(json_agg(json_build_array(dia, ft, qt, lt) order by dia), '[]') from g where gd = 0),
        'r', (select coalesce(json_agg(json_build_array(mes, loja, canal, vendedor, ft, qt, ct, lt)), '[]') from g where gd = 1))$q$, w)
    into res;
  elsif parte = 'c' then
    execute format($q$
      with g as materialized (
        select case when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(vendedor)=0 then 'vendedor'
                    when grouping(categoria)=0 then 'categoria' when grouping(marca)=0 then 'marca' when grouping(montadora)=0 then 'montadora'
                    when grouping(linha)=0 then 'linha' when grouping(emitente)=0 then 'emitente' when grouping(origem)=0 then 'origem'
                    when grouping(tipo_cliente)=0 then 'tipo_cliente' when grouping(classificacao)=0 then 'classificacao' else 'cidade' end s,
               coalesce(loja, canal, vendedor, categoria, marca, montadora, linha, emitente, origem, tipo_cliente, classificacao, cidade) k,
               sum(fat) ft, sum(qtd) qt, sum(lb) lt,
               sum(fat) filter (where dia between $1 and $2) fp, sum(qtd) filter (where dia between $1 and $2) qp, sum(lb) filter (where dia between $1 and $2) lp,
               sum(fat) filter (where dia between $3 and $4) fq, sum(qtd) filter (where dia between $3 and $4) qq, sum(lb) filter (where dia between $3 and $4) lq
        from public.bi_venda where %s
        group by grouping sets ((loja),(canal),(vendedor),(categoria),(marca),(montadora),(linha),
                                (emitente),(origem),(tipo_cliente),(classificacao),(cidade)))
      select json_object_agg(s, x) from (select s, json_agg(json_build_array(k, fp, qp, lp, fq, qq, lq, ft, qt, lt)) x from g group by s) z$q$, w)
    into res using i1, i2, q1, q2;
  else
    execute format($q$
      with g as materialized (
        select produto, mes, grouping(mes) gm,
               sum(fat) ft, sum(qtd) qt, sum(lb) lt,
               sum(fat) filter (where dia between $1 and $2) fp, sum(qtd) filter (where dia between $1 and $2) qp, sum(lb) filter (where dia between $1 and $2) lp,
               sum(fat) filter (where dia between $3 and $4) fq, sum(qtd) filter (where dia between $3 and $4) qq, sum(lb) filter (where dia between $3 and $4) lq,
               sum(fat) filter (where dia between $5 and $6) f7, sum(fat) filter (where dia between $7 and $8) g7
        from public.bi_venda where %s
        group by grouping sets ((produto), (produto, mes))),
      top as (select produto from g where gm = 1 order by ft desc limit 2000)
      select json_build_object(
        'p', (select coalesce(json_agg(json_build_array(produto, fp, qp, lp, fq, qq, lq, f7, g7, ft, qt, lt)), '[]') from g where gm = 1),
        'pm', (select coalesce(json_agg(json_build_array(g.produto, mes, ft, qt, lt)), '[]') from g join top t on t.produto = g.produto where gm = 0))$q$, w)
    into res using i1, i2, q1, q2, s1, s2, t1, t2;
  end if;
  -- só a visão sem filtros (a de abertura) vai para o cache: poucas combinações, apagadas a cada carga
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $$;

create or replace function public.bi_vendedores(f jsonb, per jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $$
declare w text; res json; ck text;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb), 'vendedor');
  ck := md5(concat_ws('|', 'vendedores', w, per->>'ini', per->>'fim'));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with b as materialized (select * from public.bi_venda where %s and dia between $1 and $2),
    g as (
      select case when grouping(marca)=0 then 'vm' when grouping(categoria)=0 then 'vc' when grouping(dia)=0 then 'vd'
                  when grouping(produto)=0 then 'vp' else 'v' end s,
             vendedor, coalesce(marca, categoria, produto) k, dia, sum(fat) ft, sum(qtd) qt, sum(lb) lt
      from b group by grouping sets ((vendedor),(vendedor,marca),(vendedor,categoria),(vendedor,dia),(vendedor,produto))
    ), topp as (select k from g where s = 'vp' group by k order by sum(ft) desc limit 10)
    select json_build_object(
      'v', (select coalesce(json_agg(json_build_array(vendedor, ft, qt, lt)), '[]') from g where s = 'v'),
      'vm', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vm'),
      'vc', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vc'),
      'vd', (select coalesce(json_agg(json_build_array(vendedor, dia, ft)), '[]') from g where s = 'vd'),
      'vp', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vp' and k in (select k from topp)),
      'vs', (select coalesce(json_agg(json_build_array(vendedor, n)), '[]') from (
               select vendedor, avg(n) n from (select vendedor, mes, count(distinct produto) n from b group by 1, 2) x group by 1) y)
    )$q$, w)
  into res using (per->>'ini')::date, (per->>'fim')::date;
  if coalesce(f, '{}'::jsonb) - 'vendedor' = '{}'::jsonb then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $$;

-- série diária de um produto no recorte atual (gráfico do detalhe do produto)
create or replace function public.bi_produto_serie(f jsonb, produto int)
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare w text; res json;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb) - 'produto');
  execute format('select coalesce(json_agg(json_build_array(dia, f, q) order by dia), ''[]'') from (
    select dia, sum(fat) f, sum(qtd) q from public.bi_venda where produto = $1 and %s group by dia) x', w) into res using produto;
  return res;
end $$;

revoke all on function public.bi_painel(jsonb, jsonb, text), public.bi_produto_serie(jsonb, int) from public, anon;
grant execute on function public.bi_painel(jsonb, jsonb, text), public.bi_produto_serie(jsonb, int) to authenticated;
-- versão antiga (uma chamada só, lenta demais): fica sem acesso
revoke execute on function public.bi_painel(jsonb, jsonb) from authenticated;
