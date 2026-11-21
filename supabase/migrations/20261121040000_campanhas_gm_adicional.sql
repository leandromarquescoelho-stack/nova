-- Campanhas GM: itens com bônus adicional dentro da linha (ex.: JCH "amortecedor+5" = mais R$ 5 por peça nesses itens).
-- segs[i].extra = {produtos:[ids], bonus:5}; a consulta devolve a quantidade vendida desses itens no período.
-- acompanhamento: segs:[[índice, fat, qtd, lb, base_fat, base_qtd, base_lb, qtd_itens_com_adicional]] e base_min (primeiro dia com venda na base)
create or replace function public.bi_campanha_dados(p_id int)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare c public.bi_campanha; w text; ck text; res json; ult date; d2 date; bi date; bf date; o jsonb := '{}'::jsonb; x json;
  fe jsonb; uni jsonb; i int; s jsonb; ids int[]; xids int[]; pri date;
begin
  select * into c from public.bi_campanha where id = p_id;
  if not found then raise exception 'campanha não encontrada'; end if;
  -- com linhas e sem lista geral de produtos: a campanha mede a soma das linhas
  fe := c.f;
  if jsonb_array_length(c.segs) > 0 and coalesce(jsonb_array_length(fe->'produto'), 0) = 0 then
    select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into uni from jsonb_array_elements(c.segs) sg(e), jsonb_array_elements((case when jsonb_typeof(sg.e->'produtos') = 'array' then sg.e->'produtos' else '[]'::jsonb end)) v;
    if jsonb_array_length(uni) > 0 then fe := fe || jsonb_build_object('produto', uni); end if;
  end if;
  w := private.bi_where(fe);
  select max(v.dia), min(v.dia) into ult, pri from public.bi_venda v;
  d2 := least(c.fim, ult);
  bi := case when c.meta_tipo = 'base' then c.base_ini end; bf := case when c.meta_tipo = 'base' then c.base_fim end;
  ck := md5(concat_ws('|', 'camp3', p_id, c.atualizado_em, w, ult));
  select k.valor into res from public.bi_cache k where k.chave = ck;
  if found then return res; end if;
  if to_regclass('pg_temp.cp_base') is not null then drop table pg_temp.cp_base; end if;
  execute format('create temp table cp_base on commit drop as
                    select dia, loja, produto, fat, qtd, lb, (dia between $1 and $2) atual, (dia between $3 and $4) base
                      from public.bi_venda where %s and ((dia between $1 and $2) or (dia between $3 and $4))', w)
    using c.ini, d2, coalesce(bi, '1900-01-01'::date), coalesce(bf, '1900-01-01'::date);
  select coalesce(json_agg(json_build_array(dia, f, q, l) order by dia), '[]'::json) into x
    from (select dia, sum(fat) f, sum(qtd) q, sum(lb) l from pg_temp.cp_base where atual group by dia) y;
  o := o || jsonb_build_object('dias', x::jsonb);
  select coalesce(json_agg(json_build_array(dia, f, q, l) order by dia), '[]'::json) into x
    from (select dia, sum(fat) f, sum(qtd) q, sum(lb) l from pg_temp.cp_base where base group by dia) y;
  o := o || jsonb_build_object('base_dias', x::jsonb);
  select json_build_array(coalesce(sum(fat), 0), coalesce(sum(qtd), 0), coalesce(sum(lb), 0)) into x from pg_temp.cp_base where base;
  o := o || jsonb_build_object('base', x::jsonb);
  select coalesce(json_agg(json_build_array(loja, f, q, l, bf_, bq, bl) order by f desc nulls last), '[]'::json) into x
    from (select loja, sum(fat) filter (where atual) f, sum(qtd) filter (where atual) q, sum(lb) filter (where atual) l,
                 sum(fat) filter (where base) bf_, sum(qtd) filter (where base) bq, sum(lb) filter (where base) bl
            from pg_temp.cp_base group by loja) y;
  o := o || jsonb_build_object('lojas', x::jsonb);
  execute format($q$
    select coalesce(json_agg(json_build_array(produto, f, q, l, bf_, bq, bl, nome)), '[]'::json) from (
      select produto, f, q, l, bf_, bq, bl, (select p.pn || ' · ' || coalesce(p.nome, '') from public.bi_produto p where p.id = y.produto) nome from (
        select produto, coalesce(sum(fat) filter (where atual), 0) f, coalesce(sum(qtd) filter (where atual), 0) q, coalesce(sum(lb) filter (where atual), 0) l,
               coalesce(sum(fat) filter (where base), 0) bf_, coalesce(sum(qtd) filter (where base), 0) bq, coalesce(sum(lb) filter (where base), 0) bl
          from pg_temp.cp_base group by produto) y
       order by %s desc limit 40) z$q$, case c.metrica when 'qtd' then 'q' when 'lb' then 'l' else 'f' end) into x;
  o := o || jsonb_build_object('produtos', x::jsonb);
  -- linhas
  x := '[]'::json;
  for i in 0 .. jsonb_array_length(c.segs) - 1 loop
    s := c.segs -> i;
    select coalesce(array_agg(v::int), '{}') into ids from jsonb_array_elements_text(case when jsonb_typeof(s->'produtos') = 'array' then s->'produtos' else '[]'::jsonb end) v;
    select coalesce(array_agg(v::int), '{}') into xids from jsonb_array_elements_text(case when jsonb_typeof(s->'extra'->'produtos') = 'array' then s->'extra'->'produtos' else '[]'::jsonb end) v;
    select (x::jsonb || jsonb_build_array(jsonb_build_array(i, coalesce(sum(fat) filter (where atual), 0), coalesce(sum(qtd) filter (where atual), 0), coalesce(sum(lb) filter (where atual), 0),
             coalesce(sum(fat) filter (where base), 0), coalesce(sum(qtd) filter (where base), 0), coalesce(sum(lb) filter (where base), 0),
             coalesce(sum(qtd) filter (where atual and produto = any(xids)), 0))))::json
      into x from pg_temp.cp_base where produto = any(ids);
  end loop;
  o := o || jsonb_build_object('segs', x::jsonb);
  res := (jsonb_build_object('id', p_id, 'ultimo', ult, 'primeiro', pri) || o)::json;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;

revoke all on function public.bi_campanha_dados(int) from public, anon;
grant execute on function public.bi_campanha_dados(int) to authenticated;
