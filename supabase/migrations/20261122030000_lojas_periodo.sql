-- Vendas > Lojas: evolução no período escolhido, uma linha por loja.
-- Granularidade automática: por dia até 62 dias, por semana até 1 ano, por mês acima disso.
-- {gran, linhas:[[início do período, loja, fat, lb, qtd]]} (valores em centavos; filtros e escopo do usuário pelo bi_where)
create or replace function public.bi_lojas_periodo(f jsonb, per jsonb)
 returns json
 language plpgsql
 security definer
 set search_path to ''
 set work_mem to '48MB'
as $function$
declare w text; res json; ck text; gran text;
  i1 date := (per->>'ini')::date; i2 date := (per->>'fim')::date;
begin
  if i1 is null or i2 is null or i2 < i1 then raise exception 'período inválido'; end if;
  gran := case when i2 - i1 <= 62 then 'dia' when i2 - i1 <= 366 then 'semana' else 'mes' end;
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'lojasper1', w, i1, i2));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    select json_build_object('gran', %L, 'linhas', coalesce(json_agg(json_build_array(p, loja, ft, lt, qt) order by p, loja), '[]'))
      from (select date_trunc(%L, dia)::date p, loja, sum(fat) ft, sum(lb) lt, sum(qtd) qt
              from public.bi_venda where %s and dia between %L and %L
             group by 1, 2) g$q$,
    gran, case gran when 'dia' then 'day' when 'semana' then 'week' else 'month' end, w, i1, i2)
  into res;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;

revoke all on function public.bi_lojas_periodo(jsonb, jsonb) from public, anon;
grant execute on function public.bi_lojas_periodo(jsonb, jsonb) to authenticated;
