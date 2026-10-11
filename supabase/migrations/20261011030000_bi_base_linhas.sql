-- Base de vendas linha a linha + estoque por item, para filtros exatos em todos os visuais.
-- As tabelas não são lidas diretamente pelo painel: só pelas funções abaixo, que aplicam
-- o escopo do usuário (lojas, canais, vendedor) antes de qualquer filtro.

create table if not exists public.bi_dim (
  tipo text not null,
  id smallint not null,
  valor text not null,
  primary key (tipo, id)
);

create table if not exists public.bi_produto (
  id int primary key,
  pn text not null,
  nome text,
  categoria smallint, marca smallint, montadora smallint, linha smallint, classificacao smallint
);

create table if not exists public.bi_cliente (
  id int primary key,
  codcli text,
  razao text,
  tipo_cliente smallint,
  cidade smallint
);

-- valores em centavos; mes = (ano-2000)*100 + mês (ex.: 2601 = jan/2026)
create table if not exists public.bi_venda (
  dia date not null,
  mes smallint not null,
  loja smallint not null, canal smallint not null, emitente smallint not null, origem smallint not null,
  vendedor smallint not null, linha smallint not null, marca smallint not null, categoria smallint not null,
  montadora smallint not null, classificacao smallint not null, tipo_cliente smallint not null, cidade smallint not null,
  produto int not null, cliente int not null, nf int not null,
  qtd int not null, fat int not null, custo int not null, lb int not null
);
create index if not exists bi_venda_produto on public.bi_venda (produto);
create index if not exists bi_venda_cliente on public.bi_venda (cliente);
create index if not exists bi_venda_nf on public.bi_venda (nf);

create table if not exists public.bi_estoque (
  loja smallint not null,
  produto int not null,
  est_fis numeric(14,3),
  custo numeric(14,2),
  dt_ult_vend date,
  dt_ult_comp date,
  parado boolean not null default false
);

alter table public.bi_dim enable row level security;
alter table public.bi_produto enable row level security;
alter table public.bi_cliente enable row level security;
alter table public.bi_venda enable row level security;
alter table public.bi_estoque enable row level security;
revoke all on public.bi_dim, public.bi_produto, public.bi_cliente, public.bi_venda, public.bi_estoque from anon, authenticated;

-- escopo do usuário logado: ids de lojas/canais liberados e vendedor (nulo = sem restrição)
create or replace function private.bi_escopo(out ok boolean, out todas boolean, out lojas smallint[], out canais smallint[], out vendedor smallint)
 language plpgsql stable security definer set search_path to ''
as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid() and active;
  if not found then ok := false; return; end if;
  ok := true;
  todas := p.role = 'bi';
  if todas then return; end if;
  if coalesce(cardinality(p.lojas), 0) > 0 then
    lojas := coalesce((select array_agg(d.id) from public.bi_dim d where d.tipo = 'loja' and d.valor = any(p.lojas)), '{}');
  elsif p.role = 'gerencia' then
    lojas := coalesce((select array_agg(d.id) from public.bi_dim d where d.tipo = 'loja' and d.valor = p.loja), '{}');
  end if;
  if coalesce(cardinality(p.canais), 0) > 0 then
    canais := coalesce((select array_agg(d.id) from public.bi_dim d where d.tipo = 'canal' and d.valor = any(p.canais)), '{}');
  end if;
  if p.role = 'vendedor' then
    vendedor := coalesce((select d.id from public.bi_dim d where d.tipo = 'vendedor' and d.valor = p.vendedor_nome), -1);
  end if;
end $$;

-- condição SQL (escopo + filtros do painel); `ignorar` deixa um filtro de fora (ex.: comparativo de vendedores)
create or replace function private.bi_where(f jsonb, ignorar text default null)
 returns text language plpgsql stable security definer set search_path to ''
as $$
declare e record; w text[] := array['true']; k text; arr jsonb; ids bigint[];
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if not e.todas then
    if e.lojas is not null then w := w || format('loja = any(%L::smallint[])', e.lojas); end if;
    if e.canais is not null then w := w || format('canal = any(%L::smallint[])', e.canais); end if;
    if e.vendedor is not null then w := w || format('vendedor = %s', e.vendedor); end if;
  end if;
  foreach k in array array['loja','canal','emitente','origem','vendedor','linha','marca','categoria','montadora',
                           'classificacao','tipo_cliente','cidade','produto','cliente','nf'] loop
    continue when k = ignorar;
    arr := f -> k;
    if arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      w := w || format('%I = any(%L::%s[])', k, ids, case when k in ('produto','cliente','nf') then 'int' else 'smallint' end);
    end if;
  end loop;
  return array_to_string(w, ' and ');
end $$;

-- opções dos filtros, meses, produtos e estoque por item dentro do escopo (uma vez por sessão)
create or replace function public.bi_meta()
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare w text; res json;
begin
  w := private.bi_where('{}'::jsonb);
  execute format($q$
    with g as (
      select case when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(emitente)=0 then 'emitente'
                  when grouping(origem)=0 then 'origem' when grouping(vendedor)=0 then 'vendedor' when grouping(linha)=0 then 'linha'
                  when grouping(marca)=0 then 'marca' when grouping(categoria)=0 then 'categoria' when grouping(montadora)=0 then 'montadora'
                  when grouping(classificacao)=0 then 'classificacao' when grouping(tipo_cliente)=0 then 'tipo_cliente'
                  when grouping(cidade)=0 then 'cidade' else 'mes' end tipo,
             coalesce(loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora, classificacao, tipo_cliente, cidade, mes) id
      from public.bi_venda where %s
      group by grouping sets ((loja),(canal),(emitente),(origem),(vendedor),(linha),(marca),(categoria),(montadora),
                              (classificacao),(tipo_cliente),(cidade),(mes))
    )
    select json_build_object(
      'dims', (select json_object_agg(tipo, vals) from (
                 select g.tipo, json_agg(json_build_array(g.id, d.valor) order by d.valor) vals
                 from g join public.bi_dim d on d.tipo = g.tipo and d.id = g.id group by g.tipo) z),
      'meses', (select json_agg(id order by id) from g where tipo = 'mes'),
      'dias', (select json_build_array(min(dia), max(dia)) from public.bi_venda),
      'produtos', (select json_agg(json_build_array(p.id, p.pn, p.nome, p.categoria, p.marca, p.montadora, p.linha, p.classificacao))
                   from public.bi_produto p),
      'dimTodas', (select json_object_agg(tipo, vals) from (
                 select d.tipo, json_agg(json_build_array(d.id, d.valor)) vals from public.bi_dim d
                 where d.tipo in ('categoria','marca','montadora','linha','classificacao','loja') group by d.tipo) z)
    )$q$, w) into res;
  return res;
end $$;

-- estoque item a item (loja x produto) nas lojas liberadas
create or replace function public.bi_estoque_itens()
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare e record;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  return (select json_build_object(
      'loja', coalesce(json_agg(s.loja), '[]'), 'produto', coalesce(json_agg(s.produto), '[]'),
      'est', coalesce(json_agg(s.est_fis), '[]'), 'custo', coalesce(json_agg(s.custo), '[]'),
      'vend', coalesce(json_agg(s.dt_ult_vend), '[]'), 'comp', coalesce(json_agg(s.dt_ult_comp), '[]'),
      'parado', coalesce(json_agg(s.parado), '[]'))
    from public.bi_estoque s
    where e.todas or e.lojas is null or s.loja = any(e.lojas));
end $$;

-- números do painel para os filtros e o período pedidos (valores em centavos)
-- per: {ini, fim, pini, pfim, s7i, s7f, p7i, p7f} (datas)
create or replace function public.bi_painel(f jsonb, per jsonb)
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare w text; res json;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  execute format($q$
    with g as materialized (
      select
        case when grouping(produto)=0 and grouping(mes)=0 then 'pm'
             when grouping(produto)=0 then 'p'
             when grouping(dia)=0 then 'd'
             when grouping(mes)=0 then 'r'
             when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(vendedor)=0 then 'vendedor'
             when grouping(categoria)=0 then 'categoria' when grouping(marca)=0 then 'marca' when grouping(montadora)=0 then 'montadora'
             when grouping(linha)=0 then 'linha' when grouping(emitente)=0 then 'emitente' when grouping(origem)=0 then 'origem'
             when grouping(tipo_cliente)=0 then 'tipo_cliente' when grouping(classificacao)=0 then 'classificacao'
             else 'cidade' end s,
        dia, mes, loja, canal, vendedor,
        coalesce(produto, categoria, marca, montadora, linha, emitente, origem, tipo_cliente, classificacao, cidade, loja, canal, vendedor) k,
        sum(fat) ft, sum(qtd) qt, sum(lb) lt, sum(custo) ct,
        sum(fat) filter (where dia between $1 and $2) fp, sum(qtd) filter (where dia between $1 and $2) qp, sum(lb) filter (where dia between $1 and $2) lp,
        sum(fat) filter (where dia between $3 and $4) fq, sum(qtd) filter (where dia between $3 and $4) qq, sum(lb) filter (where dia between $3 and $4) lq,
        sum(fat) filter (where dia between $5 and $6) f7, sum(fat) filter (where dia between $7 and $8) g7
      from public.bi_venda where %s
      group by grouping sets ((dia),(mes,loja,canal,vendedor),(loja),(canal),(vendedor),(categoria),(marca),(montadora),(linha),
                              (emitente),(origem),(tipo_cliente),(classificacao),(cidade),(produto),(produto,mes))
    ), top as (select k from g where s = 'p' order by ft desc limit 2000)
    select json_build_object(
      'd', (select coalesce(json_agg(json_build_array(dia, ft, qt, lt) order by dia), '[]') from g where s = 'd'),
      'r', (select coalesce(json_agg(json_build_array(mes, loja, canal, vendedor, ft, qt, ct, lt)), '[]') from g where s = 'r'),
      'ag', (select json_object_agg(s, x) from (select s, json_agg(json_build_array(k, fp, qp, lp, fq, qq, lq, ft, qt, lt)) x
                                                from g where s not in ('d','r','p','pm') group by s) z),
      'p', (select coalesce(json_agg(json_build_array(k, fp, qp, lp, fq, qq, lq, f7, g7, ft, qt, lt)), '[]') from g where s = 'p'),
      'pm', (select coalesce(json_agg(json_build_array(k, mes, ft, qt, lt)), '[]') from g where s = 'pm' and k in (select k from top))
    )$q$, w)
  into res
  using (per->>'ini')::date, (per->>'fim')::date, (per->>'pini')::date, (per->>'pfim')::date,
        (per->>'s7i')::date, (per->>'s7f')::date, (per->>'p7i')::date, (per->>'p7f')::date;
  return res;
end $$;

-- comparativo de vendedores: mesmos filtros, exceto o próprio vendedor
create or replace function public.bi_vendedores(f jsonb, per jsonb)
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare w text; res json;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb), 'vendedor');
  execute format($q$
    with b as materialized (select * from public.bi_venda where %s and dia between $1 and $2),
    g as (
      select case when grouping(marca)=0 then 'vm' when grouping(categoria)=0 then 'vc' when grouping(dia)=0 then 'vd'
                  when grouping(produto)=0 then 'vp' else 'v' end s,
             vendedor, coalesce(marca, categoria, produto) k, dia, sum(fat) ft, sum(qtd) qt, sum(lb) lt
      from b group by grouping sets ((vendedor),(vendedor,marca),(vendedor,categoria),(vendedor,dia),(vendedor,produto))
    ), topp as (select k from g where s = 'vp' group by k order by sum(ft) desc limit 10)
    select json_build_object(
      'v', (select coalesce(json_agg(json_build_array(vendedor, ft, qt, lt)), '[]') from g where s = 'v'),
      'vm', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vm'),
      'vc', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vc'),
      'vd', (select coalesce(json_agg(json_build_array(vendedor, dia, ft)), '[]') from g where s = 'vd'),
      'vp', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vp' and k in (select k from topp)),
      'vs', (select coalesce(json_agg(json_build_array(vendedor, n)), '[]') from (
               select vendedor, avg(n) n from (select vendedor, mes, count(distinct produto) n from b group by 1, 2) x group by 1) y)
    )$q$, w)
  into res using (per->>'ini')::date, (per->>'fim')::date;
  return res;
end $$;

-- busca de cliente (razão ou código) e NF dentro do escopo, para os filtros com muitos valores
create or replace function public.bi_busca(campo text, termo text)
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare w text; res json; t text := btrim(coalesce(termo, ''));
begin
  if length(t) < 2 then return '[]'; end if;
  w := private.bi_where('{}'::jsonb);
  if campo = 'cliente' then
    execute format($q$
      select coalesce(json_agg(json_build_array(c.id, c.razao || ' (' || c.codcli || ')')), '[]') from (
        select c.id, c.razao, c.codcli from public.bi_cliente c
        where (c.razao ilike '%%' || $1 || '%%' or c.codcli = $1)
          and exists (select 1 from public.bi_venda v where v.cliente = c.id and %s)
        order by c.razao limit 30) c$q$, w) into res using t;
  elsif campo = 'nf' then
    if t !~ '^\d+$' then return '[]'; end if;
    execute format($q$
      select coalesce(json_agg(json_build_array(nf, 'NF ' || nf || ' · ' || to_char(d, 'DD/MM/YY') || ' · ' || razao)), '[]') from (
        select v.nf, min(v.dia) d, min(c.razao) razao from public.bi_venda v join public.bi_cliente c on c.id = v.cliente
        where v.nf::text like $1 || '%%' and %s group by v.nf order by v.nf limit 30) x$q$, w) into res using t;
  else
    res := '[]';
  end if;
  return res;
end $$;

revoke all on function public.bi_meta(), public.bi_estoque_itens(), public.bi_painel(jsonb, jsonb),
  public.bi_vendedores(jsonb, jsonb), public.bi_busca(text, text) from public, anon;
grant execute on function public.bi_meta(), public.bi_estoque_itens(), public.bi_painel(jsonb, jsonb),
  public.bi_vendedores(jsonb, jsonb), public.bi_busca(text, text) to authenticated;
revoke all on function private.bi_escopo(), private.bi_where(jsonb, text) from public;

-- novas colunas lidas pela carga
update public.bi_config set valor = jsonb_set(jsonb_set(valor,
  '{vendas,colunas}', (valor #> '{vendas,colunas}') || '{"emitente":"EMITENTE","linha":"LINHA","nf":"NF","codcli":"CODCLI","razao":"RAZAO","tipo_cliente":"TIPO_CLIENTE","cidade":"CIDADES","classificacao":"CLASSIFICACAO_PECA"}'::jsonb),
  '{estoque,colunas}', (valor #> '{estoque,colunas}') || '{"loja":"loja","descricao":"descrição","linha":"linha","grupo":"grupo","dt_ult_vend":"dt últ. vend","dt_ult_comp":"dt últ. comp"}'::jsonb)
where chave = 'mapa_colunas';
