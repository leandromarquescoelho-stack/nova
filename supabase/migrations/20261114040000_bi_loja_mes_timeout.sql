-- Clientes e notas por mês (Evolução mensal e Loja × mês) passavam do limite de 8 s da API e apareciam como "indisponível".
-- 1) a função ganha limite próprio de 30 s (o PostgREST aplica o statement_timeout definido na função);
-- 2) o resultado fica em cache para qualquer filtro (a chave inclui o filtro e o escopo do usuário; a carga limpa o cache);
-- 3) mais memória para a ordenação não ir para o disco.
create or replace function public.bi_loja_mes(f jsonb)
 returns json language plpgsql volatile security definer set search_path to ''
 set work_mem to '96MB' set statement_timeout to '30s'
as $$
declare w text; res json; ck text;
begin
  w := private.bi_where(coalesce(f, '{}'::jsonb));
  ck := md5(concat_ws('|', 'lojames2', w));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    select coalesce(json_agg(json_build_array(loja, mes, ft, lt, nn, nc, gl)), '[]') from (
      select loja, mes, grouping(loja) gl, sum(fat) ft, sum(lb) lt,
             count(distinct (emitente, nf)) filter (where fat > 0 and nf <> 0) nn,
             count(distinct cliente) filter (where fat > 0) nc
      from public.bi_venda where %s
      group by grouping sets ((loja, mes), (loja), (mes))) g$q$, w)
  into res;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $$;

revoke all on function public.bi_loja_mes(jsonb) from public, anon;
grant execute on function public.bi_loja_mes(jsonb) to authenticated;
