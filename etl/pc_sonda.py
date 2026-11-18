"""Sonda do site Peça Chevrolet (marketplace): mostra só a estrutura pública (robots, endereços, chamadas da página), nada da empresa."""
import re, urllib.request, time, gzip

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
B = 'https://www.pecachevrolet.com.br'


def get(u, n=8_000_000):
    time.sleep(0.6)
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers={'User-Agent': UA, 'Accept-Language': 'pt-BR'}), timeout=40) as r:
            b = r.read(n)
            if b[:2] == b'\x1f\x8b':
                b = gzip.decompress(b)
            return r.status, b.decode('utf-8', 'ignore')
    except Exception as e:
        return getattr(e, 'code', type(e).__name__), ''


st, rb = get(B + '/robots.txt')
print('ROBOTS', st)
print(rb[:3000])
st, home = get(B + '/')
print('HOME', st, len(home))
print(home[:2300])
srcs = re.findall(r'<script[^>]+src="([^"]+)"', home)
print('SCRIPTS', srcs)
for s in srcs[:6]:
    u = s if s.startswith('http') else B + s
    st, js = get(u)
    apis = sorted(set(re.findall(r'["\'`](/?(?:api|graphql|v\d|bff|services?)[/\w\-{}.:?=&$]*)["\'`]', js)))[:80]
    hosts = sorted(set(re.findall(r'https://[a-z0-9.\-]+\.[a-z]{2,}(?:/[\w\-./]*)?', js)))[:60]
    print('JS', u.rsplit('/', 1)[-1], st, len(js))
    print('  APIS', apis)
    print('  HOSTS', hosts)
    for k in ('seller', 'lojista', 'concession', 'dealer', 'oferta', 'offer', 'price', 'preco'):
        ctx = [js[max(0, m.start() - 60):m.start() + 80].replace('\n', ' ') for m in re.finditer(k, js)][:3]
        if ctx:
            print('  CTX', k, ctx)
st, sm = get(B + '/sitemap_index.xml')
print('SITEMAP_INDEX', st, re.findall(r'<loc>([^<]+)</loc>', sm)[:10])
st, s1 = get(B + '/sitemap1.xml')
locs = re.findall(r'<loc>([^<]+)</loc>', s1)
print('SITEMAP1', st, len(locs), locs[:8])
if locs:
    st, pg = get(locs[min(3, len(locs) - 1)])
    print('PRODUTO', st, len(pg))
    print('  LDJSON', re.findall(r'application/ld\+json[^>]*>(.{0,600})', pg, re.S)[:2])
    print('  INICIO', pg[:1500])
