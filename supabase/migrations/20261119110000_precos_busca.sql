-- Aba Preços: busca do produto digitado e estoque/custo só desse produto (sem carregar o estoque inteiro no navegador).
create or replace function public.bi_preco_busca(termo text)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare t text := upper(btrim(coalesce(termo, ''))); res json;
begin
  if not private.bi_aba_liberada('precos') then raise exception 'sem acesso aos preços'; end if;
  if length(t) < 2 then return '[]'::json; end if;
  select coalesce(json_agg(json_build_array(id, pn, nome) order by ordem, pn), '[]'::json) into res from (
    select p.id, p.pn, p.nome, case when upper(p.pn) = t then 0 when upper(p.pn) like t || '%' then 1 else 2 end ordem
      from public.bi_produto p
     where upper(p.pn) like t || '%' or upper(p.nome) like '%' || t || '%'
     order by 4, p.pn limit 30) x;
  return res;
end $function$;
revoke all on function public.bi_preco_busca(text) from public, anon;
grant execute on function public.bi_preco_busca(text) to authenticated;

-- {id, pn, nome, clsf, impostos:[pis, cofins, icms] ou null, lojas:[[loja, saldo, custo unitário]]} (lojas do escopo do usuário)
create or replace function public.bi_preco_produto(p_produto int)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record; res json;
begin
  if not private.bi_aba_liberada('precos') then raise exception 'sem acesso aos preços'; end if;
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  select json_build_object('id', p.id, 'pn', p.pn, 'nome', p.nome, 'clsf', c.clsf,
           'impostos', (select json_build_array(k.pis, k.cofins, k.icms) from public.bi_clsf k where k.codigo = c.clsf),
           'lojas', (select coalesce(json_agg(json_build_array(d.valor, s.est_fis,
                              coalesce(nullif(s.custo_u, 0), case when s.est_fis > 0 and s.custo > 0 then s.custo / s.est_fis end)) order by d.valor), '[]'::json)
                       from public.bi_estoque s join public.bi_dim d on d.tipo = 'loja' and d.id = s.loja
                      where s.produto = p.id and (e.todas or e.lojas is null or s.loja = any(e.lojas))))
    into res
    from public.bi_produto p
    left join lateral (select s.clsf from public.bi_estoque s where s.produto = p.id and s.clsf is not null and s.clsf <> '' limit 1) c on true
   where p.id = p_produto;
  return res;
end $function$;
revoke all on function public.bi_preco_produto(int) from public, anon;
grant execute on function public.bi_preco_produto(int) to authenticated;
