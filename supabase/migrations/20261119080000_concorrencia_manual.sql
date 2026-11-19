-- Concorrência: produtos adicionados à mão nas guias VTEX e Peça Chevrolet. Ficam fixos no monitoramento (além do top 100)
-- e, ao adicionar, a coleta roda só para o item (workflow "Concorrência", modo item, disparado pelo banco).
create table if not exists public.bi_conc_manual (
  fonte text not null check (fonte in ('vtex', 'pc')),
  pn text not null,
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now(),
  primary key (fonte, pn)
);
alter table public.bi_conc_manual enable row level security;
revoke all on public.bi_conc_manual from anon, authenticated;

-- {acao:'add'|'remover', fonte:'vtex'|'pc', pn} -> {ok, disparado}
create or replace function public.bi_conc_manual_gravar(p jsonb)
 returns json language plpgsql security definer set search_path to ''
as $function$
declare a text := p->>'acao'; f text := p->>'fonte'; c text := upper(btrim(coalesce(p->>'pn', ''))); tok text; disp boolean := false;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso à concorrência'; end if;
  if f not in ('vtex', 'pc') then raise exception 'guia inválida'; end if;
  if c = '' or length(c) > 40 or c !~ '^[A-Z0-9][A-Z0-9 ./_-]*$' then raise exception 'código inválido'; end if;
  if a = 'remover' then
    delete from public.bi_conc_manual where fonte = f and pn = c;
    return json_build_object('ok', true, 'disparado', false);
  end if;
  if a <> 'add' then raise exception 'ação inválida'; end if;
  if (select count(*) from public.bi_conc_manual where fonte = f) >= 200 then raise exception 'limite de 200 produtos manuais por guia'; end if;
  insert into public.bi_conc_manual (fonte, pn) values (f, c) on conflict do nothing;
  -- coleta só deste item (o token do GitHub fica no Vault; sem ele o item entra na coleta diária)
  select s.decrypted_secret into tok from vault.decrypted_secrets s where s.name = 'github_token_carga';
  if coalesce(tok, '') <> '' then
    perform net.http_post(
      url := 'https://api.github.com/repos/leandromarquescoelho-stack/nova/actions/workflows/concorrencia.yml/dispatches',
      body := jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('modo', 'item', 'fonte', f, 'pn', c)),
      headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                    'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'nova-bi-carga'),
      timeout_milliseconds := 10000);
    disp := true;
  end if;
  return json_build_object('ok', true, 'disparado', disp);
end $function$;
revoke all on function public.bi_conc_manual_gravar(jsonb) from public, anon;
grant execute on function public.bi_conc_manual_gravar(jsonb) to authenticated;

-- itens / itens_pc: [pn, nome, fat 90d, qtd 90d, fat da loja, qtd da loja, custo da loja, lucro bruto da loja, manual, top100]
-- o top 100 vem primeiro (por faturamento); os manuais fora do top 100 vêm depois, na ordem em que foram adicionados
create or replace function public.bi_concorrencia_ler()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso à concorrência'; end if;
  with c as (select id from public.bi_dim where tipo = 'canal' and valor = 'ECOMMERCE'),
  l as (select id from public.bi_dim where tipo = 'loja' and valor = 'PEÇA CHEVROLET'),
  lv as (select id from public.bi_dim where tipo = 'loja' and valor = 'VTEX'),
  ult as (select max(dia) - 89 d0 from public.bi_venda_det),
  t as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, c, ult
        where v.canal = c.id and v.dia >= ult.d0 and v.fat > 0
        group by 1 order by 2 desc limit 100),
  tp as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, l, ult
         where v.loja = l.id and v.dia >= ult.d0 and v.fat > 0
         group by 1 order by 2 desc limit 100),
  man as (select m.fonte, m.pn, m.criado_em, p.id produto, p.nome from public.bi_conc_manual m left join public.bi_produto p on p.pn = m.pn),
  -- vendas 90 dias dos manuais fora do top 100 (e-commerce; na guia Peça Chevrolet, a loja PEÇA CHEVROLET)
  tm as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, c, ult
         where v.canal = c.id and v.dia >= ult.d0 and v.fat > 0
           and v.produto in (select produto from man where fonte = 'vtex' and produto not in (select produto from t)) group by 1),
  tmp as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, l, ult
          where v.loja = l.id and v.dia >= ult.d0 and v.fat > 0
            and v.produto in (select produto from man where fonte = 'pc' and produto not in (select produto from tp)) group by 1),
  mv as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd, sum(v.custo) custo, sum(v.lb) lb from public.bi_venda_det v, c, lv, ult
         where v.canal = c.id and v.loja = lv.id and v.dia >= ult.d0 and v.fat > 0
           and v.produto in (select produto from t union select produto from man where fonte = 'vtex') group by 1),
  mp as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd, sum(v.custo) custo, sum(v.lb) lb from public.bi_venda_det v, c, l, ult
         where v.canal = c.id and v.loja = l.id and v.dia >= ult.d0 and v.fat > 0
           and v.produto in (select produto from tp union select produto from man where fonte = 'pc') group by 1),
  iv as (select p.pn, p.nome, t.fat, t.qtd, t.produto, exists (select 1 from man where fonte = 'vtex' and man.produto = t.produto) manual, true top, 0 g, -t.fat::numeric o
           from t join public.bi_produto p on p.id = t.produto
         union all
         select m.pn, m.nome, tm.fat, tm.qtd, m.produto, true, false, 1, extract(epoch from m.criado_em)
           from man m left join tm on tm.produto = m.produto
          where m.fonte = 'vtex' and (m.produto is null or m.produto not in (select produto from t))),
  ip as (select p.pn, p.nome, tp.fat, tp.qtd, tp.produto, exists (select 1 from man where fonte = 'pc' and man.produto = tp.produto) manual, true top, 0 g, -tp.fat::numeric o
           from tp join public.bi_produto p on p.id = tp.produto
         union all
         select m.pn, m.nome, tmp.fat, tmp.qtd, m.produto, true, false, 1, extract(epoch from m.criado_em)
           from man m left join tmp on tmp.produto = m.produto
          where m.fonte = 'pc' and (m.produto is null or m.produto not in (select produto from tp))),
  -- histórico dos últimos 60 dias: só o primeiro dia e os dias em que o preço mudou
  h as (select dia, site, pn, preco, lag(preco) over (partition by site, pn order by dia) ant,
               row_number() over (partition by site, pn order by dia) n
        from public.bi_concorrencia_hist where dia >= current_date - 60 and preco is not null)
  select json_build_object(
    'itens', coalesce((select json_agg(json_build_array(iv.pn, iv.nome, iv.fat, iv.qtd, mv.fat, mv.qtd, mv.custo, mv.lb, iv.manual, iv.top) order by iv.g, iv.o) from iv left join mv on mv.produto = iv.produto), '[]'),
    'itens_pc', coalesce((select json_agg(json_build_array(ip.pn, ip.nome, ip.fat, ip.qtd, mp.fat, mp.qtd, mp.custo, mp.lb, ip.manual, ip.top) order by ip.g, ip.o) from ip left join mp on mp.produto = ip.produto), '[]'),
    'precos', coalesce((select json_agg(json_build_array(site, pn, preco, preco_lista, disponivel, titulo, url, confianca, coletado_em)) from public.bi_concorrencia), '[]'),
    'hist', coalesce((select json_agg(json_build_array(site, pn, dia, preco) order by site, pn, dia) from h where n = 1 or preco is distinct from ant), '[]'),
    'dias', (select count(distinct dia) from public.bi_concorrencia_hist)
  ) into res;
  return res;
end $function$;
