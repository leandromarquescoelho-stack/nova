-- Vendedores > Maratona de Pontos: meta por vendedor e por categoria da campanha, vendido no mês e pontos.
-- Regras (conferidas com a planilha da campanha):
--  * só atacado; participam os vendedores com função SELLER* no cadastro (aba vendedores do infobi);
--  * categoria da venda: ALTERNATIVOS e IMPORTADOS -> linha do mês (1P) ou demais alternativos (1Q); GM - LUBRIFICANTES -> 1L;
--    GM - PEÇAS ACDelco -> aditivos (1M), multimarcas (1N) ou Chevrolet (1O); GM - PEÇAS genuíno -> pela categoria do produto;
--  * meta mínima da categoria = média por vendedor (só quem vendeu no mês) dos 5 meses fechados, sem o maior e o menor,
--    x (1 + crescimento), arredondada para cima de 10 em 10;
--  * meta do vendedor = maior entre a mínima e a média dele x (1 + crescimento), arredondada para a dezena
--    (com 4 ou 5 meses com venda tira o maior e o menor; com até 3 meses, média simples).

create table if not exists public.bi_maratona_cat (
  cod text primary key,
  nome text not null,
  regra text not null,          -- GM | LUB | ADIT | ACD_MULTI | ACD_CHEV | LINHA | ALT
  categoria text,               -- só regra GM: nome da categoria do produto
  cresc numeric not null,
  pontos int not null,
  ordem int not null
);
alter table public.bi_maratona_cat enable row level security;
revoke all on public.bi_maratona_cat from anon, authenticated;

insert into public.bi_maratona_cat (cod, nome, regra, categoria, cresc, pontos, ordem) values
  ('1A', 'Suspensão',                 'GM', 'SUSPENSÃO', 0.20, 9, 1),
  ('1B', 'Motor',                     'GM', 'MOTOR', 0.08, 5, 2),
  ('1C', 'Câmbio & Transmissão',      'GM', 'CÂMBIO & TRANSMISSÃO', 0.15, 5, 3),
  ('1D', 'Direção',                   'GM', 'DIREÇÃO', 0.15, 4, 4),
  ('1E', 'Elétrica',                  'GM', 'ELÉTRICA', 0.15, 5, 5),
  ('1F', 'Iluminação',                'GM', 'ILUMINAÇÃO', 0.15, 5, 6),
  ('1G', 'Ignição',                   'GM', 'IGNIÇÃO', 0.15, 5, 7),
  ('1H', 'Injeção Combustível',       'GM', 'INJEÇÃO COMBUSTÍVEL', 0.15, 5, 8),
  ('1I', 'Arrefecimento',             'GM', 'ARREFECIMENTO', 0.18, 5, 9),
  ('1J', 'Lataria & Ferragem',        'GM', 'LATARIA & FERRAGEM', 0.15, 4, 10),
  ('1K', 'Parachoque',                'GM', 'PARACHOQUE', 0.15, 4, 11),
  ('1L', 'Lubrificantes ACDelco',     'LUB', null, 0.25, 5, 12),
  ('1M', 'Aditivos ACDelco',          'ADIT', null, 0.15, 5, 13),
  ('1N', 'ACDelco Multimarcas',       'ACD_MULTI', null, 0.15, 10, 14),
  ('1O', 'ACDelco Chevrolet',         'ACD_CHEV', null, 0.16, 5, 15),
  ('1P', 'Linha do mês',              'LINHA', null, 0.15, 12, 16),
  ('1Q', 'Alternativos (exceto linha do mês)', 'ALT', null, 0.15, 7, 17)
on conflict (cod) do nothing;

-- linha do mês por mês da campanha (mes = (ano-2000)*100 + mês); sem linha cadastrada vale 'CF' (Cofap)
create table if not exists public.bi_maratona_cfg (
  mes smallint primary key,
  linha_mes text not null
);
alter table public.bi_maratona_cfg enable row level security;
revoke all on public.bi_maratona_cfg from anon, authenticated;

-- {mes, linha_mes, meses:[5 meses base], cats:[[cod, nome, pontos, cresc, meta_minima]],
--  vend:[[vendedor_id, loja_id, funcao, equipe, [meta por categoria], [vendido no mês por categoria]]]}  (reais)
create or replace function public.bi_maratona(f jsonb, p_mes int default null)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; m0 smallint; ms smallint[]; d0 date; lm text; vis smallint[]; cats json; vend json; atc smallint; vpart smallint[];
begin
  f := coalesce(f, '{}'::jsonb);
  f := jsonb_strip_nulls(jsonb_build_object('loja', f->'loja', 'vendedor', f->'vendedor', 'equipe', f->'equipe', 'funcao', f->'funcao'));
  w := private.bi_where(f);
  m0 := coalesce(p_mes::smallint, (select max(v.mes) from public.bi_venda v));
  d0 := make_date(2000 + m0 / 100, m0 % 100, 1);
  ms := array(select ((extract(year from x) - 2000) * 100 + extract(month from x))::smallint
                from generate_series(d0 - interval '5 month', d0 - interval '1 month', interval '1 month') x order by x);
  lm := coalesce((select c.linha_mes from public.bi_maratona_cfg c where c.mes = m0), 'CF');
  ck := md5(concat_ws('|', 'maratona1', w, m0, lm, (select string_agg(concat_ws(':', cod, cresc, pontos, categoria), ',') from public.bi_maratona_cat)));
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
    select d.id categoria, k.cod from public.bi_dim d join public.bi_maratona_cat k on k.regra = 'GM' and trim(k.categoria) = trim(d.valor)
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
      left join public.bi_maratona_cat k on cr.regra <> 'GM' and k.regra = cr.regra
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
        from public.bi_maratona_cat k cross join unnest(ms) m(mes)
        left join (select b.cod, b.mes, avg(b.fat) md from mr_base b group by 1, 2) a on a.cod = k.cod and a.mes = m.mes
    )
    select k.cod, k.cresc, ceil((sum(med.md) - min(med.md) - max(med.md)) / 3 * (1 + k.cresc) / 10) * 10 piso
      from public.bi_maratona_cat k join med on med.cod = k.cod group by k.cod, k.cresc;

  select json_agg(json_build_array(k.cod, k.nome, k.pontos, k.cresc, p.piso) order by k.ordem) into cats
    from public.bi_maratona_cat k join mr_piso p on p.cod = k.cod;

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
      from part pt cross join public.bi_maratona_cat k join mr_piso p on p.cod = k.cod
      left join hist h on h.vendedor = pt.vendedor and h.cod = k.cod
      left join mr_base cur on cur.vendedor = pt.vendedor and cur.cod = k.cod and cur.mes = m0
  ), porv as (
    select m.vendedor, json_agg(m.meta order by m.ordem) metas, json_agg(round(m.vend, 2) order by m.ordem) vendas
      from meta m group by m.vendedor
  )
  select coalesce(json_agg(json_build_array(pt.vendedor, l.loja, pt.funcao, pt.equipe, pv.metas, pv.vendas)), '[]'::json)
    into vend
    from part pt join porv pv on pv.vendedor = pt.vendedor left join mr_loja l on l.vendedor = pt.vendedor;

  res := json_build_object('mes', m0, 'linha_mes', lm, 'meses', to_json(ms), 'cats', cats, 'vend', vend);
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_maratona(jsonb, int) from public, anon;
grant execute on function public.bi_maratona(jsonb, int) to authenticated;
