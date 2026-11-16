-- Zonas da capital (Centro, Norte, Sul, Leste, Oeste) pela faixa de CEP do cliente.
-- A carga calcula a zona de cada cliente a partir da coluna CEP da planilha e grava em bi_cliente.zona
-- (código da dimensão 'zona' em bi_dim). Cliente fora da capital ou sem CEP fica sem zona.
-- O filtro "Zona da capital" do painel vira: cliente da venda pertence às zonas escolhidas.
alter table public.bi_cliente add column if not exists zona smallint;
create index if not exists bi_cliente_zona on public.bi_cliente (zona) where zona is not null;

create or replace function private.bi_where(f jsonb, ignorar text default null::text)
 returns text
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare e record; w text[] := array['true']; k text; arr jsonb; ids bigint[]; sem jsonb; eq text[]; nomes text[];
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
    if sem @> '["fds"]' and not sem @> '["util"]' then w := w || 'extract(isodow from dia) >= 6'::text;
    elsif sem @> '["util"]' and not sem @> '["fds"]' then w := w || 'extract(isodow from dia) < 6'::text;
    end if;
  end if;
  return array_to_string(w, ' and ');
end $function$;

-- opções do filtro: as zonas que têm cliente com venda no escopo do usuário
create or replace function public.bi_meta()
 returns json
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare w text; res json; ck text;
begin
  w := private.bi_where('{}'::jsonb);
  ck := md5('meta|' || w);
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with g as (
      select case when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(emitente)=0 then 'emitente'
                  when grouping(origem)=0 then 'origem' when grouping(vendedor)=0 then 'vendedor' when grouping(linha)=0 then 'linha'
                  when grouping(marca)=0 then 'marca' when grouping(categoria)=0 then 'categoria' when grouping(subcategoria)=0 then 'subcategoria'
                  when grouping(montadora)=0 then 'montadora'
                  when grouping(classificacao)=0 then 'classificacao' when grouping(tipo_cliente)=0 then 'tipo_cliente'
                  when grouping(cidade)=0 then 'cidade' when grouping(condicao)=0 then 'condicao'
                  when grouping(grupo_cliente)=0 then 'grupo_cliente' when grouping(pessoa)=0 then 'pessoa'
                  when grouping(grupo_peca)=0 then 'grupo_peca' when grouping(aplicacao)=0 then 'aplicacao'
                  when grouping(curva_gm)=0 then 'curva_gm' when grouping(zona)=0 then 'zona' else 'mes' end tipo,
             coalesce(loja, canal, emitente, origem, vendedor, linha, marca, categoria, subcategoria, montadora, classificacao, tipo_cliente, cidade,
                      condicao, grupo_cliente, pessoa, grupo_peca, aplicacao, curva_gm, zona, mes) id
      from (select v.*, c.zona from (select * from public.bi_venda where %s) v left join public.bi_cliente c on c.id = v.cliente) v
      group by grouping sets ((loja),(canal),(emitente),(origem),(vendedor),(linha),(marca),(categoria),(subcategoria),(montadora),
                              (classificacao),(tipo_cliente),(cidade),(condicao),(grupo_cliente),(pessoa),(grupo_peca),(aplicacao),(curva_gm),(zona),(mes))
    ),
    -- equipe e função: dos vendedores que aparecem no escopo
    gv as (
      select t.tipo, dx.id from g join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = g.id
      join public.bi_vendedor_equipe ve on ve.vendedor = dv.valor
      cross join lateral (values ('equipe', ve.equipe), ('funcao', ve.funcao)) t(tipo, valor)
      join public.bi_dim dx on dx.tipo = t.tipo and dx.valor = t.valor
      where g.tipo = 'vendedor' group by 1, 2
    ),
    ga as (select tipo, id from g where tipo <> 'mes' and id is not null union all select tipo, id from gv)
    select json_build_object(
      'dims', (select json_object_agg(tipo, vals) from (
                 select g.tipo, json_agg(json_build_array(g.id, d.valor) order by d.valor) vals
                 from ga g join public.bi_dim d on d.tipo = g.tipo and d.id = g.id group by g.tipo) z),
      'meses', (select json_agg(id order by id) from g where tipo = 'mes'),
      'dias', (select json_build_array(min(dia), max(dia)) from public.bi_venda),
      'produtos', (select json_agg(json_build_array(p.id, p.pn, p.nome, p.categoria, p.marca, p.montadora, p.linha, p.classificacao, p.subcategoria, p.grupo_peca, p.aplicacao, p.curva_gm))
                   from public.bi_produto p),
      'dimTodas', (select json_object_agg(tipo, vals) from (
                 select d.tipo, json_agg(json_build_array(d.id, d.valor)) vals from public.bi_dim d
                 where d.tipo in ('categoria','subcategoria','marca','montadora','linha','classificacao','grupo_peca','aplicacao','curva_gm','loja') group by d.tipo) z)
    )$q$, w) into res;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;

delete from public.bi_cache;
