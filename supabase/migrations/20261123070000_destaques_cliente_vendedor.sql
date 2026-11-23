-- Destaques do dia: cada cliente em destaque passa a vir com o vendedor que mais faturou para ele no dia (cli_vend).
create or replace function public.bi_vendas_destaques(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; d0 date; nd int; tot json; cm numeric; nm numeric; r jsonb := '{}'::jsonb; x json;
  dims text[][] := array[
    ['lojas', 'loja', 'null', 'fat'], ['canais', 'canal', 'null', 'fat'], ['marcas', 'marca', 'null', 'fat'],
    ['categorias', 'categoria', 'null', 'fat'], ['vendedores', 'vendedor', 'null', 'fat'],
    ['produtos', 'produto', '(select p.pn || '' · '' || coalesce(p.nome, '''') from public.bi_produto p where p.id = x.k)', 'fat'],
    ['produtos_q', 'produto', '(select p.pn || '' · '' || coalesce(p.nome, '''') from public.bi_produto p where p.id = x.k)', 'qtd'],
    ['clientes', 'cliente', '(select coalesce(nullif(c.razao, ''''), c.codcli::text) from public.bi_cliente c where c.id = x.k)', 'fat']];
  i int;
begin
  f := coalesce(f, '{}'::jsonb);
  w := private.bi_where(f);
  d0 := coalesce(dia, (select max(v.dia) from public.bi_venda v));
  ck := md5(concat_ws('|', 'vdest2', w, d0));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  -- uma leitura só da base (60 dias + o dia); as contas seguintes saem dessa cópia temporária
  if to_regclass('pg_temp.vd_base') is not null then drop table pg_temp.vd_base; end if;
  execute format('create temp table vd_base on commit drop as select dia, loja, canal, marca, categoria, vendedor, produto, cliente, nf, fat, lb, qtd
                    from public.bi_venda where %s and dia between $1 - 60 and $1', w) using d0;
  select count(distinct b.dia) into nd from pg_temp.vd_base b where b.dia < d0;
  nd := greatest(coalesce(nd, 0), 1);
  execute format($q$
    select json_build_object('fh', sum(fat) filter (where dia = $1), 'lh', sum(lb) filter (where dia = $1), 'qh', sum(qtd) filter (where dia = $1),
             'clih', count(distinct cliente) filter (where dia = $1), 'nfh', count(distinct nf) filter (where dia = $1),
             'fb', sum(fat) filter (where dia < $1), 'lb', sum(lb) filter (where dia < $1), 'qb', sum(qtd) filter (where dia < $1))
      from pg_temp.vd_base$q$) into tot using d0;
  execute format($q$
    select avg(c), avg(n) from (select dia, count(distinct cliente) c, count(distinct nf) n from pg_temp.vd_base
                                 where dia < $1 group by dia) y$q$) into cm, nm using d0;
  for i in 1 .. array_length(dims, 1) loop
    execute format($q$
      select coalesce(json_agg(json_build_array(k, fh, lh, qh, fb, qb, ch, %s)), '[]'::json) from (
        select %I k, sum(fat) filter (where dia = $1) fh, sum(lb) filter (where dia = $1) lh, sum(qtd) filter (where dia = $1) qh,
               coalesce(sum(fat) filter (where dia < $1), 0) fb, coalesce(sum(qtd) filter (where dia < $1), 0) qb,
               count(distinct cliente) filter (where dia = $1) ch
          from pg_temp.vd_base where %I is not null
         group by 1 having sum(%s) filter (where dia = $1) > 0
         order by sum(%s) filter (where dia = $1) - coalesce(sum(%s) filter (where dia < $1), 0) / %s::numeric desc
         limit 10) x$q$, dims[i][3], dims[i][2], dims[i][2], dims[i][4], dims[i][4], dims[i][4], nd)
    into x using d0;
    r := r || jsonb_build_object(dims[i][1], x::jsonb);
  end loop;
  -- vendedor principal de cada cliente em destaque (quem mais faturou para ele no dia): {cliente: vendedor}
  select coalesce(jsonb_object_agg(cliente::text, vendedor), '{}'::jsonb) into x from (
    select distinct on (b.cliente) b.cliente, b.vendedor from pg_temp.vd_base b
     where b.dia = d0 and b.vendedor is not null
       and b.cliente in (select (e->>0)::int from jsonb_array_elements(coalesce(r->'clientes', '[]'::jsonb)) e)
     group by b.cliente, b.vendedor order by b.cliente, sum(b.fat) desc) y;
  r := r || jsonb_build_object('cli_vend', x::jsonb);
  res := (jsonb_build_object('dia', d0, 'nd', nd, 'tot', tot::jsonb, 'cli_med', round(cm, 1), 'nf_med', round(nm, 1)) || r)::json;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_vendas_destaques(jsonb, date) from public, anon;
grant execute on function public.bi_vendas_destaques(jsonb, date) to authenticated;
