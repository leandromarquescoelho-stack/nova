-- Velocidade da carga: o resumo de clientes (aba Clientes) passa a recalcular só os clientes dos dias regravados
-- quando a data de referência não mudou (várias cargas por dia). Uma vez por dia, ou sem a lista de dias, recalcula tudo.
-- Empate de valor entre vendedores (venda e devolução) passa a ter desempate fixo.
-- A tabela temporária ganha índice e estatística (sem isso o banco às vezes escolhia um caminho lento e a etapa passava de 4 minutos).
create or replace function private.bi_clientes_atualizar(p_dias date[])
 returns void language plpgsql security definer set search_path to '' set work_mem to '128MB'
as $function$
declare ref date; ecom smallint; ant date; alvo integer[];
begin
  select max(dia) into ref from public.bi_venda;
  ecom := coalesce((select d.id from public.bi_dim d where d.tipo = 'canal' and d.valor = 'ECOMMERCE'), -1);
  -- incremental: com a mesma data de referência da última vez, só mudam os clientes que compraram nos dias regravados
  -- (os que ganharam venda e os que tinham venda nesses dias, que estão com última compra a partir do 1º dia regravado)
  ant := (select (c.valor ->> 'ref')::date from public.bi_config c where c.chave = 'clientes_resumo');
  if p_dias is not null and ant = ref then
    if cardinality(p_dias) = 0 then return; end if;
    alvo := array(select distinct v.cliente from public.bi_venda_det v where v.dia = any(p_dias) and v.cliente is not null
                  union select r.cliente from public.bi_cliente_resumo r where r.ult >= (select min(x) from unnest(p_dias) x));
  end if;
  drop table if exists pg_temp._res;
  create temp table _res (like public.bi_cliente_resumo) on commit drop;
  insert into _res
  with b as materialized (select cliente, vendedor, loja, canal, dia, fat, lb, tipo_cliente, grupo_cliente, pessoa, cidade
                          from public.bi_venda where dia > ref - 730 and (alvo is null or cliente = any(alvo))),
  v as (select distinct on (cliente) cliente, vendedor from (
          select cliente, vendedor, sum(fat) ft from b where dia > ref - 365 group by 1, 2) x order by cliente, ft desc, vendedor),
  l as (select distinct on (cliente) cliente, loja, canal from (
          select cliente, loja, canal, sum(fat) ft from b group by 1, 2, 3) x order by cliente, ft desc, loja, canal),
  c as (select cliente, max(dia) ult, min(dia) pri, min(dia) filter (where dia > ref - 365) pri12,
               count(distinct dia) filter (where dia > ref - 365) ncomp,
               sum(fat) filter (where dia > ref - 365) f12, sum(lb) filter (where dia > ref - 365) l12,
               sum(fat) filter (where dia > ref - 90) f90, sum(fat) filter (where dia > ref - 180 and dia <= ref - 90) f180,
               max(tipo_cliente) tc, max(grupo_cliente) gc, max(pessoa) pe, max(cidade) ci,
               coalesce(sum(fat) filter (where canal = ecom), 0) > 0.5 * coalesce(sum(fat), 0) ec
        from b group by cliente)
  select c.cliente, c.ult, c.pri, c.pri12, coalesce(c.ncomp, 0), c.f12, c.l12, c.f90, c.f180, c.tc, c.gc, c.pe, c.ci,
         v.vendedor, l.loja, l.canal,
         c.ec or coalesce((select d.valor from public.bi_dim d where d.tipo = 'vendedor' and d.id = v.vendedor), '') ilike '%ECOMMERCE%',
         ref
  from c left join v on v.cliente = c.cliente left join l on l.cliente = c.cliente;
  create index on _res (cliente);
  analyze _res;
  -- grava só o que mudou (antes apagava e regravava os ~95 mil clientes a cada carga)
  delete from public.bi_cliente_resumo r where (alvo is null or r.cliente = any(alvo))
     and not exists (select 1 from _res t where t.cliente = r.cliente);
  update public.bi_cliente_resumo r set ult = t.ult, pri = t.pri, pri12 = t.pri12, ncomp = t.ncomp, f12 = t.f12, l12 = t.l12,
         f90 = t.f90, f180 = t.f180, tipo_cliente = t.tipo_cliente, grupo_cliente = t.grupo_cliente, pessoa = t.pessoa,
         cidade = t.cidade, vendedor = t.vendedor, loja = t.loja, canal = t.canal, ecom = t.ecom, ref = t.ref
    from _res t where t.cliente = r.cliente
     and (r.ult, r.pri, r.pri12, r.ncomp, r.f12, r.l12, r.f90, r.f180, r.tipo_cliente, r.grupo_cliente, r.pessoa,
          r.cidade, r.vendedor, r.loja, r.canal, r.ecom)
         is distinct from
         (t.ult, t.pri, t.pri12, t.ncomp, t.f12, t.l12, t.f90, t.f180, t.tipo_cliente, t.grupo_cliente, t.pessoa,
          t.cidade, t.vendedor, t.loja, t.canal, t.ecom);
  insert into public.bi_cliente_resumo select t.* from _res t
   where not exists (select 1 from public.bi_cliente_resumo r where r.cliente = t.cliente);
  -- a data de referência (muda todo dia) fica num lugar só, para não regravar todas as linhas por causa dela
  insert into public.bi_config (chave, valor) values ('clientes_resumo', jsonb_build_object('ref', ref))
  on conflict (chave) do update set valor = excluded.valor;
end $function$;

-- a versão antiga (sem parâmetro) continua funcionando: recálculo completo
create or replace function private.bi_clientes_atualizar()
 returns void language sql security definer set search_path to ''
as $$ select private.bi_clientes_atualizar(null::date[]) $$;
revoke all on function private.bi_clientes_atualizar(date[]) from public, anon, authenticated;
revoke all on function private.bi_clientes_atualizar() from public, anon, authenticated;
grant execute on function private.bi_clientes_atualizar(date[]), private.bi_clientes_atualizar() to carga;

-- aquecimento da tela de entrada (Vendas de hoje) pelo usuário da carga
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('bi_metas_vend', 'bi_vendas_hoje', 'bi_vendas_hoje_estoque', 'bi_ticker', 'bi_vendas_destaques')
  loop
    execute format('grant execute on function %s to carga', r.sig);
  end loop;
end $$;
