"""Sonda das fontes da Sugestão de Cadastro: para alguns códigos de peça, mostra quais sites respondem e a forma dos dados
(campos, contagens, domínios). Só dado público de catálogo; nada de vendas, estoque ou clientes da empresa."""
import json, os, re, sys, time, urllib.parse, urllib.request

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
PNS = (os.environ.get('PN') or '93344705 94767674').split()


def get(url, n=4_000_000, hdr=None):
    time.sleep(0.6)
    h = {'User-Agent': UA, 'Accept-Language': 'pt-BR,pt;q=0.9', 'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8'}
    h.update(hdr or {})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=30) as r:
            return r.status, r.read(n).decode('utf-8', 'ignore'), r.geturl()
    except Exception as e:
        return getattr(e, 'code', 0), '', url


def forma(x, n=0):
    if isinstance(x, dict):
        return {k: forma(v, n + 1) for k, v in list(x.items())[:40]} if n < 3 else '{…}'
    if isinstance(x, list):
        return [forma(x[0], n + 1), f'({len(x)})'] if x else []
    if isinstance(x, str):
        return f'str{len(x)}'
    return type(x).__name__


def p(*a):
    print(*a, flush=True)


for pn in PNS:
    p('=' * 30, 'PN', pn[:3] + '…')
    q = urllib.parse.quote(pn)
    # nossa loja VTEX
    st, b, _ = get('https://loja.chevroletnova.com.br/api/catalog_system/pub/products/search?ft=' + q)
    try:
        d = json.loads(b)
        p('VTEX', st, len(d), json.dumps(forma(d[0]) if d else {}, ensure_ascii=False)[:2500])
        if d:
            p('VTEX specs', d[0].get('allSpecifications'), [k for k in d[0] if k not in ('items',)][:60])
            it = (d[0].get('items') or [{}])[0]
            p('VTEX item', {k: it.get(k) for k in ('measurementUnit', 'unitMultiplier', 'complementName', 'ean')})
    except Exception as e:
        p('VTEX', st, 'não-json', len(b))
    # Peça Chevrolet API
    st, b, _ = get(f'https://api.pecachevroletapi.com/api/v1/dealers/-/parts/{q}?latitude=-23.550413&longitude=-46.633904')
    try:
        d = json.loads(b)
        p('PC dealers', st, json.dumps(forma(d), ensure_ascii=False)[:1500])
    except Exception:
        p('PC dealers', st, len(b))
    for u in [f'https://api.pecachevroletapi.com/api/v1/parts/{q}', f'https://api.pecachevroletapi.com/api/v1/parts?search={q}',
              f'https://api.pecachevroletapi.com/api/v1/parts/{q}/applications', f'https://api.pecachevroletapi.com/api/v1/parts/{q}/vehicles']:
        st, b, _ = get(u)
        try:
            p('PC', u.split('/v1/')[1].replace(q, 'PN'), st, json.dumps(forma(json.loads(b)), ensure_ascii=False)[:1500])
        except Exception:
            p('PC', u.split('/v1/')[1].replace(q, 'PN'), st, len(b))
    # Mercado Livre
    st, b, _ = get('https://api.mercadolibre.com/sites/MLB/search?q=' + q, hdr={'Accept': 'application/json'})
    p('ML api', st, len(b), b[:200].replace('\n', ' '))
    st, b, fu = get('https://lista.mercadolivre.com.br/' + q)
    links = list(dict.fromkeys(re.findall(r'href="(https://(?:produto|www)\.mercadolivre\.com\.br/[^"#?]+)', b)))
    p('ML lista', st, len(b), 'links', len(links), 'final', fu[:80], 'titulos', re.findall(r'class="poly-component__title[^"]*"[^>]*>([^<]{5,90})<', b)[:4])
    if links:
        st, b, _ = get(links[0])
        p('ML item', st, len(b), links[0][:90])
        p('ML ld', [json.dumps(forma(json.loads(m)), ensure_ascii=False)[:600] for m in re.findall(r'<script[^>]+ld\+json[^>]*>(.*?)</script>', b, re.S)[:2]])
        p('ML tabelas', re.findall(r'andes-table__header[^>]*>(?:<[^>]+>)*([^<]{2,40})<', b)[:40])
        p('ML compat', 'compat' in b.lower(), b.lower().count('compatib'), re.findall(r'"(?:LENGTH|WIDTH|HEIGHT|PACKAGE_\w+)"[^}]{0,120}', b)[:6])
        st2, b2, _ = get(f'https://api.mercadolibre.com/items/' + (re.findall(r'MLB-?(\d{6,})', links[0]) or ['0'])[0].join(['MLB', '']))
        p('ML items api', st2, b2[:160])
    # buscadores
    for nome, u in [('DDG', 'https://html.duckduckgo.com/html/?q=' + q), ('Bing', 'https://www.bing.com/search?q=' + q + '&setlang=pt-BR'),
                    ('Google', 'https://www.google.com/search?hl=pt-BR&q=' + q)]:
        st, b, _ = get(u)
        doms = re.findall(r'https?://([a-z0-9.\-]+\.[a-z]{2,})/', urllib.parse.unquote(b))
        doms = [x for x in dict.fromkeys(doms) if not re.search(r'duckduckgo|bing|microsoft|google|gstatic|msn|live\.com|w3\.org|schema', x)]
        p(nome, st, len(b), doms[:15])

# página do Peça Chevrolet num navegador, para ver as chamadas de dados da busca e do produto
if os.environ.get('NAV') == '1':
    from playwright.sync_api import sync_playwright
    def resp(r):
        if 'json' not in r.headers.get('content-type', '') or any(x in r.url for x in ('google', 'facebook', 'hotjar', 'clarity')):
            return
        try:
            p('NAV', r.request.method, re.sub(r'\d{6,}', 'N', r.url)[:200], json.dumps(forma(r.json()), ensure_ascii=False)[:1500])
        except Exception:
            pass
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        pg = br.new_page(user_agent=UA, locale='pt-BR')
        pg.on('response', resp)
        pg.goto(f'https://www.pecachevrolet.com.br/pesquisa/?q={PNS[0]}', wait_until='networkidle', timeout=60000)
        hs = pg.eval_on_selector_all('a[href]', 'as => as.map(a => a.href)')
        prod = [h for h in hs if re.search(r'/(produto|peca|p)/', h)]
        p('NAV links', len(hs), [re.sub(r'\d{6,}', 'N', h)[:120] for h in prod[:5]])
        if prod:
            pg.goto(prod[0], wait_until='networkidle', timeout=60000)
            txt = pg.inner_text('body')
            p('NAV texto', len(txt), [l[:80] for l in txt.split('\n') if re.search(r'(?i)aplica|compat|ve[ií]culo|dimens|medida|peso|altura|largura|compr', l)][:25])
        br.close()
