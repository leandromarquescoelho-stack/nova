-- Conteúdo de texto do painel que não pode ficar no repositório público (ex.: apresentação do planejamento anual).
-- Fica no banco e só é lido por função, por quem tem acesso a todas as lojas.
create table if not exists public.bi_conteudo (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.bi_conteudo enable row level security;
revoke all on public.bi_conteudo from anon, authenticated;

create or replace function public.bi_conteudo_ler(p_chave text)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $$
declare e record; res jsonb;
begin
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) or not coalesce(e.todas, false) then raise exception 'sem acesso ao planejamento'; end if;
  select c.valor into res from public.bi_conteudo c where c.chave = p_chave;
  return res;
end $$;
revoke all on function public.bi_conteudo_ler(text) from public, anon;
grant execute on function public.bi_conteudo_ler(text) to authenticated;

-- o conteúdo em si é gravado direto no banco (não fica neste repositório)
