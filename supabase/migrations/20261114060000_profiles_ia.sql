-- Acesso ao agente de IA por usuário: o perfil BI libera no cadastro de cada pessoa (o perfil BI sempre tem acesso).
-- A chave geral em bi_config ('ia') continua valendo: desligada, ninguém usa.
alter table public.profiles add column if not exists ia boolean not null default false;

-- o próprio usuário não pode liberar a IA para si
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
    and equipes is not distinct from (select p.equipes from public.profiles p where p.id = auth.uid())
    and ia = (select p.ia from public.profiles p where p.id = auth.uid())
  );
