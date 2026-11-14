"""Comparativo de preços do e-commerce: top 100 itens (últimos 90 dias) x sites concorrentes -> tabela bi_concorrencia.

Fontes (só páginas públicas, respeitando o robots.txt de cada site, com pausa entre acessos):
  nossa    loja.chevroletnova.com.br  API pública de catálogo da VTEX (busca pelo código)
  accioly  www.acciolygm.com.br       busca da loja + dados estruturados (JSON-LD) da página do produto (mpn = código)
  carrera  pecas.carrera.com.br       mapa do site (o código está no fim do endereço do produto) + JSON-LD da página
Vigorito fica de fora: o site bloqueia acesso automatizado (verificação anti-robô), e não contornamos isso.
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


def main():
    url = os.environ.get('SUPABASE_DB_URL')
    if not url:
        print('SUPABASE_DB_URL não configurado; nada a fazer.'); return
    with psycopg.connect(url, autocommit=True) as con:
        itens = con.execute("""
          with c as (select id from public.bi_dim where tipo = 'canal' and valor = 'ECOMMERCE'),
          t as (select v.produto, sum(v.fat) fat from public.bi_venda_det v, c
                where v.canal = c.id and v.dia >= (select max(dia) from public.bi_venda_det) - 89 and v.fat > 0
                group by 1 order by 2 desc limit 100)
          select p.pn, p.nome from t join public.bi_produto p on p.id = t.produto order by t.fat desc""").fetchall()
        print(f'{len(itens)} itens no top 100 do e-commerce', flush=True)
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
        with con.transaction():
            con.execute('delete from public.bi_concorrencia')
            with con.cursor() as cur:
                cur.executemany("""insert into public.bi_concorrencia (site, pn, preco, preco_lista, disponivel, titulo, url, confianca)
                                   values (%s,%s,%s,%s,%s,%s,%s,%s) on conflict (site, pn) do nothing""", linhas)
        print('accioly (diagnóstico):', ACC_DBG, flush=True)
        print('gravado: ' + ', '.join(f'{k} {v}' for k, v in achou.items()), flush=True)


if __name__ == '__main__':
    main()
