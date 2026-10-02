create or replace function private.bi_pode_ver(p_loja text, p_vendedor text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active
      and (
        p.role in ('bi','diretoria')
        or (p.role = 'gerencia' and p.loja is not null and p.loja = p_loja)
        or (p.role = 'vendedor' and p.vendedor_nome is not null and p.vendedor_nome = p_vendedor)
      )
  );
$$;

create or replace function private.bi_usuario_ativo()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.active);
$$;

create or replace function private.bi_pode_ver_meta(p_vendedor text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active
      and (
        p.role in ('bi','diretoria')
        or (p.role = 'vendedor' and p.vendedor_nome = p_vendedor)
        or (p.role = 'gerencia' and exists (
              select 1 from public.bi_produtos b where b.vendedor = p_vendedor and b.loja = p.loja))
      )
  );
$$;

revoke all on function private.bi_pode_ver(text,text), private.bi_usuario_ativo(), private.bi_pode_ver_meta(text) from public, anon;
grant execute on function private.bi_pode_ver(text,text), private.bi_usuario_ativo(), private.bi_pode_ver_meta(text) to authenticated;

create policy bi_produtos_select on public.bi_produtos for select to authenticated
  using (private.bi_pode_ver(loja, vendedor));
create policy bi_peso_diario_select on public.bi_peso_diario for select to authenticated
  using (private.bi_usuario_ativo());
create policy bi_meta_vendedor_select on public.bi_meta_vendedor for select to authenticated
  using (private.bi_pode_ver_meta(vendedor));
create policy bi_config_select on public.bi_config for select to authenticated
  using (private.bi_usuario_ativo());
