-- Filtro de dias da semana em todos os painéis: f.semana = ["fds"] (sábado e domingo) ou ["util"] (segunda a sexta).
-- Igual à versão anterior de private.bi_where, só acrescenta essa condição sobre a coluna dia de bi_venda.
create or replace function private.bi_where(f jsonb, ignorar text default null::text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare e record; w text[] := array['true']; k text; arr jsonb; ids bigint[]; sem jsonb;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if not e.todas then
    if e.lojas is not null then w := w || format('loja = any(%L::smallint[])', e.lojas); end if;
    if e.canais is not null then w := w || format('canal = any(%L::smallint[])', e.canais); end if;
    if e.vendedor is not null then w := w || format('vendedor = %s', e.vendedor); end if;
  end if;
  foreach k in array array['loja','canal','emitente','origem','vendedor','linha','marca','categoria','subcategoria','montadora',
                           'classificacao','tipo_cliente','cidade','produto','cliente','nf'] loop
    continue when k = ignorar;
    arr := f -> k;
    if arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      w := w || format('%I = any(%L::%s[])', k, ids, case when k in ('produto','cliente','nf') then 'int' else 'smallint' end);
    end if;
  end loop;
  sem := f -> 'semana';
  if coalesce(ignorar, '') <> 'semana' and sem is not null and jsonb_typeof(sem) = 'array' then
    if sem @> '["fds"]' and not sem @> '["util"]' then w := w || 'extract(isodow from dia) >= 6'::text;
    elsif sem @> '["util"]' and not sem @> '["fds"]' then w := w || 'extract(isodow from dia) < 6'::text;
    end if;
  end if;
  return array_to_string(w, ' and ');
end $function$;
