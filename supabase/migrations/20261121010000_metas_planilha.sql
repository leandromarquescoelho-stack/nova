-- Metas e campanha vindas da planilha data-bi (abas lojas, meta_lojas, meta_vendas_vendedores, meta_lb_vendedores,
-- maratona e maratona_config). A carga grava; o site lê pelas funções.
-- Metas das lojas: mensais, gravadas em bi_objetivo com origem 'planilha'. Meta que veio da planilha não se edita no site;
-- o site só edita mês/loja sem meta na planilha.
-- Metas dos vendedores: venda é DIÁRIA (o site multiplica pelos dias úteis), LB é % de margem (não multiplica).
-- Maratona: pontos e crescimento por mês (bi_maratona_peso) e linha do mês (bi_maratona_cfg). Mês sem config usa o anterior
-- e o site mostra "linha do mês a definir".
-- Grava no banco: só estrutura (colunas, tabelas, funções). Os dados entram na próxima carga.

alter table public.bi_objetivo add column if not exists origem text not null default 'site';

create table if not exists public.bi_loja (
  codigo text primary key,            -- U000xx
  nome text not null,
  regiao text,
  divisao text);
alter table public.bi_loja enable row level security;
revoke all on public.bi_loja from anon, authenticated;

create table if not exists public.bi_meta_vend (
  re text not null,
  mes date not null,                  -- 1º dia do mês
  venda_dia numeric,                  -- meta de venda por dia
  lb numeric,                         -- meta de margem (0,27 = 27%)
  loja text,                          -- loja do vendedor (aba vendedores -> aba lojas): feriados municipais
  primary key (re, mes));
alter table public.bi_meta_vend add column if not exists loja text;
alter table public.bi_meta_vend enable row level security;
revoke all on public.bi_meta_vend from anon, authenticated;

-- pesos e crescimento por mês da campanha (aba maratona_config); mes = (ano-2000)*100 + mês, como em bi_maratona_cfg.
-- A linha do mês continua em bi_maratona_cfg (mes, linha_mes). Mês sem config usa o último mês anterior que tiver.
create table if not exists public.bi_maratona_peso (
  cod text not null,                  -- 1A..1Q (loc)
  mes smallint not null,
  pontos int not null,
  cresc numeric not null,
  primary key (cod, mes));
alter table public.bi_maratona_peso enable row level security;
revoke all on public.bi_maratona_peso from anon, authenticated;

-- {chave: valor, _planilha: [chaves que vieram da planilha]} do mês
create or replace function public.bi_objetivos(p_mes date)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record; res jsonb;
begin
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) then raise exception 'sem acesso ao painel'; end if;
  select coalesce(jsonb_object_agg(o.chave, o.valor), '{}'::jsonb)
         || jsonb_build_object('_planilha', coalesce(jsonb_agg(o.chave) filter (where o.origem = 'planilha'), '[]'::jsonb))
    into res
    from public.bi_objetivo o where o.mes = date_trunc('month', p_mes)::date;
  return res::json;
end $function$;

-- grava (ou apaga, com valor nulo) a meta de uma loja no mês; só BI e diretoria; a que veio da planilha não muda
create or replace function public.bi_objetivo_gravar(p_mes date, p_chave text, p_valor numeric)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare m date := date_trunc('month', p_mes)::date; c text := upper(btrim(coalesce(p_chave, '')));
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria')) then
    raise exception 'só BI e diretoria alteram as metas';
  end if;
  if c = '' or length(c) > 60 then raise exception 'loja inválida'; end if;
  if exists (select 1 from public.bi_objetivo o where o.mes = m and o.chave = c and o.origem = 'planilha') then
    raise exception 'a meta deste mês vem da planilha; altere na planilha';
  end if;
  if p_valor is null then
    delete from public.bi_objetivo where mes = m and chave = c;
  else
    if p_valor < 0 or p_valor > 1e12 then raise exception 'valor inválido'; end if;
    insert into public.bi_objetivo (mes, chave, valor) values (m, c, p_valor)
    on conflict (mes, chave) do update set valor = excluded.valor, atualizado_por = auth.uid(), atualizado_em = now();
  end if;
end $function$;

-- Maratona: pesos do mês e linha do mês com atraso (recriada a partir de 20261120020000_maratona_pontos.sql)
create or replace function public.bi_maratona(f jsonb, p_mes int default null)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; m0 smallint; ms smallint[]; d0 date; lm text; lm_def boolean; vis smallint[]; cats json; vend json; atc smallint; vpart smallint[];
begin
  f := coalesce(f, '{}'::jsonb);
  f := jsonb_strip_nulls(jsonb_build_object('loja', f->'loja', 'vendedor', f->'vendedor', 'equipe', f->'equipe', 'funcao', f->'funcao'));
  w := private.bi_where(f);
  m0 := coalesce(p_mes::smallint, (select max(v.mes) from public.bi_venda v));
  d0 := make_date(2000 + m0 / 100, m0 % 100, 1);
  ms := array(select ((extract(year from x) - 2000) * 100 + extract(month from x))::smallint
                from generate_series(d0 - interval '5 month', d0 - interval '1 month', interval '1 month') x order by x);
  -- linha do mês: a do mês; sem ela (atraso), a do último mês anterior; sem nenhuma, CF
  lm_def := exists (select 1 from public.bi_maratona_cfg c where c.mes = m0);
  lm := coalesce((select c.linha_mes from public.bi_maratona_cfg c where c.mes <= m0 order by c.mes desc limit 1), 'CF');
  -- categorias com os pontos e o crescimento do mês (ou do último mês anterior com config; sem nenhum, os da tabela)
  if to_regclass('pg_temp.mr_cat') is not null then drop table mr_cat; end if;
  create temp table mr_cat on commit drop as
    select k.cod, k.nome, k.regra, k.categoria, k.ordem, coalesce(p.pontos, k.pontos) pontos, coalesce(p.cresc, k.cresc) cresc
      from public.bi_maratona_cat k
      left join lateral (select x.pontos, x.cresc from public.bi_maratona_peso x where x.cod = k.cod and x.mes <= m0 order by x.mes desc limit 1) p on true;
  ck := md5(concat_ws('|', 'maratona2', w, m0, lm, (select string_agg(concat_ws(':', cod, cresc, pontos, categoria), ',' order by cod) from mr_cat), lm_def));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;

  -- vendedores visíveis para quem pergunta (escopo + filtros de loja/vendedor/equipe)
  execute format('select coalesce(array_agg(distinct vendedor), ''{}'') from public.bi_venda where mes between $1 and $2 and %s', w)
    into vis using ms[1], m0;

  -- vendas do atacado dos 6 meses por vendedor participante, mês e categoria da campanha
  atc := (select id from public.bi_dim where tipo = 'canal' and valor = 'ATACADO');
  vpart := array(select d.id from public.bi_dim d join public.bi_vendedor_equipe ve on ve.vendedor = d.valor
                 where d.tipo = 'vendedor' and ve.funcao like 'SELLER%');
  if to_regclass('pg_temp.mr_raw') is not null then drop table mr_raw; end if;
  create temp table mr_raw on commit drop as
    select v.vendedor, v.mes, v.loja, v.classificacao, v.categoria, v.linha, v.marca, v.grupo_peca, v.aplicacao, v.montadora,
           coalesce(p.grupo_peca, -1)::smallint pgrupo, coalesce(p.aplicacao, -1)::smallint papl, sum(v.fat) fat
      from public.bi_venda v left join public.bi_produto p on p.id = v.produto
     where v.canal = atc and v.mes between ms[1] and m0
     group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12;
  analyze mr_raw;
  if to_regclass('pg_temp.mr_base') is not null then drop table mr_base; end if;
  create temp table mr_base on commit drop as
  with gm as (
    select d.id categoria, k.cod from public.bi_dim d join mr_cat k on k.regra = 'GM' and trim(k.categoria) = trim(d.valor)
     where d.tipo = 'categoria'
  ), cmb as (   -- cada combinação de atributos vira uma regra da campanha (poucas combinações, muitas linhas)
    select distinct classificacao, categoria, linha, marca, grupo_peca, aplicacao, montadora, pgrupo, papl from mr_raw
  ), cr as (
    select c.*,
           case when cl.valor in ('ALTERNATIVOS', 'IMPORTADOS') then case when l.valor = lm then 'LINHA' else 'ALT' end
                when cl.valor = 'GM - LUBRIFICANTES' then 'LUB'
                when cl.valor = 'GM - PEÇAS' and (m.valor = 'ACDELCO' or gv.valor = 'ACDELCO' or gp.valor = 'ACDELCO') then
                  case when kd.valor = 'ADITIVOS & FLUIDOS' then 'ADIT'
                       when coalesce(nullif(av.valor, 'N/D'), nullif(ap.valor, 'N/D'), case when mo.valor like 'CHEVROLET%' then 'CHEVROLET' else 'MULTIMARCAS' end) = 'CHEVROLET' then 'ACD_CHEV'
                       else 'ACD_MULTI' end
                when cl.valor = 'GM - PEÇAS' then 'GM' end regra
      from cmb c
      left join public.bi_dim cl on cl.tipo = 'classificacao' and cl.id = c.classificacao
      left join public.bi_dim kd on kd.tipo = 'categoria' and kd.id = c.categoria
      left join public.bi_dim l on l.tipo = 'linha' and l.id = c.linha
      left join public.bi_dim m on m.tipo = 'marca' and m.id = c.marca
      left join public.bi_dim mo on mo.tipo = 'montadora' and mo.id = c.montadora
      left join public.bi_dim gv on gv.tipo = 'grupo_peca' and gv.id = c.grupo_peca
      left join public.bi_dim av on av.tipo = 'aplicacao' and av.id = c.aplicacao
      left join public.bi_dim gp on gp.tipo = 'grupo_peca' and gp.id = c.pgrupo
      left join public.bi_dim ap on ap.tipo = 'aplicacao' and ap.id = c.papl
  ), cc as (
    select cr.classificacao, cr.categoria, cr.linha, cr.marca, cr.grupo_peca, cr.aplicacao, cr.montadora, cr.pgrupo, cr.papl, coalesce(gm.cod, k.cod) cod
      from cr left join gm on cr.regra = 'GM' and gm.categoria = cr.categoria
      left join mr_cat k on cr.regra <> 'GM' and k.regra = cr.regra
     where coalesce(gm.cod, k.cod) is not null
  )
  select r.vendedor, r.mes, cc.cod, sum(r.fat)::numeric / 100 fat
    from mr_raw r join cc using (classificacao, categoria, linha, marca, grupo_peca, aplicacao, montadora, pgrupo, papl)
   where r.vendedor = any(vpart)
   group by 1, 2, 3;
  analyze mr_base;

  -- loja principal de cada vendedor (maior venda no atacado nos 6 meses)
  if to_regclass('pg_temp.mr_loja') is not null then drop table mr_loja; end if;
  create temp table mr_loja on commit drop as
    select distinct on (vendedor) vendedor, loja from (select vendedor, loja, sum(fat) ft from mr_raw group by 1, 2) x order by vendedor, ft desc;

  -- meta mínima por categoria
  if to_regclass('pg_temp.mr_piso') is not null then drop table mr_piso; end if;
  create temp table mr_piso on commit drop as
    with med as (
      select k.cod, m.mes, coalesce(a.md, 0) md
        from mr_cat k cross join unnest(ms) m(mes)
        left join (select b.cod, b.mes, avg(b.fat) md from mr_base b group by 1, 2) a on a.cod = k.cod and a.mes = m.mes
    )
    select k.cod, k.cresc, ceil((sum(med.md) - min(med.md) - max(med.md)) / 3 * (1 + k.cresc) / 10) * 10 piso
      from mr_cat k join med on med.cod = k.cod group by k.cod, k.cresc;

  select json_agg(json_build_array(k.cod, k.nome, k.pontos, k.cresc, p.piso) order by k.ordem) into cats
    from mr_cat k join mr_piso p on p.cod = k.cod;

  with part as (
    select d.id vendedor, ve.funcao, ve.equipe from public.bi_dim d join public.bi_vendedor_equipe ve on ve.vendedor = d.valor
     where d.tipo = 'vendedor' and ve.funcao like 'SELLER%' and d.id = any(vis)
  ), hist as (
    select b.vendedor, b.cod, count(*) n, sum(b.fat) s, min(b.fat) mn, max(b.fat) mx
      from mr_base b where b.mes = any(ms) group by 1, 2
  ), meta as (
    select pt.vendedor, k.cod, k.ordem,
           greatest(p.piso, round(coalesce(case when h.n >= 4 then (h.s - h.mn - h.mx) / (h.n - 2) when h.n > 0 then h.s / h.n end, 0) * (1 + k.cresc), -1)) meta,
           coalesce(cur.fat, 0) vend
      from part pt cross join mr_cat k join mr_piso p on p.cod = k.cod
      left join hist h on h.vendedor = pt.vendedor and h.cod = k.cod
      left join mr_base cur on cur.vendedor = pt.vendedor and cur.cod = k.cod and cur.mes = m0
  ), porv as (
    select m.vendedor, json_agg(m.meta order by m.ordem) metas, json_agg(round(m.vend, 2) order by m.ordem) vendas
      from meta m group by m.vendedor
  )
  select coalesce(json_agg(json_build_array(pt.vendedor, l.loja, pt.funcao, pt.equipe, pv.metas, pv.vendas)), '[]'::json)
    into vend
    from part pt join porv pv on pv.vendedor = pt.vendedor left join mr_loja l on l.vendedor = pt.vendedor;

  res := json_build_object('mes', m0, 'linha_mes', lm, 'linha_definida', lm_def, 'meses', to_json(ms), 'cats', cats, 'vend', vend);
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_maratona(jsonb, int) from public, anon;
grant execute on function public.bi_maratona(jsonb, int) to authenticated;

-- metas dos vendedores da planilha, pelo nome do vendedor (RE -> nome em bi_vendedor_re), no escopo de quem pergunta:
-- [[vendedor, 'AAAA-MM', meta de venda por dia, meta de LB, loja do vendedor]]
-- Até dez/2025 a coluna de venda da planilha traz frações (não é R$ por dia): valores abaixo de 1 vão como nulos.
create or replace function public.bi_metas_vend()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record; res json; vnome text; lnomes text[];
begin
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) then raise exception 'sem acesso ao painel'; end if;
  if e.vendedor is not null then vnome := (select d.valor from public.bi_dim d where d.tipo = 'vendedor' and d.id = e.vendedor); end if;
  if not coalesce(e.todas, false) and e.lojas is not null then
    lnomes := array(select d.valor from public.bi_dim d where d.tipo = 'loja' and d.id = any(e.lojas));
  end if;
  select coalesce(json_agg(json_build_array(r.vendedor, to_char(m.mes, 'YYYY-MM'), case when m.venda_dia >= 1 then m.venda_dia end, m.lb, m.loja) order by r.vendedor, m.mes), '[]'::json)
    into res
    from public.bi_meta_vend m
    join public.bi_vendedor_re r on r.re = m.re
   where m.mes >= date_trunc('month', now()) - interval '24 months'
     and (vnome is null or r.vendedor = vnome)
     and (lnomes is null or exists (select 1 from public.bi_vendedor_loja vl where vl.vendedor = r.vendedor and vl.loja = any(lnomes)));
  return res;
end $function$;
revoke all on function public.bi_metas_vend() from public, anon;
grant execute on function public.bi_metas_vend() to authenticated;
