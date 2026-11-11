-- O login lê bi_meta (opções de filtro de toda a base no escopo do usuário). Sem cache, cada login refazia
-- a contagem de todas as vendas (2 a 3 s, mais com o banco frio) e às vezes estourava o limite de 8 s do Supabase.
-- Agora o resultado fica em bi_cache por escopo, como as demais funções; a carga limpa o cache.
create or replace function public.bi_meta()
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text;
begin
  w := private.bi_where('{}'::jsonb);
  ck := md5('meta|' || w);
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with g as (
      select case when grouping(loja)=0 then 'loja' when grouping(canal)=0 then 'canal' when grouping(emitente)=0 then 'emitente'
                  when grouping(origem)=0 then 'origem' when grouping(vendedor)=0 then 'vendedor' when grouping(linha)=0 then 'linha'
                  when grouping(marca)=0 then 'marca' when grouping(categoria)=0 then 'categoria' when grouping(subcategoria)=0 then 'subcategoria'
                  when grouping(montadora)=0 then 'montadora'
                  when grouping(classificacao)=0 then 'classificacao' when grouping(tipo_cliente)=0 then 'tipo_cliente'
                  when grouping(cidade)=0 then 'cidade' else 'mes' end tipo,
             coalesce(loja, canal, emitente, origem, vendedor, linha, marca, categoria, subcategoria, montadora, classificacao, tipo_cliente, cidade, mes) id
      from public.bi_venda where %s
      group by grouping sets ((loja),(canal),(emitente),(origem),(vendedor),(linha),(marca),(categoria),(subcategoria),(montadora),
                              (classificacao),(tipo_cliente),(cidade),(mes))
    )
    select json_build_object(
      'dims', (select json_object_agg(tipo, vals) from (
                 select g.tipo, json_agg(json_build_array(g.id, d.valor) order by d.valor) vals
                 from g join public.bi_dim d on d.tipo = g.tipo and d.id = g.id group by g.tipo) z),
      'meses', (select json_agg(id order by id) from g where tipo = 'mes'),
      'dias', (select json_build_array(min(dia), max(dia)) from public.bi_venda),
      'produtos', (select json_agg(json_build_array(p.id, p.pn, p.nome, p.categoria, p.marca, p.montadora, p.linha, p.classificacao, p.subcategoria))
                   from public.bi_produto p),
      'dimTodas', (select json_object_agg(tipo, vals) from (
                 select d.tipo, json_agg(json_build_array(d.id, d.valor)) vals from public.bi_dim d
                 where d.tipo in ('categoria','subcategoria','marca','montadora','linha','classificacao','loja') group by d.tipo) z)
    )$q$, w) into res;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
