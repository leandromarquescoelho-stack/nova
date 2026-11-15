-- 1) Peso de sábado e domingo na projeção do mês, configurável na tela Dias úteis (só o perfil BI grava).
--    bi_config 'projecao_pesos' = {"modo": "auto" | "manual", "sab": 0..1.5, "dom": 0..1.5}; "auto" usa a venda real dos últimos 12 meses.
create or replace function public.bi_config_projecao_gravar(p jsonb)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare m text := coalesce(p->>'modo', 'auto'); s numeric; d numeric;
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active and pr.role = 'bi') then
    raise exception 'só o perfil BI altera a configuração da projeção';
  end if;
  if m not in ('auto', 'manual') then raise exception 'modo inválido'; end if;
  s := nullif(p->>'sab', '')::numeric; d := nullif(p->>'dom', '')::numeric;
  if m = 'manual' and (s is null or s < 0 or s > 1.5 or (d is not null and (d < 0 or d > 1.5))) then
    raise exception 'pesos devem ficar entre 0 e 1,5';
  end if;
  insert into public.bi_config (chave, valor)
    values ('projecao_pesos', jsonb_build_object('modo', m, 'sab', s, 'dom', d, 'por', auth.uid(), 'em', now()))
    on conflict (chave) do update set valor = excluded.valor;
end $function$;
revoke all on function public.bi_config_projecao_gravar(jsonb) from public, anon;
grant execute on function public.bi_config_projecao_gravar(jsonb) to authenticated;

-- 2) Disparo da carga pelo banco: a cada 10 minutos chama o workflow "Carga planilhas -> Supabase" no GitHub,
--    que só recarrega quando a planilha tem data de modificação nova. O agendamento do GitHub continua como reserva.
--    Precisa do token do GitHub no Vault com o nome 'github_token_carga'; sem ele a função não faz nada.
create extension if not exists pg_net;
create extension if not exists pg_cron;
create or replace function private.disparar_carga()
 returns void language plpgsql security definer set search_path to ''
as $function$
declare tok text;
begin
  select s.decrypted_secret into tok from vault.decrypted_secrets s where s.name = 'github_token_carga';
  if coalesce(tok, '') = '' then return; end if;
  perform net.http_post(
    url := 'https://api.github.com/repos/leandromarquescoelho-stack/nova/actions/workflows/carga-drive.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'nova-bi-carga'),
    timeout_milliseconds := 10000);
end $function$;
revoke all on function private.disparar_carga() from public, anon, authenticated;
select cron.schedule('disparar-carga', '*/10 * * * *', 'select private.disparar_carga()');
