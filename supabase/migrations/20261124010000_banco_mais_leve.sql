-- Banco mais leve: nada muda no que o painel mostra.
-- 1) bi_estoque não tinha nenhum índice: toda consulta que cruza estoque com produto/loja (Vendas de hoje, giro,
--    carga e limpeza de produtos) lia a tabela inteira. Este índice serve tanto para "produto" quanto para "produto + loja".
create index if not exists bi_estoque_produto_loja on public.bi_estoque (produto, loja);
analyze public.bi_estoque;

-- 2) metas (abertura do painel): a conta transbordava para o disco por falta de memória de trabalho.
--    Mais memória só para estas funções (o resto do banco fica como está).
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname in ('bi_meta', 'bi_meta_leve')
  loop
    execute format('alter function %s set work_mem = %L', r.sig, '48MB');
  end loop;
end $$;
