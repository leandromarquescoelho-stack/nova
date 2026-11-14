-- 1) Vendedor: comparativo com os pares, configurado no cadastro (perfil BI).
--    pares_modo nulo = desligado; 'grupo' = todos os vendedores do escopo; 'equipe' = só as equipes de pares_equipes.
--    Os outros vendedores voltam com id negativo (Par 1, Par 2… por faturamento): o vendedor não vê nomes.
-- 2) Guias Concorrência e Planejamento liberáveis por usuário (antes só o perfil BI).
alter table public.profiles add column if not exists pares_modo text check (pares_modo in ('grupo', 'equipe'));
alter table public.profiles add column if not exists pares_equipes text[];

alter policy profiles_update_own_limited on public.profiles
  with check (
    auth.uid() = id
    and role = (select p.role from public.profiles p where p.id = auth.uid())
    and loja is not distinct from (select p.loja from public.profiles p where p.id = auth.uid())
    and vendedor_nome is not distinct from (select p.vendedor_nome from public.profiles p where p.id = auth.uid())
    and active = (select p.active from public.profiles p where p.id = auth.uid())
    and email = (select p.email from public.profiles p where p.id = auth.uid())
    and abas is not distinct from (select p.abas from public.profiles p where p.id = auth.uid())
    and lojas is not distinct from (select p.lojas from public.profiles p where p.id = auth.uid())
    and canais is not distinct from (select p.canais from public.profiles p where p.id = auth.uid())
    and equipes is not distinct from (select p.equipes from public.profiles p where p.id = auth.uid())
    and ia = (select p.ia from public.profiles p where p.id = auth.uid())
    and pares_modo is not distinct from (select p.pares_modo from public.profiles p where p.id = auth.uid())
    and pares_equipes is not distinct from (select p.pares_equipes from public.profiles p where p.id = auth.uid())
  );

create or replace function public.bi_vendedores(f jsonb, per jsonb)
 returns json language plpgsql security definer set search_path to '' set work_mem to '48MB'
as $function$
declare w text; w2 text; res json; ck text; e record; pm text; pe text[]; me int; k text; mp jsonb; out jsonb := '{}'::jsonb;
begin
  select * into e from private.bi_escopo();
  if coalesce(e.ok, false) and not coalesce(e.todas, false) and e.vendedor is not null and e.vendedor > 0 then
    select p.pares_modo, p.pares_equipes into pm, pe from public.profiles p where p.id = auth.uid();
  end if;
  w := private.bi_where(coalesce(f, '{}'::jsonb), 'vendedor');
  if pm is not null then
    me := e.vendedor;
    -- tira só a trava do próprio vendedor; o resto do escopo (lojas, canais, equipes) continua
    w2 := regexp_replace(w, ' and vendedor = ' || me || '(?![0-9])', '');
    if w2 = w then pm := null; else w := w2; end if;
    if pm = 'equipe' then
      w := w || format(' and (vendedor = %s or vendedor = any(%L::smallint[]))', me,
             coalesce((select array_agg(d.id) from public.bi_dim d join public.bi_vendedor_equipe ve on ve.vendedor = d.valor
                       where d.tipo = 'vendedor' and ve.equipe = any(coalesce(pe, '{}'))), '{}'));
    end if;
  end if;
  ck := md5(concat_ws('|', 'vendedores2', w, per->>'ini', per->>'fim'));
  select c.valor into res from public.bi_cache c where c.chave = ck;
  if not found then
    execute format($q$
      with b as materialized (select vendedor, marca, categoria, produto, dia, mes, cliente, nf, fat, qtd, lb
                           from public.bi_venda where %s and dia between $1 and $2),
      g as materialized (
        select case when grouping(marca)=0 then 'vm' when grouping(categoria)=0 then 'vc' when grouping(dia)=0 then 'vd'
                    when grouping(produto)=0 then 'vp' else 'v' end s,
               vendedor, coalesce(marca, categoria, produto) k, dia, sum(fat) ft, sum(qtd) qt, sum(lb) lt
        from b group by grouping sets ((vendedor),(vendedor,marca),(vendedor,categoria),(vendedor,dia),(vendedor,produto))
      ), topp as (select k from g where s = 'vp' group by k order by sum(ft) desc limit 10)
      select json_build_object(
        'v', (select coalesce(json_agg(json_build_array(vendedor, ft, qt, lt)), '[]') from g where s = 'v'),
        'vm', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vm'),
        'vc', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vc'),
        'vd', (select coalesce(json_agg(json_build_array(vendedor, dia, ft)), '[]') from g where s = 'vd'),
        'vp', (select coalesce(json_agg(json_build_array(vendedor, k, ft)), '[]') from g where s = 'vp' and k in (select k from topp)),
        'vs', (select coalesce(json_agg(json_build_array(vendedor, n)), '[]') from (
                 select vendedor, avg(n) n from (select vendedor, mes, count(distinct produto) n from b group by 1, 2) x group by 1) y),
        'vcli', (select coalesce(json_agg(json_build_array(vendedor, nc, nn)), '[]') from (
                 select vendedor, count(distinct cliente) nc, count(distinct nf) nn from b group by 1) y)
      )$q$, w)
    into res using (per->>'ini')::date, (per->>'fim')::date;
    if coalesce(f, '{}'::jsonb) - 'vendedor' = '{}'::jsonb then
      insert into public.bi_cache (chave, valor) values (ck, res) on conflict do nothing;
    end if;
  end if;
  if pm is null then return res; end if;
  -- pares sem nome: o próprio vendedor mantém o id; os demais (só pessoas) viram -1, -2… por faturamento
  select coalesce(jsonb_object_agg(y.id::text, y.nid), '{}'::jsonb) into mp
    from (select x.id, case when x.id = me then me
                 else -(row_number() over (partition by x.id = me order by x.ft desc))::int end nid
          from (select (j->>0)::int id, (j->>1)::numeric ft from json_array_elements(res->'v') j) x
          join public.bi_dim d on d.tipo = 'vendedor' and d.id = x.id
          where d.valor not in ('Diversos', 'N/D', '')) y;
  foreach k in array array['v','vm','vc','vd','vp','vs','vcli'] loop
    out := out || jsonb_build_object(k, coalesce((select jsonb_agg(jsonb_set(j::jsonb, '{0}', mp -> (j->>0)))
             from json_array_elements(res->k) j where mp ? (j->>0)), '[]'::jsonb));
  end loop;
  return out::json;
end $function$;

-- Concorrência e Planejamento: perfil BI ou quem tiver a guia marcada no cadastro
create or replace function private.bi_aba_liberada(p_aba text)
 returns boolean language sql stable security definer set search_path to ''
as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.active
                 and (p.role = 'bi' or p_aba = any(coalesce(p.abas, '{}'))))
$$;

create or replace function public.bi_concorrencia_ler()
 returns json language plpgsql stable security definer set search_path to ''
as $function$
declare res json;
begin
  if not private.bi_aba_liberada('concorrencia') then raise exception 'sem acesso à concorrência'; end if;
  with c as (select id from public.bi_dim where tipo = 'canal' and valor = 'ECOMMERCE'),
  t as (select v.produto, sum(v.fat) fat, sum(v.qtd) qtd from public.bi_venda_det v, c
        where v.canal = c.id and v.dia >= (select max(dia) from public.bi_venda_det) - 89 and v.fat > 0
        group by 1 order by 2 desc limit 100)
  select json_build_object(
    'itens', coalesce((select json_agg(json_build_array(p.pn, p.nome, t.fat, t.qtd) order by t.fat desc) from t join public.bi_produto p on p.id = t.produto), '[]'),
    'precos', coalesce((select json_agg(json_build_array(site, pn, preco, preco_lista, disponivel, titulo, url, confianca, coletado_em)) from public.bi_concorrencia), '[]')
  ) into res;
  return res;
end $function$;

create or replace function public.bi_conteudo_ler(p_chave text)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare res jsonb;
begin
  if not private.bi_aba_liberada(split_part(p_chave, '_', 1)) then raise exception 'sem acesso ao planejamento'; end if;
  select c.valor into res from public.bi_conteudo c where c.chave = p_chave;
  return res;
end $function$;
