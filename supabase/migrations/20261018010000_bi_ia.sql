-- Agente de IA ("Pergunte aos dados"): chave liga/desliga em bi_config e registro de uso para avaliar se vale a pena.
-- A chamada ao modelo fica na Edge Function bi-ia (a chave da API nunca vai para o navegador).

insert into public.bi_config (chave, valor) values ('ia', '{"ativa": false}'::jsonb)
on conflict (chave) do nothing;

-- uma linha por pergunta: quem, quando, tamanho e custo em tokens. Só o perfil BI lê; quem grava é a Edge Function
create table if not exists public.bi_ia_uso (
  id bigserial primary key,
  user_id uuid not null,
  criado_em timestamptz not null default now(),
  pergunta text not null,
  tokens_in integer,
  tokens_out integer,
  cache_lido integer,
  cache_gravado integer,
  ms integer,
  modelo text,
  erro text
);
create index if not exists bi_ia_uso_user_dia on public.bi_ia_uso (user_id, criado_em);
alter table public.bi_ia_uso enable row level security;
revoke all on public.bi_ia_uso from anon, authenticated;
revoke all on sequence public.bi_ia_uso_id_seq from anon, authenticated;

-- liga/desliga o agente; só o perfil BI ativo
create or replace function public.bi_ia_config(ativa boolean)
 returns jsonb language plpgsql volatile security definer set search_path to ''
as $$
declare v jsonb;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role = 'bi') then
    raise exception 'Apenas o perfil BI pode ligar ou desligar o agente de IA' using errcode = '42501';
  end if;
  v := jsonb_build_object('ativa', coalesce(ativa, false), 'por', auth.uid(), 'em', now());
  insert into public.bi_config (chave, valor) values ('ia', v)
  on conflict (chave) do update set valor = excluded.valor;
  return v;
end $$;
revoke all on function public.bi_ia_config(boolean) from public, anon;
grant execute on function public.bi_ia_config(boolean) to authenticated;

-- resumo do uso nos últimos N dias, para o perfil BI decidir se mantém o agente
create or replace function public.bi_ia_uso_resumo(dias integer default 30)
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare res json;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role = 'bi') then
    raise exception 'Apenas o perfil BI pode ver o uso do agente de IA' using errcode = '42501';
  end if;
  select json_build_object(
    'perguntas', count(*) filter (where u.erro is null),
    'erros', count(*) filter (where u.erro is not null),
    'usuarios', count(distinct u.user_id),
    'tokens_in', coalesce(sum(u.tokens_in), 0),
    'tokens_out', coalesce(sum(u.tokens_out), 0),
    'cache_lido', coalesce(sum(u.cache_lido), 0),
    'cache_gravado', coalesce(sum(u.cache_gravado), 0),
    'ultimas', coalesce((select json_agg(json_build_array(x.criado_em, coalesce(p.full_name, p.email), x.pergunta, x.erro) order by x.criado_em desc)
                         from (select * from public.bi_ia_uso where criado_em >= now() - make_interval(days => dias) order by criado_em desc limit 15) x
                         left join public.profiles p on p.id = x.user_id), '[]'::json))
  into res
  from public.bi_ia_uso u
  where u.criado_em >= now() - make_interval(days => dias);
  return res;
end $$;
revoke all on function public.bi_ia_uso_resumo(integer) from public, anon;
grant execute on function public.bi_ia_uso_resumo(integer) to authenticated;
