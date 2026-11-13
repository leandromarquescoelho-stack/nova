-- Login mais leve, quadros do dashboard e análise de clientes.
--   bi_meta_leve   opções de filtro sem o cadastro de produtos (o login não baixa mais ~2 MB de produtos)
--                  + equipe de cada vendedor (comparativo dos pares por equipe)
--   bi_produtos    cadastro de produtos, buscado só quando uma aba precisa dele
--   bi_kpis        notas e clientes distintos (ticket por NF e por cliente) e estoque a custo do recorte
--   bi_clientes    análise de clientes: responsável (vendedor que mais faturou), média, margem, última compra,
--                  termômetro e clientes disponíveis (política de 60 dias sem compra)
-- Só acrescenta funções; nada é apagado.

create or replace function public.bi_meta_leve()
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text;
begin
  w := private.bi_where('{}'::jsonb);
  ck := md5('metaleve|' || w);
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  res := ((public.bi_meta()::jsonb - 'produtos') || jsonb_build_object('vequipe',
           coalesce((select jsonb_agg(jsonb_build_array(d.id, ve.equipe)) from public.bi_vendedor_equipe ve
                     join public.bi_dim d on d.tipo = 'vendedor' and d.valor = ve.vendedor where ve.equipe is not null), '[]'::jsonb)))::json;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_meta_leve() from public, anon;
grant execute on function public.bi_meta_leve() to authenticated;

create or replace function public.bi_produtos()
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare e record; res json;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  select c.valor into res from public.bi_cache c where c.chave = 'produtos';
  if found then return res; end if;
  select coalesce(json_agg(json_build_array(p.id, p.pn, p.nome, p.categoria, p.marca, p.montadora, p.linha, p.classificacao,
                                            p.subcategoria, p.grupo_peca, p.aplicacao, p.curva_gm)), '[]')
    into res from public.bi_produto p;
  insert into public.bi_cache (chave, valor) values ('produtos', res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_produtos() from public, anon;
grant execute on function public.bi_produtos() to authenticated;

-- notas: no histórico (antes de 2026) não há número da nota; cada cliente por dia conta como uma nota
create or replace function public.bi_kpis(f jsonb, per jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $function$
declare w text; res json; ck text; e record; ew text[] := array['true']; k text; arr jsonb; ids bigint[]; sov boolean := false;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; q1 date := (per->>'pini')::date; q2 date := (per->>'pfim')::date;
  v json; s json;
begin
  f := coalesce(f, '{}'::jsonb);
  w := private.bi_where(f);
  ck := md5(concat_ws('|', 'kpis1', w, i1, i2, q1, q2));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    select json_build_array(
      count(distinct nf) filter (where nf > 0 and dia between $1 and $2) + count(distinct (dia, cliente)) filter (where nf = 0 and dia between $1 and $2),
      count(distinct cliente) filter (where dia between $1 and $2),
      count(distinct nf) filter (where nf > 0 and dia between $3 and $4) + count(distinct (dia, cliente)) filter (where nf = 0 and dia between $3 and $4),
      count(distinct cliente) filter (where dia between $3 and $4))
    from public.bi_venda where %s and (dia between $1 and $2 or dia between $3 and $4)$q$, w)
  into v using i1, i2, q1, q2;
  -- estoque a custo do recorte: loja e atributos do produto; com filtro só de venda, apenas produtos vendidos no recorte
  select * into e from private.bi_escopo();
  if not e.todas and e.lojas is not null then ew := ew || format('s.loja = any(%L::smallint[])', e.lojas); end if;
  if jsonb_typeof(f->'loja') = 'array' and jsonb_array_length(f->'loja') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(f->'loja') x;
    ew := ew || format('s.loja = any(%L::smallint[])', ids);
  end if;
  foreach k in array array['linha','marca','categoria','subcategoria','montadora','classificacao','grupo_peca','aplicacao','curva_gm'] loop
    arr := f -> k;
    if jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      ew := ew || format('p.%I = any(%L::smallint[])', k, ids);
    end if;
  end loop;
  if jsonb_typeof(f->'produto') = 'array' and jsonb_array_length(f->'produto') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(f->'produto') x;
    ew := ew || format('s.produto = any(%L::int[])', ids);
  end if;
  foreach k in array array['vendedor','canal','origem','emitente','tipo_cliente','cidade','grupo_cliente','pessoa','condicao','equipe','funcao','cliente','nf'] loop
    if jsonb_typeof(f->k) = 'array' and jsonb_array_length(f->k) > 0 then sov := true; end if;
  end loop;
  if sov then ew := ew || format('s.produto in (select distinct produto from public.bi_venda where %s)', w); end if;
  execute format($q$
    select json_build_array(coalesce(sum(s.custo), 0), coalesce(sum(s.est_fis), 0),
                            coalesce(sum(s.custo) filter (where s.parado and s.est_fis > 0), 0))
    from public.bi_estoque s left join public.bi_produto p on p.id = s.produto where %s$q$, array_to_string(ew, ' and '))
  into s;
  res := json_build_object('nf', v->0, 'cli', v->1, 'nfp', v->2, 'clip', v->3,
                           'est_custo', s->0, 'est_qtd', s->1, 'est_parado', s->2);
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_kpis(jsonb, jsonb) from public, anon;
grant execute on function public.bi_kpis(jsonb, jsonb) to authenticated;

-- Clientes. Base: vendas no escopo e filtros do painel (o filtro de vendedor vira "vendedor responsável").
-- Responsável = vendedor que mais faturou para o cliente nos últimos 365 dias.
-- o (opções da aba): tipo, grupo, pessoa, cidade, vend (ids), equipe (nomes), termo (status), busca, ordem ('fat'|'dias'|'media'|'margem'),
--   disp (só disponíveis: mais de 60 dias sem compra), limite (linhas; padrão 300)
-- Termômetro (referência = último dia com venda na base):
--   disponivel  mais de 60 dias sem compra (política)
--   novo        primeira compra nos últimos 60 dias
--   esfriando   últimos 90 dias abaixo de 60% dos 90 anteriores, ou sem comprar há mais de 2x o intervalo médio entre compras
--   esquentando últimos 90 dias acima de 130% dos 90 anteriores
--   estavel     os demais
create or replace function public.bi_clientes(f jsonb, per jsonb, o jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '64MB'
as $function$
declare w text; res json; ck text; ow text[] := array['true']; ids bigint[]; ord text; lim int;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; vend bigint[]; eqs text[];
begin
  f := coalesce(f, '{}'::jsonb); o := coalesce(o, '{}'::jsonb);
  w := private.bi_where(f, 'vendedor');
  ck := md5(concat_ws('|', 'clientes1', w, f->'vendedor', i1, i2, o));
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
  if coalesce((o->>'disp')::boolean, false) then ow := ow || 'dias > 60'::text; end if;
  ord := case o->>'ordem' when 'dias' then 'dias desc, f12 desc' when 'dias_asc' then 'dias asc, fp desc nulls last'
                          when 'media' then 'med desc nulls last' when 'margem' then 'mg desc nulls last'
                          when 'f12' then 'f12 desc nulls last' else 'fp desc nulls last, f12 desc nulls last' end;
  lim := least(greatest(coalesce((o->>'limite')::int, 300), 1), 50000);
  execute format($q$
    with r as (select max(dia) ref from public.bi_venda),
    b as materialized (select cliente, vendedor, dia, fat, lb, tipo_cliente, grupo_cliente, pessoa, cidade
                       from public.bi_venda where %1$s),
    v as (select cliente, vendedor, row_number() over (partition by cliente order by sum(fat) desc) rn
          from b, r where dia > r.ref - 365 group by cliente, vendedor),
    c as (select b.cliente, max(dia) ult, min(dia) pri, min(dia) filter (where dia > r.ref - 365) pri12,
                 count(distinct dia) filter (where dia > r.ref - 365) ncomp,
                 sum(fat) filter (where dia between $1 and $2) fp, sum(lb) filter (where dia between $1 and $2) lp,
                 sum(fat) filter (where dia > r.ref - 365) f12, sum(lb) filter (where dia > r.ref - 365) l12,
                 sum(fat) filter (where dia > r.ref - 90) f90, sum(fat) filter (where dia > r.ref - 180 and dia <= r.ref - 90) f180,
                 max(tipo_cliente) tc, max(grupo_cliente) gc,
                 max(pessoa) pe, max(cidade) ci, max(r.ref) ref
          from b, r group by b.cliente),
    x as (select c.*, (c.ref - c.ult) dias, coalesce(v.vendedor, -1) resp, ve.equipe, cl.razao, cl.codcli,
                 c.f12 / greatest(1, least(12, ceil((c.ref - coalesce(c.pri12, c.ult) + 1) / 30.4375))) med,
                 case when c.f12 > 0 then c.l12::numeric / c.f12 end mg,
                 case when c.ncomp > 1 then (c.ult - c.pri12)::numeric / (c.ncomp - 1) end intv,
                 case when c.ref - c.ult > 60 then 'disponivel'
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
      'disp', (select json_build_array(count(*), coalesce(sum(f12), 0)) from y where dias > 60),
      'linhas', (select coalesce(json_agg(json_build_array(cliente, codcli, razao, resp, equipe, tc, gc, pe, ci,
                         fp, lp, f12, med, round(mg * 1000) / 10, ult, dias, ncomp, round(intv), termo, f90, f180)), '[]')
                 from (select * from t order by %4$s limit %5$s) z)
    )$q$, w, array_to_string(ow, ' and '),
         case when jsonb_typeof(o->'termo') = 'array' and jsonb_array_length(o->'termo') > 0
              then format('termo = any(%L::text[])', (select array_agg(x) from jsonb_array_elements_text(o->'termo') x)) else 'true' end,
         ord, lim)
  into res using i1, i2;
  if f - 'vendedor' = '{}'::jsonb and lim <= 300 then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $function$;
revoke all on function public.bi_clientes(jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.bi_clientes(jsonb, jsonb, jsonb) to authenticated;

-- vendedores sem equipe estavam gravados com o texto 'NaN' (corrigido na carga): volta a ficar sem equipe
update public.bi_vendedor_equipe set equipe = null where equipe in ('NaN', 'nan', 'None', '');
update public.bi_vendedor_equipe set funcao = null where funcao in ('NaN', 'nan', 'None', '');
delete from public.bi_dim where tipo in ('equipe', 'funcao') and valor in ('NaN', 'nan', 'None', '');
delete from public.bi_cache;
