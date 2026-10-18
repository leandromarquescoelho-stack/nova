-- Consultas do agente de IA direto no banco (independem dos filtros da tela). Somente leitura, sempre dentro do escopo do
-- usuário logado (private.bi_where / private.bi_escopo). Filtros chegam por nome e são convertidos para os ids de bi_dim.

-- ids de uma dimensão a partir de nomes: igual (sem diferença de maiúsculas) ou, se não houver, "contém"
create or replace function private.bi_ia_ids(p_tipo text, nomes jsonb, out ids bigint[], out sem text[])
 language plpgsql stable security definer set search_path to ''
as $$
declare n text; achou bigint[];
begin
  ids := '{}'; sem := '{}';
  if nomes is null or jsonb_typeof(nomes) <> 'array' then return; end if;
  for n in select trim(x) from jsonb_array_elements_text(nomes) x where trim(x) <> '' loop
    if p_tipo = 'produto' then
      select array_agg(p.id) into achou from (select id from public.bi_produto where upper(pn) = upper(n)
        union all select id from (select id from public.bi_produto where nome ilike '%'||n||'%' or pn ilike n||'%' limit 300) z) p;
    elsif p_tipo = 'cliente' then
      select array_agg(c.id) into achou from (select id from public.bi_cliente where upper(codcli) = upper(n)
        union all select id from (select id from public.bi_cliente where razao ilike '%'||n||'%' limit 300) z) c;
    else
      select array_agg(d.id) into achou from public.bi_dim d where d.tipo = p_tipo and upper(d.valor) = upper(n);
      if achou is null then
        select array_agg(d.id) into achou from public.bi_dim d where d.tipo = p_tipo and d.valor ilike '%'||n||'%';
      end if;
    end if;
    if achou is null then sem := sem || (p_tipo||': '||n); else ids := ids || achou; end if;
  end loop;
end $$;

-- vendas agregadas: agrupar por até 3 campos, filtros por nome, período, medidas e ordenação
-- q: {agrupar:[...], filtros:{marca:[..], loja:[..], produto:[..], cliente:[..], ...}, de:'AAAA-MM-DD', ate:'AAAA-MM-DD',
--     medidas:['notas','clientes'] (opcionais; fat/qtd/lb/custo vêm sempre), ordenar:'fat'|'qtd'|'lb'|'custo'|'margem'|'notas'|'clientes'|'grupo',
--     crescente:bool, limite:int}
create or replace function public.bi_ia_vendas(q jsonb)
 returns json language plpgsql stable security definer set search_path to '' set work_mem to '64MB'
as $$
declare
  dims text[] := array['loja','canal','emitente','origem','vendedor','linha','marca','categoria','subcategoria','montadora',
                       'classificacao','tipo_cliente','cidade','produto','cliente','nf'];
  grp text[] := '{}'; g text; w text; k text; r record; avisos text[] := '{}';
  sel_id text[] := '{}'; sel_rot text[] := '{}'; i int := 0;
  de date; ate date; lim int; ord text; dir text; med text[]; extra text := ''; res json; tot json; sqlq text;
begin
  w := private.bi_where('{}'::jsonb); -- escopo do usuário
  ate := coalesce(nullif(q->>'ate','')::date, (select max(dia) from public.bi_venda));
  de := coalesce(nullif(q->>'de','')::date, ate - 364);
  w := w || format(' and dia between %L and %L', de, ate);
  for k in select jsonb_object_keys(coalesce(q->'filtros','{}'::jsonb)) loop
    if k = any(dims) then
      if k = 'nf' then
        w := w || format(' and nf = any(%L::int[])', (select array_agg(x::int) from jsonb_array_elements_text(q->'filtros'->'nf') x where x ~ '^\d+$'));
      else
        select * into r from private.bi_ia_ids(k, q->'filtros'->k);
        avisos := avisos || r.sem;
        w := w || format(' and %I = any(%L::%s[])', k, coalesce(r.ids, '{}'), case when k in ('produto','cliente') then 'int' else 'smallint' end);
      end if;
    else
      avisos := avisos || ('filtro desconhecido ignorado: '||k);
    end if;
  end loop;
  for g in select jsonb_array_elements_text(coalesce(q->'agrupar','[]'::jsonb)) loop
    exit when cardinality(grp) >= 3;
    if g = any(dims) or g in ('mes','ano','dia','dia_semana') then grp := grp || g;
    else avisos := avisos || ('agrupamento desconhecido ignorado: '||g); end if;
  end loop;
  foreach g in array grp loop
    i := i + 1;
    if g = 'ano' then sel_id := sel_id || format('2000 + mes/100 g%s', i);
    elsif g = 'dia_semana' then sel_id := sel_id || format('extract(isodow from dia)::int g%s', i);
    else sel_id := sel_id || format('%I g%s', g, i); end if;
    sel_rot := sel_rot || case
      when g = 'mes' then format('format(''%%s-%%s'', 2000 + g%s/100, lpad((g%s %% 100)::text, 2, ''0''))', i, i)
      when g = 'ano' then format('g%s::text', i)
      when g = 'dia' then format('g%s::text', i)
      when g = 'dia_semana' then format('(array[''seg'',''ter'',''qua'',''qui'',''sex'',''sáb'',''dom''])[g%s]', i)
      when g = 'nf' then format('g%s::text', i)
      when g = 'produto' then format('(select p.pn||'' - ''||coalesce(p.nome,'''') from public.bi_produto p where p.id = g%s)', i)
      when g = 'cliente' then format('(select coalesce(c.codcli,'''')||'' - ''||coalesce(c.razao,'''') from public.bi_cliente c where c.id = g%s)', i)
      else format('(select d.valor from public.bi_dim d where d.tipo = %L and d.id = g%s)', g, i) end;
  end loop;
  med := array(select jsonb_array_elements_text(coalesce(q->'medidas','[]'::jsonb)));
  if 'notas' = any(med) then extra := extra || ', count(distinct (emitente, nf)) filter (where fat > 0 and nf <> 0) notas'; end if;
  if 'clientes' = any(med) then extra := extra || ', count(distinct cliente) filter (where fat > 0) clientes'; end if;
  lim := least(greatest(coalesce((q->>'limite')::int, 50), 1), 200);
  dir := case when coalesce((q->>'crescente')::boolean, false) then 'asc' else 'desc' end;
  ord := coalesce(q->>'ordenar', 'fat');
  ord := case
    when ord in ('fat','qtd','lb','custo') then ord
    when ord = 'margem' then 'case when fat > 0 then lb::numeric/fat end'
    when ord = 'notas' and extra like '%notas%' then 'notas'
    when ord = 'clientes' and extra like '%clientes%' then 'clientes'
    when ord = 'grupo' and cardinality(grp) > 0 then (select string_agg('g'||n, ', ') from generate_series(1, cardinality(grp)) n)
    else 'fat' end;
  if ord ~ '^g\d' then dir := case when (q->>'crescente') = 'false' then 'desc' else 'asc' end; end if; -- por grupo: crescente salvo pedido

  sqlq := format($f$
    select json_build_object('n_grupos', coalesce(max(n), 0), 'linhas', coalesce(json_agg(json_build_object(
        'grupo', %s, 'fat', round(fat/100.0, 2), 'qtd', qtd, 'lb', round(lb/100.0, 2), 'custo', round(custo/100.0, 2),
        'margem_pct', case when fat > 0 then round(lb*100.0/fat, 1) end %s) order by rn), '[]'::json))
    from (select *, row_number() over (order by %s %s nulls last) rn, count(*) over () n from (
            select %s sum(fat)::bigint fat, sum(qtd)::bigint qtd, sum(lb)::bigint lb, sum(custo)::bigint custo %s
            from public.bi_venda where %s %s) a
          order by rn limit %s) b$f$,
    case when cardinality(grp) = 0 then '''total''' else 'json_build_array('||array_to_string(sel_rot, ', ')||')' end,
    (case when extra like '%notas%' then ', ''notas'', notas' else '' end) || (case when extra like '%clientes%' then ', ''clientes'', clientes' else '' end),
    ord, dir,
    case when cardinality(grp) = 0 then '' else array_to_string(sel_id, ', ')||',' end,
    extra, w,
    case when cardinality(grp) = 0 then '' else 'group by '||(select string_agg(n::text, ', ') from generate_series(1, cardinality(grp)) n) end,
    lim);
  execute sqlq into res;
  return json_build_object('periodo', json_build_object('de', de, 'ate', ate), 'agrupado_por', grp, 'avisos', avisos,
    'valores_em', 'reais; qtd em unidades', 'resultado', res);
end $$;
revoke all on function public.bi_ia_vendas(jsonb) from public, anon;
grant execute on function public.bi_ia_vendas(jsonb) to authenticated;

-- estoque atual agregado: agrupar por loja/produto/atributos do produto, filtros por nome, só parados opcional
create or replace function public.bi_ia_estoque(q jsonb)
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare
  e record; dims text[] := array['marca','categoria','subcategoria','montadora','linha','classificacao'];
  grp text[] := '{}'; g text; k text; r record; avisos text[] := '{}'; w text := 'true';
  sel_id text[] := '{}'; sel_rot text[] := '{}'; i int := 0; lim int; ord text; res json;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if not e.todas and e.lojas is not null then w := w || format(' and s.loja = any(%L::smallint[])', e.lojas); end if;
  for k in select jsonb_object_keys(coalesce(q->'filtros','{}'::jsonb)) loop
    if k = 'loja' or k = any(dims) or k = 'produto' then
      select * into r from private.bi_ia_ids(k, q->'filtros'->k);
      avisos := avisos || r.sem;
      w := w || case when k = 'loja' then format(' and s.loja = any(%L::smallint[])', coalesce(r.ids, '{}'))
                     when k = 'produto' then format(' and s.produto = any(%L::int[])', coalesce(r.ids, '{}'))
                     else format(' and p.%I = any(%L::smallint[])', k, coalesce(r.ids, '{}')) end;
    else avisos := avisos || ('filtro desconhecido ignorado: '||k); end if;
  end loop;
  if coalesce((q->>'somente_parados')::boolean, false) then w := w || ' and s.parado'; end if;
  for g in select jsonb_array_elements_text(coalesce(q->'agrupar','[]'::jsonb)) loop
    exit when cardinality(grp) >= 2;
    if g = 'loja' or g = 'produto' or g = any(dims) then grp := grp || g;
    else avisos := avisos || ('agrupamento desconhecido ignorado: '||g); end if;
  end loop;
  foreach g in array grp loop
    i := i + 1;
    sel_id := sel_id || case when g = 'loja' then format('s.loja g%s', i) when g = 'produto' then format('s.produto g%s', i) else format('p.%I g%s', g, i) end;
    sel_rot := sel_rot || case
      when g = 'produto' then format('(select p2.pn||'' - ''||coalesce(p2.nome,'''') from public.bi_produto p2 where p2.id = g%s)', i)
      else format('(select d.valor from public.bi_dim d where d.tipo = %L and d.id = g%s)', g, i) end;
  end loop;
  lim := least(greatest(coalesce((q->>'limite')::int, 50), 1), 200);
  ord := case q->>'ordenar' when 'unidades' then 'unidades' when 'itens' then 'itens' when 'parados' then 'custo_parado'
                            when 'dias_sem_venda' then 'dias_sem_venda' else 'custo' end;
  execute format($f$
    select json_build_object('n_grupos', coalesce(max(n), 0), 'linhas', coalesce(json_agg(json_build_object(
        'grupo', %s, 'itens', itens, 'unidades', unidades, 'custo', custo, 'itens_parados', parados, 'custo_parado', custo_parado,
        'dias_sem_venda_medio', dias_sem_venda) order by rn), '[]'::json))
    from (select *, row_number() over (order by %s desc nulls last) rn, count(*) over () n from (
            select %s count(*) filter (where s.est_fis > 0) itens, round(sum(s.est_fis)) unidades, round(sum(s.custo), 2) custo,
                   count(*) filter (where s.parado) parados, round(coalesce(sum(s.custo) filter (where s.parado), 0), 2) custo_parado,
                   round(avg(current_date - s.dt_ult_vend) filter (where s.est_fis > 0)) dias_sem_venda
            from public.bi_estoque s left join public.bi_produto p on p.id = s.produto
            where %s and coalesce(s.est_fis, 0) <> 0 %s) a
          order by rn limit %s) b$f$,
    case when cardinality(grp) = 0 then '''total''' else 'json_build_array('||array_to_string(sel_rot, ', ')||')' end,
    ord, case when cardinality(grp) = 0 then '' else array_to_string(sel_id, ', ')||',' end, w,
    case when cardinality(grp) = 0 then '' else 'group by '||(select string_agg(n::text, ', ') from generate_series(1, cardinality(grp)) n) end,
    lim) into res;
  return json_build_object('agrupado_por', grp, 'avisos', avisos, 'valores_em', 'custo em reais; unidades em peças', 'resultado', res);
end $$;
revoke all on function public.bi_ia_estoque(jsonb) from public, anon;
grant execute on function public.bi_ia_estoque(jsonb) to authenticated;

-- nomes existentes de uma dimensão (para o agente achar a grafia certa antes de filtrar)
create or replace function public.bi_ia_valores(tipo text, busca text default '')
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare e record; res json;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if tipo = 'produto' then
    select json_agg(x) into res from (select pn||' - '||coalesce(nome,'') x from public.bi_produto
      where nome ilike '%'||coalesce(busca,'')||'%' or pn ilike coalesce(busca,'')||'%' order by pn limit 40) z;
  elsif tipo = 'cliente' then
    -- só clientes com venda dentro do escopo do usuário
    execute format('select json_agg(x) from (select coalesce(c.codcli,'''')||'' - ''||coalesce(c.razao,'''') x from public.bi_cliente c
      where c.razao ilike %L and exists (select 1 from public.bi_venda v where v.cliente = c.id and %s) order by c.razao limit 40) z',
      '%'||coalesce(busca,'')||'%', private.bi_where('{}'::jsonb)) into res;
  elsif tipo in ('loja','canal','emitente','origem','vendedor','linha','marca','categoria','subcategoria','montadora','classificacao','tipo_cliente','cidade') then
    if tipo = 'vendedor' and e.vendedor is not null then
      select json_agg(d.valor) into res from public.bi_dim d where d.tipo = 'vendedor' and d.id = e.vendedor;
    else
      select json_agg(valor) into res from (select d.valor from public.bi_dim d where d.tipo = bi_ia_valores.tipo
        and d.valor ilike '%'||coalesce(busca,'')||'%' order by d.valor limit 80) z;
    end if;
  else
    raise exception 'tipo desconhecido: %', tipo;
  end if;
  return coalesce(res, '[]'::json);
end $$;
revoke all on function public.bi_ia_valores(text, text) from public, anon;
grant execute on function public.bi_ia_valores(text, text) to authenticated;
