alter policy "profiles_select_diretoria" on public.profiles
  rename to "profiles_select_bi";
alter policy "profiles_select_bi" on public.profiles
  using (public.current_role_name() = 'bi');

alter policy "profiles_manage_diretoria" on public.profiles
  rename to "profiles_manage_bi";
alter policy "profiles_manage_bi" on public.profiles
  using (public.current_role_name() = 'bi')
  with check (public.current_role_name() = 'bi');
