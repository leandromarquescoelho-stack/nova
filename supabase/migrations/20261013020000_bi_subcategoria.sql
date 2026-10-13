-- Subcategoria (coluna SUBGRUPO da planilha de vendas) como dimensão e filtro do painel.
-- Colunas novas começam em 0 e são preenchidas na próxima carga.
alter table public.bi_venda add column if not exists subcategoria smallint not null default 0;
alter table public.bi_produto add column if not exists subcategoria smallint not null default 0;

create or replace function private.bi_where(f jsonb, ignorar text default null::text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare e record; w text[] := array['true']; k text; arr jsonb; ids bigint[];
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if not e.todas then
    if e.lojas is not null then w := w || format('loja = any(%L::smallint[])', e.lojas); end if;
    if e.canais is not null then w := w || format('canal = any(%L::smallint[])', e.canais); end if;
    if e.vendedor is not null then w := w || format('vendedor = %s', e.vendedor); end if;
  end if;
  foreach k in array array['loja','canal','emitente','origem','vendedor','linha','marca','categoria','subcategoria','montadora',
                           'classificacao','tipo_cliente','cidade','produto','cliente','nf'] loop
    continue when k = ignorar;
    arr := f -> k;
    if arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      w := w || format('%I = any(%L::%s[])', k, ids, case when k in ('produto','cliente','nf') then 'int' else 'smallint' end);
    end if;
  end loop;
  return array_to_string(w, ' and ');
end $function$;

create or replace function public.bi_meta()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare w text; res json;
begin
  w := private.bi_where('{}'::jsonb);
  execute format($q$
    with g as (
      select case when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(emitente)=0 then 'emitente'
                  when grouping(origem)=0 then 'origem' when grouping(vendedor)=0 then 'vendedor' when grouping(linha)=0 then 'linha'
                  when grouping(marca)=0 then 'marca' when grouping(categoria)=0 then 'categoria' when grouping(subcategoria)=0 then 'subcategoria'
                  when grouping(montadora)=0 then 'montadora'
                  when grouping(classificacao)=0 then 'classificacao' when grouping(tipo_cliente)=0 then 'tipo_cliente'
                  when grouping(cidade)=0 then 'cidade' else 'mes' end tipo,
             coalesce(loja, canal, emitente, origem, vendedor, linha, marca, categoria, subcategoria, montadora, classificacao, tipo_cliente, cidade, mes) id
      from public.bi_venda where %s
      group by grouping sets ((loja),(canal),(emitente),(origem),(vendedor),(linha),(marca),(categoria),(subcategoria),(montadora),
                              (classificacao),(tipo_cliente),(cidade),(mes))
    )
    select json_build_object(
      'dims', (select json_object_agg(tipo, vals) from (
                 select g.tipo, json_agg(json_build_array(g.id, d.valor) order by d.valor) vals
                 from g join public.bi_dim d on d.tipo = g.tipo and d.id = g.id group by g.tipo) z),
      'meses', (select json_agg(id order by id) from g where tipo = 'mes'),
      'dias', (select json_build_array(min(dia), max(dia)) from public.bi_venda),
      'produtos', (select json_agg(json_build_array(p.id, p.pn, p.nome, p.categoria, p.marca, p.montadora, p.linha, p.classificacao, p.subcategoria))
                   from public.bi_produto p),
      'dimTodas', (select json_object_agg(tipo, vals) from (
                 select d.tipo, json_agg(json_build_array(d.id, d.valor)) vals from public.bi_dim d
                 where d.tipo in ('categoria','subcategoria','marca','montadora','linha','classificacao','loja') group by d.tipo) z)
    )$q$, w) into res;
  return res;
end $function$;

create or replace function public.bi_painel(f jsonb, per jsonb, parte text)
 returns json language plpgsql security definer set search_path to '' set work_mem to '48MB'
as $function$
declare w text; res json; ck text;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; q1 date := (per->>'pini')::date; q2 date := (per->>'pfim')::date;
  s1 date := (per->>'s7i')::date; s2 date := (per->>'s7f')::date; t1 date := (per->>'p7i')::date; t2 date := (per->>'p7f')::date;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'painel2', parte, w, i1, i2, q1, q2, s1, s2, t1, t2));
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
                    when grouping(categoria)=0 then 'categoria' when grouping(subcategoria)=0 then 'subcategoria'
                    when grouping(marca)=0 then 'marca' when grouping(montadora)=0 then 'montadora'
                    when grouping(linha)=0 then 'linha' when grouping(emitente)=0 then 'emitente' when grouping(origem)=0 then 'origem'
                    when grouping(tipo_cliente)=0 then 'tipo_cliente' when grouping(classificacao)=0 then 'classificacao' else 'cidade' end s,
               coalesce(loja, canal, vendedor, categoria, subcategoria, marca, montadora, linha, emitente, origem, tipo_cliente, classificacao, cidade) k,
               sum(fat) ft, sum(qtd) qt, sum(lb) lt,
               sum(fat) filter (where dia between $1 and $2) fp, sum(qtd) filter (where dia between $1 and $2) qp, sum(lb) filter (where dia between $1 and $2) lp,
               sum(fat) filter (where dia between $3 and $4) fq, sum(qtd) filter (where dia between $3 and $4) qq, sum(lb) filter (where dia between $3 and $4) lq
        from public.bi_venda where %s
        group by grouping sets ((loja),(canal),(vendedor),(categoria),(subcategoria),(marca),(montadora),(linha),
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
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $function$;
