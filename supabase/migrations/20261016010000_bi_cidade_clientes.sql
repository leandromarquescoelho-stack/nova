-- Cidades que mais compram: clientes distintos por cidade no período e no período anterior
-- (base da quantidade de clientes e do faturamento médio por cliente). Só linhas de venda (fat > 0).
create or replace function public.bi_cidade_clientes(f jsonb, per jsonb)
 returns json language plpgsql volatile security definer set search_path to '' set work_mem to '48MB'
as $$
declare w text; res json; ck text;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date; q1 date := (per->>'pini')::date; q2 date := (per->>'pfim')::date;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'cidcli1', w, i1, i2, q1, q2));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    select coalesce(json_agg(json_build_array(cidade, nc, ncp)), '[]') from (
      select cidade,
             count(distinct cliente) filter (where fat > 0 and dia between $1 and $2) nc,
             count(distinct cliente) filter (where fat > 0 and dia between $3 and $4) ncp
      from public.bi_venda where %s and (dia between $1 and $2 or dia between $3 and $4)
      group by cidade) g$q$, w)
  into res using i1, i2, q1, q2;
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb then
    insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  end if;
  return res;
end $$;

revoke all on function public.bi_cidade_clientes(jsonb, jsonb) from public, anon;
grant execute on function public.bi_cidade_clientes(jsonb, jsonb) to authenticated;
