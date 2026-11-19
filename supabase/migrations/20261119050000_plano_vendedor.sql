-- Vendedores: plano de melhoria baseado na média dos pares, com meta, prazo e acompanhamento.
-- Cada linha é um indicador combinado com o vendedor (ex.: margem bruta de 14% para 16% em 60 dias).
-- O site calcula o valor atual com as vendas desde o início do plano (mesmos filtros de quando foi criado).
create table if not exists public.bi_vend_plano (
  id bigint generated always as identity primary key,
  vendedor text not null,              -- nome do vendedor (bi_dim tipo 'vendedor')
  metrica text not null,               -- fat_mes, margem, cli_mes, fat_nota, sku_mes, dias_venda
  base numeric,                        -- valor do vendedor quando o plano foi criado
  pares numeric,                       -- média dos pares naquele momento
  alvo numeric not null,               -- meta combinada
  ini date not null default current_date,
  prazo date not null,
  base_ini date, base_fim date,        -- período usado para calcular a base
  f jsonb not null default '{}'::jsonb,  -- filtros do painel na criação (lojas, canais...)
  obs text,                            -- ações combinadas
  status text not null default 'ativo' check (status in ('ativo', 'encerrado', 'excluido')),
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now(),
  encerrado_em timestamptz,
  check (prazo >= ini)
);
create index if not exists bi_vend_plano_vend on public.bi_vend_plano (vendedor);
alter table public.bi_vend_plano enable row level security;
revoke all on public.bi_vend_plano from anon, authenticated;

-- o vendedor está no escopo de quem pergunta? (BI: todos; diretoria e gerência: quem vende nas lojas/canais do acesso; vendedor: só ele)
create or replace function private.bi_vend_visivel(p_vend text)
 returns boolean language plpgsql stable security definer set search_path to ''
as $function$
declare e record; vid int; ok boolean;
begin
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) then return false; end if;
  if e.todas then return true; end if;
  select d.id into vid from public.bi_dim d where d.tipo = 'vendedor' and d.valor = p_vend;
  if vid is null then return false; end if;
  execute format('select exists (select 1 from public.bi_venda where %s and vendedor = %s)', private.bi_where('{}'::jsonb), vid) into ok;
  return ok;
end $function$;
revoke all on function private.bi_vend_visivel(text) from public;

-- [[id, metrica, base, pares, alvo, ini, prazo, base_ini, base_fim, f, obs, status, criado_em, encerrado_em, criado_por], ...]
create or replace function public.bi_vend_planos(p_vendedor text)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_vend_visivel(p_vendedor) then return '[]'::json; end if;
  select coalesce(json_agg(json_build_array(p.id, p.metrica, p.base, p.pares, p.alvo, p.ini, p.prazo, p.base_ini, p.base_fim, p.f, p.obs,
                                            p.status, p.criado_em, p.encerrado_em, coalesce(nullif(pr.full_name, ''), pr.email))
                           order by p.status, p.prazo, p.id), '[]'::json)
    into res
    from public.bi_vend_plano p left join public.profiles pr on pr.id = p.criado_por
   where p.vendedor = p_vendedor and p.status <> 'excluido';
  return res;
end $function$;
revoke all on function public.bi_vend_planos(text) from public, anon;
grant execute on function public.bi_vend_planos(text) to authenticated;

-- {acao:'criar', vendedor, itens:[{metrica, base, pares, alvo, dias}], f, base_ini, base_fim, obs}
-- {acao:'encerrar'|'excluir'|'reabrir', id}
create or replace function public.bi_vend_plano_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare a text := p->>'acao'; v text; it jsonb; d int;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria', 'gerencia')) then
    raise exception 'só BI, diretoria e gerência criam ou alteram planos';
  end if;
  if a = 'criar' then
    v := p->>'vendedor';
    if not private.bi_vend_visivel(v) then raise exception 'vendedor fora do seu acesso'; end if;
    for it in select * from jsonb_array_elements(coalesce(p->'itens', '[]'::jsonb)) loop
      d := (it->>'dias')::int;
      if it->>'metrica' not in ('fat_mes', 'margem', 'cli_mes', 'fat_nota', 'sku_mes', 'dias_venda') then raise exception 'indicador inválido'; end if;
      if d is null or d < 7 or d > 365 then raise exception 'prazo deve ficar entre 7 e 365 dias'; end if;
      insert into public.bi_vend_plano (vendedor, metrica, base, pares, alvo, prazo, base_ini, base_fim, f, obs)
      values (v, it->>'metrica', (it->>'base')::numeric, (it->>'pares')::numeric, (it->>'alvo')::numeric, current_date + d,
              (p->>'base_ini')::date, (p->>'base_fim')::date, coalesce(p->'f', '{}'::jsonb), nullif(left(p->>'obs', 1000), ''));
    end loop;
  elsif a in ('encerrar', 'excluir', 'reabrir') then
    select pl.vendedor into v from public.bi_vend_plano pl where pl.id = (p->>'id')::bigint;
    if v is null or not private.bi_vend_visivel(v) then raise exception 'plano não encontrado'; end if;
    update public.bi_vend_plano set
      status = case a when 'encerrar' then 'encerrado' when 'excluir' then 'excluido' else 'ativo' end,
      encerrado_em = case when a = 'reabrir' then null else now() end
    where id = (p->>'id')::bigint;
  else
    raise exception 'ação inválida';
  end if;
end $function$;
revoke all on function public.bi_vend_plano_gravar(jsonb) from public, anon;
grant execute on function public.bi_vend_plano_gravar(jsonb) to authenticated;
