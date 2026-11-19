"""Sugestão de cadastro: pesquisa um código de peça em fontes públicas e grava a sugestão em bi_cadastro_sug.

Fontes: nosso catálogo (banco), nossa loja VTEX, Peça Chevrolet (marketplace GM), resultados de busca na web
(DuckDuckGo; o Google e o Bing não respondem a consultas automáticas), Mercado Livre (títulos dos anúncios que a busca encontra;
a página do ML pede login para robôs) e o site do fabricante (pela marca do produto). Das páginas encontradas lê o JSON-LD do produto,
as meta tags e o texto, e monta: melhor título para anúncio, descrição, medidas C x L x A e aplicação, com a lista das fontes.

Sem inteligência artificial: tudo é regra e contagem entre as fontes. O log mostra só contagens."""
import html as H, json, os, re, sys, time, unicodedata, urllib.parse, urllib.request
from collections import Counter, defaultdict

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
MAX_PAGINAS = 10
LIMITE_TITULO = 60  # o Mercado Livre aceita até 60 caracteres no título

# site do fabricante por marca (a chave é procurada dentro do nome da marca)
FABRICANTE = {
    'ACDELCO': ['acdelco.com.br', 'acdelco.com'], 'AC DELCO': ['acdelco.com.br', 'acdelco.com'],
    'GM': ['chevrolet.com.br', 'acdelco.com.br'], 'CHEVROLET': ['chevrolet.com.br', 'acdelco.com.br'], 'GENERAL MOTORS': ['chevrolet.com.br'],
    'BOSCH': ['bosch.com.br', 'boschaftermarket.com'], 'MAHLE': ['mahle-aftermarket.com', 'mahle.com'], 'METAL LEVE': ['mahle-aftermarket.com'],
    'COFAP': ['cofap.com.br', 'marelli.com'], 'MAGNETI': ['magnetimarelli.com.br', 'marelli.com'], 'NAKATA': ['nakata.com.br'],
    'MONROE': ['monroe.com.br', 'monroe.com'], 'SKF': ['skf.com'], 'FRAS-LE': ['fras-le.com'], 'FRASLE': ['fras-le.com'],
    'TRW': ['trwaftermarket.com'], 'VALEO': ['valeo.com', 'valeoservice.com.br'], 'NGK': ['ngkntk.com.br'], 'DENSO': ['denso.com'],
    'GATES': ['gates.com'], 'CONTITECH': ['continental-aftermarket.com'], 'CONTINENTAL': ['continental-aftermarket.com'],
    'DAYCO': ['dayco.com'], 'SABO': ['sabo.com.br'], 'TECFIL': ['tecfil.com.br'], 'WEGA': ['wegamotors.com'], 'FRAM': ['fram.com.br'],
    'MANN': ['mann-filter.com'], 'SACHS': ['aftermarket.zf.com'], 'ZF': ['aftermarket.zf.com'], 'LUK': ['schaeffler.com.br'],
    'INA': ['schaeffler.com.br'], 'FAG': ['schaeffler.com.br'], 'MOURA': ['moura.com.br'], 'HELIAR': ['heliar.com.br'],
    'VIEMAR': ['viemar.com.br'], 'AXIOS': ['axios.com.br'], 'URBA': ['urba.com.br'], 'FERODO': ['ferodo.com.br'], 'COBREQ': ['cobreq.com.br'],
    'SYL': ['syl.com.br'], 'DS ': ['dstecnologia.com.br'], 'MTE': ['mte-thomson.com.br'], 'VETOR': ['vetorautopecas.com.br'],
    'KYB': ['kyb.com.br'], 'HIPPER': ['hipperfreios.com.br'], 'FREMAX': ['fremax.com.br'], 'BEHR': ['mahle-aftermarket.com'],
    'DELPHI': ['delphiautoparts.com'], 'VDO': ['vdo.com.br'], 'ARTEB': ['arteb.com.br'], 'ORIGINAL GM': ['chevrolet.com.br'],
}
MARKETPLACES = ('mercadolivre.com', 'mercadolibre.com', 'shopee.', 'amazon.', 'aliexpress.', 'ebay.', 'magazineluiza.', 'americanas.', 'casasbahia.')
VEICULOS = ['ONIX PLUS', 'ONIX', 'PRISMA', 'CRUZE', 'S10', 'TRACKER', 'SPIN', 'COBALT', 'CELTA', 'CORSA', 'AGILE', 'MONTANA', 'CAPTIVA',
            'EQUINOX', 'TRAILBLAZER', 'SONIC', 'ASTRA', 'VECTRA', 'ZAFIRA', 'MERIVA', 'CLASSIC', 'BLAZER', 'OMEGA', 'KADETT', 'MONZA',
            'IPANEMA', 'CAMARO', 'MALIBU', 'BOLT', 'SILVERADO', 'OPALA', 'CHEVETTE', 'JOY', 'D20', 'A20', 'C20', 'CALIBRA', 'TIGRA', 'SIERRA']
PARADAS = set('de da do das dos para p/ com e em a o as os no na ao kit un und unid peca peça pecas peças original novo nova pç pc cod cód código codigo ref'.split())
LOJAS_RUIDO = r'\s*[\|\-–—]\s*(mercado\s*livre|mercadolivre|shopee|amazon(\.com\.br)?|loja.*|.*pe[çc]as.*|.*auto.*|.*store.*|frete gr[áa]tis)\s*$'


def log(*a):
    print(*a, flush=True)


def get(url, n=3_000_000):
    time.sleep(0.5)
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'pt-BR,pt;q=0.9',
                                               'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, r.read(n).decode('utf-8', 'ignore'), r.geturl()
    except Exception as e:
        return getattr(e, 'code', 0), '', url


def norm(c):
    return re.sub(r'[^A-Z0-9]', '', str(c).upper())


def sem_acento(t):
    return ''.join(ch for ch in unicodedata.normalize('NFD', t) if unicodedata.category(ch) != 'Mn')


def texto_html(page):
    page = re.sub(r'(?is)<(script|style|noscript|svg)[^>]*>.*?</\1>', ' ', page)
    page = re.sub(r'(?i)<br\s*/?>|</(p|div|li|tr|h\d|td|th)>', '\n', page)
    t = H.unescape(re.sub(r'<[^>]+>', ' ', page))
    t = re.sub(r'[ \t\r\f\v]+', ' ', t)
    return re.sub(r'\n\s*\n+', '\n', t).strip()


def dominio(u):
    return urllib.parse.urlparse(u).netloc.lower().removeprefix('www.')


# ---------------- busca na web (DuckDuckGo, versão HTML) ----------------
def ddg(q):
    st, b, _ = get('https://html.duckduckgo.com/html/?kl=br-pt&q=' + urllib.parse.quote(q))
    out = []
    for m in re.finditer(r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>(.*?)(?=<a[^>]+class="result__a"|$)', b, re.S):
        href, tit, resto = m.group(1), m.group(2), m.group(3)
        if 'uddg=' in href:
            href = urllib.parse.unquote(re.search(r'uddg=([^&]+)', href).group(1))
        if href.startswith('//'):
            href = 'https:' + href
        if 'duckduckgo.com/y.js' in href or not href.startswith('http'):
            continue  # anúncio
        sn = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', resto, re.S)
        out.append({'url': href, 'titulo': texto_html(tit), 'trecho': texto_html(sn.group(1)) if sn else ''})
    return st, out


# ---------------- leitura das páginas ----------------
def jsonld(page):
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
                t = x.get('@type')
                if t == 'Product' or (isinstance(t, list) and 'Product' in t):
                    out.append(x)
                pilha.extend(v for v in x.values() if isinstance(v, (dict, list)))
    return out


def meta(page, nome):
    m = re.search(r'<meta[^>]+(?:property|name)="' + re.escape(nome) + r'"[^>]+content="([^"]*)"', page, re.I) or \
        re.search(r'<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="' + re.escape(nome) + r'"', page, re.I)
    return H.unescape(m.group(1)).strip() if m else ''


UN_CM = {'mm': 0.1, 'cm': 1.0, 'm': 100.0, 'pol': 2.54, '"': 2.54}


def num(s):
    s = s.strip()
    if ',' in s and '.' in s:
        s = s.replace('.', '').replace(',', '.')
    else:
        s = s.replace(',', '.')
    try:
        return float(s)
    except ValueError:
        return None


def medidas_texto(t):
    """Lista de (c, l, a, tipo) em cm achadas no texto."""
    achados = []
    tl = sem_acento(t.lower())
    # campos separados: comprimento / largura / altura (procura um bloco curto com os três)
    rx = {'c': r'(?:comprimento|profundidade|compr\.?)', 'l': r'(?:largura|larg\.?)', 'a': r'(?:altura|alt\.?)'}
    for m in re.finditer(r'(comprimento|profundidade|largura|altura)', tl):
        bloco = tl[max(0, m.start() - 60): m.start() + 260]
        vals = {}
        for k, r in rx.items():
            mm = re.search(r + r'[^0-9\n]{0,30}?(\d+(?:[.,]\d+)?)\s*(mm|cm|m|pol)\b', bloco)
            if mm and num(mm.group(1)):
                vals[k] = num(mm.group(1)) * UN_CM[mm.group(2)]
        if len(vals) == 3:
            tipo = 'embalagem' if re.search(r'embalag|caixa|pacote', bloco) else 'produto'
            achados.append((round(vals['c'], 1), round(vals['l'], 1), round(vals['a'], 1), tipo))
    # formato 30 x 20 x 10 cm
    for m in re.finditer(r'(\d+(?:[.,]\d+)?)\s*(?:mm|cm)?\s*x\s*(\d+(?:[.,]\d+)?)\s*(?:mm|cm)?\s*x\s*(\d+(?:[.,]\d+)?)\s*(mm|cm|m)\b', tl):
        ctx = tl[max(0, m.start() - 80): m.start()]
        if not re.search(r'dimens|medida|tamanho|embalag|c\s*x\s*l\s*x\s*a', ctx):
            continue
        f = UN_CM[m.group(4)]
        vs = [num(m.group(i)) for i in (1, 2, 3)]
        if all(vs):
            tipo = 'embalagem' if re.search(r'embalag|caixa|pacote', ctx) else 'produto'
            achados.append((round(vs[0] * f, 1), round(vs[1] * f, 1), round(vs[2] * f, 1), tipo))
    for m in re.finditer(r'(dimens\w*|medidas?|tamanho)\s*(?:\(([clap])\s*x\s*([clap])\s*x\s*([clap])\)|([clap])\s*x\s*([clap])\s*x\s*([clap]))?\s*[:\-]?\s*'
                         r'(\d+(?:[.,]\d+)?)\s*x\s*(\d+(?:[.,]\d+)?)\s*x\s*(\d+(?:[.,]\d+)?)\s*(mm|cm|m)?(?![\dx])', tl):
        ordem = [m.group(i) for i in (2, 3, 4)] if m.group(2) else ([m.group(i) for i in (5, 6, 7)] if m.group(5) else ['c', 'l', 'a'])
        ordem = ['c' if o == 'p' else o for o in ordem]
        vs = [num(m.group(i)) for i in (8, 9, 10)]
        if sorted(ordem) != ['a', 'c', 'l'] or not all(vs):
            continue
        f = UN_CM[m.group(11)] if m.group(11) else 1.0
        d = dict(zip(ordem, vs))
        ctx = tl[max(0, m.start() - 60): m.end() + 20]
        tipo = 'embalagem' if re.search(r'embalag|caixa|pacote', ctx) else 'produto'
        achados.append((round(d['c'] * f, 1), round(d['l'] * f, 1), round(d['a'] * f, 1), tipo))
    return [a for a in dict.fromkeys(achados) if all(0.1 <= x <= 300 for x in a[:3])]


def peso_texto(t):
    tl = sem_acento(t.lower())
    for m in re.finditer(r'peso(?: liquido| bruto| aproximado)?\s*(?:\(kg\)|\(g\))?[^0-9\n]{0,15}(\d+(?:[.,]\d+)?)\s*(kg|g|gramas|quilos)\b', tl):
        v = num(m.group(1))
        if v:
            kg = v / 1000 if m.group(2) in ('g', 'gramas') else v
            if 0.001 <= kg <= 500:
                return round(kg, 3)
    return None


def medida_ld(p):
    def qv(v):
        if isinstance(v, dict):
            n, u = num(str(v.get('value', ''))), str(v.get('unitCode') or v.get('unitText') or 'cm').lower()
            f = {'mmt': 0.1, 'mm': 0.1, 'cmt': 1, 'cm': 1, 'mtr': 100, 'm': 100}.get(u, 1)
            return n * f if n else None
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, str):
            m = re.match(r'\s*(\d+(?:[.,]\d+)?)\s*(mm|cm|m)?', v)
            return num(m.group(1)) * UN_CM.get(m.group(2) or 'cm', 1) if m else None
        return None
    c, l, a = qv(p.get('depth')), qv(p.get('width')), qv(p.get('height'))
    if c and l and a and all(0.1 <= x <= 300 for x in (c, l, a)):
        return (round(c, 1), round(l, 1), round(a, 1), 'produto')
    return None


def aplicacao_texto(t):
    out = []
    for m in re.finditer(r'(?im)^\s*(?:aplica[çc][ãa]o(?: do produto)?|compat[ií]vel com|ve[ií]culos? compat[ií]ve(?:l|is)|serve (?:no|nos|para))\s*[:\-]?\s*(.{6,400})$', t):
        v = m.group(1).strip(' :-')
        if len(v) >= 6 and not re.search(r'(?i)consulte|verifique|chassi', v[:30]):
            out.append(v[:400])
    return out


def veiculos(t):
    """{modelo: set(anos)} citados no texto."""
    tu = sem_acento(t.upper())
    achou = {}
    for v in VEICULOS:
        for m in re.finditer(r'(?<![A-Z0-9])' + re.escape(v) + r'(?![A-Z0-9])', tu):
            if v == 'ONIX' and tu[m.end():m.end() + 5] == ' PLUS':
                continue
            anos = set()
            depois = tu[m.end(): m.end() + 60]
            r = re.search(r'((?:19|20)\d{2})\s*(?:A|ATE|-|/|À|AO)\s*((?:19|20)\d{2})', depois)
            if r:
                a0, a1 = int(r.group(1)), int(r.group(2))
                if 1960 < a0 <= a1 <= 2035:
                    anos.add(f'{a0}-{a1}')
            else:
                r = re.search(r'^[^0-9]{0,25}((?:19|20)\d{2})(?!\d)', depois)
                if r:
                    anos.add(r.group(1))
            achou.setdefault(v, set()).update(anos)
    return achou


def limpar_desc(d):
    linhas = [l.strip() for l in d.split('\n')]
    linhas = [l for l in linhas if l and not re.search(r'(?i)nova chevrolet|loja oficial|chevroletnova', l)]
    return '\n'.join(linhas)


def limpar_titulo(t):
    t = re.sub(LOJAS_RUIDO, '', H.unescape(t or '').strip(), flags=re.I)
    t = re.sub(r'\s+', ' ', t).strip(' -|')
    return t


# ---------------- fotos ----------------
def img_tamanho(url):
    """(largura, altura, bytes lidos) lendo só o começo do arquivo; None se não for imagem."""
    time.sleep(0.3)
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': 'image/*', 'Range': 'bytes=0-65535'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            ct = r.headers.get('Content-Type', '')
            b = r.read(65536)
    except Exception:
        return None
    try:
        if b[:8] == b'\x89PNG\r\n\x1a\n':
            return int.from_bytes(b[16:20], 'big'), int.from_bytes(b[20:24], 'big')
        if b[:3] == b'GIF':
            return int.from_bytes(b[6:8], 'little'), int.from_bytes(b[8:10], 'little')
        if b[:4] == b'RIFF' and b[8:12] == b'WEBP':
            k = b[12:16]
            if k == b'VP8X':
                return 1 + int.from_bytes(b[24:27], 'little'), 1 + int.from_bytes(b[27:30], 'little')
            if k == b'VP8 ':
                return int.from_bytes(b[26:28], 'little') & 0x3fff, int.from_bytes(b[28:30], 'little') & 0x3fff
            if k == b'VP8L':
                v = int.from_bytes(b[21:25], 'little')
                return (v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1
        if b[:2] == b'\xff\xd8':
            i = 2
            while i + 9 < len(b):
                if b[i] != 0xFF:
                    i += 1; continue
                m = b[i + 1]
                if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    return int.from_bytes(b[i + 7:i + 9], 'big'), int.from_bytes(b[i + 5:i + 7], 'big')
                if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:
                    i += 2; continue
                i += 2 + int.from_bytes(b[i + 2:i + 4], 'big')
    except Exception:
        return None
    return None


def ddg_imagens(pn):
    """Busca de imagens do DuckDuckGo: [{url, w, h, pagina, titulo}] cujo título ou página citam o código."""
    st, b, _ = get('https://duckduckgo.com/?q=' + urllib.parse.quote(f'"{pn}"') + '&iax=images&ia=images')
    m = re.search(r'vqd=["\']?([\d-]+)', b)
    if not m:
        return []
    time.sleep(0.5)
    req = urllib.request.Request('https://duckduckgo.com/i.js?l=br-pt&o=json&f=,,,,,&p=1&q=' + urllib.parse.quote(f'"{pn}"') + '&vqd=' + m.group(1),
                                 headers={'User-Agent': UA, 'Referer': 'https://duckduckgo.com/', 'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            d = json.loads(r.read(3_000_000).decode('utf-8', 'ignore'))
    except Exception:
        return []
    out = []
    for x in d.get('results') or []:
        if norm(pn) not in norm(str(x.get('title', '')) + ' ' + str(x.get('url', ''))):
            continue
        out.append({'url': x.get('image'), 'w': int(x.get('width') or 0), 'h': int(x.get('height') or 0), 'pagina': x.get('url') or '', 'titulo': x.get('title') or ''})
    return out


def escolher_fotos(cands, n=3):
    """As n melhores fotos: maior resolução (lado menor de pelo menos 300 px), sem repetir a mesma imagem."""
    vistos, medidas = set(), 0
    for c in cands:
        if (not c.get('w') or not c.get('h')) and medidas < 14:
            t = img_tamanho(c['url']); medidas += 1
            if t:
                c['w'], c['h'] = t
    boas = [c for c in cands if c.get('w') and c.get('h') and min(c['w'], c['h']) >= 300 and max(c['w'], c['h']) / max(1, min(c['w'], c['h'])) <= 2.5]
    boas.sort(key=lambda c: (-(c['w'] * c['h']), c.get('ordem', 9)))
    out, fontes_usadas = [], Counter()
    for c in boas:
        chave = re.sub(r'(\?.*$)|(-\d+-\d+)|(_\d+x\d+)', '', c['url'].lower()).rsplit('/', 1)[-1]
        tam = (c['w'], c['h'])
        if chave in vistos:
            continue
        # no máximo 2 fotos da mesma fonte, para variar os ângulos
        if fontes_usadas[c.get('dominio', '')] >= 2 and len(boas) > n:
            continue
        vistos.add(chave); fontes_usadas[c.get('dominio', '')] += 1
        out.append({k: c.get(k) for k in ('url', 'w', 'h', 'fonte', 'pagina', 'dominio')})
        if len(out) >= n:
            break
    return out


# ---------------- fontes próprias ----------------
def catalogo(cur, pn):
    cur.execute("""select p.nome, dm.valor, dc.valor, da.valor, dmo.valor
                   from public.bi_produto p
                   left join public.bi_dim dm on dm.tipo = 'marca' and dm.id = p.marca
                   left join public.bi_dim dc on dc.tipo = 'categoria' and dc.id = p.categoria
                   left join public.bi_dim da on da.tipo = 'aplicacao' and da.id = p.aplicacao
                   left join public.bi_dim dmo on dmo.tipo = 'montadora' and dmo.id = p.montadora
                   where upper(p.pn) = %s limit 1""", (pn,))
    r = cur.fetchone()
    return dict(zip(['nome', 'marca', 'categoria', 'aplicacao', 'montadora'], r)) if r else {}


def vtex(pn):
    st, b, _ = get('https://loja.chevroletnova.com.br/api/catalog_system/pub/products/search?ft=' + urllib.parse.quote(pn))
    try:
        ps = json.loads(b)
    except Exception:
        return None
    for p in ps:
        refs = {norm(r) for r in str(p.get('productReference') or '').split('|')}
        if norm(pn) in refs or norm(pn) in norm(p.get('productName', '')):
            specs = {k: p.get(k) for k in (p.get('allSpecifications') or []) if p.get(k)}
            return {'titulo': p.get('productName') or '', 'marca': p.get('brand') or '', 'url': p.get('link') or '',
                    'descricao': texto_html(p.get('description') or ''), 'specs': specs,
                    'categorias': p.get('categories') or [],
                    'imagens': [im.get('imageUrl') for it in (p.get('items') or [])[:1] for im in (it.get('images') or []) if im.get('imageUrl')]}
    return None


def peca_chevrolet(pn):
    st, b, _ = get(f'https://api.pecachevroletapi.com/api/v1/dealers/-/parts/{urllib.parse.quote(pn)}?latitude=-23.550413&longitude=-46.633904')
    try:
        ds = json.loads(b)
    except Exception:
        return 0
    return len(ds) if isinstance(ds, list) else 0


# ---------------- pesquisa ----------------
def pesquisar(pn, cat):
    pnn = norm(pn)
    marca = (cat.get('marca') or '').upper()
    fontes = []          # {titulo, url, dominio, tipo, usado:set}
    titulos = []         # (titulo, peso, indice da fonte)
    medidas = []         # (c, l, a, tipo, indice)
    aplics = []          # (texto, indice)
    veic = defaultdict(lambda: {'anos': set(), 'fontes': set()})
    descricoes = []      # (texto, indice)
    pesos = []           # (kg, indice)
    fotos = []           # {url, w, h, fonte, pagina, dominio, ordem}

    def fonte(titulo, url, tipo):
        fontes.append({'titulo': titulo[:160], 'url': url, 'dominio': dominio(url) if url else '', 'tipo': tipo, 'usado': set()})
        return len(fontes) - 1

    def somar_veic(texto, i):
        for v, anos in veiculos(texto).items():
            veic[v]['anos'] |= anos
            veic[v]['fontes'].add(i)

    # 1) nosso catálogo e nossa loja
    if cat.get('nome'):
        i = fonte('Cadastro interno (base do painel)', '', 'interno')
        titulos.append((cat['nome'], 0.5, i))
        if cat.get('aplicacao') and cat['aplicacao'] not in ('-', 'SEM APLICACAO', 'SEM APLICAÇÃO'):
            aplics.append((cat['aplicacao'], i)); fontes[i]['usado'].add('aplicacao')
        somar_veic(cat['nome'], i)
    v = vtex(pn)
    if v:
        i = fonte('Nossa loja (VTEX): ' + v['titulo'], v['url'], 'loja')
        titulos.append((v['titulo'], 1.0, i)); fontes[i]['usado'].add('descricao')
        if not marca and v.get('marca'):
            marca = v['marca'].upper()
        sp = v['specs']
        for k, u in enumerate(v.get('imagens') or []):
            fotos.append({'url': u, 'fonte': i, 'pagina': v['url'], 'dominio': dominio(v['url']), 'ordem': 0})
        if sp.get('Aplicação do Produto'):
            aplics.append((texto_html('; '.join(sp['Aplicação do Produto'])).replace('\n', ' '), i)); fontes[i]['usado'].add('aplicacao')
        if sp.get('Modelo do Veículo'):
            anos = sp.get('Ano do Veículo') or []
            for mo in sp['Modelo do Veículo']:
                k = sem_acento(mo.upper()).strip()
                veic[k]['fontes'].add(i)
                anos_i = sorted(int(a) for a in anos if str(a).isdigit())
                if anos_i:
                    veic[k]['anos'].add(f'{anos_i[0]}-{anos_i[-1]}' if anos_i[0] != anos_i[-1] else str(anos_i[0]))
            fontes[i]['usado'].add('aplicacao')
        if v['descricao']:
            descricoes.append((v['descricao'], i))
            pk = peso_texto(v['descricao'])
            if pk:
                pesos.append((pk, i))
            for m in medidas_texto(v['descricao']):
                medidas.append((*m, i)); fontes[i]['usado'].add('medidas')
            for a in aplicacao_texto(v['descricao']):
                aplics.append((a, i)); fontes[i]['usado'].add('aplicacao')
            somar_veic(v['descricao'], i)
        somar_veic(v['titulo'], i)
    n_pc = peca_chevrolet(pn)
    if n_pc:
        fonte(f'Peça Chevrolet: código encontrado em {n_pc} concessionária(s) GM', f'https://www.pecachevrolet.com.br/pesquisa/?q={urllib.parse.quote(pn)}', 'fabricante')

    # 2) buscas na web
    nome_curto = ' '.join((cat.get('nome') or (v or {}).get('titulo') or '').split()[:3])
    buscas = [('web', f'"{pn}"'), ('mercadolivre', f'{pn} site:mercadolivre.com.br'), ('web', f'{pn} {nome_curto} medidas dimensões aplicação')]
    doms_fab = []
    for k, ds in FABRICANTE.items():
        if k in marca + ' ':
            doms_fab += [d for d in ds if d not in doms_fab]
    for d in doms_fab[:2]:
        buscas.append(('fabricante', f'{pn} site:{d}'))
    if marca and not doms_fab:
        buscas.append(('fabricante', f'{pn} {marca} fabricante catálogo'))
    resultados, vistos = [], set()
    n_busca = 0
    for tipo, q in buscas:
        st, rs = ddg(q)
        n_busca += 1
        for r in rs[:10]:
            u = r['url'].split('#')[0]
            if u in vistos:
                continue
            vistos.add(u)
            d = dominio(u)
            t = 'mercadolivre' if 'mercadolivre' in d or 'mercadolibre' in d else ('fabricante' if any(d.endswith(x) for x in doms_fab) else
                 ('fabricante' if tipo == 'fabricante' and marca and norm(marca.split()[0]) in norm(d) else 'web'))
            r['tipo'] = t
            resultados.append(r)
    log(f'buscas: {n_busca}, resultados: {len(resultados)}')

    # títulos dos anúncios do Mercado Livre e dos demais resultados (o código precisa aparecer no título, no trecho ou no endereço)
    for r in resultados:
        alvo = norm(r['titulo'] + ' ' + r['trecho'] + ' ' + r['url'])
        if pnn not in alvo:
            continue
        r['bate'] = True
        if r['tipo'] == 'mercadolivre':
            i = fonte('Mercado Livre: ' + limpar_titulo(r['titulo']), r['url'], 'mercadolivre')
            titulos.append((limpar_titulo(r['titulo']), 1.3, i)); fontes[i]['usado'].add('descricao')
            somar_veic(r['titulo'] + ' ' + r['trecho'], i)
            for m in medidas_texto(r['trecho']):
                medidas.append((*m, i)); fontes[i]['usado'].add('medidas')
            if veiculos(r['titulo'] + ' ' + r['trecho']):
                fontes[i]['usado'].add('aplicacao')

    # 3) páginas (fabricante primeiro, depois lojas; o Mercado Livre pede login para robôs)
    ordem = sorted([r for r in resultados if r.get('bate') or r['tipo'] == 'fabricante'],
                   key=lambda r: (r['tipo'] != 'fabricante', r['tipo'] == 'mercadolivre', any(x in dominio(r['url']) for x in MARKETPLACES),
                                  not dominio(r['url']).endswith('.br')))
    lidas = 0
    for r in ordem:
        if lidas >= MAX_PAGINAS:
            break
        if r['tipo'] == 'mercadolivre' or dominio(r['url']).endswith('chevroletnova.com.br'):
            continue
        st, page, final = get(r['url'])
        if st != 200 or not page or re.search(r'account-verification|/registration|captcha', final):
            continue
        lidas += 1
        txt = texto_html(page)
        if pnn not in norm(txt) and pnn not in norm(final):
            continue
        prods = jsonld(page)
        imgs = []
        for p in prods:
            im = p.get('image')
            for x in (im if isinstance(im, list) else [im]):
                if isinstance(x, dict):
                    x = x.get('url') or x.get('contentUrl')
                if isinstance(x, str) and x.startswith('http'):
                    imgs.append(x)
        og = meta(page, 'og:image')
        if og.startswith('//'):
            og = 'https:' + og
        if og.startswith('http'):
            imgs.append(og)
        titulo = limpar_titulo((prods[0].get('name') if prods else '') or meta(page, 'og:title') or r['titulo'])
        i = fonte(('Fabricante: ' if r['tipo'] == 'fabricante' else '') + (titulo or r['titulo']), final, r['tipo'])
        for u in list(dict.fromkeys(imgs))[:4]:
            if not re.search(r'(?i)logo|banner|sprite|placeholder|sem-foto|no-image', u):
                fotos.append({'url': u, 'fonte': i, 'pagina': final, 'dominio': dominio(final), 'ordem': 1 if r['tipo'] == 'fabricante' else 2})
        if titulo:
            titulos.append((titulo, 1.2 if r['tipo'] == 'fabricante' else 1.0, i)); fontes[i]['usado'].add('descricao')
        for p in prods:
            m = medida_ld(p)
            if m:
                medidas.append((*m, i)); fontes[i]['usado'].add('medidas')
            props = p.get('additionalProperty') or []
            if isinstance(props, dict):
                props = [props]
            linhas = '\n'.join(f"{x.get('name')}: {x.get('value')}" for x in props if isinstance(x, dict))
            if linhas:
                txt = linhas + '\n' + txt
            if isinstance(p.get('description'), str) and len(p['description']) > 40:
                descricoes.append((texto_html(p['description']), i))
        desc_meta = meta(page, 'og:description') or meta(page, 'description')
        if desc_meta and len(desc_meta) > 40 and not prods:
            descricoes.append((desc_meta, i))
        for m in medidas_texto(txt):
            medidas.append((*m, i)); fontes[i]['usado'].add('medidas')
        pk = peso_texto(txt)
        if pk:
            pesos.append((pk, i))
        for a in aplicacao_texto(txt):
            aplics.append((a, i)); fontes[i]['usado'].add('aplicacao')
        # veículos só do trecho perto do código (o resto da página costuma ter menus com todos os modelos)
        for m in re.finditer(re.escape(pn), txt, re.I):
            somar_veic(txt[max(0, m.start() - 300): m.end() + 600], i)
        if any(i in x['fontes'] for x in veic.values()):
            fontes[i]['usado'].add('aplicacao')
    # busca de imagens (resolução já vem no resultado)
    for x in ddg_imagens(pn)[:12]:
        if not x.get('url'):
            continue
        i = None
        for k, f in enumerate(fontes):
            if f['url'] and f['url'] == x['pagina']:
                i = k
        if i is None:
            i = fonte('Imagem: ' + limpar_titulo(x['titulo'] or dominio(x['pagina'])), x['pagina'], 'mercadolivre' if 'mercadoli' in dominio(x['pagina']) else 'web')
        fotos.append({'url': x['url'], 'w': x['w'], 'h': x['h'], 'fonte': i, 'pagina': x['pagina'], 'dominio': dominio(x['pagina']), 'ordem': 3})
    escolhidas = escolher_fotos(fotos)
    for ft in escolhidas:
        fontes[ft['fonte']]['usado'].add('fotos')
    log(f'fotos candidatas: {len(fotos)}, escolhidas: {len(escolhidas)}')
    log(f'páginas lidas: {lidas}, fontes usadas: {len(fontes)}, títulos: {len(titulos)}, medidas: {len(medidas)}, aplicações: {len(aplics)}')

    res = montar(pn, marca, cat, v, fontes, titulos, medidas, aplics, veic, descricoes, resultados, pesos)
    res['fotos'] = escolhidas
    return res


# ---------------- montagem da sugestão ----------------
def tokens(t):
    return [w for w in re.findall(r'[A-Za-zÀ-ÿ0-9][A-Za-zÀ-ÿ0-9/\-\.]*', t) if sem_acento(w.lower()) not in PARADAS and len(w) > 1]


SIGLAS = {'GM': 'GM', 'ACDELCO': 'ACDelco', 'AC-DELCO': 'ACDelco', 'NGK': 'NGK', 'SKF': 'SKF', 'TRW': 'TRW', 'KYB': 'KYB', 'MTE': 'MTE',
          'ABS': 'ABS', 'LED': 'LED', 'SUV': 'SUV', 'DOHC': 'DOHC', 'SOHC': 'SOHC', 'MPFI': 'MPFI', 'LT': 'LT', 'LTZ': 'LTZ', 'LS': 'LS', 'ZF': 'ZF'}


def titulo_bonito(t):
    pal = []
    for w in t.split():
        if w.upper() in SIGLAS:
            pal.append(SIGLAS[w.upper()])
        elif re.search(r'\d', w) or (w.isupper() and len(w) <= 4 and w not in ('PARA', 'COM', 'KIT')) or w.upper() in VEICULOS:
            pal.append(w.upper() if w.upper() in VEICULOS or re.search(r'\d', w) else w)
        elif sem_acento(w.lower()) in PARADAS:
            pal.append(w.lower())
        else:
            pal.append(w[:1].upper() + w[1:].lower())
    s = ' '.join(pal)
    return s[:1].upper() + s[1:]


def cortar(t, n=LIMITE_TITULO):
    if len(t) <= n:
        return t
    return t[:n].rsplit(' ', 1)[0].rstrip(' -,/')


def marca_curta(marca):
    m = re.sub(r'(?i)pe[çc]as|genu[ií]nas?|originais|original|\bdo brasil\b', ' ', marca or '').split()
    if not m:
        return ''
    w = m[-1] if m[-1].upper() == 'GM' else m[0]
    return SIGLAS.get(w.upper(), w.title() if len(w) > 4 else w.upper())


def montar(pn, marca, cat, v, fontes, titulos, medidas, aplics, veic, descricoes, resultados, pesos):
    # termos que mais se repetem entre fontes diferentes
    df = Counter()
    for t, peso, i in titulos:
        for w in set(sem_acento(x.lower()) for x in tokens(t)):
            df[w] += peso
    cands = []
    for t, peso, i in titulos:
        if not t:
            continue
        tk = [sem_acento(x.lower()) for x in tokens(t)]
        if not tk:
            continue
        cobertura = sum(df[w] for w in set(tk))
        s = cobertura * peso / (1 + max(0, len(t) - LIMITE_TITULO) / 12)
        if norm(pn) in norm(t):
            s *= 1.15
        cands.append((s, t, i))
    cands.sort(key=lambda x: -x[0])

    # aplicação: veículos citados por mais fontes primeiro
    vs = sorted(veic.items(), key=lambda kv: (-len(kv[1]['fontes']), kv[0]))
    lista_v = []
    for k, x in vs:
        anos = sorted(x['anos'], key=lambda a: (len(a), a))
        lista_v.append({'modelo': k.title() if not re.search(r'\d', k) else k, 'anos': anos[:3], 'fontes': len(x['fontes'])})
    aplic_txt = []
    for a, i in aplics:
        a = re.sub(r'\s+', ' ', texto_html(a)).strip(' •;-')
        if a and all(sem_acento(a.lower()) != sem_acento(b.lower()) for b, _ in aplic_txt):
            aplic_txt.append((a, i))

    # melhor título: o candidato mais bem pontuado, completado com marca, aplicação e código quando couber
    melhor = ''
    if cands:
        base = limpar_titulo(cands[0][1])
        base = re.sub(r'(?i)\b' + re.escape(pn) + r'\b', '', base).strip(' -')
        extra = []
        bu = sem_acento(base.upper())
        mc = marca_curta(marca)
        if mc and sem_acento(mc.upper()) not in bu.replace('-', ''):
            extra.append(mc)
        top_v = [x['modelo'] for x in lista_v[:2] if sem_acento(x['modelo'].upper()) not in bu]
        if top_v and not any(sem_acento(x['modelo'].upper()) in bu for x in lista_v[:3]):
            extra.append(' '.join(top_v))
        melhor = titulo_bonito(base)
        for e in extra:
            if len(melhor) + len(e) + 1 <= LIMITE_TITULO - len(pn) - 1:
                melhor += ' ' + e
        if len(melhor) + len(pn) + 1 <= LIMITE_TITULO:
            melhor += ' ' + pn
        melhor = cortar(melhor)
    alternativas = []
    for s, t, i in cands[:8]:
        t2 = cortar(titulo_bonito(limpar_titulo(t)))
        if t2 and t2.lower() != melhor.lower() and all(t2.lower() != a['texto'].lower() for a in alternativas):
            alternativas.append({'texto': t2, 'fonte': i})
        if len(alternativas) >= 4:
            break

    # medidas: a combinação que mais se repete (produto antes de embalagem)
    med = None
    if medidas:
        cont = Counter((c, l, a, tp) for c, l, a, tp, i in medidas)
        (c, l, a, tp), n = sorted(cont.items(), key=lambda kv: (kv[0][3] != 'produto', -kv[1]))[0]
        fts = sorted({i for c2, l2, a2, tp2, i in medidas if (c2, l2, a2, tp2) == (c, l, a, tp)})
        outras = [{'c': c2, 'l': l2, 'a': a2, 'tipo': tp2, 'fontes': nn} for (c2, l2, a2, tp2), nn in cont.most_common(4) if (c2, l2, a2, tp2) != (c, l, a, tp)]
        med = {'c': c, 'l': l, 'a': a, 'unidade': 'cm', 'tipo': tp, 'fontes': fts, 'outras': outras}

    # descrição longa para o anúncio
    desc_base = ''
    descricoes = [(limpar_desc(d), i) for d, i in descricoes]
    for d, i in sorted(descricoes, key=lambda x: (fontes[x[1]]['tipo'] != 'fabricante', fontes[x[1]]['tipo'] != 'loja', -min(len(x[0]), 1500))):
        d = re.sub(r'\s+\n', '\n', d).strip()
        if len(d) > 40:
            desc_base = d[:1500]
            fontes[i]['usado'].add('descricao')
            break
    linhas = [melhor or (cat.get('nome') or pn), '']
    if desc_base:
        linhas += [desc_base, '']
    linhas.append(f'Código: {pn}')
    if marca:
        linhas.append(f'Marca: {marca_curta(marca) or marca.title()}')
    if lista_v:
        linhas.append('Aplicação: ' + '; '.join(x['modelo'] + (' ' + ', '.join(x['anos']) if x['anos'] else '') for x in lista_v[:8]))
    elif aplic_txt:
        linhas.append('Aplicação: ' + aplic_txt[0][0])
    if med:
        linhas.append(f"Medidas{' da embalagem' if med['tipo'] == 'embalagem' else ''} (C x L x A): "
                      f"{fmt(med['c'])} x {fmt(med['l'])} x {fmt(med['a'])} cm")
    peso = Counter(p for p, i in pesos).most_common(1)[0][0] if pesos else None
    if peso:
        linhas.append(f'Peso: {fmt(peso)} kg')
    linhas.append('Confira a compatibilidade pelo chassi do veículo antes da compra.')

    fontes_out = []
    for f in fontes:
        f = dict(f, usado=sorted(f['usado']))
        fontes_out.append(f)
    return {
        'pn': pn, 'marca': marca, 'catalogo': cat,
        'titulo': melhor, 'alternativas': alternativas, 'descricao': '\n'.join(linhas).strip(),
        'medidas': med, 'peso': {'kg': peso, 'fontes': sorted({i for p, i in pesos if p == peso})} if peso else None, 'aplicacao': {'veiculos': lista_v[:15], 'textos': [{'texto': a, 'fonte': i} for a, i in aplic_txt[:6]]},
        'fontes': fontes_out,
        'buscas': {'resultados': len(resultados), 'com_codigo': sum(1 for r in resultados if r.get('bate'))},
        'links': {'google': 'https://www.google.com/search?q=' + urllib.parse.quote(f'"{pn}"'),
                  'mercadolivre': 'https://lista.mercadolivre.com.br/' + urllib.parse.quote(pn)},
    }


def fmt(x):
    return (f'{x:.1f}'.rstrip('0').rstrip('.')).replace('.', ',')


def main():
    pn = re.sub(r'\s+', ' ', (os.environ.get('PN') or '').strip().upper())
    if not pn or len(pn) > 40 or not re.match(r'^[A-Z0-9][A-Z0-9 ./_-]*$', pn):
        log('código inválido'); sys.exit(1)
    url = os.environ.get('SUPABASE_DB_URL')
    if not url or os.environ.get('SEM_BANCO') == '1':
        res = pesquisar(pn, {})
        if os.environ.get('MOSTRAR') == '1':
            log(json.dumps(res, ensure_ascii=False, indent=1)[:12000])
        return
    import psycopg
    with psycopg.connect(url, autocommit=True) as con, con.cursor() as cur:
        cur.execute("update public.bi_cadastro_sug set status = 'pesquisando', atualizado_em = now() where pn = %s", (pn,))
        try:
            res = pesquisar(pn, catalogo(cur, pn))
            cur.execute("""insert into public.bi_cadastro_sug (pn, status, dados, atualizado_em) values (%s, 'ok', %s, now())
                           on conflict (pn) do update set status = 'ok', dados = excluded.dados, erro = null, atualizado_em = now()""",
                        (pn, json.dumps(res, ensure_ascii=False)))
            log('gravado')
        except Exception as e:
            cur.execute("""insert into public.bi_cadastro_sug (pn, status, erro, atualizado_em) values (%s, 'erro', %s, now())
                           on conflict (pn) do update set status = 'erro', erro = excluded.erro, atualizado_em = now()""",
                        (pn, type(e).__name__))
            raise


if __name__ == '__main__':
    main()
