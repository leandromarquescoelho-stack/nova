-- Arquivamento passa a manter só 3 meses fechados linha a linha (antes 4). Os meses mais antigos continuam no painel
-- pela tabela de histórico (mesmo detalhe por dia, produto, cliente e vendedor), só sem o número da NF.
-- Rode depois de uma carga terminar. Pode levar alguns minutos.

-- 1) agenda mensal (todo dia 2, 04:15) com 3 meses
select cron.unschedule('arquivar-vendas') where exists (select 1 from cron.job where jobname = 'arquivar-vendas');
select cron.schedule('arquivar-vendas', '15 7 2 * *', $c$set statement_timeout = '15min'; select private.bi_arquivar_vendas(3)$c$);

-- 2) arquiva agora o mês que passou do novo limite
set statement_timeout = '15min';
select private.bi_arquivar_vendas(3);
