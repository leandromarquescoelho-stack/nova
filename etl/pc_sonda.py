"""Sonda do site Peça Chevrolet (marketplace): mostra só a estrutura pública (plataforma, vendedores, campos), nada da empresa."""
import json, re, urllib.parse, urllib.request, time

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
B = 'https://pecachevrolet.com.br'


def get(u):
    time.sleep(0.6)
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers={'User-Agent': UA, 'Accept-Language': 'pt-BR'}), timeout=30) as r:
            return r.status, dict(r.headers), r.read(4_000_000).decode('utf-8', 'ignore')
    except Exception as e:
        return getattr(e, 'code', type(e).__name__), {}, ''


st, h, body = get(B + '/')
print('home', st, len(body), {k: v for k, v in h.items() if k.lower().startswith(('x-vtex', 'server', 'x-powered', 'powered'))})
print('marcas no html:', [k for k in ('vtex', '__NEXT_DATA__', 'nuvemshop', 'tray', 'magento', 'shopify', 'wake', 'linx', 'vnda', 'occ') if k.lower() in body.lower()])
st, _, rb = get(B + '/robots.txt')
print('robots', st, [l for l in rb.splitlines() if l.strip()][:25])
for termo in ('filtro de oleo', 'pastilha de freio', 'amortecedor'):
    st, _, b = get(B + '/api/catalog_system/pub/products/search?ft=' + urllib.parse.quote(termo) + '&_from=0&_to=49')
    try:
        ps = json.loads(b)
    except Exception:
        print('busca vtex', termo, st, 'não é json', b[:120].replace('\n', ' ')); continue
    vend, campos = {}, set()
    for p in ps:
        campos |= set(p.keys())
        for it in p.get('items', []):
            for s in it.get('sellers', []):
                o = s.get('commertialOffer') or {}
                k = f"{s.get('sellerId')}|{s.get('sellerName')}"
                vend[k] = vend.get(k, 0) + (1 if o.get('Price') else 0)
    print('busca vtex', termo, st, len(ps), 'produtos; vendedores (ofertas com preço):', sorted(vend.items(), key=lambda x: -x[1])[:40])
    if ps:
        p = ps[0]
        print('  campos de referência:', {k: p.get(k) for k in ('productReference', 'productReferenceCode', 'brand') if k in p}, '| itens:', len(p.get('items', [])),
              '| campos do item:', sorted((p.get('items') or [{}])[0].keys())[:30])
# intelligent search (VTEX IO)
st, _, b = get(B + '/api/io/_v/api/intelligent-search/product_search/?query=filtro%20de%20oleo&count=20')
print('intelligent search', st, b[:200].replace('\n', ' '))
