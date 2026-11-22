-- Sino de alertas: metas atingidas (lojas, e-commerce e grupo). Os alertas são montados no site com os dados que cada
-- usuário já vê; aqui fica só o que cada usuário já leu (por chave do alerta), para o contador valer em qualquer aparelho.
create table if not exists public.bi_alerta_lido (
  usuario uuid not null,
  chave text not null,
  lido_em timestamptz not null default now(),
  primary key (usuario, chave)
);
alter table public.bi_alerta_lido enable row level security;
revoke all on public.bi_alerta_lido from anon, authenticated;

-- devolve, entre as chaves informadas, as que o usuário já leu
create or replace function public.bi_alertas_lidos(p_chaves jsonb)
 returns json language sql stable security definer set search_path to ''
as $function$
  select coalesce(json_agg(l.chave), '[]'::json) from public.bi_alerta_lido l
   where l.usuario = auth.uid()
     and l.chave in (select jsonb_array_elements_text(case when jsonb_typeof(p_chaves) = 'array' then p_chaves else '[]'::jsonb end));
$function$;

-- marca as chaves como lidas e apaga leituras com mais de 120 dias
create or replace function public.bi_alertas_marcar(p_chaves jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if auth.uid() is null then raise exception 'sem usuário'; end if;
  if jsonb_typeof(p_chaves) <> 'array' or jsonb_array_length(p_chaves) > 500 then raise exception 'chaves inválidas'; end if;
  insert into public.bi_alerta_lido (usuario, chave)
    select auth.uid(), left(k, 200) from jsonb_array_elements_text(p_chaves) k where coalesce(k, '') <> ''
  on conflict do nothing;
  delete from public.bi_alerta_lido where usuario = auth.uid() and lido_em < now() - interval '120 days';
end $function$;

revoke all on function public.bi_alertas_lidos(jsonb) from public, anon;
revoke all on function public.bi_alertas_marcar(jsonb) from public, anon;
grant execute on function public.bi_alertas_lidos(jsonb) to authenticated;
grant execute on function public.bi_alertas_marcar(jsonb) to authenticated;
