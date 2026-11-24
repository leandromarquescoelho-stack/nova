-- Liberar espaço no banco (plano grátis: 500 MB) e arquivar vendas antigas todo mês.
-- O que o painel mostra não muda: os meses arquivados continuam aparecendo (a visão bi_venda junta as duas tabelas).
-- Nos meses arquivados a contagem de notas fica aproximada (sem o número da NF), como já era no histórico.
--
-- Rode à noite, logo depois de uma carga (a carga roda nos minutos :00 e :30). São 3 partes, nesta ordem,
-- cada uma numa consulta nova do SQL Editor. Entre a parte 1 e a parte 3 o painel fica mais lento (sem índices).

-- ===================== PARTE 1 (rode tudo deste bloco de uma vez) =====================
set statement_timeout = '15min';

-- 1) índice por número de nota (25 MB): só a busca da IA por NF usa
drop index if exists public.bi_venda_det_nf;

-- 2) arquivamento: meses com mais de N meses fechados saem de bi_venda_det (linha a linha, com NF e índices)
--    e vão para bi_venda_hist (mesmo detalhe por dia, produto, cliente e vendedor, sem NF e só com índice leve).
create or replace function private.bi_arquivar_vendas(p_meses int default 4)
 returns text language plpgsql security definer set search_path to ''
as $$
declare mx date; corte date; atual date; n_lin bigint; n_res bigint;
begin
  select max(v.dia) into mx from public.bi_venda_det v;
  if mx is null then return 'sem vendas'; end if;
  -- mantém o mês atual + p_meses meses fechados linha a linha (nunca menos de 3: a carga regrava os dias recentes)
  corte := (date_trunc('month', mx) - make_interval(months => greatest(coalesce(p_meses, 4), 3)))::date;
  atual := coalesce((select (c.valor->>'corte')::date from public.bi_config c where c.chave = 'arquivo'), date '2026-01-01');
  if corte <= atual then return 'nada a arquivar: limite já em ' || atual; end if;
  lock table public.bi_venda_det, public.bi_venda_hist in share row exclusive mode;   -- a carga espera terminar
  -- os limites das duas tabelas andam junto (o banco usa isso para não ler a tabela errada): saem e voltam com o novo corte
  alter table public.bi_venda_det drop constraint if exists bi_venda_det_periodo;
  alter table public.bi_venda_hist drop constraint if exists bi_venda_hist_periodo;
  insert into public.bi_venda_hist (dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora,
         classificacao, tipo_cliente, cidade, produto, cliente, qtd, fat, custo, lb, subcategoria, condicao, grupo_cliente,
         pessoa, grupo_peca, aplicacao, curva_gm)
  select dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora,
         classificacao, tipo_cliente, cidade, produto, cliente, sum(qtd), sum(fat), sum(custo), sum(lb), subcategoria, condicao,
         grupo_cliente, pessoa, grupo_peca, aplicacao, curva_gm
    from public.bi_venda_det where dia < corte
   group by dia, mes, loja, canal, emitente, origem, vendedor, linha, marca, categoria, montadora, classificacao, tipo_cliente,
            cidade, produto, cliente, subcategoria, condicao, grupo_cliente, pessoa, grupo_peca, aplicacao, curva_gm;
  get diagnostics n_res = row_count;
  delete from public.bi_venda_det where dia < corte;
  get diagnostics n_lin = row_count;
  execute format('alter table public.bi_venda_det add constraint bi_venda_det_periodo check (dia >= %L::date)', corte);
  execute format('alter table public.bi_venda_hist add constraint bi_venda_hist_periodo check (dia < %L::date)', corte);
  insert into public.bi_config (chave, valor)
  values ('arquivo', jsonb_build_object('corte', corte, 'meses', p_meses, 'em', now(), 'linhas', n_lin, 'resumidas', n_res))
  on conflict (chave) do update set valor = excluded.valor;
  delete from public.bi_cache;
  analyze public.bi_venda_hist;
  return format('arquivado até %s: %s linhas viraram %s no histórico', corte - 1, n_lin, n_res);
end $$;
revoke all on function private.bi_arquivar_vendas(int) from public, anon, authenticated;

-- 3) "produto nunca vendido" (Novidades em estoque) passa a olhar também os meses arquivados
do $$
declare d text;
begin
  d := pg_get_functiondef('public.bi_vendas_hoje_estoque(jsonb, date)'::regprocedure);
  if position('bi_venda_hist' in d) = 0 then
    d := replace(d, 'not exists (select 1 from public.bi_venda_det v where v.produto = s.produto) nv',
                    'not exists (select 1 from public.bi_venda_det v where v.produto = s.produto) and not exists (select 1 from public.bi_venda_hist h where h.produto = s.produto) nv');
    if position('bi_venda_hist' in d) = 0 then raise exception 'bi_vendas_hoje_estoque: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

-- 4) todo dia 2, às 04:15 (07:15 UTC, entre duas cargas), arquiva o mês que passou do limite
select cron.unschedule('arquivar-vendas') where exists (select 1 from cron.job where jobname = 'arquivar-vendas');
select cron.schedule('arquivar-vendas', '15 7 2 * *', $c$set statement_timeout = '15min'; select private.bi_arquivar_vendas(4)$c$);

-- 5) agora: arquiva janeiro a junho (fica linha a linha de julho em diante)
select private.bi_arquivar_vendas(4);

-- 6) tira os índices de bi_venda_det antes de compactar (assim o banco não passa do limite durante a parte 2);
--    a parte 3 recria
drop index if exists public.bi_venda_det_produto;
drop index if exists public.bi_venda_det_cliente;
drop index if exists public.bi_venda_det_dia;
drop index if exists public.bi_venda_det_canal_dia;

-- ===================== PARTE 2 (rode SOZINHA, numa consulta nova) =====================
-- Reescreve a tabela sem o espaço das linhas apagadas. Trava as vendas por 1 a 2 minutos.
--
--   vacuum (full, analyze) public.bi_venda_det;

-- ===================== PARTE 3 (rode numa consulta nova) =====================
--   set statement_timeout = '15min';
--   create index if not exists bi_venda_det_produto on public.bi_venda_det (produto);
--   create index if not exists bi_venda_det_cliente on public.bi_venda_det (cliente);
--   create index if not exists bi_venda_det_dia on public.bi_venda_det (dia);
--   create index if not exists bi_venda_det_canal_dia on public.bi_venda_det (canal, dia);
--   analyze public.bi_venda_det;
