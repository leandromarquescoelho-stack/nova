-- GM > Campanhas GM: cadastro de campanhas com filtros próprios, métrica e meta (valor fixo ou base anterior + crescimento)
-- e a consulta de acompanhamento (evolução diária, lojas e produtos).

create table if not exists public.bi_campanha (
  id serial primary key,
  nome text not null,
  descricao text,
  ini date not null,
  fim date not null,
  f jsonb not null default '{}'::jsonb,          -- filtros da campanha (mesmas chaves do painel: marca, linha, categoria, produto…)
  metrica text not null default 'fat' check (metrica in ('fat', 'qtd', 'lb')),
  meta_tipo text not null default 'fixa' check (meta_tipo in ('fixa', 'base')),
  meta_valor numeric,                            -- meta fixa (R$ ou peças)
  base_ini date,                                 -- meta pela base: período comparado
  base_fim date,
  cresc numeric,                                 -- crescimento sobre a base, em %
  ativo boolean not null default true,
  criado_por uuid default auth.uid(),
  atualizado_em timestamptz not null default now(),
  check (fim >= ini)
);
alter table public.bi_campanha enable row level security;
revoke all on public.bi_campanha from anon, authenticated;

create or replace function public.bi_campanhas()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  return coalesce((select json_agg(json_build_object('id', c.id, 'nome', c.nome, 'descricao', c.descricao, 'ini', c.ini, 'fim', c.fim, 'f', c.f,
            'metrica', c.metrica, 'meta_tipo', c.meta_tipo, 'meta_valor', c.meta_valor, 'base_ini', c.base_ini, 'base_fim', c.base_fim,
            'cresc', c.cresc, 'ativo', c.ativo, 'atualizado_em', c.atualizado_em) order by c.ativo desc, c.fim desc, c.id desc)
          from public.bi_campanha c), '[]'::json);
end $function$;

create or replace function public.bi_campanha_gravar(p jsonb)
 returns int language plpgsql security definer set search_path to ''
as $function$
declare v_id int := nullif(p->>'id', '')::int; v_nome text := btrim(coalesce(p->>'nome', ''));
  v_tipo text := coalesce(p->>'meta_tipo', 'fixa'); v_met text := coalesce(p->>'metrica', 'fat');
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria')) then
    raise exception 'só BI e diretoria cadastram campanhas';
  end if;
  if v_nome = '' or length(v_nome) > 120 then raise exception 'informe o nome da campanha'; end if;
  if (p->>'ini') is null or (p->>'fim') is null or (p->>'fim')::date < (p->>'ini')::date then raise exception 'período inválido'; end if;
  if v_tipo = 'fixa' and coalesce((p->>'meta_valor')::numeric, 0) <= 0 then raise exception 'informe a meta'; end if;
  if v_tipo = 'base' and ((p->>'base_ini') is null or (p->>'base_fim') is null or (p->>'base_fim')::date < (p->>'base_ini')::date) then
    raise exception 'informe o período de comparação';
  end if;
  if jsonb_typeof(coalesce(p->'f', '{}'::jsonb)) <> 'object' then raise exception 'filtros inválidos'; end if;
  if v_id is null then
    insert into public.bi_campanha (nome, descricao, ini, fim, f, metrica, meta_tipo, meta_valor, base_ini, base_fim, cresc, ativo)
    values (v_nome, nullif(btrim(coalesce(p->>'descricao', '')), ''), (p->>'ini')::date, (p->>'fim')::date, coalesce(p->'f', '{}'::jsonb), v_met, v_tipo,
            case when v_tipo = 'fixa' then (p->>'meta_valor')::numeric end,
            case when v_tipo = 'base' then (p->>'base_ini')::date end, case when v_tipo = 'base' then (p->>'base_fim')::date end,
            case when v_tipo = 'base' then coalesce((p->>'cresc')::numeric, 0) end, coalesce((p->>'ativo')::boolean, true))
    returning id into v_id;
  else
    update public.bi_campanha set nome = v_nome, descricao = nullif(btrim(coalesce(p->>'descricao', '')), ''), ini = (p->>'ini')::date, fim = (p->>'fim')::date,
      f = coalesce(p->'f', '{}'::jsonb), metrica = v_met, meta_tipo = v_tipo,
      meta_valor = case when v_tipo = 'fixa' then (p->>'meta_valor')::numeric end,
      base_ini = case when v_tipo = 'base' then (p->>'base_ini')::date end, base_fim = case when v_tipo = 'base' then (p->>'base_fim')::date end,
      cresc = case when v_tipo = 'base' then coalesce((p->>'cresc')::numeric, 0) end,
      ativo = coalesce((p->>'ativo')::boolean, true), atualizado_em = now()
    where id = v_id;
    if not found then raise exception 'campanha não encontrada'; end if;
  end if;
  return v_id;
end $function$;

create or replace function public.bi_campanha_excluir(p_id int)
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria')) then
    raise exception 'só BI e diretoria excluem campanhas';
  end if;
  delete from public.bi_campanha where id = p_id;
end $function$;

-- acompanhamento: {ultimo, dias:[[dia, fat, qtd, lb]], base_dias:[[dia, fat, qtd, lb]], base:[fat, qtd, lb],
--   lojas:[[loja, fat, qtd, lb, base_fat, base_qtd, base_lb]], produtos:[[produto, fat, qtd, lb, base_fat, base_qtd, base_lb]]}
-- (valores em centavos; escopo do usuário aplicado pelo bi_where)
create or replace function public.bi_campanha_dados(p_id int)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
declare c public.bi_campanha; w text; ck text; res json; ult date; d2 date; bi date; bf date; o jsonb := '{}'::jsonb; x json;
begin
  select * into c from public.bi_campanha where id = p_id;
  if not found then raise exception 'campanha não encontrada'; end if;
  w := private.bi_where(c.f);
  select max(v.dia) into ult from public.bi_venda v;
  d2 := least(c.fim, ult);
  bi := case when c.meta_tipo = 'base' then c.base_ini end; bf := case when c.meta_tipo = 'base' then c.base_fim end;
  ck := md5(concat_ws('|', 'camp1', p_id, c.atualizado_em, w, ult));
  select k.valor into res from public.bi_cache k where k.chave = ck;
  if found then return res; end if;
  if to_regclass('pg_temp.cp_base') is not null then drop table pg_temp.cp_base; end if;
  execute format('create temp table cp_base on commit drop as
                    select dia, loja, produto, fat, qtd, lb, (dia between $1 and $2) atual, (dia between $3 and $4) base
                      from public.bi_venda where %s and ((dia between $1 and $2) or (dia between $3 and $4))', w)
    using c.ini, d2, coalesce(bi, '1900-01-01'::date), coalesce(bf, '1900-01-01'::date);
  select coalesce(json_agg(json_build_array(dia, f, q, l) order by dia), '[]'::json) into x
    from (select dia, sum(fat) f, sum(qtd) q, sum(lb) l from pg_temp.cp_base where atual group by dia) y;
  o := o || jsonb_build_object('dias', x::jsonb);
  select coalesce(json_agg(json_build_array(dia, f, q, l) order by dia), '[]'::json) into x
    from (select dia, sum(fat) f, sum(qtd) q, sum(lb) l from pg_temp.cp_base where base group by dia) y;
  o := o || jsonb_build_object('base_dias', x::jsonb);
  select json_build_array(coalesce(sum(fat), 0), coalesce(sum(qtd), 0), coalesce(sum(lb), 0)) into x from pg_temp.cp_base where base;
  o := o || jsonb_build_object('base', x::jsonb);
  select coalesce(json_agg(json_build_array(loja, f, q, l, bf_, bq, bl) order by f desc nulls last), '[]'::json) into x
    from (select loja, sum(fat) filter (where atual) f, sum(qtd) filter (where atual) q, sum(lb) filter (where atual) l,
                 sum(fat) filter (where base) bf_, sum(qtd) filter (where base) bq, sum(lb) filter (where base) bl
            from pg_temp.cp_base group by loja) y;
  o := o || jsonb_build_object('lojas', x::jsonb);
  execute format($q$
    select coalesce(json_agg(json_build_array(produto, f, q, l, bf_, bq, bl, nome)), '[]'::json) from (
      select produto, f, q, l, bf_, bq, bl, (select p.pn || ' · ' || coalesce(p.nome, '') from public.bi_produto p where p.id = y.produto) nome from (
        select produto, coalesce(sum(fat) filter (where atual), 0) f, coalesce(sum(qtd) filter (where atual), 0) q, coalesce(sum(lb) filter (where atual), 0) l,
               coalesce(sum(fat) filter (where base), 0) bf_, coalesce(sum(qtd) filter (where base), 0) bq, coalesce(sum(lb) filter (where base), 0) bl
          from pg_temp.cp_base group by produto) y
       order by %s desc limit 40) z$q$, case c.metrica when 'qtd' then 'q' when 'lb' then 'l' else 'f' end) into x;
  o := o || jsonb_build_object('produtos', x::jsonb);
  res := (jsonb_build_object('id', p_id, 'ultimo', ult) || o)::json;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;

revoke all on function public.bi_campanhas() from public, anon;
revoke all on function public.bi_campanha_gravar(jsonb) from public, anon;
revoke all on function public.bi_campanha_excluir(int) from public, anon;
revoke all on function public.bi_campanha_dados(int) from public, anon;
grant execute on function public.bi_campanhas() to authenticated;
grant execute on function public.bi_campanha_gravar(jsonb) to authenticated;
grant execute on function public.bi_campanha_excluir(int) to authenticated;
grant execute on function public.bi_campanha_dados(int) to authenticated;
