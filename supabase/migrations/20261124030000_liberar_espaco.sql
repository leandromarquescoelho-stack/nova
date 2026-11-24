-- Liberar espaço no banco (plano grátis: 500 MB). Nada muda no que o painel mostra.
--
-- PARTE 1: rode normalmente no SQL Editor.
-- Índice por número de nota (25 MB): só a busca da IA por NF usa (68 vezes em 2 meses); sem ele essa busca fica um pouco mais lenta.
drop index if exists public.bi_venda_det_nf;

-- PARTE 2: rode SOZINHA, numa consulta nova do SQL Editor (o VACUUM não roda junto com outros comandos),
-- de preferência à noite, logo depois de uma carga (a carga roda a cada 30 min, nos minutos :00 e :30).
-- Reescreve a tabela de vendas sem as linhas mortas de cargas antigas. Trava a tabela por 1 a 3 minutos:
-- quem abrir o painel nesse intervalo espera. Se der "canceling statement due to statement timeout", me avise.
--
--   vacuum (full, analyze) public.bi_venda_det;
