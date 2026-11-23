-- Filtro de dias da semana: Todos, Seg-Sex (sem feriados), Final de semana e Feriados.
-- O site manda as datas de feriado (nacionais e do estado de SP) em f.feriados; o resto do bi_where não muda.
create or replace function private.bi_where(f jsonb, ignorar text default null::text)
 returns text
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare e record; w text[] := array['true']; k text; arr jsonb; ids bigint[]; sem jsonb; eq text[]; nomes text[]; fer date[];
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if not e.todas then
    if e.lojas is not null then w := w || format('loja = any(%L::smallint[])', e.lojas); end if;
    if e.canais is not null then w := w || format('canal = any(%L::smallint[])', e.canais); end if;
    if e.vendedor is not null then w := w || format('vendedor = %s', e.vendedor); end if;
    select p.equipes into eq from public.profiles p where p.id = auth.uid();
    if coalesce(cardinality(eq), 0) > 0 then
      w := w || format('vendedor = any(%L::smallint[])', coalesce((select array_agg(d.id) from public.bi_dim d
             join public.bi_vendedor_equipe ve on ve.vendedor = d.valor where d.tipo = 'vendedor' and ve.equipe = any(eq)), '{}'));
    end if;
  end if;
  foreach k in array array['loja','canal','emitente','origem','vendedor','linha','marca','categoria','subcategoria','montadora',
                           'classificacao','tipo_cliente','cidade','condicao','grupo_cliente','pessoa','grupo_peca','aplicacao','curva_gm','produto','cliente','nf'] loop
    continue when k = ignorar;
    arr := f -> k;
    if arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      w := w || format('%I = any(%L::%s[])', k, ids, case when k in ('produto','cliente','nf') then 'int' else 'smallint' end);
    end if;
  end loop;
  -- equipe e função não ficam na venda: viram a lista de vendedores que pertencem a elas (cadastro atual)
  foreach k in array array['equipe','funcao'] loop
    continue when k = ignorar;
    arr := f -> k;
    if arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(d.valor) into nomes from public.bi_dim d
        where d.tipo = k and d.id in (select x::bigint from jsonb_array_elements_text(arr) x);
      w := w || format('vendedor = any(%L::smallint[])', coalesce((select array_agg(d.id) from public.bi_dim d
             join public.bi_vendedor_equipe ve on ve.vendedor = d.valor
             where d.tipo = 'vendedor' and (case when k = 'equipe' then ve.equipe else ve.funcao end) = any(coalesce(nomes, '{}'))), '{}'));
    end if;
  end loop;
  -- zona da capital não fica na venda: vira "cliente com CEP nas zonas escolhidas"
  arr := f -> 'zona';
  if coalesce(ignorar, '') <> 'zona' and arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
    w := w || format('cliente in (select c.id from public.bi_cliente c where c.zona = any(%L::smallint[]))', ids);
  end if;
  sem := f -> 'semana';
  if coalesce(ignorar, '') <> 'semana' and sem is not null and jsonb_typeof(sem) = 'array' then
    -- feriados (nacionais e do estado) vêm do site em f.feriados; datas inválidas são ignoradas
    select coalesce(array_agg(x::date), '{}') into fer from jsonb_array_elements_text(
      case when jsonb_typeof(f -> 'feriados') = 'array' then f -> 'feriados' else '[]'::jsonb end) x
     where x ~ '^\d{4}-\d{2}-\d{2}$';
    if sem @> '["feriado"]' then w := w || format('dia = any(%L::date[])', fer);
    elsif sem @> '["fds"]' and not sem @> '["util"]' then w := w || 'extract(isodow from dia) >= 6'::text;
    elsif sem @> '["util"]' and not sem @> '["fds"]' then
      w := w || ('extract(isodow from dia) < 6' || case when cardinality(fer) > 0 then format(' and not (dia = any(%L::date[]))', fer) else '' end);
    end if;
  end if;
  return array_to_string(w, ' and ');
end $function$;
