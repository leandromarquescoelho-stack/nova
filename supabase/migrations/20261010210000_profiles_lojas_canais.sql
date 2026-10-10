-- lojas e canais liberados por usuário (nulo = todos). BI sempre vê tudo.
-- Gerência sem lista continua limitada à loja do cadastro (profiles.loja).
alter table public.profiles add column if not exists lojas text[];
alter table public.profiles add column if not exists canais text[];

create or replace function private.bi_pode_ver(p_loja text, p_canal text, p_vendedor text)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active
      and (
        p.role = 'bi'
        or (
          (coalesce(cardinality(p.canais), 0) = 0 or p_canal = any(p.canais))
          and (
            (p.role = 'diretoria' and (coalesce(cardinality(p.lojas), 0) = 0 or p_loja = any(p.lojas)))
            or (p.role = 'gerencia' and (
                  case when coalesce(cardinality(p.lojas), 0) > 0 then p_loja = any(p.lojas)
                       else p.loja is not null and p.loja = p_loja end))
            or (p.role = 'vendedor' and p.vendedor_nome is not null and p.vendedor_nome = p_vendedor
                and (coalesce(cardinality(p.lojas), 0) = 0 or p_loja = any(p.lojas)))
          )
        )
      )
  );
$function$;
revoke all on function private.bi_pode_ver(text, text, text) from public;
grant execute on function private.bi_pode_ver(text, text, text) to authenticated;

alter policy bi_produtos_select on public.bi_produtos
  using (private.bi_pode_ver(loja, canal, vendedor));
alter policy bi_resumo_mes_leitura on public.bi_resumo_mes
  using (private.bi_pode_ver(loja, canal, vendedor));

-- metas: gerência vê os vendedores das lojas liberadas
create or replace function private.bi_pode_ver_meta(p_vendedor text)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active
      and (
        p.role in ('bi','diretoria')
        or (p.role = 'vendedor' and p.vendedor_nome = p_vendedor)
        or (p.role = 'gerencia' and exists (
              select 1 from public.bi_produtos b where b.vendedor = p_vendedor
                and (case when coalesce(cardinality(p.lojas), 0) > 0 then b.loja = any(p.lojas) else b.loja = p.loja end)))
      )
  );
$function$;

-- o próprio usuário não pode alterar as lojas e canais liberados para ele
alter policy profiles_update_own_limited on public.profiles
  with check (
    auth.uid() = id
    and role = (select p.role from public.profiles p where p.id = auth.uid())
    and loja is not distinct from (select p.loja from public.profiles p where p.id = auth.uid())
    and vendedor_nome is not distinct from (select p.vendedor_nome from public.profiles p where p.id = auth.uid())
    and active = (select p.active from public.profiles p where p.id = auth.uid())
    and email = (select p.email from public.profiles p where p.id = auth.uid())
    and abas is not distinct from (select p.abas from public.profiles p where p.id = auth.uid())
    and lojas is not distinct from (select p.lojas from public.profiles p where p.id = auth.uid())
    and canais is not distinct from (select p.canais from public.profiles p where p.id = auth.uid())
  );
