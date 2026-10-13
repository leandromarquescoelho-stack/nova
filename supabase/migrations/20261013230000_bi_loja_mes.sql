-- Loja × mês: faturamento, lucro bruto, notas fiscais e clientes distintos por loja e mês (e no total de cada loja),
-- para o seletor de métrica do painel (Faturamento, Margem, Ticket médio NF, Ticket médio cliente).
-- Notas e clientes contam só linhas de venda (fat > 0); a mesma nota em emitentes diferentes conta separada.
create or replace function public.bi_loja_mes(f jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $$
declare w text; res json; ck text;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'lojames1', w));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    select coalesce(json_agg(json_build_array(loja, mes, ft, lt, nn, nc)), '[]') from (
      select loja, mes, sum(fat) ft, sum(lb) lt,
             count(distinct (emitente, nf)) filter (where fat > 0 and nf <> 0) nn,
             count(distinct cliente) filter (where fat > 0) nc
      from public.bi_venda where %s
      group by grouping sets ((loja, mes), (loja))) g$q$, w)
  into res;
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $$;

revoke all on function public.bi_loja_mes(jsonb) from public, anon;
grant execute on function public.bi_loja_mes(jsonb) to authenticated;
