-- Campanhas: tipo (Campanhas GM ou Campanhas Nova) e configuração extra em cfg:
--   bonif:   produtos bonificados (pagam bônus); em branco, todos os participantes pagam. Os bonificados também contam na meta.
--   bonus:   bônus em R$ por peça bonificada (campanha sem linhas)
--   nivel:   'todo' | 'canal' | 'loja' | 'divisao'
--   unidades:[{nome, ids:[canal ou loja], meta}] (divisão = grupo de lojas, ex.: R1, R5, R9); só as unidades listadas participam
--   regra:   'nivel' (paga a unidade que bater a própria meta) | 'todo' (meta geral / da linha) | 'livre' (independente da meta)
alter table public.bi_campanha add column if not exists tipo text not null default 'gm';
alter table public.bi_campanha add column if not exists cfg jsonb not null default '{}'::jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bi_campanha_tipo_chk') then
    alter table public.bi_campanha add constraint bi_campanha_tipo_chk check (tipo in ('gm', 'nova'));
  end if;
end $$;

create or replace function public.bi_campanhas()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  return coalesce((select json_agg(json_build_object('id', c.id, 'nome', c.nome, 'descricao', c.descricao, 'ini', c.ini, 'fim', c.fim, 'f', c.f,
            'metrica', c.metrica, 'meta_tipo', c.meta_tipo, 'meta_valor', c.meta_valor, 'base_ini', c.base_ini, 'base_fim', c.base_fim,
            'cresc', c.cresc, 'ativo', c.ativo, 'segs', c.segs, 'tipo', c.tipo, 'cfg', c.cfg, 'atualizado_em', c.atualizado_em) order by c.ativo desc, c.fim desc, c.id desc)
          from public.bi_campanha c), '[]'::json);
end $function$;

create or replace function public.bi_campanha_gravar(p jsonb)
 returns int language plpgsql security definer set search_path to ''
as $function$
declare v_id int := nullif(p->>'id', '')::int; v_nome text := btrim(coalesce(p->>'nome', ''));
  v_tipo text := coalesce(p->>'meta_tipo', 'fixa'); v_met text := coalesce(p->>'metrica', 'fat');
  v_segs jsonb := coalesce(p->'segs', '[]'::jsonb); v_fixa_ok boolean;
  v_ct text := coalesce(nullif(p->>'tipo', ''), 'gm'); v_cfg jsonb := coalesce(p->'cfg', '{}'::jsonb);
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria')) then
    raise exception 'só BI e diretoria cadastram campanhas';
  end if;
  if v_nome = '' or length(v_nome) > 120 then raise exception 'informe o nome da campanha'; end if;
  if v_ct not in ('gm', 'nova') then raise exception 'tipo de campanha inválido'; end if;
  if (p->>'ini') is null or (p->>'fim') is null or (p->>'fim')::date < (p->>'ini')::date then raise exception 'período inválido'; end if;
  if jsonb_typeof(v_segs) <> 'array' or jsonb_array_length(v_segs) > 60 then raise exception 'linhas inválidas'; end if;
  if jsonb_typeof(v_cfg) <> 'object' then raise exception 'configuração inválida'; end if;
  if jsonb_typeof(coalesce(v_cfg->'unidades', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(v_cfg->'unidades', '[]'::jsonb)) > 60 then raise exception 'unidades inválidas'; end if;
  if jsonb_typeof(coalesce(v_cfg->'bonif', '[]'::jsonb)) <> 'array' then raise exception 'produtos bonificados inválidos'; end if;
  -- meta fixa: vale a meta geral, a soma das linhas ou a soma das unidades do nível
  v_fixa_ok := coalesce((p->>'meta_valor')::numeric, 0) > 0
    or exists (select 1 from jsonb_array_elements(v_segs) s where coalesce((s->>'meta')::numeric, 0) > 0)
    or exists (select 1 from jsonb_array_elements(coalesce(v_cfg->'unidades', '[]'::jsonb)) u where coalesce((u->>'meta')::numeric, 0) > 0);
  if v_tipo = 'fixa' and not v_fixa_ok then raise exception 'informe a meta'; end if;
  if v_tipo = 'base' and ((p->>'base_ini') is null or (p->>'base_fim') is null or (p->>'base_fim')::date < (p->>'base_ini')::date) then
    raise exception 'informe o período de comparação';
  end if;
  if jsonb_typeof(coalesce(p->'f', '{}'::jsonb)) <> 'object' then raise exception 'filtros inválidos'; end if;
  if v_id is null then
    insert into public.bi_campanha (nome, descricao, ini, fim, f, metrica, meta_tipo, meta_valor, base_ini, base_fim, cresc, ativo, segs, tipo, cfg)
    values (v_nome, nullif(btrim(coalesce(p->>'descricao', '')), ''), (p->>'ini')::date, (p->>'fim')::date, coalesce(p->'f', '{}'::jsonb), v_met, v_tipo,
            case when v_tipo = 'fixa' then nullif((p->>'meta_valor')::numeric, 0) end,
            case when v_tipo = 'base' then (p->>'base_ini')::date end, case when v_tipo = 'base' then (p->>'base_fim')::date end,
            case when v_tipo = 'base' then coalesce((p->>'cresc')::numeric, 0) end, coalesce((p->>'ativo')::boolean, true), v_segs, v_ct, v_cfg)
    returning id into v_id;
  else
    update public.bi_campanha set nome = v_nome, descricao = nullif(btrim(coalesce(p->>'descricao', '')), ''), ini = (p->>'ini')::date, fim = (p->>'fim')::date,
      f = coalesce(p->'f', '{}'::jsonb), metrica = v_met, meta_tipo = v_tipo,
      meta_valor = case when v_tipo = 'fixa' then nullif((p->>'meta_valor')::numeric, 0) end,
      base_ini = case when v_tipo = 'base' then (p->>'base_ini')::date end, base_fim = case when v_tipo = 'base' then (p->>'base_fim')::date end,
      cresc = case when v_tipo = 'base' then coalesce((p->>'cresc')::numeric, 0) end,
      ativo = coalesce((p->>'ativo')::boolean, true), segs = v_segs, tipo = v_ct, cfg = v_cfg, atualizado_em = now()
    where id = v_id;
    if not found then raise exception 'campanha não encontrada'; end if;
  end if;
  return v_id;
end $function$;

-- acompanhamento: além do anterior,
--   lc:  [[loja, canal, fat, qtd, lb, base_fat, base_qtd, base_lb, qtd_bonificada]]
--   slc: [[índice da linha, loja, canal, fat, qtd, lb, qtd_bonificada, qtd_adicional_bonificada]]
create or replace function public.bi_campanha_dados(p_id int)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare c public.bi_campanha; w text; ck text; res json; ult date; d2 date; bi date; bf date; o jsonb := '{}'::jsonb; x json;
  fe jsonb; uni jsonb; i int; s jsonb; ids int[]; xids int[]; bids int[]; pri date; niv text; uids jsonb; tb boolean;
begin
  select * into c from public.bi_campanha where id = p_id;
  if not found then raise exception 'campanha não encontrada'; end if;
  fe := c.f;
  -- produtos bonificados
  select coalesce(array_agg(v::int), '{}') into bids
    from jsonb_array_elements_text(case when jsonb_typeof(c.cfg->'bonif') = 'array' then c.cfg->'bonif' else '[]'::jsonb end) v;
  tb := cardinality(bids) = 0;   -- sem lista de bonificados: todos pagam
  -- com linhas e sem lista geral de produtos: a campanha mede a soma das linhas
  if jsonb_array_length(c.segs) > 0 and coalesce(jsonb_array_length(fe->'produto'), 0) = 0 then
    select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into uni from jsonb_array_elements(c.segs) sg(e), jsonb_array_elements((case when jsonb_typeof(sg.e->'produtos') = 'array' then sg.e->'produtos' else '[]'::jsonb end)) v;
    if jsonb_array_length(uni) > 0 then fe := fe || jsonb_build_object('produto', uni); end if;
  end if;
  -- os bonificados também contam na meta (quando a campanha tem lista de produtos)
  if coalesce(jsonb_array_length(fe->'produto'), 0) > 0 and not tb then
    select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into uni from (select jsonb_array_elements(fe->'produto') v union select to_jsonb(b) from unnest(bids) b) z;
    fe := fe || jsonb_build_object('produto', uni);
  end if;
  -- nível de participação: só as unidades listadas entram
  niv := coalesce(c.cfg->>'nivel', 'todo');
  if niv in ('canal', 'loja', 'divisao') and jsonb_typeof(c.cfg->'unidades') = 'array' then
    select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into uids from jsonb_array_elements(c.cfg->'unidades') u(e),
      jsonb_array_elements(case when jsonb_typeof(u.e->'ids') = 'array' then u.e->'ids' else '[]'::jsonb end) v;
    if jsonb_array_length(uids) > 0 then fe := fe || jsonb_build_object(case when niv = 'canal' then 'canal' else 'loja' end, uids); end if;
  end if;
  w := private.bi_where(fe);
  select max(v.dia), min(v.dia) into ult, pri from public.bi_venda v;
  d2 := least(c.fim, ult);
  bi := case when c.meta_tipo = 'base' then c.base_ini end; bf := case when c.meta_tipo = 'base' then c.base_fim end;
  ck := md5(concat_ws('|', 'camp4', p_id, c.atualizado_em, w, ult));
  select k.valor into res from public.bi_cache k where k.chave = ck;
  if found then return res; end if;
  if to_regclass('pg_temp.cp_base') is not null then drop table pg_temp.cp_base; end if;
  execute format('create temp table cp_base on commit drop as
                    select dia, loja, canal, produto, fat, qtd, lb, (dia between $1 and $2) atual, (dia between $3 and $4) base
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
  select coalesce(json_agg(json_build_array(loja, canal, f, q, l, bf_, bq, bl, qb)), '[]'::json) into x
    from (select loja, canal, coalesce(sum(fat) filter (where atual), 0) f, coalesce(sum(qtd) filter (where atual), 0) q, coalesce(sum(lb) filter (where atual), 0) l,
                 coalesce(sum(fat) filter (where base), 0) bf_, coalesce(sum(qtd) filter (where base), 0) bq, coalesce(sum(lb) filter (where base), 0) bl,
                 coalesce(sum(qtd) filter (where atual and (tb or produto = any(bids))), 0) qb
            from pg_temp.cp_base group by loja, canal) y;
  o := o || jsonb_build_object('lc', x::jsonb);
  execute format($q$
    select coalesce(json_agg(json_build_array(produto, f, q, l, bf_, bq, bl, nome)), '[]'::json) from (
      select produto, f, q, l, bf_, bq, bl, (select p.pn || ' · ' || coalesce(p.nome, '') from public.bi_produto p where p.id = y.produto) nome from (
        select produto, coalesce(sum(fat) filter (where atual), 0) f, coalesce(sum(qtd) filter (where atual), 0) q, coalesce(sum(lb) filter (where atual), 0) l,
               coalesce(sum(fat) filter (where base), 0) bf_, coalesce(sum(qtd) filter (where base), 0) bq, coalesce(sum(lb) filter (where base), 0) bl
          from pg_temp.cp_base group by produto) y
       order by %s desc limit 40) z$q$, case c.metrica when 'qtd' then 'q' when 'lb' then 'l' else 'f' end) into x;
  o := o || jsonb_build_object('produtos', x::jsonb);
  -- linhas: totais e por loja × canal
  x := '[]'::json;
  o := o || jsonb_build_object('slc', '[]'::jsonb);
  for i in 0 .. jsonb_array_length(c.segs) - 1 loop
    s := c.segs -> i;
    select coalesce(array_agg(v::int), '{}') into ids from jsonb_array_elements_text(case when jsonb_typeof(s->'produtos') = 'array' then s->'produtos' else '[]'::jsonb end) v;
    select coalesce(array_agg(v::int), '{}') into xids from jsonb_array_elements_text(case when jsonb_typeof(s->'extra'->'produtos') = 'array' then s->'extra'->'produtos' else '[]'::jsonb end) v;
    select (x::jsonb || jsonb_build_array(jsonb_build_array(i, coalesce(sum(fat) filter (where atual), 0), coalesce(sum(qtd) filter (where atual), 0), coalesce(sum(lb) filter (where atual), 0),
             coalesce(sum(fat) filter (where base), 0), coalesce(sum(qtd) filter (where base), 0), coalesce(sum(lb) filter (where base), 0),
             coalesce(sum(qtd) filter (where atual and produto = any(xids)), 0))))::json
      into x from pg_temp.cp_base where produto = any(ids);
    o := jsonb_set(o, '{slc}', (o->'slc') || coalesce((select jsonb_agg(jsonb_build_array(i, loja, canal, f, q, l, qb, qx)) from (
           select loja, canal, coalesce(sum(fat), 0) f, coalesce(sum(qtd), 0) q, coalesce(sum(lb), 0) l,
                  coalesce(sum(qtd) filter (where tb or produto = any(bids)), 0) qb,
                  coalesce(sum(qtd) filter (where produto = any(xids) and (tb or produto = any(bids))), 0) qx
             from pg_temp.cp_base where atual and produto = any(ids) group by loja, canal) y), '[]'::jsonb));
  end loop;
  o := o || jsonb_build_object('segs', x::jsonb);
  res := (jsonb_build_object('id', p_id, 'ultimo', ult, 'primeiro', pri) || o)::json;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;

revoke all on function public.bi_campanhas() from public, anon;
revoke all on function public.bi_campanha_gravar(jsonb) from public, anon;
revoke all on function public.bi_campanha_dados(int) from public, anon;
grant execute on function public.bi_campanhas() to authenticated;
grant execute on function public.bi_campanha_gravar(jsonb) to authenticated;
grant execute on function public.bi_campanha_dados(int) to authenticated;
