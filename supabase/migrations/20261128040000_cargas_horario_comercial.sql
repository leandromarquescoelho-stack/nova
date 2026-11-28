-- Plano Free: o banco só procura planilha nova das 7h às 20h (horário de Brasília), de segunda a sábado.
-- O pg_cron do Supabase usa UTC: 7h–20h BRT = 10h–23h UTC (mesmo dia, então seg–sáb não muda).
-- Fora desse horário a carga continua possível pelo botão de forçar carga.
create or replace function private.cron_disparo_carga(g int)
 returns text language sql immutable set search_path to ''
as $f$
  select case when g >= 60 then format('0 10-23/%s * * 1-6', g/60)
              else format('*/%s 10-23 * * 1-6', g) end
$f$;
revoke all on function private.cron_disparo_carga(int) from public, anon, authenticated;

create or replace function public.bi_config_atualizacao_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare g int := (p->>'geral')::int; d int := (p->>'dashboard')::int;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI altera os tempos de atualização';
  end if;
  if g is null or g not in (5, 10, 15, 20, 30, 60, 120, 180, 240, 300) then raise exception 'tempo geral inválido'; end if;
  if d is null or d not in (1, 2, 3, 5, 10, 60, 120, 180, 240, 300) then raise exception 'tempo do dashboard inválido'; end if;
  insert into public.bi_config (chave, valor)
    values ('atualizacao', jsonb_build_object('geral', g, 'dashboard', d, 'por', auth.uid(), 'em', now()))
    on conflict (chave) do update set valor = excluded.valor;
  perform cron.schedule('disparar-carga', private.cron_disparo_carga(g), 'select private.disparar_carga()');
end $function$;
revoke all on function public.bi_config_atualizacao_gravar(jsonb) from public, anon;
grant execute on function public.bi_config_atualizacao_gravar(jsonb) to authenticated;

-- aplica já ao intervalo gravado hoje
select cron.schedule('disparar-carga',
  private.cron_disparo_carga(coalesce((select (valor->>'geral')::int from public.bi_config where chave = 'atualizacao'), 60)),
  'select private.disparar_carga()');
