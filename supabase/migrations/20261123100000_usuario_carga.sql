-- Usuário próprio da carga das planilhas (GitHub Actions), no lugar do postgres.
-- Ele só grava nas tabelas de dados que a carga refaz e chama as funções da carga e do aquecimento do painel.
-- Não vê logins (auth), segredos (vault), agendamentos (cron), perfis completos, envios de relatório nem o que os usuários criam no site.
-- A senha NÃO fica aqui (o repositório é público): depois de rodar este SQL, rode à parte no SQL Editor
--   alter role carga password 'SUA-SENHA-FORTE';
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'carga') then
    create role carga login bypassrls noinherit connection limit 10;
  end if;
end $$;
-- bypassrls: as tabelas têm RLS ligado e sem política para a carga; as permissões abaixo é que limitam o que ela faz
alter role carga set statement_timeout = '15min';
alter role carga set search_path = public;

grant usage on schema public, private to carga;
grant temporary on database postgres to carga;
grant usage, select on all sequences in schema public to carga;

-- tabelas de dados que a carga apaga, grava e confere
grant select, insert, update, delete on table
  public.bi_venda_hist, public.bi_venda_det, public.bi_cliente, public.bi_produto, public.bi_estoque, public.bi_dim,
  public.bi_loja, public.bi_clsf, public.bi_config, public.bi_carga_controle, public.bi_cache,
  public.bi_meta_vend, public.bi_meta_vendedor, public.bi_objetivo,
  public.bi_maratona_cat, public.bi_maratona_cfg, public.bi_maratona_peso,
  public.bi_vendedor_equipe, public.bi_vendedor_loja, public.bi_vendedor_re
  to carga;
grant select on table public.bi_venda to carga;                 -- visão sobre bi_venda_hist + bi_venda_det
grant select (papel, link, ativo) on table public.bi_fonte to carga;  -- links das planilhas, só leitura
grant select (id, role, active) on table public.profiles to carga;    -- aquecimento: só quem está ativo e o perfil

-- funções da carga e as que o aquecimento chama (todas as versões de cada nome)
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p
            where (p.pronamespace = 'private'::regnamespace and p.proname in ('bi_where', 'bi_estoque_foto', 'bi_clientes_atualizar'))
               or (p.pronamespace = 'public'::regnamespace and p.proname in ('bi_painel', 'bi_vendedores', 'bi_produtos', 'bi_meta_leve',
                                                                              'bi_loja_mes', 'bi_kpis', 'bi_hoje'))
  loop
    execute format('grant execute on function %s to carga', r.sig);
  end loop;
end $$;
