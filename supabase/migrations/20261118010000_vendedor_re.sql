-- RE (registro) de cada vendedor, para o seletor da aba Vendedores mostrar "RE - Nome".
-- A carga preenche a tabela a partir da coluna RE das vendas; o site lê pela função abaixo.
create table if not exists public.bi_vendedor_re (
  vendedor text primary key,
  re text not null
);
alter table public.bi_vendedor_re enable row level security;  -- leitura só pela função
revoke all on public.bi_vendedor_re from anon, authenticated;

create or replace function public.bi_vendedor_re()
 returns json language sql stable security definer set search_path to ''
as $function$
  select coalesce(json_agg(json_build_array(vendedor, re)), '[]'::json) from public.bi_vendedor_re
$function$;
revoke all on function public.bi_vendedor_re() from public, anon;
grant execute on function public.bi_vendedor_re() to authenticated;
