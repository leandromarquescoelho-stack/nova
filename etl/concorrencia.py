"""Comparativo de preços do e-commerce: top 100 itens (últimos 90 dias) x sites concorrentes -> tabela bi_concorrencia.

Fontes (só páginas públicas, respeitando o robots.txt de cada site, com pausa entre acessos):
  nossa    loja.chevroletnova.com.br  API pública de catálogo da VTEX (busca pelo código)
  accioly  www.acciolygm.com.br       busca da loja + dados estruturados (JSON-LD) da página do produto (mpn = código)
  carrera  pecas.carrera.com.br       mapa do site (o código está no fim do endereço do produto) + JSON-LD da página
Vigorito fica de fora: o site bloqueia acesso automatizado (verificação anti-robô), e não contornamos isso.
Peça Chevrolet (www.pecachevrolet.com.br, marketplace da GM): top 100 da loja PEÇA CHEVROLET; para cada peça, a lista pública de
  preços por concessionária que a própria página do produto usa. Guarda Nova, Accioly, Vigorito e Carrera (sites pc_*).
O log mostra só contagens: nenhum código, nome ou preço da empresa é impresso (o repositório é público).
"""
import gzip, html as H, json, os, re, sys, time, urllib.parse, urllib.request
import psycopg

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
PAUSA = 0.5


def get(url, n=3_000_000):
    time.sleep(PAUSA)
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'pt-BR,pt;q=0.9'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            b = r.read(n)
            if url.endswith('.gz') or b[:2] == b'\x1f\x8b':
                b = gzip.decompress(b)
            return r.status, b.decode('utf-8', 'ignore')
    except Exception as e:
        return getattr(e, 'code', 0), ''


def norm(c):
    return re.sub(r'[^A-Z0-9]', '', str(c).upper()).lstrip('0')


def codigos(pn, nome):
    cs = [pn] + re.findall(r'\(([A-Z0-9\-]{5,})\)', nome or '')
    return [c for c in dict.fromkeys(norm(c) for c in cs) if len(c) >= 5]


def jsonld_produtos(page):
    out = []
    for m in re.finditer(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', page, re.S | re.I):
        try:
            d = json.loads(m.group(1).strip(), strict=False)
        except Exception:
            continue
        pilha = [d]
        while pilha:
            x = pilha.pop()
            if isinstance(x, list):
                pilha.extend(x)
            elif isinstance(x, dict):
                if x.get('@type') == 'Product':
                    out.append(x)
                pilha.extend(v for v in x.values() if isinstance(v, (dict, list)))
    return out


def ld_regex(page):
    # JSON-LD que não abre como JSON (aspas soltas na descrição): lê os campos direto do texto
    out = []
    for m in re.finditer(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', page, re.S | re.I):
        t = m.group(1)
        if '"Product"' not in t:
            continue
        def campo(k):
            mm = re.search(r'"' + k + r'"\s*:\s*"?([^",}]+)', t)
            return mm.group(1).strip() if mm else ''
        out.append({'@type': 'Product', 'name': campo('name'), 'sku': campo('sku'), 'mpn': campo('mpn'), 'gtin': campo('gtin'),
                    'offers': {'price': campo('price'), 'availability': campo('availability')}})
    return out


def oferta(p):
    of = p.get('offers') or {}
    if isinstance(of, list):
        of = of[0] if of else {}
    if of.get('@type') == 'AggregateOffer':
        preco = of.get('lowPrice') or of.get('price')
    else:
        preco = of.get('price')
    try:
        preco = float(str(preco).replace(',', '.')) if preco not in (None, '') else None
    except ValueError:
        preco = None
    disp = of.get('availability')
    return preco, (None if disp is None else 'InStock' in str(disp))


# ---------------- nossa loja (VTEX) ----------------
def nossa(cs):
    st, body = get('https://loja.chevroletnova.com.br/api/catalog_system/pub/products/search?ft=' + urllib.parse.quote(cs[0]))
    try:
        prods = json.loads(body)
    except Exception:
        return None
    melhor = None
    for p in prods:
        refs = {norm(r) for r in str(p.get('productReference') or '').split('|')}
        if not refs & set(cs) and cs[0] not in norm(p.get('productName', '')):
            continue
        for it in p.get('items', []):
            for s in it.get('sellers', []):
                o = s.get('commertialOffer') or {}
                pr = o.get('Price')
                if not pr:
                    continue
                cand = dict(preco=float(pr), lista=float(o.get('ListPrice') or pr), disp=(o.get('AvailableQuantity') or 0) > 0,
                            titulo=p.get('productName'), url=p.get('link'), conf='codigo')
                if melhor is None or (cand['disp'], -cand['preco']) > (melhor['disp'], -melhor['preco']):
                    melhor = cand
    return melhor


# ---------------- Accioly (Tray) ----------------
ACC_NAV = None
ACC_DBG = {'buscas': 0, 'sem_200': 0, 'links': 0, 'paginas': 0, 'com_produto': 0}


def acc_links(term):
    st, body = get('https://www.acciolygm.com.br/loja/busca.php?loja=476243&palavra_busca=' + urllib.parse.quote(term))
    ACC_DBG['buscas'] += 1; ACC_DBG['sem_200'] += st != 200
    return list(dict.fromkeys(re.findall(r'href="(https://www\.acciolygm\.com\.br/[a-z0-9\-]+)"', body)))


def accioly(cs):
    global ACC_NAV
    if ACC_NAV is None:
        ACC_NAV = set(acc_links('zzqxw9'))  # links de menu/rodapé, presentes em toda busca
    links = [l for l in acc_links(cs[0]) if l not in ACC_NAV][:4]
    ACC_DBG['links'] += len(links)
    for l in links:
        st, page = get(l)
        prods = jsonld_produtos(page) or ld_regex(page)
        ACC_DBG['paginas'] += 1; ACC_DBG['com_produto'] += bool(prods)
        for p in prods:
            ids = {norm(p.get(k, '')) for k in ('mpn', 'sku', 'gtin', 'gtin13', 'gtin8', 'gtin14')}
            ids |= {norm(r) for r in re.findall(r'"(?:reference|EAN)"\s*:\s*"([^"]+)"', page)}
            nome = norm(p.get('name', ''))
            if ids & set(cs) or any(c in nome for c in cs):
                preco, disp = oferta(p)
                if preco:
                    return dict(preco=preco, lista=None, disp=disp, titulo=H.unescape(p.get('name', '')), url=l,
                                conf='codigo' if ids & set(cs) else 'nome')
    return None


# ---------------- Carrera (Nuvemshop) ----------------
CAR_MAPA = None


def car_mapa():
    st, body = get('https://pecas.carrera.com.br/sitemap.xml')
    locs = re.findall(r'<loc>([^<]+)</loc>', body)
    m = {}
    for u in locs:
        mm = re.search(r'/produtos/([^/]+)/?$', u)
        if not mm:
            continue
        for tok in mm.group(1).split('-')[-2:]:
            if re.search(r'\d', tok) and len(norm(tok)) >= 5:
                m.setdefault(norm(tok), u)
    return m, len(locs)


def carrera(cs):
    global CAR_MAPA
    if CAR_MAPA is None:
        CAR_MAPA, n = car_mapa()
        print(f'carrera: {n} endereços no mapa do site, {len(CAR_MAPA)} com código', flush=True)
    for c in cs:
        u = CAR_MAPA.get(c)
        if not u:
            continue
        st, page = get(u)
        for p in (jsonld_produtos(page) or ld_regex(page)):
            ids = {norm(p.get(k, '')) for k in ('mpn', 'sku', 'gtin')}
            titulo = H.unescape(p.get('name', ''))
            # o código precisa estar no nome do produto ou no sku/mpn (o fim do endereço sozinho pode ser outro número)
            if not (ids & set(cs) or any(re.search(r'(?<![0-9A-Z])0*' + c + r'(?![0-9A-Z])', titulo.upper()) for c in cs)):
                continue
            preco, disp = oferta(p)
            if preco:
                return dict(preco=preco, lista=None, disp=disp, titulo=titulo, url=u, conf='codigo')
    return None


SITES = [('nossa', nossa), ('accioly', accioly), ('carrera', carrera)]

# ---------------- Peça Chevrolet (marketplace GM) ----------------
PC = 'https://www.pecachevrolet.com.br'
PC_API = 'https://api.pecachevroletapi.com/api/v1/dealers/-/parts/{}?latitude=-23.550413&longitude=-46.633904'
PC_REDES = {'pc_nova': r'\bNOVA\b', 'pc_accioly': r'ACCIOLY', 'pc_vigorito': r'VIGORITO', 'pc_carrera': r'CARRERA'}


def pc_redes_log():
    # nomes das concessionárias de cada rede (dado público do site) para conferir a identificação
    st, body = get(PC + '/active_dealers.json')
    try:
        ds = json.loads(body)
    except Exception:
        print(f'peça chevrolet: lista de concessionárias indisponível ({st})', flush=True); return
    for site, rx in PC_REDES.items():
        nomes = sorted({d.get('dealer_name', '') for d in ds if re.search(rx, (d.get('dealer_name', '') + ' ' + d.get('dealer_shortname', '')).upper())})
        print(f'peça chevrolet {site}: {len(nomes)} concessionária(s): {nomes}', flush=True)


def peca_chevrolet(cs):
    """{site: oferta} das redes acompanhadas para a peça; a menor oferta com estoque de cada rede (sem estoque, a menor)."""
    for c in cs:
        st, body = get(PC_API.format(urllib.parse.quote(c)))
        try:
            ds = json.loads(body)
        except Exception:
            continue
        if not isinstance(ds, list) or not ds:
            continue
        out = {}
        for d in ds:
            nome = str(d.get('dealer_name') or '')
            pr = d.get('price_b2c')
            if not pr:
                continue
            for site, rx in PC_REDES.items():
                if re.search(rx, nome.upper()):
                    cand = dict(preco=float(pr), lista=float(d['price_b2b']) if d.get('price_b2b') else None,
                                disp=(d.get('stock_position') or 0) > 0, titulo=nome[:200], url=f'{PC}/pesquisa/?q={c}', conf='codigo')
                    old = out.get(site)
                    if old is None or (cand['disp'], -cand['preco']) > (old['disp'], -old['preco']):
                        out[site] = cand
        return out, len(ds)
    return {}, 0


def main():
    url = os.environ.get('SUPABASE_DB_URL')
    if not url:
        print('SUPABASE_DB_URL não configurado; nada a fazer.'); return
    # modo item: só o produto que acabou de ser adicionado à mão, numa guia (vtex ou pc)
    modo = (os.environ.get('MODO') or 'coleta').strip()
    item_pn, item_fonte = (os.environ.get('PN') or '').strip().upper(), (os.environ.get('FONTE') or '').strip()
    if modo == 'item' and (not item_pn or item_fonte not in ('vtex', 'pc')):
        print('modo item sem código ou guia; nada a fazer.'); return
    with psycopg.connect(url, autocommit=True) as con:
        tem_manual = con.execute("select to_regclass('public.bi_conc_manual') is not null").fetchone()[0]

        def manuais(fonte, ja):
            if not tem_manual:
                return []
            rs = con.execute("""select m.pn, p.nome from public.bi_conc_manual m left join public.bi_produto p on p.pn = m.pn
                                 where m.fonte = %s order by m.criado_em""", (fonte,)).fetchall()
            vistos = {pn for pn, _ in ja}
            return [(pn, nome) for pn, nome in rs if pn not in vistos]

        if modo == 'item':
            nome = con.execute('select nome from public.bi_produto where pn = %s', (item_pn,)).fetchone()
            um = [(item_pn, nome[0] if nome else None)]
            itens, itens_pc = (um, []) if item_fonte == 'vtex' else ([], um)
            print(f'modo item: 1 produto na guia {item_fonte}', flush=True)
        else:
            itens = con.execute("""
              with c as (select id from public.bi_dim where tipo = 'canal' and valor = 'ECOMMERCE'),
              t as (select v.produto, sum(v.fat) fat from public.bi_venda_det v, c
                    where v.canal = c.id and v.dia >= (select max(dia) from public.bi_venda_det) - 89 and v.fat > 0
                    group by 1 order by 2 desc limit 100)
              select p.pn, p.nome from t join public.bi_produto p on p.id = t.produto order by t.fat desc""").fetchall()
            itens += manuais('vtex', itens)
            print(f'{len(itens)} itens do e-commerce (top 100 e adicionados à mão)', flush=True)
        linhas, achou = [], {s: 0 for s, _ in SITES}
        for i, (pn, nome) in enumerate(itens, 1):
            cs = codigos(pn, nome)
            if not cs:
                continue
            for site, fn in SITES:
                try:
                    r = fn(cs)
                except Exception as e:
                    r = None
                    print(f'  {site}: erro {type(e).__name__}', flush=True)
                if r:
                    achou[site] += 1
                    linhas.append((site, pn, r['preco'], r['lista'], r['disp'], (r['titulo'] or '')[:200], r['url'], r['conf']))
            if i % 10 == 0:
                print(f'{i} itens processados · encontrados: ' + ', '.join(f'{k} {v}' for k, v in achou.items()), flush=True)
        # Peça Chevrolet: top 100 da loja PEÇA CHEVROLET (90 dias) e os adicionados à mão
        if modo != 'item':
            itens_pc = con.execute("""
              with l as (select id from public.bi_dim where tipo = 'loja' and valor = 'PEÇA CHEVROLET'),
              t as (select v.produto, sum(v.fat) fat from public.bi_venda_det v, l
                    where v.loja = l.id and v.dia >= (select max(dia) from public.bi_venda_det) - 89 and v.fat > 0
                    group by 1 order by 2 desc limit 100)
              select p.pn, p.nome from t join public.bi_produto p on p.id = t.produto order by t.fat desc""").fetchall()
            itens_pc += manuais('pc', itens_pc)
            print(f'{len(itens_pc)} itens da loja Peça Chevrolet (top 100 e adicionados à mão)', flush=True)
        if itens_pc:
            pc_redes_log()
        achou_pc, com_lista = {s: 0 for s in PC_REDES}, 0
        for i, (pn, nome) in enumerate(itens_pc, 1):
            cs = codigos(pn, nome)
            if not cs:
                continue
            try:
                ofs, n = peca_chevrolet(cs)
            except Exception as e:
                ofs, n = {}, 0
                print(f'  peça chevrolet: erro {type(e).__name__}', flush=True)
            com_lista += n > 0
            for site, r in ofs.items():
                achou_pc[site] += 1
                linhas.append((site, pn, r['preco'], r['lista'], r['disp'], r['titulo'], r['url'], r['conf']))
            if i % 20 == 0:
                print(f'peça chevrolet: {i} itens · com concessionárias {com_lista} · ' + ', '.join(f'{k} {v}' for k, v in achou_pc.items()), flush=True)
        achou.update(achou_pc)
        sites_ok = [k for k, v in achou.items() if v]   # um site sem nenhum resultado mantém a coleta anterior
        with con.transaction():
            if modo == 'item':   # só o item: troca os preços dele nos sites da guia (sem nenhum resultado, mantém os anteriores)
                sites_guia = [s for s, _ in SITES] if item_fonte == 'vtex' else list(PC_REDES)
                if linhas:
                    con.execute('delete from public.bi_concorrencia where pn = %s and site = any(%s)', (item_pn, sites_guia))
            else:
                con.execute('delete from public.bi_concorrencia where site = any(%s)', (sites_ok,))
            with con.cursor() as cur:
                cur.executemany("""insert into public.bi_concorrencia (site, pn, preco, preco_lista, disponivel, titulo, url, confianca)
                                   values (%s,%s,%s,%s,%s,%s,%s,%s) on conflict (site, pn) do nothing""", linhas)
            # histórico diário (um registro por dia, site e peça; a última coleta do dia vale)
            if con.execute("select to_regclass('public.bi_concorrencia_hist') is not null").fetchone()[0]:
                con.execute("""insert into public.bi_concorrencia_hist (dia, site, pn, preco, disponivel)
                               select (now() at time zone 'America/Sao_Paulo')::date, site, pn, preco, disponivel from public.bi_concorrencia
                               where %s = '' or pn = %s
                               on conflict (dia, site, pn) do update set preco = excluded.preco, disponivel = excluded.disponivel""",
                            (item_pn if modo == 'item' else '', item_pn if modo == 'item' else ''))
        print('accioly (diagnóstico):', ACC_DBG, flush=True)
        print('gravado: ' + ', '.join(f'{k} {v}' for k, v in achou.items()), flush=True)


if __name__ == '__main__':
    main()
