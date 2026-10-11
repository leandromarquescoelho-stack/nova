-- Painel usa só a base linha a linha: remove as tabelas do modelo antigo (aprovado pelo Leandro em 11/10/2026).
-- Metas por vendedor continuam em bi_meta_vendedor; a gerência vê as metas dos vendedores que venderam nas suas lojas.
create table if not exists public.bi_vendedor_loja (vendedor text not null, loja text not null, primary key (vendedor, loja));
alter table public.bi_vendedor_loja enable row level security;
revoke all on public.bi_vendedor_loja from anon, authenticated;
insert into public.bi_vendedor_loja (vendedor, loja)
  select distinct dv.valor, dl.valor from public.bi_venda v
  join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = v.vendedor
  join public.bi_dim dl on dl.tipo = 'loja' and dl.id = v.loja
on conflict do nothing;

create or replace function private.bi_pode_ver_meta(p_vendedor text)
 returns boolean language sql stable security definer set search_path to ''
as $function$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active
      and (
        p.role in ('bi','diretoria')
        or (p.role = 'vendedor' and p.vendedor_nome = p_vendedor)
        or (p.role = 'gerencia' and exists (
              select 1 from public.bi_vendedor_loja b where b.vendedor = p_vendedor
                and (case when coalesce(cardinality(p.lojas), 0) > 0 then b.loja = any(p.lojas) else b.loja = p.loja end)))
      )
  );
$function$;

drop table public.bi_produtos;
drop table public.bi_resumo_mes;
drop table public.bi_peso_diario;
drop function public.bi_painel(jsonb, jsonb);
