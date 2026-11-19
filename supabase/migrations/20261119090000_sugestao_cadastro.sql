-- E-commerce > Sugestão Cadastro: o site pede a pesquisa de um código; o banco dispara o workflow "Sugestão de cadastro"
-- (GitHub Actions, sem IA), que pesquisa em fontes públicas e grava o resultado aqui. Quem pode ver a aba E-commerce (antiga Concorrência) usa.
create table if not exists public.bi_cadastro_sug (
  pn text primary key,
  status text not null default 'pendente' check (status in ('pendente', 'pesquisando', 'ok', 'erro')),
  dados jsonb,
  erro text,
  pedido_por uuid,
  pedido_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.bi_cadastro_sug enable row level security;
revoke all on public.bi_cadastro_sug from anon, authenticated;

-- pede a pesquisa (refaz se já existe) -> {ok, disparado}
create or replace function public.bi_cadastro_pedir(p_pn text)
 returns json language plpgsql security definer set search_path to ''
as $function$
declare c text := upper(regexp_replace(btrim(coalesce(p_pn, '')), '\s+', ' ', 'g')); tok text; disp boolean := false; ult timestamptz;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso ao e-commerce'; end if;
  if c = '' or length(c) > 40 or c !~ '^[A-Z0-9][A-Z0-9 ./_-]*$' then raise exception 'código inválido'; end if;
  select pedido_em into ult from public.bi_cadastro_sug where pn = c and status in ('pendente', 'pesquisando');
  if ult is not null and ult > now() - interval '5 minutes' then
    return json_build_object('ok', true, 'disparado', false, 'andamento', true);   -- já está pesquisando
  end if;
  insert into public.bi_cadastro_sug (pn, status, pedido_por, pedido_em, atualizado_em)
  values (c, 'pendente', auth.uid(), now(), now())
  on conflict (pn) do update set status = 'pendente', pedido_por = auth.uid(), pedido_em = now(), atualizado_em = now();
  select s.decrypted_secret into tok from vault.decrypted_secrets s where s.name = 'github_token_carga';
  if coalesce(tok, '') <> '' then
    perform net.http_post(
      url := 'https://api.github.com/repos/leandromarquescoelho-stack/nova/actions/workflows/cadastro.yml/dispatches',
      body := jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('modo', 'pesquisa', 'pn', c)),
      headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                    'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'nova-bi-carga'),
      timeout_milliseconds := 10000);
    disp := true;
  end if;
  return json_build_object('ok', true, 'disparado', disp);
end $function$;
revoke all on function public.bi_cadastro_pedir(text) from public, anon;
grant execute on function public.bi_cadastro_pedir(text) to authenticated;

-- lê a pesquisa de um código -> {pn, status, dados, erro, pedido_em, atualizado_em} ou null
create or replace function public.bi_cadastro_ler(p_pn text)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare c text := upper(regexp_replace(btrim(coalesce(p_pn, '')), '\s+', ' ', 'g')); res json;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso ao e-commerce'; end if;
  select json_build_object('pn', pn, 'status', status, 'dados', dados, 'erro', erro, 'pedido_em', pedido_em, 'atualizado_em', atualizado_em)
    into res from public.bi_cadastro_sug where pn = c;
  return res;
end $function$;
revoke all on function public.bi_cadastro_ler(text) from public, anon;
grant execute on function public.bi_cadastro_ler(text) to authenticated;

-- últimas pesquisas (para a lista de recentes da tela)
create or replace function public.bi_cadastro_recentes()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso ao e-commerce'; end if;
  select coalesce(json_agg(json_build_object('pn', pn, 'status', status, 'titulo', dados->>'titulo', 'atualizado_em', atualizado_em)
                           order by atualizado_em desc), '[]'::json)
    into res from (select * from public.bi_cadastro_sug order by atualizado_em desc limit 15) t;
  return res;
end $function$;
revoke all on function public.bi_cadastro_recentes() from public, anon;
grant execute on function public.bi_cadastro_recentes() to authenticated;
