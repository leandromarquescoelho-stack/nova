-- Concorrência: guia "Peça Chevrolet". A função passa a devolver também o top 100 da loja PEÇA CHEVROLET (itens_pc);
-- os preços das concessionárias no site pecachevrolet.com.br ficam na mesma tabela, com sites pc_nova, pc_accioly, pc_vigorito e pc_carrera.
create or replace function public.bi_concorrencia_ler()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso à concorrência'; end if;
  with c as (select id from public.bi_dim where tipo = 'canal' and valor = 'ECOMMERCE'),
  l as (select id from public.bi_dim where tipo = 'loja' and valor = 'PEÇA CHEVROLET'),
  ult as (select max(dia) - 89 d0 from public.bi_venda_det),
  t as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, c, ult
        where v.canal = c.id and v.dia >= ult.d0 and v.fat > 0
        group by 1 order by 2 desc limit 100),
  tp as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, l, ult
         where v.loja = l.id and v.dia >= ult.d0 and v.fat > 0
         group by 1 order by 2 desc limit 100),
  -- histórico dos últimos 60 dias: só o primeiro dia e os dias em que o preço mudou
  h as (select dia, site, pn, preco, lag(preco) over (partition by site, pn order by dia) ant,
               row_number() over (partition by site, pn order by dia) n
        from public.bi_concorrencia_hist where dia >= current_date - 60 and preco is not null)
  select json_build_object(
    'itens', coalesce((select json_agg(json_build_array(p.pn, p.nome, t.fat, t.qtd) order by t.fat desc) from t join public.bi_produto p on p.id = t.produto), '[]'),
    'itens_pc', coalesce((select json_agg(json_build_array(p.pn, p.nome, tp.fat, tp.qtd) order by tp.fat desc) from tp join public.bi_produto p on p.id = tp.produto), '[]'),
    'precos', coalesce((select json_agg(json_build_array(site, pn, preco, preco_lista, disponivel, titulo, url, confianca, coletado_em)) from public.bi_concorrencia), '[]'),
    'hist', coalesce((select json_agg(json_build_array(site, pn, dia, preco) order by site, pn, dia) from h where n = 1 or preco is distinct from ant), '[]'),
    'dias', (select count(distinct dia) from public.bi_concorrencia_hist)
  ) into res;
  return res;
end $function$;
