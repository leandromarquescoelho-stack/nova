-- Dashboard: ticker com destaques além do estoque (o gerenciador escolhe em Configurações o que aparece).
-- 1) bi_ticker(f, dia): destaques do dia, do mês e do ano no escopo do usuário (valores em centavos)
--    {dia,
--     vend: {d:[[vendedor, fat, lb]], m:[...], a:[...]}                         top 3 do dia, do mês e do ano
--     cres: {fat:[vendedor, atual, anterior], mix:[...], part:[...], mg:[...]}  quem mais cresceu no mês até o dia
--           contra os mesmos dias do mês anterior (mix = produtos diferentes; part = participação no faturamento;
--           mg = margem bruta). Só vendedores com pelo menos R$ 5 mil nos dois períodos.
--     prod: [[produto, nome, qtd, fat]]                     mais vendidos do dia (faturamento)
--     notas: [[nf, cliente, loja, vendedor, fat, itens]]    maiores vendas (notas) do dia
--     novos: {n, fat, top:[[cliente, loja, fat]]}           clientes que compraram no dia sem compra nos 365 dias anteriores
--     cli: [[cliente, fat, notas]]}                         clientes que mais compraram no dia
-- 2) bi_config 'ticker' = {"itens": {"estoque": true, ...}}: o que o ticker mostra; só o perfil BI grava.
create or replace function public.bi_ticker(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '64MB'
as $function$
declare w text; res json; ck text; d0 date; m0 date; a0 date; p0 date; p1 date;
  vend json; cres json; prod json; notas json; novos json; cli json;
begin
  f := coalesce(f, '{}'::jsonb) - 'produto';
  w := private.bi_where(f);
  d0 := coalesce(dia, (select max(v.dia) from public.bi_venda v));
  ck := md5(concat_ws('|', 'ticker1', w, d0));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  m0 := date_trunc('month', d0)::date; a0 := date_trunc('year', d0)::date;
  p0 := (m0 - interval '1 month')::date; p1 := least((p0 + (d0 - m0))::date, m0 - 1);

  -- vendedores: uma leitura do ano (e do mês anterior, em janeiro) com tudo o que os rankings precisam
  if to_regclass('pg_temp.tk_v') is not null then drop table pg_temp.tk_v; end if;
  execute format($q$create temp table tk_v on commit drop as
    select vendedor,
           coalesce(sum(fat) filter (where dia = $1), 0) fd, coalesce(sum(lb) filter (where dia = $1), 0) ld,
           coalesce(sum(fat) filter (where dia >= $2), 0) fm, coalesce(sum(lb) filter (where dia >= $2), 0) lm,
           count(distinct produto) filter (where dia >= $2) xm,
           coalesce(sum(fat) filter (where dia >= $3), 0) fa, coalesce(sum(lb) filter (where dia >= $3), 0) la,
           coalesce(sum(fat) filter (where dia between $4 and $5), 0) fp, coalesce(sum(lb) filter (where dia between $4 and $5), 0) lp,
           count(distinct produto) filter (where dia between $4 and $5) xp
      from public.bi_venda where %s and dia between least($3, $4) and $1 and vendedor is not null
     group by vendedor$q$, w) using d0, m0, a0, p0, p1;
  select json_build_object(
    'd', (select coalesce(json_agg(json_build_array(vendedor, fd, ld) order by fd desc), '[]') from (select * from pg_temp.tk_v where fd > 0 order by fd desc limit 3) x),
    'm', (select coalesce(json_agg(json_build_array(vendedor, fm, lm) order by fm desc), '[]') from (select * from pg_temp.tk_v where fm > 0 order by fm desc limit 3) x),
    'a', (select coalesce(json_agg(json_build_array(vendedor, fa, la) order by fa desc), '[]') from (select * from pg_temp.tk_v where fa > 0 order by fa desc limit 3) x))
  into vend;
  with t as (select sum(fm) tm, sum(fp) tp from pg_temp.tk_v),
       c as (select v.vendedor, v.fm, v.fp, v.xm, v.xp, v.lm::numeric / v.fm mgm, v.lp::numeric / v.fp mgp,
                    v.fm::numeric / nullif(t.tm, 0) pm, v.fp::numeric / nullif(t.tp, 0) pp
               from pg_temp.tk_v v, t where v.fm >= 500000 and v.fp >= 500000)
  select json_build_object(
    'fat',  (select json_build_array(vendedor, fm, fp) from c where fm > fp order by fm::numeric / fp desc limit 1),
    'mix',  (select json_build_array(vendedor, xm, xp) from c where xm > xp order by xm - xp desc, fm desc limit 1),
    'part', (select json_build_array(vendedor, round(pm * 10000) / 100, round(pp * 10000) / 100) from c where pm > pp order by pm - pp desc limit 1),
    'mg',   (select json_build_array(vendedor, round(mgm * 10000) / 100, round(mgp * 10000) / 100) from c where mgm > mgp order by mgm - mgp desc limit 1))
  into cres;

  -- vendas do dia (poucas linhas, pelo índice de dia)
  if to_regclass('pg_temp.tk_d') is not null then drop table pg_temp.tk_d; end if;
  execute format($q$create temp table tk_d on commit drop as
    select produto, cliente, nf, loja, vendedor, qtd, fat from public.bi_venda where %s and dia = $1$q$, w) using d0;
  select coalesce(json_agg(json_build_array(x.produto, p.pn || ' · ' || coalesce(p.nome, ''), x.q, x.ft) order by x.ft desc), '[]')
    into prod
    from (select produto, sum(qtd) q, sum(fat) ft from pg_temp.tk_d where produto is not null group by 1 order by 3 desc limit 5) x
    left join public.bi_produto p on p.id = x.produto;
  select coalesce(json_agg(json_build_array(x.nf, coalesce(c.razao, c.codcli), x.loja, x.vendedor, x.ft, x.n) order by x.ft desc), '[]')
    into notas
    from (select nf, cliente, loja, max(vendedor) vendedor, sum(fat) ft, count(*) n from pg_temp.tk_d
           where nf is not null group by 1, 2, 3 order by 5 desc limit 5) x
    left join public.bi_cliente c on c.id = x.cliente;
  execute format($q$
    with n as (select d.cliente, max(d.loja) loja, sum(d.fat) ft from pg_temp.tk_d d where d.cliente is not null group by 1),
         nv as (select n.* from n where not exists (select 1 from public.bi_venda v where v.cliente = n.cliente
                                                    and v.dia between $1 - 365 and $1 - 1 and %s))
    select json_build_object('n', (select count(*) from nv), 'fat', (select coalesce(sum(ft), 0) from nv),
      'top', (select coalesce(json_agg(json_build_array(coalesce(c.razao, c.codcli), x.loja, x.ft) order by x.ft desc), '[]')
                from (select * from nv order by ft desc limit 5) x left join public.bi_cliente c on c.id = x.cliente))$q$, w)
  into novos using d0;
  select coalesce(json_agg(json_build_array(coalesce(c.razao, c.codcli), x.ft, x.n) order by x.ft desc), '[]')
    into cli
    from (select cliente, sum(fat) ft, count(distinct nf) n from pg_temp.tk_d where cliente is not null group by 1 order by 2 desc limit 3) x
    left join public.bi_cliente c on c.id = x.cliente;

  res := json_build_object('dia', d0, 'vend', vend, 'cres', cres, 'prod', prod, 'notas', notas, 'novos', novos, 'cli', cli);
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_ticker(jsonb, date) from public, anon;
grant execute on function public.bi_ticker(jsonb, date) to authenticated;

-- o que o ticker mostra (Configurações); só o perfil BI grava
create or replace function public.bi_config_ticker_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare it jsonb := '{}'::jsonb; k text;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI altera o ticker';
  end if;
  foreach k in array array['estoque','alta','vend_dia','vend_mes','vend_ano','cres_fat','cres_mix','cres_part','cres_mg',
                           'mais_vendidos','notas','cli_novos','cli_top'] loop
    it := it || jsonb_build_object(k, coalesce((p->'itens'->>k)::boolean, false));
  end loop;
  insert into public.bi_config (chave, valor)
    values ('ticker', jsonb_build_object('itens', it, 'por', auth.uid(), 'em', now()))
    on conflict (chave) do update set valor = excluded.valor;
end $function$;
revoke all on function public.bi_config_ticker_gravar(jsonb) from public, anon;
grant execute on function public.bi_config_ticker_gravar(jsonb) to authenticated;
