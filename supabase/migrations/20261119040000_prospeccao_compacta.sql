-- Prospecção compactada: as empresas da Receita passam a ficar num arquivo compactado (gzip) por município,
-- em vez de uma linha por empresa. Ocupa cerca de 1/5 do espaço; o site descompacta no navegador.
-- Depois de rodar: a tabela antiga (bi_prospect, ~83 MB) é apagada e a rotina "Prospecção (Receita)" recarrega tudo.
create table if not exists public.bi_prospect_mun (
  chave text primary key,         -- código IBGE do município; ou 'UF|NOME' quando o nome não bateu com o IBGE
  uf text not null,
  ibge int,
  municipio text,                 -- nome do município como vem da Receita (sem acento, maiúsculo)
  n int not null,                 -- quantidade de empresas
  dados bytea not null            -- JSON compactado: [[cnpj, razao, fantasia, cnae, sec, inicio, endereco, bairro, cep, tel, email, porte, matriz], ...]
);
alter table public.bi_prospect_mun alter column dados set storage external;   -- já vem compactado
create index if not exists bi_prospect_mun_ibge on public.bi_prospect_mun (ibge);
alter table public.bi_prospect_mun enable row level security;
revoke all on public.bi_prospect_mun from anon, authenticated;

-- {ref, em, n, gz:[base64 do JSON compactado, ...]}
create or replace function public.bi_prospeccao(p_ibge int, p_uf text, p_nome text)
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare e record; res json;
begin
  select * into e from private.bi_escopo();
  if not e.ok then raise exception 'sem acesso ao painel'; end if;
  select json_build_object('ref', i.ref, 'em', i.em, 'n', coalesce(m.n, 0), 'gz', coalesce(m.gz, '[]'::json))
  into res
  from (select 1) x
  left join public.bi_prospect_info i on i.id = 1
  left join lateral (
    select sum(p.n) n, json_agg(encode(p.dados, 'base64')) gz
    from public.bi_prospect_mun p
    where p.ibge = p_ibge
       or (p.ibge is null and p.uf = upper(p_uf) and p.municipio = upper(translate(p_nome,
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç', 'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc')))
  ) m on true;
  return res;
end $function$;
revoke all on function public.bi_prospeccao(int, text, text) from public, anon;
grant execute on function public.bi_prospeccao(int, text, text) to authenticated;

drop table if exists public.bi_prospect;
