-- Concorrência: margem pela fórmula da empresa, com PIS, COFINS e ICMS da classificação fiscal do item.
--   PIS = preço × PIS × (1 − ICMS); COFINS = preço × COFINS × (1 − ICMS); ICMS = preço × ICMS
--   lucro bruto = preço − impostos − custo; margem = lucro bruto ÷ preço (truncada em 4 casas)
-- A carga passa a gravar o custo unitário (CUSTO_U) e a classificação fiscal (CLSF) de cada item do estoque,
-- e a aba clsf com as alíquotas.
alter table public.bi_estoque add column if not exists custo_u numeric;   -- custo unitário (vale mesmo sem saldo)
alter table public.bi_estoque add column if not exists clsf text;         -- classificação fiscal (liga às alíquotas)

create table if not exists public.bi_clsf (
  codigo text primary key,        -- fiscal_indicator (ex.: N-73-)
  origem text,
  pis numeric not null default 0,
  cofins numeric not null default 0,
  icms numeric not null default 0,
  ipi numeric not null default 0,
  mva numeric not null default 0
);
alter table public.bi_clsf enable row level security;
revoke all on public.bi_clsf from anon, authenticated;

-- nomes da aba e das colunas no arquivo infobi
update public.bi_config set valor =
  jsonb_set(jsonb_set(valor,
    '{infobi,abas,estoque,colunas}', (valor #> '{infobi,abas,estoque,colunas}') || '{"custo_u":"CUSTO_U","clsf":"CLSF"}'::jsonb),
    '{infobi,abas,clsf}', '{"aba":"clsf","colunas":{"codigo":"fiscal_indicator","origem":"origem","mva":"mva","pis":"pis","cofins":"cofins","icms":"icms","ipi":"ipi"}}'::jsonb)
where chave = 'mapa_colunas';

-- estoque item a item + custo unitário, classificação fiscal e a tabela de alíquotas {codigo: [pis, cofins, icms]}
create or replace function public.bi_estoque_itens()
 returns json language plpgsql stable security definer set search_path to ''
as $$
declare e record;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  return (select json_build_object(
      'loja', coalesce(json_agg(s.loja), '[]'), 'produto', coalesce(json_agg(s.produto), '[]'),
      'est', coalesce(json_agg(s.est_fis), '[]'), 'custo', coalesce(json_agg(s.custo), '[]'),
      'vend', coalesce(json_agg(s.dt_ult_vend), '[]'), 'comp', coalesce(json_agg(s.dt_ult_comp), '[]'),
      'parado', coalesce(json_agg(s.parado), '[]'),
      'custo_u', coalesce(json_agg(s.custo_u), '[]'), 'clsf', coalesce(json_agg(s.clsf), '[]'),
      'impostos', (select coalesce(json_object_agg(c.codigo, json_build_array(c.pis, c.cofins, c.icms)), '{}'::json) from public.bi_clsf c))
    from public.bi_estoque s
    where e.todas or e.lojas is null or s.loja = any(e.lojas));
end $$;
