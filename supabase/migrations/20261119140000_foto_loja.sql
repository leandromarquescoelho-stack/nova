-- Aba Preços: foto do produto na nossa loja virtual (loja.chevroletnova.com.br).
-- A loja não libera o navegador a consultar direto (sem CORS), então o banco pede à busca pública da VTEX (pg_net)
-- e guarda o resultado por 7 dias. Só dado público de catálogo (título, link e foto).
create table if not exists public.bi_foto_loja (
  pn text primary key,
  status text not null default 'pendente' check (status in ('pendente', 'ok', 'sem', 'erro')),
  req bigint,
  foto text, link text, titulo text,
  atualizado_em timestamptz not null default now()
);
alter table public.bi_foto_loja enable row level security;
revoke all on public.bi_foto_loja from anon, authenticated;

-- {status: 'pendente'|'ok'|'sem'|'erro', foto, link, titulo}; chamar de novo enquanto 'pendente'
create or replace function public.bi_foto_loja(p_pn text)
 returns json language plpgsql security definer set search_path to ''
as $function$
declare c text := upper(btrim(coalesce(p_pn, ''))); n text; r record; resp record; prod jsonb; rid bigint;
begin
  if not private.bi_aba_liberada('precos') then raise exception 'sem acesso aos preços'; end if;
  if c = '' or length(c) > 40 or c !~ '^[A-Z0-9][A-Z0-9 ./_-]*$' then return json_build_object('status', 'sem'); end if;
  n := regexp_replace(c, '[^A-Z0-9]', '', 'g');
  select * into r from public.bi_foto_loja where pn = c;
  -- resultado guardado e recente
  if found and r.status in ('ok', 'sem') and r.atualizado_em > now() - interval '7 days' then
    return json_build_object('status', r.status, 'foto', r.foto, 'link', r.link, 'titulo', r.titulo);
  end if;
  -- pedido em andamento: vê se a resposta chegou
  if found and r.status = 'pendente' and r.req is not null and r.atualizado_em > now() - interval '1 minute' then
    select h.status_code, h.content, h.timed_out, h.error_msg into resp from net._http_response h where h.id = r.req;
    if not found then return json_build_object('status', 'pendente'); end if;
    if resp.status_code = 200 and resp.content is not null then
      begin
        select p into prod from jsonb_array_elements(resp.content::jsonb) p
         where n = any (select regexp_replace(upper(x), '[^A-Z0-9]', '', 'g') from unnest(string_to_array(coalesce(p->>'productReference', ''), '|')) x)
            or position(n in regexp_replace(upper(coalesce(p->>'productName', '')), '[^A-Z0-9]', '', 'g')) > 0
         limit 1;
      exception when others then prod := null;
      end;
      update public.bi_foto_loja set
        status = case when prod is null then 'sem' else 'ok' end,
        foto = prod #>> '{items,0,images,0,imageUrl}', link = prod->>'link', titulo = prod->>'productName', atualizado_em = now()
       where pn = c;
    else
      update public.bi_foto_loja set status = 'erro', atualizado_em = now() where pn = c;
    end if;
    select * into r from public.bi_foto_loja where pn = c;
    return json_build_object('status', r.status, 'foto', r.foto, 'link', r.link, 'titulo', r.titulo);
  end if;
  -- novo pedido à busca pública da loja
  rid := net.http_get(
    url := 'https://loja.chevroletnova.com.br/api/catalog_system/pub/products/search?ft=' || replace(c, ' ', '%20'),
    headers := jsonb_build_object('User-Agent', 'nova-bi-foto', 'Accept', 'application/json'),
    timeout_milliseconds := 10000);
  insert into public.bi_foto_loja (pn, status, req, atualizado_em) values (c, 'pendente', rid, now())
  on conflict (pn) do update set status = 'pendente', req = rid, atualizado_em = now();
  return json_build_object('status', 'pendente');
end $function$;
revoke all on function public.bi_foto_loja(text) from public, anon;
grant execute on function public.bi_foto_loja(text) to authenticated;
