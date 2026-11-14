"""Sondagem dos sites (só para desenvolver o coletor): mostra a estrutura das páginas públicas com códigos de exemplo.
Não lê nada do banco e não imprime dados da empresa."""
import json, re, sys, urllib.request, urllib.parse

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
EX = ['93378018', '25FC0225', '98550378']


def get(url, n=400000):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'pt-BR,pt;q=0.9'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read(n).decode('utf-8', 'ignore'), r.geturl()
    except Exception as e:
        return getattr(e, 'code', 0), str(e), url


def trecho(html, pat, w=300, k=3):
    out = []
    for m in re.finditer(pat, html, re.I):
        out.append(re.sub(r'\s+', ' ', html[max(0, m.start() - w // 3):m.end() + w]))
        if len(out) >= k:
            break
    return out


def secao(t):
    print('\n' + '=' * 20, t, '=' * 20, flush=True)


secao('NOSSA LOJA (VTEX)')
for pn in EX:
    st, body, _ = get('https://loja.chevroletnova.com.br/api/catalog_system/pub/products/search?ft=' + pn)
    print(pn, st, len(body))
    try:
        for p in json.loads(body)[:3]:
            it = p['items'][0]; of = it['sellers'][0]['commertialOffer']
            print('  ', p.get('productName', '')[:80], '| ref', p.get('productReference'), '| ean', it.get('ean'), '| preço', of.get('Price'), 'lista', of.get('ListPrice'), 'disp', of.get('AvailableQuantity'), '|', p.get('link'))
    except Exception as e:
        print('  erro', e, body[:200])

secao('ACCIOLY (Tray)')
_, nav, _ = get('https://www.acciolygm.com.br/loja/busca.php?loja=476243&palavra_busca=zzqxw9')
NAV = set(re.findall(r'href="(https://www\.acciolygm\.com\.br/[a-z0-9\-]+)"', nav))
for pn in EX[:2]:
    st, body, _ = get('https://www.acciolygm.com.br/loja/busca.php?loja=476243&palavra_busca=' + pn)
    links = [l for l in dict.fromkeys(re.findall(r'href="(https://www\.acciolygm\.com\.br/[a-z0-9\-]+)"', body)) if l not in NAV]
    print(pn, 'busca', st, len(body), 'links', len(links), links[:6])
    for t in trecho(body, pn, 200, 2):
        print('  na busca>', t[:400])
    for l in links[:3]:
        st, page, _ = get(l, 1500000)
        print(' pág', l, st, len(page))
        for m in re.finditer(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', page, re.S | re.I):
            t = re.sub(r'\s+', ' ', m.group(1))
            if 'Product' in t:
                print('   ld>', t[:900])
        for pat in [r'refer[eê]ncia', r'c[oó]digo', pn]:
            for t in trecho(page, pat, 200, 2):
                print('   ', pat, '>', t[:300])

secao('CARRERA (Nuvemshop)')
st, body, _ = get('https://pecas.carrera.com.br/robots.txt')
print('robots', st, body[:1500])
st, body, _ = get('https://pecas.carrera.com.br/sitemap.xml')
locs = re.findall(r'<loc>([^<]+)</loc>', body)
print('sitemap', st, len(body), len(locs), locs[:8])
prod = [l for l in locs if '/produtos/' in l]
print('produtos no sitemap', len(prod), prod[:5])
if not prod and locs:
    st, b2, _ = get(locs[0]); l2 = re.findall(r'<loc>([^<]+)</loc>', b2); print('sub', locs[0], len(l2), l2[:5]); prod = [l for l in l2 if '/produtos/' in l]
if prod:
    st, body, _ = get(prod[0])
    print('produto', prod[0], st, len(body))
    for pat in [r'application/ld\+json', r'"sku"', r'"mpn"', r'data-variants', r'c[oó]digo', r'LS\.variants', r'"price"']:
        for t in trecho(body, pat, 300, 2):
            print('  ', pat, '>', t[:500])

secao('VIGORITO')
st, body, url = get('https://vigoritopecas.com.br/93378018')
print('html', st, len(body), url)
print(re.findall(r'<script[^>]+src="([^"]+)"', body)[:10])
for pat in [r'api', r'__NEXT_DATA__', r'window\.__', r'goparts']:
    for t in trecho(body, pat, 200, 2):
        print('  ', pat, '>', t[:300])
try:
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch(); pg = b.new_page(user_agent=UA)
        reqs = []
        def resp(r):
            try:
                ct = r.headers.get('content-type', '')
                if 'json' in ct:
                    reqs.append((r.url, r.status, r.text()[:600]))
            except Exception:
                pass
        pg.on('response', resp)
        pg.goto('https://vigoritopecas.com.br/93378018', wait_until='networkidle', timeout=60000)
        pg.wait_for_timeout(3000)
        txt = pg.inner_text('body')
        print('texto renderizado:', re.sub(r'\s+', ' ', txt)[:1500])
        for u, s, t in reqs[:15]:
            print('  JSON', s, u[:200], '>>', re.sub(r'\s+', ' ', t)[:500])
        b.close()
except Exception as e:
    print('playwright erro', e)
