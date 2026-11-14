-- Cliente do e-commerce (maior parte da compra no canal ECOMMERCE ou responsável "VENDEDOR ECOMMERCE") só ficam disponíveis (60 dias sem compra) se forem recorrentes: mais de 3 compras nos últimos 12 meses.
-- Os demais aparecem como 'ocasional'. Só troca a função bi_clientes.

-- Clientes. Base: vendas no escopo e filtros do painel (o filtro de vendedor vira "vendedor responsável").
-- Responsável = vendedor que mais faturou para o cliente nos últimos 365 dias.
-- o (opções da aba): tipo, grupo, pessoa, cidade, vend (ids), equipe (nomes), termo (status), busca, ordem ('fat'|'dias'|'media'|'margem'),
--   disp (só disponíveis: mais de 60 dias sem compra), limite (linhas; padrão 300)
-- Termômetro (referência = último dia com venda na base):
--   disponivel  mais de 60 dias sem compra (política); cliente do e-commerce só se for recorrente (mais de 3 compras em 12 meses)
--   ocasional   cliente do e-commerce com mais de 60 dias sem compra e até 3 compras em 12 meses (não entra nos disponíveis)
--   novo        primeira compra nos últimos 60 dias
--   esfriando   últimos 90 dias abaixo de 60% dos 90 anteriores, ou sem comprar há mais de 2x o intervalo médio entre compras
--   esquentando últimos 90 dias acima de 130% dos 90 anteriores
--   estavel     os demais
create or replace function public.bi_clientes(f jsonb, per jsonb, o jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '64MB'
as $function$
declare w text; res json; ck text; ow text[] := array['true']; ids bigint[]; ord text; lim int;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; vend bigint[]; eqs text[];
  ecom smallint := coalesce((select d.id from public.bi_dim d where d.tipo = 'canal' and d.valor = 'ECOMMERCE'), -1);
begin
  f := coalesce(f, '{}'::jsonb); o := coalesce(o, '{}'::jsonb);
  w := private.bi_where(f, 'vendedor');
  ck := md5(concat_ws('|', 'clientes2', w, f->'vendedor', i1, i2, o));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  -- filtros rápidos da aba
  if jsonb_typeof(f->'vendedor') = 'array' and jsonb_array_length(f->'vendedor') > 0 then
    select array_agg(x::bigint) into vend from jsonb_array_elements_text(f->'vendedor') x;
    ow := ow || format('resp = any(%L::smallint[])', vend);
  end if;
  if jsonb_typeof(o->'vend') = 'array' and jsonb_array_length(o->'vend') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(o->'vend') x;
    ow := ow || format('resp = any(%L::smallint[])', ids);
  end if;
  if jsonb_typeof(o->'equipe') = 'array' and jsonb_array_length(o->'equipe') > 0 then
    select array_agg(x) into eqs from jsonb_array_elements_text(o->'equipe') x;
    ow := ow || format('equipe = any(%L::text[])', eqs);
  end if;
  if jsonb_typeof(o->'tipo') = 'array' and jsonb_array_length(o->'tipo') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(o->'tipo') x; ow := ow || format('tc = any(%L::smallint[])', ids); end if;
  if jsonb_typeof(o->'grupo') = 'array' and jsonb_array_length(o->'grupo') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(o->'grupo') x; ow := ow || format('gc = any(%L::smallint[])', ids); end if;
  if jsonb_typeof(o->'pessoa') = 'array' and jsonb_array_length(o->'pessoa') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(o->'pessoa') x; ow := ow || format('pe = any(%L::smallint[])', ids); end if;
  if jsonb_typeof(o->'cidade') = 'array' and jsonb_array_length(o->'cidade') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(o->'cidade') x; ow := ow || format('ci = any(%L::smallint[])', ids); end if;
  if coalesce(o->>'busca', '') <> '' then
    ow := ow || format('(razao ilike %L or codcli ilike %L)', '%' || (o->>'busca') || '%', (o->>'busca') || '%');
  end if;
  if coalesce((o->>'disp')::boolean, false) then ow := ow || $t$termo = 'disponivel'$t$::text; end if;
  ord := case o->>'ordem' when 'dias' then 'dias desc, f12 desc' when 'dias_asc' then 'dias asc, fp desc nulls last'
                          when 'media' then 'med desc nulls last' when 'margem' then 'mg desc nulls last'
                          when 'f12' then 'f12 desc nulls last' else 'fp desc nulls last, f12 desc nulls last' end;
  lim := least(greatest(coalesce((o->>'limite')::int, 300), 1), 50000);
  execute format($q$
    with r as (select max(dia) ref from public.bi_venda),
    b as materialized (select cliente, vendedor, canal, dia, fat, lb, tipo_cliente, grupo_cliente, pessoa, cidade
                       from public.bi_venda where %1$s),
    v as (select cliente, vendedor, row_number() over (partition by cliente order by sum(fat) desc) rn
          from b, r where dia > r.ref - 365 group by cliente, vendedor),
    c as (select b.cliente, max(dia) ult, min(dia) pri, min(dia) filter (where dia > r.ref - 365) pri12,
                 count(distinct dia) filter (where dia > r.ref - 365) ncomp,
                 sum(fat) filter (where dia between $1 and $2) fp, sum(lb) filter (where dia between $1 and $2) lp,
                 sum(fat) filter (where dia > r.ref - 365) f12, sum(lb) filter (where dia > r.ref - 365) l12,
                 sum(fat) filter (where dia > r.ref - 90) f90, sum(fat) filter (where dia > r.ref - 180 and dia <= r.ref - 90) f180,
                 max(tipo_cliente) tc, max(grupo_cliente) gc,
                 max(pessoa) pe, max(cidade) ci, max(r.ref) ref,
                 coalesce(sum(fat) filter (where canal = %6$s), 0) > 0.5 * coalesce(sum(fat), 0) ecom
          from b, r group by b.cliente),
    x as (select c.*, (c.ref - c.ult) dias, coalesce(v.vendedor, -1) resp, ve.equipe, cl.razao, cl.codcli,
                 c.f12 / greatest(1, least(12, ceil((c.ref - coalesce(c.pri12, c.ult) + 1) / 30.4375))) med,
                 case when c.f12 > 0 then c.l12::numeric / c.f12 end mg,
                 case when c.ncomp > 1 then (c.ult - c.pri12)::numeric / (c.ncomp - 1) end intv,
                 case when c.ref - c.ult > 60 and (c.ecom or coalesce(dv.valor, '') ilike '%%ECOMMERCE%%') and c.ncomp <= 3 then 'ocasional'
                      when c.ref - c.ult > 60 then 'disponivel'
                      when c.ref - c.pri <= 60 then 'novo'
                      when coalesce(c.f180, 0) > 0 and coalesce(c.f90, 0) < 0.6 * c.f180 then 'esfriando'
                      when c.ncomp > 2 and (c.ref - c.ult) > 2 * (c.ult - c.pri12)::numeric / (c.ncomp - 1) and (c.ref - c.ult) > 15 then 'esfriando'
                      when coalesce(c.f180, 0) > 0 and coalesce(c.f90, 0) > 1.3 * c.f180 then 'esquentando'
                      else 'estavel' end termo
          from c left join v on v.cliente = c.cliente and v.rn = 1
          left join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = v.vendedor
          left join public.bi_vendedor_equipe ve on ve.vendedor = dv.valor
          left join public.bi_cliente cl on cl.id = c.cliente
          where c.ult > c.ref - 730),
    y as (select * from x where %2$s),
    t as (select * from y where %3$s)
    select json_build_object(
      'ref', (select max(ref) from x),
      'total', (select count(*) from t),
      'resumo', (select json_object_agg(termo, json_build_array(n, fp, f12)) from (
                   select termo, count(*) n, coalesce(sum(fp), 0) fp, coalesce(sum(f12), 0) f12 from y group by termo) z),
      'disp', (select json_build_array(count(*), coalesce(sum(f12), 0)) from y where termo = 'disponivel'),
      'linhas', (select coalesce(json_agg(json_build_array(cliente, codcli, razao, resp, equipe, tc, gc, pe, ci,
                         fp, lp, f12, med, round(mg * 1000) / 10, ult, dias, ncomp, round(intv), termo, f90, f180)), '[]')
                 from (select * from t order by %4$s limit %5$s) z)
    )$q$, w, array_to_string(ow, ' and '),
         case when jsonb_typeof(o->'termo') = 'array' and jsonb_array_length(o->'termo') > 0
              then format('termo = any(%L::text[])', (select array_agg(x) from jsonb_array_elements_text(o->'termo') x)) else 'true' end,
         ord, lim, ecom)
  into res using i1, i2;
  if f - 'vendedor' = '{}'::jsonb and lim <= 300 then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $function$;
revoke all on function public.bi_clientes(jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.bi_clientes(jsonb, jsonb, jsonb) to authenticated;
delete from public.bi_cache where true;
