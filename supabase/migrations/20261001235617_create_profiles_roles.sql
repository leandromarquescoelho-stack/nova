-- Tipo de papel de acesso
create type public.user_role as enum ('diretoria', 'gerencia', 'vendedor');

-- Perfis de usuário, 1:1 com auth.users
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  role public.user_role not null default 'vendedor',
  vendedor_nome text,       -- nome do vendedor como aparece nos dados (para filtrar "meus números")
  loja text,                -- opcional: restringir a uma loja/região específica
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Perfis de acesso dos usuários do Nova Chevrolet BI';
comment on column public.profiles.vendedor_nome is 'Deve corresponder exatamente ao campo "vendedor" usado nos dados do dashboard, para que o papel vendedor veja apenas seus próprios números';

alter table public.profiles enable row level security;

-- Função helper (security definer) para checar o papel do usuário logado sem recursão de RLS
create or replace function public.current_role_name()
returns public.user_role
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Qualquer usuário autenticado pode ler o próprio perfil
create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

-- Diretoria pode ler todos os perfis (gestão de usuários)
create policy "profiles_select_diretoria"
  on public.profiles for select
  using (public.current_role_name() = 'diretoria');

-- Apenas diretoria pode criar/editar/excluir perfis de outros usuários
create policy "profiles_manage_diretoria"
  on public.profiles for all
  using (public.current_role_name() = 'diretoria')
  with check (public.current_role_name() = 'diretoria');

-- Usuário pode atualizar alguns campos do próprio perfil (ex: full_name), mas não o próprio role
create policy "profiles_update_own_limited"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id and role = (select role from public.profiles where id = auth.uid()));

-- Ao criar um usuário no Auth, cria automaticamente um profile (role padrão: vendedor, inativo até a diretoria liberar)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, role, active)
  values (new.id, new.email, 'vendedor', false);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
