-- Equipes de venda: cada vendedor da aba "vendedores" tem a sua equipe (gravada pela carga em bi_vendedor_equipe).
-- profiles.equipes limita o usuário aos vendedores dessas equipes (nulo = todas). BI sempre vê tudo.

create table if not exists public.bi_vendedor_equipe (
  vendedor text primary key,
  equipe text not null
);
alter table public.bi_vendedor_equipe enable row level security;
revoke all on public.bi_vendedor_equipe from anon, authenticated;

alter table public.profiles add column if not exists equipes text[];

-- lista de equipes para a tela de usuários
create or replace function public.bi_equipes()
 returns json language sql stable security definer set search_path to ''
as $$ select coalesce(json_agg(e order by e), '[]') from (select distinct equipe e from public.bi_vendedor_equipe) x $$;
revoke all on function public.bi_equipes() from public, anon;
grant execute on function public.bi_equipes() to authenticated;

-- o próprio usuário não pode alterar as equipes liberadas para ele
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
  );

-- bi_where: igual à versão anterior, mais o limite de equipes
create or replace function private.bi_where(f jsonb, ignorar text default null::text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare e record; w text[] := array['true']; k text; arr jsonb; ids bigint[]; sem jsonb; eq text[];
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  if not e.todas then
    if e.lojas is not null then w := w || format('loja = any(%L::smallint[])', e.lojas); end if;
    if e.canais is not null then w := w || format('canal = any(%L::smallint[])', e.canais); end if;
    if e.vendedor is not null then w := w || format('vendedor = %s', e.vendedor); end if;
    select p.equipes into eq from public.profiles p where p.id = auth.uid();
    if coalesce(cardinality(eq), 0) > 0 then
      w := w || format('vendedor = any(%L::smallint[])', coalesce((select array_agg(d.id) from public.bi_dim d
             join public.bi_vendedor_equipe ve on ve.vendedor = d.valor where d.tipo = 'vendedor' and ve.equipe = any(eq)), '{}'));
    end if;
  end if;
  foreach k in array array['loja','canal','emitente','origem','vendedor','linha','marca','categoria','subcategoria','montadora',
                           'classificacao','tipo_cliente','cidade','produto','cliente','nf'] loop
    continue when k = ignorar;
    arr := f -> k;
    if arr is not null and jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      w := w || format('%I = any(%L::%s[])', k, ids, case when k in ('produto','cliente','nf') then 'int' else 'smallint' end);
    end if;
  end loop;
  sem := f -> 'semana';
  if coalesce(ignorar, '') <> 'semana' and sem is not null and jsonb_typeof(sem) = 'array' then
    if sem @> '["fds"]' and not sem @> '["util"]' then w := w || 'extract(isodow from dia) >= 6'::text;
    elsif sem @> '["util"]' and not sem @> '["fds"]' then w := w || 'extract(isodow from dia) < 6'::text;
    end if;
  end if;
  return array_to_string(w, ' and ');
end $function$;
