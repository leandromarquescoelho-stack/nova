-- Vendas > Vendas Hoje: acompanhamento do dia, do mês e da tendência por loja e canal, com objetivos do mês.
-- Coluna da loja: atacado, oficina e acessórios pela loja; e-commerce pelo emitente (a loja física que fatura).

-- dias do mês até o dia pedido (e os 7 anteriores, para o "ontem" no começo do mês) e o acumulado do ano
-- {dia, linhas:[[dia, loja, emitente, canal, tipo_cliente, fat, lb]], ano:[[loja, emitente, canal, fat, lb]]} (centavos)
create or replace function public.bi_vendas_hoje(f jsonb, dia date)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare w text; res json; ck text; d0 date; ini date; lin json; ano json;
begin
  f := coalesce(f, '{}'::jsonb) - 'produto';
  w := private.bi_where(f);
  d0 := coalesce(dia, (select max(v.dia) from public.bi_venda v));
  ck := md5(concat_ws('|', 'vhoje1', w, d0));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  ini := least(date_trunc('month', d0)::date, d0 - 7);
  execute format($q$
    select coalesce(json_agg(json_build_array(dia, loja, emitente, canal, tipo_cliente, ft, lt)), '[]'::json)
      from (select dia, loja, emitente, canal, tipo_cliente, sum(fat) ft, sum(lb) lt from public.bi_venda
             where %s and dia between $1 and $2 group by 1, 2, 3, 4, 5) x$q$, w)
  into lin using ini, d0;
  execute format($q$
    select coalesce(json_agg(json_build_array(loja, emitente, canal, ft, lt)), '[]'::json)
      from (select loja, emitente, canal, sum(fat) ft, sum(lb) lt from public.bi_venda
             where %s and dia between $1 and $2 group by 1, 2, 3) x$q$, w)
  into ano using date_trunc('year', d0)::date, d0;
  res := json_build_object('dia', d0, 'linhas', lin, 'ano', ano);
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_vendas_hoje(jsonb, date) from public, anon;
grant execute on function public.bi_vendas_hoje(jsonb, date) to authenticated;

-- objetivos do mês: chave = nome da loja (atacado) ou 'ECOMMERCE'
create table if not exists public.bi_objetivo (
  mes date not null,
  chave text not null,
  valor numeric not null check (valor >= 0),
  atualizado_por uuid default auth.uid(),
  atualizado_em timestamptz not null default now(),
  primary key (mes, chave)
);
alter table public.bi_objetivo enable row level security;
revoke all on public.bi_objetivo from anon, authenticated;

-- {chave: valor} do mês
create or replace function public.bi_objetivos(p_mes date)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record; res json;
begin
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) then raise exception 'sem acesso ao painel'; end if;
  select coalesce(json_object_agg(o.chave, o.valor), '{}'::json) into res
    from public.bi_objetivo o where o.mes = date_trunc('month', p_mes)::date;
  return res;
end $function$;
revoke all on function public.bi_objetivos(date) from public, anon;
grant execute on function public.bi_objetivos(date) to authenticated;

-- grava (ou apaga, com valor nulo) o objetivo de uma loja no mês; só BI e diretoria
create or replace function public.bi_objetivo_gravar(p_mes date, p_chave text, p_valor numeric)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare m date := date_trunc('month', p_mes)::date; c text := upper(btrim(coalesce(p_chave, '')));
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria')) then
    raise exception 'só BI e diretoria alteram os objetivos';
  end if;
  if c = '' or length(c) > 60 then raise exception 'loja inválida'; end if;
  if p_valor is null then
    delete from public.bi_objetivo where mes = m and chave = c;
  else
    if p_valor < 0 or p_valor > 1e12 then raise exception 'valor inválido'; end if;
    insert into public.bi_objetivo (mes, chave, valor) values (m, c, p_valor)
    on conflict (mes, chave) do update set valor = excluded.valor, atualizado_por = auth.uid(), atualizado_em = now();
  end if;
end $function$;
revoke all on function public.bi_objetivo_gravar(date, text, numeric) from public, anon;
grant execute on function public.bi_objetivo_gravar(date, text, numeric) to authenticated;
