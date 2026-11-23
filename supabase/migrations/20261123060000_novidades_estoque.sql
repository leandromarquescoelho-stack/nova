-- Novidades em Estoque (Dashboard e Vendas Hoje): além de entradas e rupturas, a função devolve
--   novos   [[loja, produto, nome, est, custo_un, dt_ult_comp, nunca_vendido, valor]]  sem estoque nas fotos dos 30 dias anteriores
--   cmel    [[loja, produto, nome, est, custo_un, custo_medio_90d, economia]]          custo unitário 3%+ menor que o custo médio das vendas de 90 dias
--   grandes [[loja, produto, nome, est, est_ant, entrou, valor, q90]]                   maiores entradas em valor desde a foto anterior
create or replace function public.bi_vendas_hoje_estoque(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; d0 date; dant date; e record; ew text[] := array['true']; ids bigint[]; k text; arr jsonb; sov boolean := false;
  vest json; esta numeric; lj json; nov json; ent json; we text; novos json; cmel json; grandes json;
begin
  f := coalesce(f, '{}'::jsonb);
  w := private.bi_where(f);
  d0 := coalesce(dia, (select max(v.dia) from public.bi_venda v));
  select max(h.dia) into dant from public.bi_estoque_hist h where h.dia < d0;
  ck := md5(concat_ws('|', 'vhest5', w, d0, dant));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  -- recorte do estoque (mesma regra do indicador de estoque do painel)
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
  we := array_to_string(ew, ' and ');
  execute format($q$
    select json_build_array(coalesce(sum(s.custo), 0), coalesce(sum(s.est_fis), 0), count(*) filter (where s.est_fis > 0),
                            coalesce(sum(s.custo) filter (where s.parado and s.est_fis > 0), 0))
      from public.bi_estoque s left join public.bi_produto p on p.id = s.produto where %s$q$, we) into vest;
  if dant is not null then
    execute format($q$select coalesce(sum(s.custo), 0) from public.bi_estoque_hist s left join public.bi_produto p on p.id = s.produto
                      where s.dia = $1 and %s$q$, we) into esta using dant;
  end if;
  execute format($q$
    select coalesce(json_agg(json_build_array(loja, c, q) order by c desc), '[]'::json) from (
      select s.loja, sum(s.custo) c, sum(s.est_fis) q from public.bi_estoque s left join public.bi_produto p on p.id = s.produto
       where %s group by 1) x$q$, we) into lj;
  -- base: loja x produto do recorte com estoque atual, foto anterior e vendas do dia (só lojas com estoque próprio)
  if to_regclass('pg_temp.vhe_b') is not null then drop table pg_temp.vhe_b; end if;
  execute format($q$create temp table vhe_b on commit drop as
    with atual as (select s.loja, s.produto, s.est_fis est, s.dt_ult_comp dc from public.bi_estoque s left join public.bi_produto p on p.id = s.produto where %1$s),
         ant as (select s.loja, s.produto, s.est_fis est from public.bi_estoque_hist s left join public.bi_produto p on p.id = s.produto where s.dia = $2 and %1$s),
         dv as (select loja, produto, sum(qtd) qd, sum(fat) fd from public.bi_venda where %2$s and dia > coalesce($2, $1 - 1) and dia <= $1 and produto is not null group by 1, 2)
    select coalesce(a.loja, b.loja, v.loja) loja, coalesce(a.produto, b.produto, v.produto) produto,
           coalesce(a.est, 0) est, case when $2 is null then null else coalesce(b.est, 0) end est_ant, a.dc, coalesce(v.qd, 0) qd, coalesce(v.fd, 0) fd
      from atual a full join ant b on b.loja = a.loja and b.produto = a.produto
      full join dv v on v.loja = coalesce(a.loja, b.loja) and v.produto = coalesce(a.produto, b.produto)
     where coalesce(a.loja, b.loja, v.loja) in (select distinct e2.loja from public.bi_estoque e2)$q$, we, w) using d0, dant;
  -- candidatos: entrou (com foto: atual - anterior + vendido > 0; sem foto: comprado no dia ou na véspera) ou zerou/baixou com venda no dia
  delete from pg_temp.vhe_b b
   where not ((b.est_ant is not null and b.est - b.est_ant + b.qd > 0)
           or (b.est_ant is null and b.dc >= d0 - 1 and b.est > 0)
           or (b.qd > 0 and (b.est_ant is null or b.est < b.est_ant)));
  if to_regclass('pg_temp.vhe_h') is not null then drop table pg_temp.vhe_h; end if;
  execute format($q$create temp table vhe_h on commit drop as
    select v.loja, v.produto, sum(v.qtd) q90, count(distinct v.dia) d90, sum(v.fat) f90 from public.bi_venda v
     where %s and v.dia between $1 - 90 and $1 - 1 and v.produto in (select produto from pg_temp.vhe_b)
     group by 1, 2$q$, w) using d0;
  select coalesce(json_agg(json_build_array(loja, produto, nome, est, est_ant, entrou, dc, q90, d90, f90, qd)
           order by (coalesce(est_ant, 0) <= q90 / 90.0 * 7) desc, f90 desc), '[]'::json) into ent from (
    select b.loja, b.produto, p.pn || ' · ' || coalesce(p.nome, '') nome, b.est, b.est_ant,
           case when b.est_ant is null then null else b.est - b.est_ant + b.qd end entrou, b.dc, h.q90, h.d90, h.f90, b.qd
      from pg_temp.vhe_b b join pg_temp.vhe_h h on h.loja = b.loja and h.produto = b.produto
      left join public.bi_produto p on p.id = b.produto
     where h.d90 >= 8 and h.q90 > 0
       and ((b.est_ant is not null and b.est - b.est_ant + b.qd > 0) or (b.est_ant is null and b.dc >= d0 - 1 and b.est > 0))
     order by (coalesce(b.est_ant, 0) <= h.q90 / 90.0 * 7) desc, h.f90 desc
     limit 20) y;
  select coalesce(json_agg(json_build_array(loja, produto, nome, est, qd, fd, q90, d90, f90, est_ant) order by (est <= 0) desc, f90 desc), '[]'::json) into nov from (
    select b.loja, b.produto, p.pn || ' · ' || coalesce(p.nome, '') nome, b.est, b.qd, b.fd, h.q90, h.d90, h.f90, b.est_ant
      from pg_temp.vhe_b b join pg_temp.vhe_h h on h.loja = b.loja and h.produto = b.produto
      left join public.bi_produto p on p.id = b.produto
     where h.d90 >= 8 and h.q90 > 0 and b.qd > 0 and (b.est_ant is null or b.est < b.est_ant)
       and (b.est <= 0 or b.est < h.q90 / 90.0 * 7)
     order by (b.est <= 0) desc, h.f90 desc
     limit 20) y;
  -- Novidades em Estoque (todos os produtos, não só os de boa venda):
  -- novos   = com estoque agora e sem estoque em nenhuma foto dos 30 dias anteriores (nv = nunca vendido no grupo)
  if dant is not null then
    execute format($q$
      select coalesce(json_agg(json_build_array(loja, produto, nome, est, cu, dc, nv, v) order by v desc), '[]'::json) from (
        select s.loja, s.produto, p.pn || ' · ' || coalesce(p.nome, '') nome, s.est_fis est, round(coalesce(s.custo_u, s.custo / nullif(s.est_fis, 0)), 2) cu,
               s.dt_ult_comp dc, not exists (select 1 from public.bi_venda_det v where v.produto = s.produto) nv,
               round(s.est_fis * coalesce(s.custo_u, s.custo / nullif(s.est_fis, 0)), 2) v
          from public.bi_estoque s left join public.bi_produto p on p.id = s.produto
         where %s and s.est_fis > 0
           and not exists (select 1 from public.bi_estoque_hist h where h.loja = s.loja and h.produto = s.produto
                                                                   and h.dia < $1 and h.dia >= $1 - 30)
         order by 8 desc nulls last limit 15) y$q$, we) into novos using d0;
  -- custo melhor = custo unitário atual do estoque (custo_u) pelo menos 3%% menor que o custo unitário médio das vendas
  --                 da loja nos 90 dias anteriores (o que vínhamos pagando); só produtos com 3 ou mais unidades vendidas
    execute format($q$
      select coalesce(json_agg(json_build_array(loja, produto, nome, est, cu, cua, eco) order by eco desc), '[]'::json) from (
        select s.loja, s.produto, p.pn || ' · ' || coalesce(p.nome, '') nome, s.est_fis est,
               round(s.custo_u, 2) cu, round(v.cm, 2) cua, round((v.cm - s.custo_u) * s.est_fis, 2) eco
          from public.bi_estoque s
          join (select loja, produto, sum(custo) / 100.0 / sum(qtd) cm from public.bi_venda
                 where %2$s and dia between $1 - 90 and $1 - 1 and qtd > 0 group by 1, 2 having sum(qtd) >= 3) v
            on v.loja = s.loja and v.produto = s.produto
          left join public.bi_produto p on p.id = s.produto
         where %1$s and s.est_fis > 0 and s.custo_u > 0 and v.cm > 0 and s.custo_u < v.cm * 0.97
         order by eco desc limit 15) y$q$, we, w) into cmel using d0;
  -- grandes entradas = maiores entradas em valor (entrada × custo unitário atual) desde a foto anterior
    select coalesce(json_agg(json_build_array(loja, produto, nome, est, est_ant, entrou, v, q90) order by v desc), '[]'::json) into grandes from (
      select b.loja, b.produto, p.pn || ' · ' || coalesce(p.nome, '') nome, b.est, b.est_ant, b.est - b.est_ant + b.qd entrou,
             round((b.est - b.est_ant + b.qd) * coalesce(s.custo_u, s.custo / nullif(s.est_fis, 0)), 2) v, h.q90
        from pg_temp.vhe_b b join public.bi_estoque s on s.loja = b.loja and s.produto = b.produto and s.est_fis > 0
        left join pg_temp.vhe_h h on h.loja = b.loja and h.produto = b.produto
        left join public.bi_produto p on p.id = b.produto
       where b.est_ant is not null and b.est - b.est_ant + b.qd > 0
       order by 7 desc nulls last limit 15) y;
  end if;
  res := json_build_object('dia', d0, 'foto', dant, 'est', vest, 'est_ant', esta, 'lojas', lj, 'ent', ent, 'nov', nov,
                           'novos', coalesce(novos, '[]'::json), 'cmel', coalesce(cmel, '[]'::json), 'grandes', coalesce(grandes, '[]'::json));
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_vendas_hoje_estoque(jsonb, date) from public, anon;
grant execute on function public.bi_vendas_hoje_estoque(jsonb, date) to authenticated;
