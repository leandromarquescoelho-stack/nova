-- Prospecção: empresas ativas do ramo (autopeças, oficinas, funilarias...) a partir dos dados abertos de CNPJ da Receita Federal.
-- Preenchida pela rotina "Prospecção (Receita)" do GitHub (etl/receita_prospeccao.py), que só lê os arquivos públicos da Receita.
-- Tabela fechada; o site lê pela função bi_prospeccao (um município por vez).
create table if not exists public.bi_prospect (
  cnpj text primary key,          -- 14 dígitos
  razao text,
  fantasia text,
  cnae int,                       -- CNAE que colocou a empresa na lista (principal; ou secundário, ver sec)
  sec boolean not null default false,  -- true = o ramo vem de uma atividade secundária
  inicio date,                    -- início de atividade
  endereco text,
  bairro text,
  cep text,
  ibge int,                       -- código IBGE do município (null quando o nome não bateu)
  municipio text,                 -- nome do município como vem da Receita
  uf text,
  tel text,
  email text,
  porte smallint,                 -- 1 micro, 3 pequeno porte, 5 demais (Receita); null = não informado
  matriz boolean
);
create index if not exists bi_prospect_ibge on public.bi_prospect (ibge);
create index if not exists bi_prospect_uf_mun on public.bi_prospect (uf, municipio) where ibge is null;
alter table public.bi_prospect enable row level security;
revoke all on public.bi_prospect from anon, authenticated;

create table if not exists public.bi_prospect_info (
  id int primary key default 1 check (id = 1),
  ref text,                       -- mês de referência dos arquivos da Receita (ex.: 2026-11)
  linhas int,
  em timestamptz not null default now()
);
alter table public.bi_prospect_info enable row level security;
revoke all on public.bi_prospect_info from anon, authenticated;

-- {ref, em, linhas:[[cnpj, razao, fantasia, cnae, sec, inicio, endereco, bairro, cep, tel, email, porte, matriz], ...]}
create or replace function public.bi_prospeccao(p_ibge int, p_uf text, p_nome text)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record; res json;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  select json_build_object('ref', i.ref, 'em', i.em, 'linhas', coalesce((
    select json_agg(json_build_array(p.cnpj, p.razao, p.fantasia, p.cnae, p.sec, p.inicio, p.endereco, p.bairro, p.cep, p.tel, p.email, p.porte, p.matriz)
                    order by p.sec, p.razao)
    from public.bi_prospect p
    where p.ibge = p_ibge
       or (p.ibge is null and p.uf = upper(p_uf) and p.municipio = upper(translate(p_nome,
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç', 'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc')))
  ), '[]'::json))
  into res
  from (select 1) x left join public.bi_prospect_info i on i.id = 1;
  return res;
end $function$;
revoke all on function public.bi_prospeccao(int, text, text) from public, anon;
grant execute on function public.bi_prospeccao(int, text, text) to authenticated;
