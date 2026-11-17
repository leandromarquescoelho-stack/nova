-- Filtro sem nenhuma venda no período: a consulta devolve vazio (null) e a gravação no cache falhava
-- (coluna valor é not null), o que aparecia no site como "Não foi possível atualizar os números".
-- Agora o resultado vazio simplesmente não é guardado no cache; a função devolve o vazio normalmente.
do $$
declare r record; def text; n int := 0;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.prokind = 'f'
      and p.prosrc like '%insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;%'
  loop
    def := replace(pg_get_functiondef(r.oid),
      'insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;',
      'if res is not null then insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing; end if;');
    execute def;
    n := n + 1;
  end loop;
  raise notice '% funções ajustadas', n;
end $$;
