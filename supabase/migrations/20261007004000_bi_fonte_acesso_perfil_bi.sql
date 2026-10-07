-- Tela de links: só o perfil BI ativo lê e altera os links; também vê o histórico das cargas
alter table public.bi_fonte add column if not exists atualizado_por uuid;
create or replace function private.bi_fonte_carimbo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;
revoke execute on function private.bi_fonte_carimbo() from public, anon, authenticated;
create trigger bi_fonte_carimbo before insert or update on public.bi_fonte
  for each row execute function private.bi_fonte_carimbo();

grant select, insert, update, delete on public.bi_fonte to authenticated;
create policy bi_fonte_perfil_bi on public.bi_fonte for all to authenticated
  using (public.current_role_name() = 'bi' and private.bi_usuario_ativo())
  with check (public.current_role_name() = 'bi' and private.bi_usuario_ativo());

grant select on public.bi_carga_controle to authenticated;
create policy bi_carga_controle_perfil_bi on public.bi_carga_controle for select to authenticated
  using (public.current_role_name() = 'bi' and private.bi_usuario_ativo());
