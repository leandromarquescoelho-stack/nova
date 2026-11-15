-- Modo edição do Planejamento: o perfil BI grava a apresentação pelo site. Cada gravação guarda a versão anterior
-- em bi_conteudo_hist (para desfazer, se preciso). E cria a guia 2027 v2 como cópia da 2027.
create table if not exists public.bi_conteudo_hist (
  id bigserial primary key,
  chave text not null,
  valor jsonb,
  gravado_em timestamptz not null default now(),
  gravado_por uuid
);
alter table public.bi_conteudo_hist enable row level security;
revoke all on public.bi_conteudo_hist from anon, authenticated;
revoke all on sequence public.bi_conteudo_hist_id_seq from anon, authenticated;

create or replace function public.bi_conteudo_gravar(p_chave text, p_valor jsonb)
 returns jsonb language plpgsql volatile security definer set search_path to ''
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role = 'bi') then
    raise exception 'Apenas o perfil BI pode editar o planejamento' using errcode = '42501';
  end if;
  if p_chave !~ '^planejamento_[a-z0-9]+$' then raise exception 'chave inválida'; end if;
  if jsonb_typeof(p_valor) <> 'object' or jsonb_typeof(p_valor->'slides') <> 'array' or jsonb_array_length(p_valor->'slides') = 0 then
    raise exception 'apresentação inválida';
  end if;
  if length(p_valor::text) > 500000 then raise exception 'apresentação grande demais'; end if;
  insert into public.bi_conteudo_hist (chave, valor, gravado_por)
    select c.chave, c.valor, auth.uid() from public.bi_conteudo c where c.chave = p_chave;
  insert into public.bi_conteudo (chave, valor, atualizado_em) values (p_chave, p_valor, now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  return jsonb_build_object('ok', true, 'em', now());
end $$;
revoke all on function public.bi_conteudo_gravar(text, jsonb) from public, anon;
grant execute on function public.bi_conteudo_gravar(text, jsonb) to authenticated;

insert into public.bi_conteudo (chave, valor, atualizado_em)
  select 'planejamento_2027v2', jsonb_set(c.valor, '{titulo}', to_jsonb(coalesce(c.valor->>'titulo', 'Planejamento 2027') || ' · v2')), now()
  from public.bi_conteudo c where c.chave = 'planejamento_2027'
on conflict (chave) do nothing;
