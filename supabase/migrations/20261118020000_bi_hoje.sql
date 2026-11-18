-- Card "Faturamento de hoje": faturamento e lucro bruto do dia por tipo de cliente (Clientes / Seguradoras).
-- Consulta só o dia pedido (antes o site usava a consulta completa de agrupamentos, que levava ~6 s por filtro).
create or replace function public.bi_hoje(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text;
begin
  f := coalesce(f, '{}'::jsonb);
  w := private.bi_where(f);
  ck := md5(concat_ws('|', 'hoje1', w, dia));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    select coalesce(json_agg(json_build_array(tipo_cliente, ft, lt)), '[]'::json)
    from (select tipo_cliente, sum(fat) ft, sum(lb) lt from public.bi_venda where %s and dia = $1 group by 1) x$q$, w)
  into res using dia;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_hoje(jsonb, date) from public, anon;
grant execute on function public.bi_hoje(jsonb, date) to authenticated;
