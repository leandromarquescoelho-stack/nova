-- guias do painel liberadas por usuário (nulo = todas as guias do papel)
alter table public.profiles add column if not exists abas text[];

-- o próprio usuário não pode alterar as guias liberadas para ele
alter policy profiles_update_own_limited on public.profiles
  with check (
    auth.uid() = id
    and role = (select p.role from public.profiles p where p.id = auth.uid())
    and loja is not distinct from (select p.loja from public.profiles p where p.id = auth.uid())
    and vendedor_nome is not distinct from (select p.vendedor_nome from public.profiles p where p.id = auth.uid())
    and active = (select p.active from public.profiles p where p.id = auth.uid())
    and email = (select p.email from public.profiles p where p.id = auth.uid())
    and abas is not distinct from (select p.abas from public.profiles p where p.id = auth.uid())
  );
