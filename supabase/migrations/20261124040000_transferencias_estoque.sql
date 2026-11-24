-- Aba Estoque: sugestões de transferência entre filiais.
-- Só sugere quando faz sentido:
--   quem recebe: vendeu o item em pelo menos 2 dias dos últimos 90 (3 peças ou mais) e o estoque dela cobre menos de 15 dias;
--                pede o que falta para 45 dias de venda.
--   quem cede:   tem estoque parado ou que cobre mais de 120 dias da própria venda; guarda 60 dias para si e cede só a sobra.
-- A venda de cada filial é pela loja que fatura (emitente), então o e-commerce faturado pela filial conta na demanda dela.
-- Perfis com lojas definidas veem as sugestões em que a loja deles cede ou recebe.
create or replace function public.bi_estoque_transferencias(f jsonb default '{}'::jsonb)
 returns json language plpgsql security definer set search_path to '' set work_mem to '48MB'
as $function$
declare e record; res json; ck text; d0 date; ew text[] := array['true']; k text; arr jsonb; ids bigint[]; sc smallint[]; lf smallint[];
begin
  f := coalesce(f, '{}'::jsonb);
  select * into e from private.bi_escopo();
  if not coalesce(e.ok, false) then raise exception 'sem acesso'; end if;
  sc := case when e.todas or e.lojas is null then null else e.lojas end;
  if jsonb_typeof(f->'loja') = 'array' and jsonb_array_length(f->'loja') > 0 then
    select array_agg(x::smallint) into lf from jsonb_array_elements_text(f->'loja') x;
  end if;
  foreach k in array array['linha','marca','categoria','subcategoria','montadora','classificacao','grupo_peca','aplicacao','curva_gm'] loop
    arr := f -> k;
    if jsonb_typeof(arr) = 'array' and jsonb_array_length(arr) > 0 then
      select array_agg(x::bigint) into ids from jsonb_array_elements_text(arr) x;
      ew := ew || format('p.%I = any(%L::smallint[])', k, ids);
    end if;
  end loop;
  if jsonb_typeof(f->'produto') = 'array' and jsonb_array_length(f->'produto') > 0 then
    select array_agg(x::bigint) into ids from jsonb_array_elements_text(f->'produto') x;
    ew := ew || format('p.id = any(%L::int[])', ids);
  end if;
  d0 := (select max(v.dia) from public.bi_venda_det v);
  ck := md5(concat_ws('|', 'transf1', coalesce(sc::text, '*'), coalesce(lf::text, '*'), array_to_string(ew, ' and '), d0));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if found then return res; end if;
  execute format($q$
    with lj as (select d.id loja, m.id emit from public.bi_dim d
                  join public.bi_dim m on m.tipo = 'emitente' and m.valor = d.valor
                 where d.tipo = 'loja' and d.id in (select distinct s.loja from public.bi_estoque s)),
    dem as (select lj.loja, v.produto, sum(v.qtd) q, count(distinct v.dia) filter (where v.qtd > 0) dd
              from public.bi_venda_det v join lj on lj.emit = v.emitente join public.bi_produto p on p.id = v.produto
             where v.dia > $1 - 90 and v.dia <= $1 and %1$s group by 1, 2),
    st as (select s.loja, s.produto, s.est_fis est, coalesce(s.custo_u, s.custo / nullif(s.est_fis, 0)) cu, coalesce(s.parado, false) parado
             from public.bi_estoque s join public.bi_produto p on p.id = s.produto where %1$s),
    b as (select coalesce(st.loja, dem.loja) loja, coalesce(st.produto, dem.produto) produto, greatest(coalesce(st.est, 0), 0) est,
                 st.cu, coalesce(st.parado, false) parado, greatest(coalesce(dem.q, 0), 0) / 90.0 md, coalesce(dem.dd, 0) dd
            from st full join dem on dem.loja = st.loja and dem.produto = st.produto),
    rec as (select loja, produto, est, md, dd, ceil(md * 45 - est) falta from b
             where dd >= 2 and md * 90 >= 3 and est < md * 15 and ceil(md * 45 - est) >= 1),
    doa as (select loja, produto, est, cu, parado, md, floor(est - ceil(md * 60)) sobra from b
             where est > 0 and cu > 0 and floor(est - ceil(md * 60)) >= 1 and (parado or md = 0 or est / md > 120)),
    par as (select r.produto, r.loja para, d.loja de, r.falta, d.sobra, d.cu, d.est est_de, d.md md_de, d.parado, r.est est_para, r.md md_para, r.dd,
                   row_number() over (partition by r.produto, r.loja order by d.sobra desc, d.loja) rk
              from rec r join doa d on d.produto = r.produto and d.loja <> r.loja),
    esc as (select *, sum(falta) over (partition by produto, de order by falta desc, para rows unbounded preceding) - falta antes
              from par where rk = 1),
    q as (select * from (select *, least(falta, sobra - antes) qt from esc where sobra - antes >= 1) z
           where qt * cu >= 150)   -- transferência de valor muito baixo não paga o frete
    select json_build_object('dia', $1, 'n', count(*), 'valor', coalesce(round(sum(qt * cu), 2), 0),
             'itens', coalesce((select json_agg(json_build_array(x.produto, (select pp.pn || ' · ' || coalesce(pp.nome, '') from public.bi_produto pp where pp.id = x.produto),
                                  x.de, x.para, x.qt, round(x.cu, 2), x.est_de, case when x.md_de > 0 then round(x.est_de / x.md_de) end,
                                  x.est_para, round(x.md_para * 90), x.dd, x.parado) order by x.qt * x.cu desc)
                                from (select * from q
                                       where ($2::smallint[] is null or de = any($2) or para = any($2))
                                         and ($3::smallint[] is null or de = any($3) or para = any($3))
                                       order by qt * cu desc limit 150) x), '[]'::json))
      from q where ($2::smallint[] is null or de = any($2) or para = any($2))
               and ($3::smallint[] is null or de = any($3) or para = any($3))$q$, array_to_string(ew, ' and '))
  into res using d0, sc, lf;
  insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
  return res;
end $function$;
revoke all on function public.bi_estoque_transferencias(jsonb) from public, anon;
grant execute on function public.bi_estoque_transferencias(jsonb) to authenticated;
