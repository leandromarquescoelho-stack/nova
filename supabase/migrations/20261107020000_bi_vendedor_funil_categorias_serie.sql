-- Funil do vendedor, versão 2: entra o funil de categorias (clientes, marcas, categorias, produtos), o produto passa a vir
-- pela descrição e chega a série de vendas do período (por dia até 62 dias, por mês acima disso) com todas as seleções.
create or replace function public.bi_vendedor_funil(f jsonb, per jsonb, lim integer default 12)
 returns json language plpgsql stable security definer set search_path to '' set work_mem to '64MB'
as $$
declare
  res jsonb := '{}'; d text; w text; wg text; parte json; fg jsonb;
  de date := (per->>'ini')::date; ate date := (per->>'fim')::date;
  n int := least(greatest(coalesce(lim, 12), 3), 30);
  grao text := case when (per->>'fim')::date - (per->>'ini')::date <= 62 then 'dia' else 'mes' end;
begin
  if f is null or jsonb_typeof(f->'vendedor') <> 'array' then raise exception 'informe o vendedor'; end if;
  fg := f - 'vendedor' - 'cliente';
  foreach d in array array['cliente','marca','categoria','produto'] loop
    w := private.bi_where(f, d) || format(' and dia between %L and %L', de, ate);
    if d = 'cliente' then
      execute format($q$
        with t as (select cliente k, sum(fat) ft, sum(qtd) qt, sum(lb) lt, count(distinct (emitente, nf)) nn
                   from public.bi_venda where %s group by 1),
             tot as (select coalesce(sum(ft), 0) ft, count(*) filter (where ft > 0) n from t),
             top as (select * from t where ft > 0 order by ft desc limit %s)
        select json_build_object('tot', (select ft from tot), 'n', (select n from tot),
          'itens', coalesce((select json_agg(json_build_array(top.k, coalesce(nullif(c.razao, ''), c.codcli, 'Cliente '||top.k), c.codcli,
                                                             top.ft, top.qt, top.lt, top.nn) order by top.ft desc)
                             from top left join public.bi_cliente c on c.id = top.k), '[]'::json))$q$, w, n)
      into parte;
    else
      wg := private.bi_where(fg, d) || format(' and dia between %L and %L', de, ate);
      execute format($q$
        with t as (select %1$I k, sum(fat) ft, sum(qtd) qt, sum(lb) lt from public.bi_venda where %2$s group by 1),
             tot as (select coalesce(sum(ft), 0) ft, count(*) filter (where ft > 0) n from t),
             top as (select * from t where ft > 0 order by ft desc limit %3$s),
             g as (select %1$I k, sum(fat) ft from public.bi_venda where %4$s and %1$I = any(array(select k from top)) group by 1)
        select json_build_object('tot', (select ft from tot), 'n', (select n from tot),
          'gtot', (select coalesce(sum(fat), 0) from public.bi_venda where %4$s),
          'itens', coalesce((select json_agg(json_build_array(top.k, %5$s, %6$s, top.ft, top.qt, top.lt, coalesce(g.ft, 0)) order by top.ft desc)
                             from top left join g on g.k = top.k), '[]'::json))$q$,
        d, w, n, wg,
        case when d = 'produto'
             then '(select coalesce(nullif(p.nome, ''''), p.pn) from public.bi_produto p where p.id = top.k)'
             else format('(select x.valor from public.bi_dim x where x.tipo = %L and x.id = top.k)', d) end,
        case when d = 'produto' then '(select p.pn from public.bi_produto p where p.id = top.k)' else 'null' end)
      into parte;
    end if;
    res := res || jsonb_build_object(d, parte);
  end loop;
  -- vendas do período com todas as seleções: por dia ou por mês, conforme o tamanho do período
  w := private.bi_where(f) || format(' and dia between %L and %L', de, ate);
  execute format($q$
    select json_build_object('grao', %L, 'pts', coalesce(json_agg(json_build_array(k, ft, qt) order by k), '[]'::json))
    from (select %s k, sum(fat) ft, sum(qtd) qt from public.bi_venda where %s group by 1) s$q$,
    grao, case when grao = 'dia' then 'dia::text' else 'mes' end, w)
  into parte;
  res := res || jsonb_build_object('serie', parte);
  return res;
end $$;
revoke all on function public.bi_vendedor_funil(jsonb, jsonb, integer) from public, anon;
grant execute on function public.bi_vendedor_funil(jsonb, jsonb, integer) to authenticated;
