-- Uso de disco: a foto do estoque do dia (bi_estoque_hist) deixa de ser apagada e regravada inteira a cada carga.
-- Na mesma data, só entram as diferenças: sai o que zerou ou sumiu, muda o que mudou, entra o novo.
create or replace function private.bi_estoque_foto()
 returns integer language plpgsql volatile security definer set search_path to ''
as $function$
declare d date; n integer;
begin
  select max(v.dia) into d from public.bi_venda v;
  if d is null then return 0; end if;
  delete from public.bi_estoque_hist h
   where h.dia = d
     and not exists (select 1 from public.bi_estoque s where s.loja = h.loja and s.produto = h.produto and coalesce(s.est_fis, 0) <> 0);
  update public.bi_estoque_hist h set est_fis = s.est_fis, custo = s.custo
    from public.bi_estoque s
   where h.dia = d and s.loja = h.loja and s.produto = h.produto and coalesce(s.est_fis, 0) <> 0
     and (h.est_fis, h.custo) is distinct from (s.est_fis, s.custo);
  insert into public.bi_estoque_hist (dia, loja, produto, est_fis, custo)
    select d, s.loja, s.produto, s.est_fis, s.custo from public.bi_estoque s where coalesce(s.est_fis, 0) <> 0
    on conflict (dia, loja, produto) do nothing;
  select count(*) into n from public.bi_estoque_hist h where h.dia = d;
  delete from public.bi_estoque_hist h where h.dia < d - 120;
  return n;
end $function$;
revoke all on function private.bi_estoque_foto() from public, anon, authenticated;
