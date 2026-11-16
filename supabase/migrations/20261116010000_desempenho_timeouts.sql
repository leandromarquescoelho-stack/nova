-- Buscas que estouravam o limite de 8s do banco ("Não foi possível carregar agora"):
-- 1) índices por data e por canal+data: a concorrência (top 100 do e-commerce dos últimos 90 dias) deixa de varrer a venda inteira;
-- 2) limite de tempo do usuário logado de 8s para 25s: com várias buscas pesadas ao mesmo tempo o servidor fica lento e elas estouravam;
-- 3) o painel passa a guardar também as respostas com filtro (antes só sem filtro). O cache é zerado a cada carga,
--    e a chave inclui o escopo do perfil (lojas/canais/vendedor), então um usuário nunca recebe o resultado de outro escopo.
create index if not exists bi_venda_det_dia on public.bi_venda_det (dia);
create index if not exists bi_venda_det_canal_dia on public.bi_venda_det (canal, dia);

alter role authenticated set statement_timeout = '25s';
notify pgrst, 'reload config';

create or replace function public.bi_painel(f jsonb, per jsonb, parte text)
 returns json
 language plpgsql
 security definer
 set search_path to ''
 set work_mem to '48MB'
as $function$
declare w text; res json; ck text;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; q1 date := (per->>'pini')::date; q2 date := (per->>'pfim')::date;
  s1 date := (per->>'s7i')::date; s2 date := (per->>'s7f')::date; t1 date := (per->>'p7i')::date; t2 date := (per->>'p7f')::date;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'painel2', parte, w, i1, i2, q1, q2, s1, s2, t1, t2));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  if parte = 'a' then
    execute format($q$
      with g as materialized (
        select dia, mes, loja, canal, vendedor, grouping(dia) gd, sum(fat) ft, sum(qtd) qt, sum(lb) lt, sum(custo) ct
        from public.bi_venda where %s
        group by grouping sets ((dia),(mes,loja,canal,vendedor)))
      select json_build_object(
        'd', (select coalesce(json_agg(json_build_array(dia, ft, qt, lt) order by dia), '[]') from g where gd = 0),
        'r', (select coalesce(json_agg(json_build_array(mes, loja, canal, vendedor, ft, qt, ct, lt)), '[]') from g where gd = 1))$q$, w)
    into res;
  elsif parte = 'c' then
    execute format($q$
      with g as materialized (
        select case when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(vendedor)=0 then 'vendedor'
                    when grouping(categoria)=0 then 'categoria' when grouping(subcategoria)=0 then 'subcategoria'
                    when grouping(marca)=0 then 'marca' when grouping(montadora)=0 then 'montadora'
                    when grouping(linha)=0 then 'linha' when grouping(emitente)=0 then 'emitente' when grouping(origem)=0 then 'origem'
                    when grouping(tipo_cliente)=0 then 'tipo_cliente' when grouping(classificacao)=0 then 'classificacao' else 'cidade' end s,
               coalesce(loja, canal, vendedor, categoria, subcategoria, marca, montadora, linha, emitente, origem, tipo_cliente, classificacao, cidade) k,
               sum(fat) ft, sum(qtd) qt, sum(lb) lt,
               sum(fat) filter (where dia between $1 and $2) fp, sum(qtd) filter (where dia between $1 and $2) qp, sum(lb) filter (where dia between $1 and $2) lp,
               sum(fat) filter (where dia between $3 and $4) fq, sum(qtd) filter (where dia between $3 and $4) qq, sum(lb) filter (where dia between $3 and $4) lq
        from public.bi_venda where %s
        group by grouping sets ((loja),(canal),(vendedor),(categoria),(subcategoria),(marca),(montadora),(linha),
                                (emitente),(origem),(tipo_cliente),(classificacao),(cidade)))
      select json_object_agg(s, x) from (select s, json_agg(json_build_array(k, fp, qp, lp, fq, qq, lq, ft, qt, lt)) x from g group by s) z$q$, w)
    into res using i1, i2, q1, q2;
  else
    execute format($q$
      with g as materialized (
        select produto, mes, grouping(mes) gm,
               sum(fat) ft, sum(qtd) qt, sum(lb) lt,
               sum(fat) filter (where dia between $1 and $2) fp, sum(qtd) filter (where dia between $1 and $2) qp, sum(lb) filter (where dia between $1 and $2) lp,
               sum(fat) filter (where dia between $3 and $4) fq, sum(qtd) filter (where dia between $3 and $4) qq, sum(lb) filter (where dia between $3 and $4) lq,
               sum(fat) filter (where dia between $5 and $6) f7, sum(fat) filter (where dia between $7 and $8) g7
        from public.bi_venda where %s
        group by grouping sets ((produto), (produto, mes))),
      top as (select produto from g where gm = 1 order by ft desc limit 2000)
      select json_build_object(
        'p', (select coalesce(json_agg(json_build_array(produto, fp, qp, lp, fq, qq, lq, f7, g7, ft, qt, lt)), '[]') from g where gm = 1),
        'pm', (select coalesce(json_agg(json_build_array(g.produto, mes, ft, qt, lt)), '[]') from g join top t on t.produto = g.produto where gm = 0))$q$, w)
    into res using i1, i2, q1, q2, s1, s2, t1, t2;
  end if;
  -- sem filtro sempre; com filtro enquanto o cache estiver pequeno (zerado a cada carga)
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb or (select count(*) from public.bi_cache) < 1500 then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $function$;
