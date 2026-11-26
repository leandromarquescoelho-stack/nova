-- Códigos das lojas (bi_loja) para o CSV de compra da guia Estoque > Produtos.
-- bi_loja continua fechada para o navegador; esta função devolve só nome e código.
create or replace function public.bi_loja_codigos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_array(l.nome, l.codigo) order by l.nome), '[]'::jsonb)
  from public.bi_loja l
  where auth.uid() is not null;
$$;

revoke all on function public.bi_loja_codigos() from public, anon;
grant execute on function public.bi_loja_codigos() to authenticated;
