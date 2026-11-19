-- Aba Preços: preço de tabela (coluna TABELA da aba estoque do arquivo infobi) no simulador.
alter table public.bi_estoque add column if not exists preco_tab numeric;

-- a carga passa a ler a coluna TABELA da aba estoque
update public.bi_config
   set valor = jsonb_set(valor, '{infobi,abas,estoque,colunas,preco_tab}', '"TABELA"'::jsonb)
 where chave = 'mapa_colunas' and valor #> '{infobi,abas,estoque,colunas}' is not null;

-- {id, pn, nome, clsf, impostos:[pis, cofins, icms] ou null, lojas:[[loja, saldo, custo unitário, preço de tabela]]} (lojas do escopo do usuário)
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
                              coalesce(nullif(s.custo_u, 0), case when s.est_fis > 0 and s.custo > 0 then s.custo / s.est_fis end), s.preco_tab) order by d.valor), '[]'::json)
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
