-- Filtros novos: condição de pagamento, grupo de cliente, pessoa física/jurídica, grupo de peça, aplicação
-- (Chevrolet / multimarcas) e curva GM (colunas da venda; os três últimos também no cadastro do produto),
-- equipe de venda e função do vendedor (pelo cadastro atual da aba vendedores, sem coluna na venda).

alter table public.bi_venda_det add column if not exists condicao smallint not null default 0,
  add column if not exists grupo_cliente smallint not null default 0, add column if not exists pessoa smallint not null default 0,
  add column if not exists grupo_peca smallint not null default 0,
  add column if not exists aplicacao smallint not null default 0, add column if not exists curva_gm smallint not null default 0;
alter table public.bi_venda_hist add column if not exists condicao smallint not null default 0,
  add column if not exists grupo_cliente smallint not null default 0, add column if not exists pessoa smallint not null default 0,
  add column if not exists grupo_peca smallint not null default 0,
  add column if not exists aplicacao smallint not null default 0, add column if not exists curva_gm smallint not null default 0;
alter table public.bi_produto add column if not exists grupo_peca smallint not null default 0,
  add column if not exists aplicacao smallint not null default 0, add column if not exists curva_gm smallint not null default 0;
alter table public.bi_vendedor_equipe add column if not exists funcao text;
alter table public.bi_vendedor_equipe alter column equipe drop not null;
create or replace function public.bi_equipes()
 returns json language sql stable security definer set search_path to ''
as $$ select coalesce(json_agg(e order by e), '[]') from (select distinct equipe e from public.bi_vendedor_equipe where equipe is not null) x $$;

create or replace view public.bi_venda with (security_invoker = true) as
  select dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora, classificacao,
         tipo_cliente, cidade, produto, cliente, nf, qtd, fat, custo, lb, subcategoria, condicao, grupo_cliente, pessoa, grupo_peca, aplicacao, curva_gm
    from public.bi_venda_det
  union all
  select dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora, classificacao,
         tipo_cliente, cidade, produto, cliente, 0, qtd, fat, custo, lb, subcategoria, condicao, grupo_cliente, pessoa, grupo_peca, aplicacao, curva_gm
    from public.bi_venda_hist;
revoke all on public.bi_venda from anon, authenticated;

delete from public.bi_cache;

create or replace function private.bi_where(f jsonb, ignorar text default null::text)
 returns text language plpgsql stable security definer set search_path to ''
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
  sem := f -> 'semana';
  if coalesce(ignorar, '') <> 'semana' and sem is not null and jsonb_typeof(sem) = 'array' then
    if sem @> '["fds"]' and not sem @> '["util"]' then w := w || 'extract(isodow from dia) >= 6'::text;
    elsif sem @> '["util"]' and not sem @> '["fds"]' then w := w || 'extract(isodow from dia) < 6'::text;
    end if;
  end if;
  return array_to_string(w, ' and ');
end $function$;

create or replace function public.bi_meta()
 returns json language plpgsql volatile security definer set search_path to ''
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
                  when grouping(curva_gm)=0 then 'curva_gm' else 'mes' end tipo,
             coalesce(loja, canal, emitente, origem, vendedor, linha, marca, categoria, subcategoria, montadora, classificacao, tipo_cliente, cidade,
                      condicao, grupo_cliente, pessoa, grupo_peca, aplicacao, curva_gm, mes) id
      from public.bi_venda where %s
      group by grouping sets ((loja),(canal),(emitente),(origem),(vendedor),(linha),(marca),(categoria),(subcategoria),(montadora),
                              (classificacao),(tipo_cliente),(cidade),(condicao),(grupo_cliente),(pessoa),(grupo_peca),(aplicacao),(curva_gm),(mes))
    ),
    -- equipe e função: dos vendedores que aparecem no escopo
    gv as (
      select t.tipo, dx.id from g join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = g.id
      join public.bi_vendedor_equipe ve on ve.vendedor = dv.valor
      cross join lateral (values ('equipe', ve.equipe), ('funcao', ve.funcao)) t(tipo, valor)
      join public.bi_dim dx on dx.tipo = t.tipo and dx.valor = t.valor
      where g.tipo = 'vendedor' group by 1, 2
    ),
    ga as (select tipo, id from g where tipo <> 'mes' union all select tipo, id from gv)
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
