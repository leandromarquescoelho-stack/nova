-- consulta de vendedores: acrescenta clientes distintos e notas fiscais por vendedor no período (aprovado pelo Leandro em 12/10/2026)
-- base e agrupamentos materializados uma vez só (antes cada parte do resultado recalculava o agrupamento)
create or replace function public.bi_vendedores(f jsonb, per jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $$
declare w text; res json; ck text;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb), 'vendedor');
  ck := md5(concat_ws('|', 'vendedores2', w, per->>'ini', per->>'fim'));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with b as materialized (select vendedor, marca, categoria, produto, dia, mes, cliente, nf, fat, qtd, lb
                         from public.bi_venda where %s and dia between $1 and $2),
    g as materialized (
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
               select vendedor, avg(n) n from (select vendedor, mes, count(distinct produto) n from b group by 1, 2) x group by 1) y),
      'vcli', (select coalesce(json_agg(json_build_array(vendedor, nc, nn)), '[]') from (
               select vendedor, count(distinct cliente) nc, count(distinct nf) nn from b group by 1) y)
    )$q$, w)
  into res using (per->>'ini')::date, (per->>'fim')::date;
  if coalesce(f, '{}'::jsonb) - 'vendedor' = '{}'::jsonb then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $$;

