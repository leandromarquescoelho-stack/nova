-- Fotos dos prêmios sorteados, intercaladas nos quadros do Visual BF2.
-- Só o perfil BI inclui, altera e exclui; todo usuário ativo lê.
-- Liga/desliga e segundos por foto ficam em bi_config 'bf2_fotos' (começa desligado).
create table if not exists public.bi_bf2_foto (
  id         bigint generated always as identity primary key,
  legenda    text not null default '',
  img        text not null,
  ativa      boolean not null default true,
  criado_em  timestamptz not null default now(),
  criado_por uuid default auth.uid()
);
alter table public.bi_bf2_foto enable row level security;
drop policy if exists bi_bf2_foto_select on public.bi_bf2_foto;
create policy bi_bf2_foto_select on public.bi_bf2_foto for select to authenticated using (private.bi_usuario_ativo());
revoke all on public.bi_bf2_foto from anon;
revoke insert, update, delete on public.bi_bf2_foto from authenticated;
grant select on public.bi_bf2_foto to authenticated;

-- incluir (sem id) ou alterar legenda/ativa (com id)
create or replace function public.bi_bf2_foto_gravar(p jsonb)
 returns bigint language plpgsql security definer set search_path to ''
as $function$
declare v_id bigint := nullif(p->>'id','')::bigint; v_img text := p->>'img';
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI altera as fotos do BF2'; end if;
  if v_id is null then
    if v_img is null or v_img !~ '^data:image/(jpeg|png|webp);base64,' then raise exception 'imagem inválida'; end if;
    if length(v_img) > 1500000 then raise exception 'imagem grande demais'; end if;
    insert into public.bi_bf2_foto (legenda, img, ativa)
      values (left(coalesce(p->>'legenda',''), 120), v_img, coalesce((p->>'ativa')::boolean, true))
      returning id into v_id;
  else
    update public.bi_bf2_foto set
      legenda = left(coalesce(p->>'legenda', legenda), 120),
      ativa = coalesce((p->>'ativa')::boolean, ativa)
    where id = v_id;
  end if;
  return v_id;
end $function$;

create or replace function public.bi_bf2_foto_excluir(p_id bigint)
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI altera as fotos do BF2'; end if;
  delete from public.bi_bf2_foto where id = p_id;
end $function$;

create or replace function public.bi_config_bf2_fotos_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI altera as fotos do BF2'; end if;
  insert into public.bi_config (chave, valor)
    values ('bf2_fotos', jsonb_build_object('ativo', coalesce((p->>'ativo')::boolean, false),
                                           'seg', greatest(3, least(60, coalesce((p->>'seg')::int, 8))),
                                           'por', auth.uid(), 'em', now()))
    on conflict (chave) do update set valor = excluded.valor;
end $function$;

revoke all on function public.bi_bf2_foto_gravar(jsonb), public.bi_bf2_foto_excluir(bigint), public.bi_config_bf2_fotos_gravar(jsonb) from public, anon;
grant execute on function public.bi_bf2_foto_gravar(jsonb), public.bi_bf2_foto_excluir(bigint), public.bi_config_bf2_fotos_gravar(jsonb) to authenticated;

-- usuário comum também lê o liga/desliga das fotos
drop policy if exists bi_config_select on public.bi_config;
create policy bi_config_select on public.bi_config for select to authenticated
  using (private.bi_usuario_ativo() and (chave in ('projecao_pesos', 'atualizacao', 'ticker', 'carga', 'bf2_fotos') or private.bi_eh_bi()));
