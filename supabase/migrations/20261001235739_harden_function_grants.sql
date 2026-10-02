-- handle_new_user só deve ser chamada pelo trigger, nunca via API pública
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- current_role_name só precisa ser usada internamente pelas policies (role authenticated),
-- nunca por anônimos
revoke execute on function public.current_role_name() from public, anon;
