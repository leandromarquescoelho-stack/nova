"""Sonda do site Peça Chevrolet (marketplace, página em React): abre algumas páginas num navegador e lista as chamadas
de dados que a própria página faz (endereço e campos), para montar a coleta. Nada da empresa é impresso."""
import json, re, urllib.request
from playwright.sync_api import sync_playwright

B = 'https://www.pecachevrolet.com.br'
UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
js = urllib.request.urlopen(urllib.request.Request(B + '/static/js/main.d476cf45.js', headers={'User-Agent': UA}), timeout=40).read().decode('utf-8', 'ignore')
print('ROTAS', sorted(set(re.findall(r'path:"(/[^"]*)"', js))))
print('FETCH', [js[max(0, m.start() - 120):m.start() + 160].replace('\n', ' ') for m in re.finditer(r'baseURL|fetch\(|REACT_APP_', js)][:12])

vistos = []


def resp(r):
    u = r.url
    if any(x in u for x in ('google', 'facebook', 'hotjar', 'doubleclick', '.png', '.jpg', '.svg', '.css', '.woff', 'clarity', 'tiktok')):
        return
    ct = r.headers.get('content-type', '')
    if 'json' not in ct:
        return
    try:
        d = r.json()
    except Exception:
        return
    def forma(x, n=0):
        if isinstance(x, dict):
            return {k: forma(v, n + 1) for k, v in list(x.items())[:25]} if n < 3 else '{…}'
        if isinstance(x, list):
            return [forma(x[0], n + 1), f'({len(x)} itens)'] if x else []
        return type(x).__name__
    vistos.append(u)
    print('JSON', r.request.method, u[:220])
    print('   ', json.dumps(forma(d), ensure_ascii=False)[:1500])


with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(user_agent=UA, locale='pt-BR')
    pg.on('response', resp)
    for u in (B + '/', B + '/busca/filtro%20de%20oleo', B + '/pesquisa?q=filtro%20de%20oleo', B + '/concessionarias_br'):
        print('PAGINA', u)
        try:
            pg.goto(u, wait_until='networkidle', timeout=45000)
        except Exception as e:
            print('  erro', type(e).__name__)
        pg.wait_for_timeout(2500)
        links = pg.eval_on_selector_all('a[href*="/peca/"]', 'as => as.slice(0, 5).map(a => a.getAttribute("href"))')
        print('  links de peça', links)
        if links:
            pg.goto(B + links[0], wait_until='networkidle', timeout=45000); pg.wait_for_timeout(3000)
            print('  PECA texto', pg.inner_text('body')[:1500].replace('\n', ' | '))
            break
    b.close()
