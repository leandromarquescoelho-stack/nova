-- Concorrência: histórico diário dos preços coletados (a tabela bi_concorrencia continua com só a última coleta).
-- A rotina passa a rodar todo dia; a aba mostra a variação de cada preço em 7 dias e as últimas mudanças.
create table if not exists public.bi_concorrencia_hist (
  dia date not null,
  site text not null,
  pn text not null,
  preco numeric(12,2),
  disponivel boolean,
  primary key (dia, site, pn)
);
alter table public.bi_concorrencia_hist enable row level security;  -- leitura só pela função abaixo
revoke all on public.bi_concorrencia_hist from anon, authenticated;

-- a coleta que já está no banco vira o primeiro dia do histórico
insert into public.bi_concorrencia_hist (dia, site, pn, preco, disponivel)
select (coletado_em at time zone 'America/Sao_Paulo')::date, site, pn, preco, disponivel from public.bi_concorrencia
on conflict do nothing;

create or replace function public.bi_concorrencia_ler()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso à concorrência'; end if;
  with c as (select id from public.bi_dim where tipo = 'canal' and valor = 'ECOMMERCE'),
  t as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, c
        where v.canal = c.id and v.dia >= (select max(dia) from public.bi_venda_det) - 89 and v.fat > 0
        group by 1 order by 2 desc limit 100),
  -- histórico dos últimos 60 dias: só o primeiro dia e os dias em que o preço mudou
  h as (select dia, site, pn, preco, lag(preco) over (partition by site, pn order by dia) ant,
               row_number() over (partition by site, pn order by dia) n
        from public.bi_concorrencia_hist where dia >= current_date - 60 and preco is not null)
  select json_build_object(
    'itens', coalesce((select json_agg(json_build_array(p.pn, p.nome, t.fat, t.qtd) order by t.fat desc) from t join public.bi_produto p on p.id = t.produto), '[]'),
    'precos', coalesce((select json_agg(json_build_array(site, pn, preco, preco_lista, disponivel, titulo, url, confianca, coletado_em)) from public.bi_concorrencia), '[]'),
    'hist', coalesce((select json_agg(json_build_array(site, pn, dia, preco) order by site, pn, dia) from h where n = 1 or preco is distinct from ant), '[]'),
    'dias', (select count(distinct dia) from public.bi_concorrencia_hist)
  ) into res;
  return res;
end $function$;
