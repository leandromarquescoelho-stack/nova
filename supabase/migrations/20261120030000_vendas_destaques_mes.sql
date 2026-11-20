-- Vendas > Vendas Hoje: resumo do mês (mês até o dia comparado com o mesmo período dos 3 meses anteriores).
-- Mesmo formato de bi_vendas_destaques: "hoje" = mês até o dia; base = soma dos mesmos dias (1 até o dia) nos meses anteriores com venda;
-- nd = quantos meses entraram na base (até 3). {dia, mes:true, nd, tot, cli_med, nf_med, lojas, canais, marcas, categorias, produtos, produtos_q, clientes, vendedores}
create or replace function public.bi_vendas_destaques_mes(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; d0 date; m0 date; dd int; nd int; tot json; cm numeric; nm numeric; r jsonb := '{}'::jsonb; x json;
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
  m0 := date_trunc('month', d0)::date;
  dd := d0 - m0;   -- dias depois do dia 1 (o período de cada mês anterior vai do dia 1 ao mesmo dia, limitado ao fim do mês)
  ck := md5(concat_ws('|', 'vdestm1', w, d0));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  if to_regclass('pg_temp.vm_base') is not null then drop table pg_temp.vm_base; end if;
  -- h = mês atual até o dia; os 3 meses anteriores entram só do dia 1 ao mesmo dia
  execute format($q$create temp table vm_base on commit drop as
    select (dia >= $2) h, date_trunc('month', dia)::date mes, dia, loja, canal, marca, categoria, vendedor, produto, cliente, nf, fat, lb, qtd
      from public.bi_venda
     where %s and dia between ($2 - interval '3 months')::date and $1
       and (dia >= $2 or dia - date_trunc('month', dia)::date <= $3)$q$, w) using d0, m0, dd;
  select count(distinct b.mes) into nd from pg_temp.vm_base b where not b.h;
  nd := greatest(coalesce(nd, 0), 1);
  select json_build_object('fh', sum(fat) filter (where h), 'lh', sum(lb) filter (where h), 'qh', sum(qtd) filter (where h),
           'clih', count(distinct cliente) filter (where h), 'nfh', count(distinct nf) filter (where h),
           'fb', sum(fat) filter (where not h), 'lb', sum(lb) filter (where not h), 'qb', sum(qtd) filter (where not h))
    into tot from pg_temp.vm_base;
  select avg(c), avg(n) into cm, nm from (select mes, count(distinct cliente) c, count(distinct nf) n from pg_temp.vm_base
                                            where not h group by mes) y;
  for i in 1 .. array_length(dims, 1) loop
    execute format($q$
      select coalesce(json_agg(json_build_array(k, fh, lh, qh, fb, qb, ch, %s)), '[]'::json) from (
        select %I k, sum(fat) filter (where h) fh, sum(lb) filter (where h) lh, sum(qtd) filter (where h) qh,
               coalesce(sum(fat) filter (where not h), 0) fb, coalesce(sum(qtd) filter (where not h), 0) qb,
               count(distinct cliente) filter (where h) ch
          from pg_temp.vm_base where %I is not null
         group by 1 having sum(%s) filter (where h) > 0
         order by sum(%s) filter (where h) - coalesce(sum(%s) filter (where not h), 0) / %s::numeric desc
         limit 10) x$q$, dims[i][3], dims[i][2], dims[i][2], dims[i][4], dims[i][4], dims[i][4], nd)
    into x;
    r := r || jsonb_build_object(dims[i][1], x::jsonb);
  end loop;
  res := (jsonb_build_object('dia', d0, 'mes', true, 'nd', nd, 'tot', tot::jsonb, 'cli_med', round(cm, 1), 'nf_med', round(nm, 1)) || r)::json;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_vendas_destaques_mes(jsonb, date) from public, anon;
grant execute on function public.bi_vendas_destaques_mes(jsonb, date) to authenticated;
