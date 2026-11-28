-- Usuários > Excluir: só o perfil BI ativo exclui, e nunca a si mesmo.
-- Apaga o login (auth.users); o perfil e os filtros salvos saem junto (on delete cascade).
create or replace function public.bi_usuario_excluir(p_id uuid)
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI exclui usuários';
  end if;
  if p_id is null or p_id = auth.uid() then raise exception 'não é possível excluir o próprio usuário'; end if;
  delete from auth.users where id = p_id;
  if not found then raise exception 'usuário não encontrado'; end if;
end $function$;
revoke all on function public.bi_usuario_excluir(uuid) from public, anon;
grant execute on function public.bi_usuario_excluir(uuid) to authenticated;
