-- Mini painel "Saúde do banco" em Configurações (só perfil BI). Uma consulta leve, só quando o painel é aberto.
-- Egress e Disk IO Budget oficiais só aparecem no painel do Supabase; aqui vão os indicadores que o próprio banco informa.
create or replace function public.bi_saude_banco()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare r jsonb; v_top jsonb := '[]'::jsonb; v_fotos jsonb;
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI vê a saúde do banco'; end if;
  select jsonb_build_object(
    'db_bytes', pg_database_size(current_database()),
    'limite_bytes', 500*1024*1024,
    'tabelas', (select coalesce(jsonb_agg(t order by t.b desc), '[]'::jsonb) from (
        select c.relname as nome, pg_total_relation_size(c.oid) as b, c.reltuples::bigint as linhas
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
        order by pg_total_relation_size(c.oid) desc limit 8) t),
    'cache_hit', (select round(100.0*sum(blks_hit)/nullif(sum(blks_hit)+sum(blks_read),0), 2) from pg_stat_database where datname = current_database()),
    'blks_read', (select blks_read from pg_stat_database where datname = current_database()),
    'linhas_lidas', (select tup_returned + tup_fetched from pg_stat_database where datname = current_database()),
    'stats_desde', (select stats_reset from pg_stat_database where datname = current_database()),
    'conexoes', (select count(*) from pg_stat_activity where datname = current_database()),
    'fotos_bf2', jsonb_build_object('n', 0, 'bytes', 0),
    'agora', now()
  ) into r;
  -- consultas que mais devolvem linhas (indicador de Egress), se pg_stat_statements estiver ligado
  begin
    execute $q$select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select left(regexp_replace(query, '\s+', ' ', 'g'), 90) as q, calls, rows, round(total_exec_time)::bigint as ms
      from extensions.pg_stat_statements s join pg_database d on d.oid = s.dbid
      where d.datname = current_database() and query ~* 'public\.bi_|from "?bi_'
      order by rows desc limit 6) x$q$ into v_top;
  exception when others then v_top := null;
  end;
  -- fotos do BF2 só se a tabela existir (o SQL das fotos é opcional)
  if to_regclass('public.bi_bf2_foto') is not null then
    execute 'select jsonb_build_object(''n'', count(*), ''bytes'', coalesce(sum(length(img)),0)) from public.bi_bf2_foto' into v_fotos;
    r := r || jsonb_build_object('fotos_bf2', v_fotos);
  end if;
  return r || jsonb_build_object('top', v_top);
end $function$;
revoke all on function public.bi_saude_banco() from public, anon;
grant execute on function public.bi_saude_banco() to authenticated;
