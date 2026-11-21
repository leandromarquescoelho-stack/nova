-- Configurações > Envio automático por e-mail: agendamentos do resumo de Vendas Hoje.
-- Cada agendamento: destinatários, filtros do painel, dias da semana, horários (hora de Brasília), pular feriados e datas de exceção.
-- A cada 5 minutos o pg_cron procura os horários vencidos (até 30 minutos de atraso), registra o envio (sem repetir)
-- e chama a função relatorio-email, que monta o e-mail com os filtros e o acesso de quem criou o agendamento.
-- Só o perfil BI vê e grava. Grava no banco: tabelas novas, um segredo no Vault e um job no pg_cron.

create table if not exists public.bi_relatorio_agenda (
  id bigserial primary key,
  nome text not null,
  para text[] not null,
  filtros jsonb not null default '{}'::jsonb,
  filtros_txt text,
  dias smallint[] not null default '{1,2,3,4,5}',          -- 0 = domingo … 6 = sábado
  horarios text[] not null default '{08:00}',              -- 'HH:MM', hora de Brasília
  pular_feriados boolean not null default true,            -- nacionais, estaduais de SP e municipais da capital
  excecoes date[] not null default '{}',                   -- datas extras sem envio
  ativo boolean not null default true,
  dono uuid not null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now());
alter table public.bi_relatorio_agenda enable row level security;   -- sem políticas: acesso só pelas funções abaixo

create table if not exists public.bi_relatorio_envio (
  agenda_id bigint not null references public.bi_relatorio_agenda (id) on delete cascade,
  slot timestamptz not null,
  status text not null default 'enviando',
  detalhe text,
  em timestamptz not null default now(),
  primary key (agenda_id, slot));
alter table public.bi_relatorio_envio enable row level security;

-- feriados que não recebem envio: nacionais, estaduais de SP e municipais da cidade de São Paulo
create or replace function private.bi_feriado_sp(d date)
 returns boolean language plpgsql immutable set search_path to ''
as $function$
declare y int := extract(year from d); a int; b int; c int; dd int; e int; f int; g int; h int; i int; k int; l int; m int; mes int; dia int; pas date;
begin
  if to_char(d, 'MM-DD') in ('01-01','01-25','04-21','05-01','07-09','09-07','10-12','11-02','11-15','11-20','12-25') then return true; end if;
  a := y % 19; b := y / 100; c := y % 100; dd := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19*a + b - dd - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2*e + 2*i - h - k) % 7; m := (a + 11*h + 22*l) / 451;
  mes := (h + l - 7*m + 114) / 31; dia := ((h + l - 7*m + 114) % 31) + 1;
  pas := make_date(y, mes, dia);
  return d in (pas - 2, pas + 60);   -- Sexta-feira Santa e Corpus Christi
end $function$;

create or replace function private.bi_eh_bi()
 returns boolean language sql stable security definer set search_path to ''
as $$ select exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role = 'bi') $$;

create or replace function public.bi_relatorio_listar()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI vê os envios automáticos'; end if;
  return coalesce((select json_agg(json_build_object('id', a.id, 'nome', a.nome, 'para', a.para, 'filtros', a.filtros, 'filtros_txt', a.filtros_txt,
      'dias', a.dias, 'horarios', a.horarios, 'pular_feriados', a.pular_feriados, 'excecoes', a.excecoes, 'ativo', a.ativo,
      'dono', (select coalesce(p.full_name, p.email) from public.profiles p where p.id = a.dono),
      'ultimos', (select coalesce(json_agg(json_build_object('slot', e.slot, 'status', e.status, 'detalhe', e.detalhe) order by e.slot desc), '[]'::json)
                    from (select * from public.bi_relatorio_envio e2 where e2.agenda_id = a.id order by e2.slot desc limit 5) e))
      order by a.id) from public.bi_relatorio_agenda a), '[]'::json);
end $function$;

create or replace function public.bi_relatorio_gravar(p jsonb)
 returns bigint language plpgsql volatile security definer set search_path to ''
as $function$
declare v_id bigint := nullif(p->>'id', '')::bigint; v_para text[]; v_dias smallint[]; v_hor text[]; v_exc date[];
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI grava os envios automáticos'; end if;
  select coalesce(array_agg(lower(trim(x))), '{}') into v_para from jsonb_array_elements_text(coalesce(p->'para', '[]')) x where trim(x) <> '';
  if cardinality(v_para) = 0 then raise exception 'informe pelo menos um e-mail'; end if;
  if exists (select 1 from unnest(v_para) x where x !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$') then raise exception 'e-mail inválido na lista'; end if;
  select coalesce(array_agg(distinct x::smallint), '{}') into v_dias from jsonb_array_elements_text(coalesce(p->'dias', '[]')) x where x ~ '^[0-6]$';
  if cardinality(v_dias) = 0 then raise exception 'escolha pelo menos um dia da semana'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_hor from jsonb_array_elements_text(coalesce(p->'horarios', '[]')) x where x ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$';
  if cardinality(v_hor) = 0 then raise exception 'informe pelo menos um horário (HH:MM)'; end if;
  select coalesce(array_agg(distinct x::date), '{}') into v_exc from jsonb_array_elements_text(coalesce(p->'excecoes', '[]')) x where x ~ '^\d{4}-\d{2}-\d{2}$';
  if v_id is null then
    insert into public.bi_relatorio_agenda (nome, para, filtros, filtros_txt, dias, horarios, pular_feriados, excecoes, ativo, dono)
      values (coalesce(nullif(trim(p->>'nome'), ''), 'Resumo de vendas'), v_para, coalesce(p->'filtros', '{}'), p->>'filtros_txt', v_dias, v_hor,
              coalesce((p->>'pular_feriados')::boolean, true), v_exc, coalesce((p->>'ativo')::boolean, true), auth.uid())
      returning id into v_id;
  else
    update public.bi_relatorio_agenda set nome = coalesce(nullif(trim(p->>'nome'), ''), nome), para = v_para, filtros = coalesce(p->'filtros', filtros),
           filtros_txt = p->>'filtros_txt', dias = v_dias, horarios = v_hor, pular_feriados = coalesce((p->>'pular_feriados')::boolean, true),
           excecoes = v_exc, ativo = coalesce((p->>'ativo')::boolean, ativo), dono = auth.uid(), atualizado_em = now()
     where id = v_id;
    if not found then raise exception 'agendamento não encontrado'; end if;
  end if;
  return v_id;
end $function$;

create or replace function public.bi_relatorio_excluir(p_id bigint)
 returns void language plpgsql volatile security definer set search_path to ''
as $function$
begin
  if not private.bi_eh_bi() then raise exception 'só o perfil BI exclui os envios automáticos'; end if;
  delete from public.bi_relatorio_agenda where id = p_id;
end $function$;

revoke all on function public.bi_relatorio_listar() from public, anon;
revoke all on function public.bi_relatorio_gravar(jsonb) from public, anon;
revoke all on function public.bi_relatorio_excluir(bigint) from public, anon;
grant execute on function public.bi_relatorio_listar() to authenticated;
grant execute on function public.bi_relatorio_gravar(jsonb) to authenticated;
grant execute on function public.bi_relatorio_excluir(bigint) to authenticated;

-- usada pela função relatorio-email (service role): vendas do dia com o acesso do dono do agendamento
create or replace function public.bi_relatorio_vendas(p_uid uuid, f jsonb)
 returns json language plpgsql volatile security definer set search_path to ''
as $function$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  return public.bi_vendas_hoje(coalesce(f, '{}'::jsonb), null);
end $function$;
revoke all on function public.bi_relatorio_vendas(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.bi_relatorio_vendas(uuid, jsonb) to service_role;

-- confere o segredo que o pg_cron manda para a função (service role)
create or replace function public.bi_relatorio_token_ok(t text)
 returns boolean language sql stable security definer set search_path to ''
as $$ select exists (select 1 from vault.decrypted_secrets s where s.name = 'relatorio_cron_token' and s.decrypted_secret = t) $$;
revoke all on function public.bi_relatorio_token_ok(text) from public, anon, authenticated;
grant execute on function public.bi_relatorio_token_ok(text) to service_role;

do $$ begin
  if not exists (select 1 from vault.secrets where name = 'relatorio_cron_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'relatorio_cron_token', 'pg_cron -> relatorio-email');
  end if;
end $$;

-- a cada 5 minutos: horários vencidos nos últimos 30 minutos, no dia da semana certo, fora de feriados e exceções
create or replace function private.bi_relatorio_disparar()
 returns integer language plpgsql volatile security definer set search_path to ''
as $function$
declare agora timestamp := (now() at time zone 'America/Sao_Paulo'); hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r record; hh text; s timestamptz; tok text; n int := 0;
begin
  select x.decrypted_secret into tok from vault.decrypted_secrets x where x.name = 'relatorio_cron_token';
  if tok is null then return 0; end if;
  for r in select * from public.bi_relatorio_agenda a
            where a.ativo and extract(dow from hoje)::smallint = any(a.dias) and not (hoje = any(a.excecoes))
              and not (a.pular_feriados and private.bi_feriado_sp(hoje)) loop
    foreach hh in array r.horarios loop
      s := (hoje + hh::time) at time zone 'America/Sao_Paulo';
      continue when (hoje + hh::time) > agora or (hoje + hh::time) < agora - interval '30 minutes';
      insert into public.bi_relatorio_envio (agenda_id, slot) values (r.id, s) on conflict do nothing;
      continue when not found;
      perform net.http_post(
        url := 'https://mybwouhzicdlxnapdeul.supabase.co/functions/v1/relatorio-email',
        body := jsonb_build_object('agenda_id', r.id, 'slot', s, 'token', tok),
        headers := jsonb_build_object('Content-Type', 'application/json'),
        timeout_milliseconds := 60000);
      n := n + 1;
    end loop;
  end loop;
  delete from public.bi_relatorio_envio e where e.em < now() - interval '90 days';
  return n;
end $function$;
revoke all on function private.bi_relatorio_disparar() from public, anon, authenticated;

select cron.unschedule('relatorio-email') where exists (select 1 from cron.job where jobname = 'relatorio-email');
select cron.schedule('relatorio-email', '*/5 * * * *', 'select private.bi_relatorio_disparar()');
