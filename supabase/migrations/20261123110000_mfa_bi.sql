-- Verificação em duas etapas (MFA) obrigatória para o perfil BI.
-- O site pede o código do aplicativo autenticador; aqui o banco garante que, sem a sessão verificada (aal2),
-- o perfil BI não lê nem altera nada, mesmo que alguém com a senha tente chamar o banco direto.
-- Os outros perfis não mudam.

-- 1) regra: quem não é BI passa; o BI só passa com a sessão verificada
create or replace function private.bi_mfa_ok()
 returns boolean language sql stable security definer set search_path to ''
as $$
  select coalesce((select pf.role::text from public.profiles pf where pf.id = auth.uid()), '') <> 'bi'
      or coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;
revoke all on function private.bi_mfa_ok() from public, anon;
grant execute on function private.bi_mfa_ok() to authenticated, carga;

-- 2) toda função que confere o perfil do usuário logado ("from public.profiles X where X.id = auth.uid()")
--    passa a conferir também a regra acima. Rodar de novo não duplica.
do $$
declare r record; d text; n text;
begin
  for r in select p.oid from pg_proc p
            where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
              and p.proname <> 'bi_mfa_ok'
              and p.prosrc ~ 'from public\.profiles (\w+)\s+where \1\.id = auth\.uid\(\)(?! and private\.bi_mfa_ok\(\))'
  loop
    d := pg_get_functiondef(r.oid);
    n := regexp_replace(d, '(from public\.profiles (\w+)\s+where \2\.id = auth\.uid\(\))(?! and private\.bi_mfa_ok\(\))',
                        '\1 and private.bi_mfa_ok()', 'g');
    if n <> d then execute n; end if;
  end loop;
end $$;

-- 3) escopo dos dados (leitura de tudo o que o painel mostra)
do $$
declare d text;
begin
  d := pg_get_functiondef('private.bi_escopo()'::regprocedure);
  if position('bi_mfa_ok' in d) = 0 then
    d := replace(d, 'from public.profiles where id = auth.uid() and active;', 'from public.profiles where id = auth.uid() and active and private.bi_mfa_ok();');
    if position('bi_mfa_ok' in d) = 0 then raise exception 'bi_escopo: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

-- 4) perfil usado nas regras de acesso das tabelas (usuários, fontes, controle de carga)
create or replace function public.current_role_name()
 returns user_role language sql stable security definer set search_path to 'public'
as $$
  select role from public.profiles where id = auth.uid() and private.bi_mfa_ok();
$$;

-- 5) envio automático de relatório: roda pelo servidor em nome do dono, que já se verificou ao agendar
do $$
declare d text;
begin
  d := pg_get_functiondef('public.bi_relatorio_vendas(uuid, jsonb)'::regprocedure);
  if position('''aal''' in d) = 0 then
    d := replace(d, 'json_build_object(''sub'', p_uid, ''role'', ''authenticated'')', 'json_build_object(''sub'', p_uid, ''role'', ''authenticated'', ''aal'', ''aal2'')');
    if position('''aal''' in d) = 0 then raise exception 'bi_relatorio_vendas: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;
