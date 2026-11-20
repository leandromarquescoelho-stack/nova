-- Vendas > Vendas Hoje: valor do estoque (a custo) e "novidades em estoque".
-- Estoque: posição da última carga, no escopo do usuário (lojas liberadas) e com os filtros de loja e de produto do painel.
-- Novidades: produtos que vendem bem (venderam em 8 dias ou mais nos 90 dias anteriores) e que, depois das vendas do dia,
-- zeraram o estoque ou ficaram com menos de 7 dias de cobertura na loja. Estoque antes do dia ≈ estoque atual + vendido no dia
-- (a base não guarda o histórico do estoque; compras e transferências do dia não entram nessa conta). Só lojas com estoque próprio.
-- {dia, est:[custo, qtd, itens, parado], lojas:[[loja, custo, qtd]], nov:[[loja, produto, nome, est_atual, qtd_dia, fat_dia, qtd90, dias90, fat90]]}
create or replace function public.bi_vendas_hoje_estoque(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; d0 date; e record; ew text[] := array['true']; ids bigint[]; k text; arr jsonb; sov boolean := false;
  est json; lj json; nov json;
begin
  f := coalesce(f, '{}'::jsonb);
  w := private.bi_where(f);
  d0 := coalesce(dia, (select max(v.dia) from public.bi_venda v));
  ck := md5(concat_ws('|', 'vhest2', w, d0));
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
  execute format($q$
    select json_build_array(coalesce(sum(s.custo), 0), coalesce(sum(s.est_fis), 0), count(*) filter (where s.est_fis > 0),
                            coalesce(sum(s.custo) filter (where s.parado and s.est_fis > 0), 0))
      from public.bi_estoque s left join public.bi_produto p on p.id = s.produto where %s$q$, array_to_string(ew, ' and ')) into est;
  execute format($q$
    select coalesce(json_agg(json_build_array(loja, c, q) order by c desc), '[]'::json) from (
      select s.loja, sum(s.custo) c, sum(s.est_fis) q from public.bi_estoque s left join public.bi_produto p on p.id = s.produto
       where %s group by 1) x$q$, array_to_string(ew, ' and ')) into lj;
  -- novidades: loja x produto vendidos no dia, com o histórico de 90 dias e o estoque atual da loja
  if to_regclass('pg_temp.vhe_dia') is not null then drop table pg_temp.vhe_dia; end if;
  execute format($q$create temp table vhe_dia on commit drop as
    select loja, produto, sum(qtd) qd, sum(fat) fd from public.bi_venda
     where %s and dia = $1 and produto is not null
       and loja in (select distinct e2.loja from public.bi_estoque e2)   -- só lojas que guardam estoque (e-commerce vende do estoque de outra)
     group by 1, 2 having sum(qtd) > 0$q$, w) using d0;
  if to_regclass('pg_temp.vhe_h') is not null then drop table pg_temp.vhe_h; end if;
  execute format($q$create temp table vhe_h on commit drop as
    select v.loja, v.produto, sum(v.qtd) q90, count(distinct v.dia) d90, sum(v.fat) f90 from public.bi_venda v
     where %s and v.dia between $1 - 90 and $1 - 1 and v.produto in (select produto from pg_temp.vhe_dia)
     group by 1, 2$q$, w) using d0;
  execute format($q$
    select coalesce(json_agg(json_build_array(loja, produto, nome, est, qd, fd, q90, d90, f90) order by (est <= 0) desc, f90 desc), '[]'::json) from (
      select x.loja, x.produto, p.pn || ' · ' || coalesce(p.nome, '') nome, coalesce(s.est_fis, 0) est, x.qd, x.fd, h.q90, h.d90, h.f90
        from pg_temp.vhe_dia x
        join pg_temp.vhe_h h on h.loja = x.loja and h.produto = x.produto
        left join public.bi_estoque s on s.loja = x.loja and s.produto = x.produto
        left join public.bi_produto p on p.id = x.produto
       where h.d90 >= 8 and h.q90 > 0
         and (coalesce(s.est_fis, 0) <= 0 or coalesce(s.est_fis, 0) < h.q90 / 90.0 * 7)
       order by (coalesce(s.est_fis, 0) <= 0) desc, h.f90 desc
       limit 20) y$q$) into nov;
  res := json_build_object('dia', d0, 'est', est, 'lojas', lj, 'nov', nov);
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_vendas_hoje_estoque(jsonb, date) from public, anon;
grant execute on function public.bi_vendas_hoje_estoque(jsonb, date) to authenticated;
