-- Visual BF2: top 10 subcategorias do dia (mostradas como "Categorias"), por faturamento, com a quantidade.
-- bi_vendas_destaques passa a devolver subcat_top = [[subcategoria, faturamento do dia, quantidade do dia], ...]
do $$
declare d text;
begin
  d := pg_get_functiondef('public.bi_vendas_destaques(jsonb, date)'::regprocedure);
  if position('subcat_top' in d) = 0 then
    d := replace(d, 'vdest3', 'vdest4');   -- respostas guardadas antigas não têm o campo novo
    d := replace(d, 'select dia, loja, canal, marca, categoria, vendedor, produto, cliente, nf, fat, lb, qtd',
                    'select dia, loja, canal, marca, categoria, subcategoria, vendedor, produto, cliente, nf, fat, lb, qtd');
    d := replace(d, $a$  r := r || jsonb_build_object('cli_vend', x::jsonb);$a$,
      $b$  r := r || jsonb_build_object('cli_vend', x::jsonb);
  -- top 10 subcategorias do dia por faturamento (com a quantidade)
  select coalesce(json_agg(json_build_array(k, fh, qh) order by fh desc), '[]'::json) into x from (
    select b.subcategoria k, sum(b.fat) fh, sum(b.qtd) qh from pg_temp.vd_base b
     where b.dia = d0 and coalesce(b.subcategoria, 0) <> 0
     group by 1 having sum(b.fat) > 0 order by 2 desc limit 10) y;
  r := r || jsonb_build_object('subcat_top', x::jsonb);$b$);
    if position('subcat_top' in d) = 0 or position('categoria, subcategoria, vendedor' in d) = 0 then
      raise exception 'bi_vendas_destaques: trecho não encontrado';
    end if;
    execute d;
  end if;
end $$;
-- limpa as respostas guardadas para a função nova responder já
delete from public.bi_cache where chave is not null and valor::text like '%"cli_vend"%' and valor::text not like '%"subcat_top"%';
