-- Aba Clientes rápida: o resumo por cliente (última compra, compras e faturamento de 12 meses, termômetro, responsável)
-- passa a ser calculado na carga e gravado em bi_cliente_resumo. Calcular na hora levava ~25 s no banco e estourava
-- o limite de 8 s. Na tela fica só a soma do período escolhido (rápida).
-- Inclui a regra do e-commerce: cliente do e-commerce (maior parte da compra no canal ECOMMERCE ou responsável
-- "VENDEDOR ECOMMERCE") só fica disponível se tiver mais de 3 compras (dias com compra) nos últimos 12 meses.
-- Este arquivo substitui o clientes_recorrencia.sql.

create table if not exists public.bi_cliente_resumo (
  cliente int primary key,
  ult date, pri date, pri12 date, ncomp int,
  f12 bigint, l12 bigint, f90 bigint, f180 bigint,
  tipo_cliente smallint, grupo_cliente smallint, pessoa smallint, cidade smallint,
  vendedor smallint,            -- responsável: quem mais faturou para o cliente nos últimos 365 dias
  loja smallint, canal smallint, -- loja e canal em que o cliente mais comprou
  ecom boolean not null default false,
  ref date
);
alter table public.bi_cliente_resumo enable row level security;
revoke all on public.bi_cliente_resumo from anon, authenticated;

-- recalcula o resumo (a carga chama ao final; pode ser chamada à mão)
create or replace function private.bi_clientes_atualizar()
 returns void language plpgsql security definer set search_path to '' set work_mem to '128MB'
as $function$
declare ref date; ecom smallint;
begin
  select max(dia) into ref from public.bi_venda;
  ecom := coalesce((select d.id from public.bi_dim d where d.tipo = 'canal' and d.valor = 'ECOMMERCE'), -1);
  delete from public.bi_cliente_resumo;
  insert into public.bi_cliente_resumo
  with b as materialized (select cliente, vendedor, loja, canal, dia, fat, lb, tipo_cliente, grupo_cliente, pessoa, cidade
                          from public.bi_venda where dia > ref - 730),
  v as (select distinct on (cliente) cliente, vendedor from (
          select cliente, vendedor, sum(fat) ft from b where dia > ref - 365 group by 1, 2) x order by cliente, ft desc),
  l as (select distinct on (cliente) cliente, loja, canal from (
          select cliente, loja, canal, sum(fat) ft from b group by 1, 2, 3) x order by cliente, ft desc),
  c as (select cliente, max(dia) ult, min(dia) pri, min(dia) filter (where dia > ref - 365) pri12,
               count(distinct dia) filter (where dia > ref - 365) ncomp,
               sum(fat) filter (where dia > ref - 365) f12, sum(lb) filter (where dia > ref - 365) l12,
               sum(fat) filter (where dia > ref - 90) f90, sum(fat) filter (where dia > ref - 180 and dia <= ref - 90) f180,
               max(tipo_cliente) tc, max(grupo_cliente) gc, max(pessoa) pe, max(cidade) ci,
               coalesce(sum(fat) filter (where canal = ecom), 0) > 0.5 * coalesce(sum(fat), 0) ec
        from b group by cliente)
  select c.cliente, c.ult, c.pri, c.pri12, coalesce(c.ncomp, 0), c.f12, c.l12, c.f90, c.f180, c.tc, c.gc, c.pe, c.ci,
         v.vendedor, l.loja, l.canal,
         c.ec or coalesce((select d.valor from public.bi_dim d where d.tipo = 'vendedor' and d.id = v.vendedor), '') ilike '%ECOMMERCE%',
         ref
  from c left join v on v.cliente = c.cliente left join l on l.cliente = c.cliente;
end $function$;
revoke all on function private.bi_clientes_atualizar() from public, anon, authenticated;

-- Clientes. Escopo do perfil e filtros do painel de loja, canal, vendedor (= responsável), equipe, função, tipo, cidade,
-- grupo e pessoa valem sobre o cadastro do cliente (loja/canal principal e responsável). Os demais filtros (produto,
-- marca, categoria...) valem só para a coluna Período.
-- o: tipo, grupo, pessoa, cidade, vend (ids), equipe (nomes), termo, busca, ordem, disp, limite
-- Termômetro: disponivel (>60 dias sem compra; e-commerce só recorrente), ocasional (e-commerce >60 dias e até 3 compras),
--   novo (1ª compra nos últimos 60 dias), esfriando, esquentando, estavel
create or replace function public.bi_clientes(f jsonb, per jsonb, o jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '64MB'
as $function$
declare w text; wv text; res json; ck text; ow text[] := array['true']; ids bigint[]; ord text; lim int; eqs text[];
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; fc jsonb := '{}'::jsonb; k text;
begin
  f := coalesce(f, '{}'::jsonb); o := coalesce(o, '{}'::jsonb);
  foreach k in array array['loja','canal','vendedor','tipo_cliente','cidade','grupo_cliente','pessoa','cliente','equipe','funcao'] loop
    if f ? k then fc := fc || jsonb_build_object(k, f->k); end if;
  end loop;
  w := private.bi_where(fc);                 -- sobre o resumo do cliente (inclui o escopo do perfil)
  wv := private.bi_where(f, 'vendedor');     -- sobre as vendas do período
  ck := md5(concat_ws('|', 'clientes3', w, wv, i1, i2, o));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  if jsonb_typeof(o->'vend') = 'array' and jsonb_array_length(o->'vend') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(o->'vend') x; ow := ow || format('resp = any(%L::smallint[])', ids); end if;
  if jsonb_typeof(o->'equipe') = 'array' and jsonb_array_length(o->'equipe') > 0 then
    select array_agg(x) into eqs from jsonb_array_elements_text(o->'equipe') x; ow := ow || format('equipe = any(%L::text[])', eqs); end if;
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
  ord := case o->>'ordem' when 'dias' then 'dias desc, f12 desc nulls last' when 'dias_asc' then 'dias asc, fp desc nulls last'
                          when 'media' then 'med desc nulls last' when 'margem' then 'mg desc nulls last'
                          when 'f12' then 'f12 desc nulls last' else 'fp desc nulls last, f12 desc nulls last' end;
  lim := least(greatest(coalesce((o->>'limite')::int, 300), 1), 50000);
  execute format($q$
    with p as (select cliente, sum(fat) fp, sum(lb) lp from public.bi_venda where %1$s and dia between $1 and $2 group by cliente),
    c as (select r.cliente, r.ult, r.pri, r.pri12, r.ncomp, r.f12, r.l12, r.f90, r.f180, r.ref, r.ecom,
                 r.tipo_cliente tc, r.grupo_cliente gc, r.pessoa pe, r.cidade ci, r.vendedor
          from public.bi_cliente_resumo r where %2$s),
    x as (select c.cliente, c.ult, c.pri, c.pri12, c.ncomp, c.f12, c.l12, c.f90, c.f180, c.ref, c.tc, c.gc, c.pe, c.ci,
                 p.fp, p.lp, (c.ref - c.ult) dias, coalesce(c.vendedor, -1) resp, ve.equipe, cl.razao, cl.codcli,
                 c.f12 / greatest(1, least(12, ceil((c.ref - coalesce(c.pri12, c.ult) + 1) / 30.4375))) med,
                 case when c.f12 > 0 then c.l12::numeric / c.f12 end mg,
                 case when c.ncomp > 1 then (c.ult - c.pri12)::numeric / (c.ncomp - 1) end intv,
                 case when c.ref - c.ult > 60 and c.ecom and c.ncomp <= 3 then 'ocasional'
                      when c.ref - c.ult > 60 then 'disponivel'
                      when c.ref - c.pri <= 60 then 'novo'
                      when coalesce(c.f180, 0) > 0 and coalesce(c.f90, 0) < 0.6 * c.f180 then 'esfriando'
                      when c.ncomp > 2 and (c.ref - c.ult) > 2 * (c.ult - c.pri12)::numeric / (c.ncomp - 1) and (c.ref - c.ult) > 15 then 'esfriando'
                      when coalesce(c.f180, 0) > 0 and coalesce(c.f90, 0) > 1.3 * c.f180 then 'esquentando'
                      else 'estavel' end termo
          from c left join p on p.cliente = c.cliente
          left join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = c.vendedor
          left join public.bi_vendedor_equipe ve on ve.vendedor = dv.valor
          left join public.bi_cliente cl on cl.id = c.cliente),
    y as (select * from x where %3$s),
    t as (select * from y where %4$s)
    select json_build_object(
      'ref', (select max(ref) from public.bi_cliente_resumo),
      'total', (select count(*) from t),
      'resumo', (select json_object_agg(termo, json_build_array(n, fp, f12)) from (
                   select termo, count(*) n, coalesce(sum(fp), 0) fp, coalesce(sum(f12), 0) f12 from y group by termo) z),
      'disp', (select json_build_array(count(*), coalesce(sum(f12), 0)) from y where termo = 'disponivel'),
      'linhas', (select coalesce(json_agg(json_build_array(cliente, codcli, razao, resp, equipe, tc, gc, pe, ci,
                         fp, lp, f12, med, round(mg * 1000) / 10, ult, dias, ncomp, round(intv), termo, f90, f180)), '[]')
                 from (select * from t order by %5$s limit %6$s) z)
    )$q$, wv, w, array_to_string(ow, ' and '),
         case when jsonb_typeof(o->'termo') = 'array' and jsonb_array_length(o->'termo') > 0
              then format('termo = any(%L::text[])', (select array_agg(x) from jsonb_array_elements_text(o->'termo') x)) else 'true' end,
         ord, lim)
  into res using i1, i2;
  if lim <= 300 then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $function$;
revoke all on function public.bi_clientes(jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.bi_clientes(jsonb, jsonb, jsonb) to authenticated;

-- primeira carga do resumo (as próximas vêm com a carga do infobi)
select private.bi_clientes_atualizar();
delete from public.bi_cache where true;
