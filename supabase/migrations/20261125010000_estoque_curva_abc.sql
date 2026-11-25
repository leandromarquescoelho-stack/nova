-- Painel (card "Estoque a custo"): estoque a custo dividido pela curva ABC de venda.
-- Curva ABC: produtos ordenados pelo faturamento dos últimos 90 dias (no escopo e com os filtros do painel);
--   A = até 80% do faturamento acumulado, B = de 80% a 95%, C = o resto; "sem venda" = produto com estoque e sem venda em 90 dias.
-- Estoque: mesma regra do card (escopo do usuário, filtros de loja e de produto), só itens com saldo.
-- {dia, c:[custo A, B, C, sem venda], n:[itens A, B, C, sem venda]}
create or replace function public.bi_estoque_abc(f jsonb default '{}'::jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $function$
declare w text; res json; ck text; d0 date; e record; ew text[] := array['true']; ids bigint[]; k text; arr jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) then raise exception 'sem acesso'; end if;
  w := private.bi_where(f);
  d0 := (select max(v.dia) from public.bi_venda_det v);
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
  ck := md5(concat_ws('|', 'estabc1', w, array_to_string(ew, ' and '), d0));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with v as (select produto, sum(fat) fat from public.bi_venda_det
                where dia > $1 - 90 and dia <= $1 and (%1$s) group by produto having sum(fat) > 0),
    cl as (select produto, case when sum(fat) over (order by fat desc, produto rows unbounded preceding) <= 0.80 * sum(fat) over () then 1
                                when sum(fat) over (order by fat desc, produto rows unbounded preceding) <= 0.95 * sum(fat) over () then 2
                                else 3 end c from v),
    st as (select coalesce(cl.c, 4) c, sum(s.custo) cu, count(*) n
             from public.bi_estoque s left join public.bi_produto p on p.id = s.produto left join cl on cl.produto = s.produto
            where s.est_fis > 0 and %2$s group by 1)
    select json_build_object('dia', $1,
             'c', json_build_array(coalesce((select round(cu, 2) from st where c = 1), 0), coalesce((select round(cu, 2) from st where c = 2), 0),
                                   coalesce((select round(cu, 2) from st where c = 3), 0), coalesce((select round(cu, 2) from st where c = 4), 0)),
             'n', json_build_array(coalesce((select n from st where c = 1), 0), coalesce((select n from st where c = 2), 0),
                                   coalesce((select n from st where c = 3), 0), coalesce((select n from st where c = 4), 0)))$q$,
    w, array_to_string(ew, ' and ')) into res using d0;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_estoque_abc(jsonb) from public, anon;
grant execute on function public.bi_estoque_abc(jsonb) to authenticated;
