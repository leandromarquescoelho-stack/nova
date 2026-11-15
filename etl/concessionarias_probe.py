"""Sondagem (só para desenvolver): descobre de onde o localizador público de concessionárias da Chevrolet carrega os dados.
Imprime só endereços de requisições e amostras públicas (nome/cidade de concessionárias). Nada da empresa."""
import json, re
from playwright.sync_api import sync_playwright

URLS = ['https://www.chevrolet.com.br/', 'https://www.chevrolet.com.br/concessionarias', 'https://www.chevrolet.com.br/encontre-uma-concessionaria',
        'https://www.chevrolet.com.br/localizador-de-concessionarias']
vistos = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(locale='pt-BR', user_agent='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
    def resp(r):
        u = r.url
        if re.search(r'dealer|concession|locator|revend', u, re.I) and r.request.resource_type in ('xhr', 'fetch', 'document', 'script'):
            amostra = ''
            try:
                if 'json' in (r.headers.get('content-type') or ''):
                    amostra = r.text()[:600]
            except Exception:
                pass
            vistos.append((r.status, r.request.resource_type, u[:300], amostra))
    pg.on('response', resp)
    for u in URLS:
        try:
            r = pg.goto(u, wait_until='networkidle', timeout=45000)
            print('==', u, r.status if r else None, pg.url, flush=True)
            links = pg.eval_on_selector_all('a[href]', 'els => els.map(e => e.href).filter(h => /concession|dealer|locali/i.test(h))')
            print('   links:', sorted(set(links))[:15], flush=True)
        except Exception as e:
            print('==', u, 'erro', type(e).__name__, flush=True)
    # tenta uma busca por CEP no localizador, se houver campo
    try:
        campo = pg.query_selector('input[type=text], input[type=search]')
        if campo:
            campo.fill('01310-100'); campo.press('Enter'); pg.wait_for_timeout(8000)
            print('   busca feita em', pg.url, flush=True)
    except Exception as e:
        print('   busca erro', type(e).__name__)
    b.close()
for v in vistos[:60]:
    print(v[0], v[1], v[2]); 
    if v[3]: print('     ', v[3].replace('\n', ' '))
