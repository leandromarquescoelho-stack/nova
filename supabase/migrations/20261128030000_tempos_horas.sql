-- Configurações > Tempos de atualização: inclui 1 h, 2 h, 3 h, 4 h e 5 h na atualização geral e no Dashboard.
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
  -- mesma agenda, novo intervalo: até 30 min "a cada N minutos"; de 1 h em diante, na virada da hora a cada N horas
  perform cron.schedule('disparar-carga',
    case when g >= 60 then format('0 */%s * * *', g/60) else format('*/%s * * * *', g) end,
    'select private.disparar_carga()');
end $function$;
revoke all on function public.bi_config_atualizacao_gravar(jsonb) from public, anon;
grant execute on function public.bi_config_atualizacao_gravar(jsonb) to authenticated;
