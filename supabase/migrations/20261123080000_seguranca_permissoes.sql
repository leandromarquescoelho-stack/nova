-- Segurança: tira permissões que sobraram e que o site não usa. Nada muda para quem usa o painel.
-- 1) Visitante sem login (anon) não precisa de nenhuma tabela: hoje o RLS já bloqueia, isto tira a permissão de fundo.
revoke all on table public.profiles, public.bi_estoque_hist, public.bi_relatorio_agenda, public.bi_relatorio_envio from anon;

-- 2) Usuário logado: TRUNCATE ignora o RLS; REFERENCES e TRIGGER não têm uso pelo site.
revoke truncate, references, trigger on table public.profiles, public.bi_estoque_hist, public.bi_filtros_salvos,
  public.bi_rede, public.bi_relatorio_agenda, public.bi_relatorio_envio, public.bi_config, public.bi_meta_vendedor from authenticated;
-- bi_estoque_hist e os envios de relatório só são lidos e gravados pelas funções do banco
revoke insert, update, delete on table public.bi_estoque_hist, public.bi_relatorio_agenda, public.bi_relatorio_envio from authenticated;
-- bi_rede é só leitura no site
revoke insert, update, delete on table public.bi_rede from authenticated;

-- 3) pg_net: só as funções do banco (dono postgres) e o agendador chamam a internet; visitante e usuário logado não.
revoke execute on all functions in schema net from anon, authenticated;
revoke usage on schema net from anon;

-- 4) Funções internas não precisam ser executáveis por visitante
revoke execute on function private.bi_aba_liberada(text), private.bi_eh_bi(), private.bi_ia_ids(text, jsonb) from anon;

-- 5) bi_config: usuário comum lê só o que o site usa; o resto (mapa de colunas da planilha, IA etc.) fica para o perfil BI
drop policy if exists bi_config_select on public.bi_config;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'bi_config' and cmd = 'SELECT' loop
    execute format('drop policy %I on public.bi_config', p.policyname);
  end loop;
end $$;
create policy bi_config_select on public.bi_config for select to authenticated
  using (private.bi_usuario_ativo() and (chave in ('projecao_pesos', 'atualizacao', 'ticker', 'carga') or private.bi_eh_bi()));
