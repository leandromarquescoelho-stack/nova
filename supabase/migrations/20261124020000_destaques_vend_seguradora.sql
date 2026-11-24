-- Vendedores em destaque: a % da meta do dia não conta as vendas para seguradoras.
-- bi_vendas_destaques passa a devolver vend_seg = {vendedor: faturamento do dia para clientes do tipo seguradora}
-- (só dos vendedores em destaque); o site desconta esse valor antes de calcular a %.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.bi_vendas_destaques(jsonb, date)'::regprocedure);
  if position('vend_seg' in d) = 0 then
    d := replace(d, 'vdest2', 'vdest3');   -- respostas guardadas antigas não têm o campo novo
    d := replace(d, $a$  r := r || jsonb_build_object('cli_vend', x::jsonb);$a$,
      $b$  r := r || jsonb_build_object('cli_vend', x::jsonb);
  -- vendas do dia para seguradoras de cada vendedor em destaque (a meta do vendedor não conta essas vendas)
  select coalesce(jsonb_object_agg(vendedor::text, fs), '{}'::jsonb) into x from (
    select b.vendedor, sum(b.fat) fs from pg_temp.vd_base b
      join public.bi_cliente c on c.id = b.cliente
      join public.bi_dim t on t.tipo = 'tipo_cliente' and t.id = c.tipo_cliente and upper(t.valor) like '%SEGURAD%'
     where b.dia = d0
       and b.vendedor in (select (e->>0)::int from jsonb_array_elements(coalesce(r->'vendedores', '[]'::jsonb)) e)
     group by b.vendedor) y;
  r := r || jsonb_build_object('vend_seg', x::jsonb);$b$);
    if position('vend_seg' in d) = 0 then raise exception 'bi_vendas_destaques: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;
