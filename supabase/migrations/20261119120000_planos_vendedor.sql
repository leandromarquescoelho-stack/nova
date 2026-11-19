-- Vendedores: cada plano de melhoria vira um plano único (agrupa os indicadores criados juntos),
-- com status Em andamento / Finalizado e no máximo 1 plano em andamento por vendedor no mesmo período.
-- Nova lista de todos os planos (aba Vendedores > Planos em andamento).
alter table public.bi_vend_plano add column if not exists plano bigint;
update public.bi_vend_plano p set plano = g.pid
  from (select vendedor, criado_em, min(id) pid from public.bi_vend_plano group by 1, 2) g
 where p.plano is null and p.vendedor = g.vendedor and p.criado_em = g.criado_em;
create index if not exists bi_vend_plano_plano on public.bi_vend_plano (plano);

-- [[id, metrica, base, pares, alvo, ini, prazo, base_ini, base_fim, f, obs, status, criado_em, encerrado_em, criado_por, plano], ...]
create or replace function public.bi_vend_planos(p_vendedor text)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_vend_visivel(p_vendedor) then return '[]'::json; end if;
  select coalesce(json_agg(json_build_array(p.id, p.metrica, p.base, p.pares, p.alvo, p.ini, p.prazo, p.base_ini, p.base_fim, p.f, p.obs,
                                            p.status, p.criado_em, p.encerrado_em, coalesce(nullif(pr.full_name, ''), pr.email), coalesce(p.plano, p.id))
                           order by coalesce(p.plano, p.id) desc, p.id), '[]'::json)
    into res
    from public.bi_vend_plano p left join public.profiles pr on pr.id = p.criado_por
   where p.vendedor = p_vendedor and p.status <> 'excluido';
  return res;
end $function$;
revoke all on function public.bi_vend_planos(text) from public, anon;
grant execute on function public.bi_vend_planos(text) to authenticated;

-- todos os planos dos vendedores visíveis para quem pergunta: as mesmas colunas + vendedor no fim
create or replace function public.bi_vend_planos_todos()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  with vis as (select v.vendedor from (select distinct vendedor from public.bi_vend_plano where status <> 'excluido') v
                where private.bi_vend_visivel(v.vendedor))
  select coalesce(json_agg(json_build_array(p.id, p.metrica, p.base, p.pares, p.alvo, p.ini, p.prazo, p.base_ini, p.base_fim, p.f, p.obs,
                                            p.status, p.criado_em, p.encerrado_em, coalesce(nullif(pr.full_name, ''), pr.email), coalesce(p.plano, p.id), p.vendedor)
                           order by coalesce(p.plano, p.id) desc, p.id), '[]'::json)
    into res
    from public.bi_vend_plano p join vis on vis.vendedor = p.vendedor
    left join public.profiles pr on pr.id = p.criado_por
   where p.status <> 'excluido';
  return res;
end $function$;
revoke all on function public.bi_vend_planos_todos() from public, anon;
grant execute on function public.bi_vend_planos_todos() to authenticated;

-- {acao:'criar', vendedor, itens:[{metrica, base, pares, alvo, dias}], f, base_ini, base_fim, obs} -> id do plano
-- {acao:'encerrar'|'excluir'|'reabrir', plano} (ou id de um indicador: vale para o plano inteiro)
drop function if exists public.bi_vend_plano_gravar(jsonb);  -- o retorno mudou de void para o id do plano
create function public.bi_vend_plano_gravar(p jsonb)
 returns bigint language plpgsql security definer set search_path to ''
as $function$
declare a text := p->>'acao'; v text; it jsonb; d int; pid bigint; nid bigint; ate date;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role in ('bi', 'diretoria', 'gerencia')) then
    raise exception 'só BI, diretoria e gerência criam ou alteram planos';
  end if;
  if a = 'criar' then
    v := p->>'vendedor';
    if not private.bi_vend_visivel(v) then raise exception 'vendedor fora do seu acesso'; end if;
    if jsonb_array_length(coalesce(p->'itens', '[]'::jsonb)) = 0 then raise exception 'marque ao menos um indicador'; end if;
    perform pg_advisory_xact_lock(hashtext('bi_vend_plano:' || v));
    -- 1 plano em andamento por vendedor por período: o novo começa hoje, então não pode haver outro ativo com prazo a partir de hoje
    select max(pl.prazo) into ate from public.bi_vend_plano pl
     where pl.vendedor = v and pl.status = 'ativo' and pl.prazo >= current_date;
    if ate is not null then
      raise exception 'já existe um plano em andamento para % até %; finalize-o antes de criar outro', v, to_char(ate, 'DD/MM/YYYY');
    end if;
    for it in select * from jsonb_array_elements(p->'itens') loop
      d := (it->>'dias')::int;
      if it->>'metrica' not in ('fat_mes', 'margem', 'cli_mes', 'fat_nota', 'sku_mes', 'dias_venda') then raise exception 'indicador inválido'; end if;
      if d is null or d < 7 or d > 365 then raise exception 'prazo deve ficar entre 7 e 365 dias'; end if;
      insert into public.bi_vend_plano (vendedor, metrica, base, pares, alvo, prazo, base_ini, base_fim, f, obs, plano)
      values (v, it->>'metrica', (it->>'base')::numeric, (it->>'pares')::numeric, (it->>'alvo')::numeric, current_date + d,
              (p->>'base_ini')::date, (p->>'base_fim')::date, coalesce(p->'f', '{}'::jsonb), nullif(left(p->>'obs', 1000), ''), pid)
      returning id into nid;
      if pid is null then pid := nid; update public.bi_vend_plano set plano = pid where id = nid; end if;
    end loop;
    return pid;
  elsif a in ('encerrar', 'excluir', 'reabrir') then
    pid := coalesce((p->>'plano')::bigint, (select coalesce(pl.plano, pl.id) from public.bi_vend_plano pl where pl.id = (p->>'id')::bigint));
    select pl.vendedor, max(pl.prazo) into v, ate from public.bi_vend_plano pl
     where coalesce(pl.plano, pl.id) = pid and pl.status <> 'excluido' group by pl.vendedor;
    if v is null or not private.bi_vend_visivel(v) then raise exception 'plano não encontrado'; end if;
    if a = 'reabrir' then
      if ate < current_date then raise exception 'o prazo deste plano já passou; crie um plano novo'; end if;
      perform pg_advisory_xact_lock(hashtext('bi_vend_plano:' || v));
      if exists (select 1 from public.bi_vend_plano pl where pl.vendedor = v and coalesce(pl.plano, pl.id) <> pid
                   and pl.status = 'ativo' and pl.prazo >= current_date) then
        raise exception 'já existe outro plano em andamento para %', v;
      end if;
    end if;
    update public.bi_vend_plano set
      status = case a when 'encerrar' then 'encerrado' when 'excluir' then 'excluido' else 'ativo' end,
      encerrado_em = case when a = 'reabrir' then null else now() end
    where coalesce(plano, id) = pid and status <> 'excluido';
    return pid;
  else
    raise exception 'ação inválida';
  end if;
end $function$;
revoke all on function public.bi_vend_plano_gravar(jsonb) from public, anon;
grant execute on function public.bi_vend_plano_gravar(jsonb) to authenticated;
