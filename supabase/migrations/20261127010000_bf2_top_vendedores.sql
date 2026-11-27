-- Visual BF2: top 10 de vendedores, clientes e produtos pelo faturamento do dia.
-- Antes o BF2 reaproveitava as listas de "destaque" (acima da própria média, 10 itens); tirando o vendedor E-COMMERCE sobravam 9
-- e quem vendeu muito mas dentro da média ficava de fora. bi_vendas_destaques passa a devolver também
-- vendedores_t, produtos_t e clientes_t (12 itens cada, por faturamento do dia, mesma estrutura das listas).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.bi_vendas_destaques(jsonb, date)'::regprocedure);
  if position('_t'', x::jsonb)' in d) = 0 then
    if position('vdest4' in d) = 0 or position($m$  r := r || jsonb_build_object('subcat_top', x::jsonb);$m$ in d) = 0 then
      raise exception 'bi_vendas_destaques: rode antes o SQL destaques_subcategorias (trecho não encontrado)';
    end if;
    d := replace(d, 'vdest4', 'vdest5');   -- respostas guardadas antigas não têm os campos novos
    d := replace(d, $a$  r := r || jsonb_build_object('subcat_top', x::jsonb);$a$,
      $b$  r := r || jsonb_build_object('subcat_top', x::jsonb);
  -- Visual BF2: top 12 do dia por faturamento (vendedores, produtos, clientes), mesma estrutura das listas de destaque
  for i in 1 .. array_length(dims, 1) loop
    continue when dims[i][1] not in ('vendedores', 'produtos', 'clientes');
    execute format($q$
      select coalesce(json_agg(json_build_array(k, fh, lh, qh, fb, qb, ch, %s) order by fh desc), '[]'::json) from (
        select %I k, sum(fat) filter (where dia = $1) fh, sum(lb) filter (where dia = $1) lh, sum(qtd) filter (where dia = $1) qh,
               coalesce(sum(fat) filter (where dia < $1), 0) fb, coalesce(sum(qtd) filter (where dia < $1), 0) qb,
               count(distinct cliente) filter (where dia = $1) ch
          from pg_temp.vd_base where %I is not null
         group by 1 having sum(fat) filter (where dia = $1) > 0
         order by 2 desc limit 12) x$q$, dims[i][3], dims[i][2], dims[i][2])
    into x using d0;
    r := r || jsonb_build_object(dims[i][1] || '_t', x::jsonb);
  end loop;$b$);
    execute d;
  end if;
end $$;
-- limpa as respostas guardadas para a função nova responder já
delete from public.bi_cache where chave is not null and valor::text like '%"subcat_top"%' and valor::text not like '%"vendedores_t"%';
