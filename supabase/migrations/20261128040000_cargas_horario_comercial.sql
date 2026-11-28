-- Plano Free: o banco só procura planilha nova dentro de um horário (Brasília), escolhido em Configurações > Tempos de atualização:
--   segunda a sexta: das 7h às 20h (padrão)      → agenda 'disparar-carga'
--   sábado:          das 9h às 12h (padrão) ou sem carga → agenda 'disparar-carga-sab'
--   domingo: sem carga. Fora do horário a carga continua possível pelo botão de forçar carga.
-- O pg_cron do Supabase usa UTC: hora de Brasília + 3 (até 20h BRT = 23h UTC, mesmo dia).
create or replace function private.cron_disparo_carga(g int, ini int, fim int, dias text)
 returns text language sql immutable set search_path to ''
as $f$
  select case when g >= 60 then format('0 %s-%s/%s * * %s', ini+3, fim+3, g/60, dias)
              else format('*/%s %s-%s * * %s', g, ini+3, fim+3-1, dias) end
$f$;
revoke all on function private.cron_disparo_carga(int, int, int, text) from public, anon, authenticated;

create or replace function private.agendar_disparo_carga(v jsonb)
 returns void language plpgsql security definer set search_path to ''
as $f$
declare g int := coalesce((v->>'geral')::int, 60);
  si int := coalesce((v->'semana'->>'ini')::int, 7);  sf int := coalesce((v->'semana'->>'fim')::int, 20);
  bi int := (v->'sabado'->>'ini')::int;              bf int := (v->'sabado'->>'fim')::int;
begin
  if not (v ? 'sabado') then bi := 9; bf := 12; end if;   -- ainda sem horário salvo: sábado das 9h às 12h
  perform cron.schedule('disparar-carga', private.cron_disparo_carga(g, si, sf, '1-5'), 'select private.disparar_carga()');
  if bi is null then
    if exists (select 1 from cron.job where jobname = 'disparar-carga-sab') then perform cron.unschedule('disparar-carga-sab'); end if;
  else
    perform cron.schedule('disparar-carga-sab', private.cron_disparo_carga(g, bi, bf, '6'), 'select private.disparar_carga()');
  end if;
end $f$;
revoke all on function private.agendar_disparo_carga(jsonb) from public, anon, authenticated;

create or replace function public.bi_config_atualizacao_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare g int := (p->>'geral')::int; d int := (p->>'dashboard')::int;
  si int := coalesce((p->'semana'->>'ini')::int, 7); sf int := coalesce((p->'semana'->>'fim')::int, 20);
  bi int := (p->'sabado'->>'ini')::int;             bf int := (p->'sabado'->>'fim')::int;
  sab jsonb;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI altera os tempos de atualização';
  end if;
  if g is null or g not in (5, 10, 15, 20, 30, 60, 120, 180, 240, 300) then raise exception 'tempo geral inválido'; end if;
  if d is null or d not in (1, 2, 3, 5, 10, 60, 120, 180, 240, 300) then raise exception 'tempo do dashboard inválido'; end if;
  if si < 0 or sf > 20 or si >= sf then raise exception 'horário de segunda a sexta inválido'; end if;
  if p ? 'sabado' and jsonb_typeof(p->'sabado') = 'null' then sab := 'null'::jsonb;
  elsif bi is null and bf is null then bi := 9; bf := 12; sab := jsonb_build_object('ini', bi, 'fim', bf);
  elsif bi is null or bf is null or bi < 0 or bf > 20 or bi >= bf then raise exception 'horário de sábado inválido';
  else sab := jsonb_build_object('ini', bi, 'fim', bf); end if;
  insert into public.bi_config (chave, valor)
    values ('atualizacao', jsonb_build_object('geral', g, 'dashboard', d, 'semana', jsonb_build_object('ini', si, 'fim', sf),
                                              'sabado', sab, 'por', auth.uid(), 'em', now()))
    on conflict (chave) do update set valor = excluded.valor;
  perform private.agendar_disparo_carga((select valor from public.bi_config where chave = 'atualizacao'));
end $function$;
revoke all on function public.bi_config_atualizacao_gravar(jsonb) from public, anon;
grant execute on function public.bi_config_atualizacao_gravar(jsonb) to authenticated;

-- aplica já ao que está gravado hoje (sem horário salvo: seg a sex 7h–20h, sábado 9h–12h)
select private.agendar_disparo_carga(coalesce((select valor from public.bi_config where chave = 'atualizacao'), '{}'::jsonb));

-- Configurações > Tempos de atualização > "Procurar planilha agora": o perfil BI dispara a procura fora do horário.
-- Só carrega se a planilha do Drive mudou (mesma regra da agenda).
create or replace function public.bi_carga_procurar_agora()
 returns void language plpgsql security definer set search_path to ''
as $f$
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI procura planilha fora do horário';
  end if;
  perform private.disparar_carga();
end $f$;
revoke all on function public.bi_carga_procurar_agora() from public, anon;
grant execute on function public.bi_carga_procurar_agora() to authenticated;
