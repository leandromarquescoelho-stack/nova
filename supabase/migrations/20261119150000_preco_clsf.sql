-- Aba Preços: lista das classificações fiscais (alíquotas) para simular o preço com outros impostos.
-- [[codigo, pis, cofins, icms], ...]
create or replace function public.bi_preco_clsf()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_aba_liberada('precos') then raise exception 'sem acesso aos preços'; end if;
  select coalesce(json_agg(json_build_array(k.codigo, k.pis, k.cofins, k.icms) order by k.codigo), '[]'::json) into res
    from (select distinct on (codigo) codigo, pis, cofins, icms from public.bi_clsf where codigo is not null and codigo <> '' order by codigo) k;
  return res;
end $function$;
revoke all on function public.bi_preco_clsf() from public, anon;
grant execute on function public.bi_preco_clsf() to authenticated;
