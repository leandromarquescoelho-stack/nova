-- Aba Preços (simulador de preço de venda): vendas do produto nos últimos 6 meses por emitente, com os filtros do painel.
-- A aba é restrita (liberada no cadastro do usuário, como E-commerce e Planejamento); o escopo de lojas e canais do usuário vale pelo bi_where.
create or replace function public.bi_preco_vendas(f jsonb, p_produto int)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare w text; ate date; res json;
begin
  if not private.bi_aba_liberada('precos') then raise exception 'sem acesso aos preços'; end if;
  w := private.bi_where(coalesce(f, '{}'::jsonb) - 'produto');
  select max(dia) into ate from public.bi_venda;
  -- [emitente, quantidade, faturamento, custo, lucro bruto, meses com venda]
  execute format('select coalesce(json_agg(json_build_array(e, q, fa, cu, lb, m) order by fa desc), ''[]'') from (
      select coalesce(d.valor, ''(sem emitente)'') e, sum(v.qtd) q, sum(v.fat) fa, sum(v.custo) cu, sum(v.lb) lb,
             count(distinct date_trunc(''month'', v.dia)) m
        from public.bi_venda v left join public.bi_dim d on d.tipo = ''emitente'' and d.id = v.emitente
       where v.produto = $1 and v.dia > $2 - interval ''6 months'' and %s
       group by 1) x', w) into res using p_produto, ate;
  return json_build_object('ate', ate, 'de', (ate - interval '6 months' + interval '1 day')::date, 'linhas', res);
end $function$;
revoke all on function public.bi_preco_vendas(jsonb, int) from public, anon;
grant execute on function public.bi_preco_vendas(jsonb, int) to authenticated;
