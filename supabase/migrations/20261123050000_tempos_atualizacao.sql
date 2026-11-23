-- Configurações > Tempos de atualização (só o perfil BI grava):
--   geral     = de quantos em quantos minutos o banco procura planilha nova (agenda "disparar-carga" do pg_cron, que chama
--               a carga no GitHub; sem planilha nova a carga termina sem mexer no banco) e as guias do site conferem
--               se chegou carga nova. Valores: 5, 10, 15, 20, 30 ou 60.
--   dashboard = de quantos em quantos minutos o Dashboard confere se chegou carga nova. Valores: 1, 2, 3, 5 ou 10.
-- bi_config 'atualizacao' = {"geral": 10, "dashboard": 1}
create or replace function public.bi_config_atualizacao_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare g int := (p->>'geral')::int; d int := (p->>'dashboard')::int;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI altera os tempos de atualização';
  end if;
  if g is null or g not in (5, 10, 15, 20, 30, 60) then raise exception 'tempo geral inválido'; end if;
  if d is null or d not in (1, 2, 3, 5, 10) then raise exception 'tempo do dashboard inválido'; end if;
  insert into public.bi_config (chave, valor)
    values ('atualizacao', jsonb_build_object('geral', g, 'dashboard', d, 'por', auth.uid(), 'em', now()))
    on conflict (chave) do update set valor = excluded.valor;
  -- mesma agenda, novo intervalo (cron.schedule com o mesmo nome troca o horário do job existente)
  perform cron.schedule('disparar-carga', case when g = 60 then '0 * * * *' else format('*/%s * * * *', g) end,
                        'select private.disparar_carga()');
end $function$;
revoke all on function public.bi_config_atualizacao_gravar(jsonb) from public, anon;
grant execute on function public.bi_config_atualizacao_gravar(jsonb) to authenticated;

insert into public.bi_config (chave, valor) values ('atualizacao', '{"geral": 10, "dashboard": 1}'::jsonb)
on conflict (chave) do nothing;
