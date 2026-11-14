"""Frota pública da Senatran -> geo/frota.json (usado no mapa da guia Vendas > Regiões).

Fonte: portal de dados abertos do Ministério dos Transportes (dados.transportes.gov.br, CKAN, sem token).
  - Automóveis por município: planilha "frota por município e tipo" (coluna AUTOMOVEL).
  - Chevrolet por município: arquivo mensal do RENAVAM por UF/município/marca-modelo (modelos "GM/..." e "CHEV...").
Grava {"ref": mês, "m": {"UF|MUNICIPIONORMALIZADO": [automoveis, chevrolet, frota_total_marca_modelo]}}.
Só dados públicos; nada da empresa entra aqui.
"""
import io, json, re, sys, unicodedata, urllib.parse, urllib.request, zipfile, tempfile, os
from datetime import date

API = 'https://dados.transportes.gov.br/api/3/action/'
MESES = {'janeiro': 1, 'fevereiro': 2, 'marco': 3, 'abril': 4, 'maio': 5, 'junho': 6, 'julho': 7, 'agosto': 8,
         'setembro': 9, 'outubro': 10, 'novembro': 11, 'dezembro': 12}
UFS = {'AC','AL','AM','AP','BA','CE','DF','ES','GO','MA','MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN','RO','RR','RS','SC','SE','SP','TO'}
NOME_UF = {'acre':'AC','alagoas':'AL','amazonas':'AM','amapa':'AP','bahia':'BA','ceara':'CE','distrito federal':'DF','espirito santo':'ES',
  'goias':'GO','maranhao':'MA','minas gerais':'MG','mato grosso do sul':'MS','mato grosso':'MT','para':'PA','paraiba':'PB','pernambuco':'PE',
  'piaui':'PI','parana':'PR','rio de janeiro':'RJ','rio grande do norte':'RN','rondonia':'RO','roraima':'RR','rio grande do sul':'RS',
  'santa catarina':'SC','sergipe':'SE','sao paulo':'SP','tocantins':'TO'}


def sigla(v):
    v = str(v).strip().strip('"')
    if v.upper() in UFS:
        return v.upper()
    return NOME_UF.get(re.sub(r'\s+', ' ', sem_acento(v)).strip())


SAIDA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'geo', 'frota.json')


def sem_acento(s):
    return unicodedata.normalize('NFD', str(s)).encode('ascii', 'ignore').decode().lower()


def norm(s):
    return re.sub(r'[^A-Z0-9]', '', sem_acento(s).upper())


def num(v):
    """'1.0' -> 1; '1.234' -> 1234; '1.234,5' -> 1234.5; 12 -> 12."""
    if isinstance(v, (int, float)):
        return float(v)
    v = str(v).strip()
    if not v:
        return 0.0
    if ',' in v:
        return float(v.replace('.', '').replace(',', '.'))
    if re.fullmatch(r'\d{1,3}(\.\d{3})+', v):
        return float(v.replace('.', ''))
    return float(v)


def api(acao, **p):
    with urllib.request.urlopen(API + acao + '?' + urllib.parse.urlencode(p), timeout=120) as r:
        return json.load(r)['result']


def mes_do_nome(txt):
    t = sem_acento(txt)
    m = re.search(r'(janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)[^0-9]{0,3}(20\d\d)', t)
    if m:
        return date(int(m.group(2)), MESES[m.group(1)], 1)
    m = re.search(r'(20\d\d)[-_]?(0[1-9]|1[0-2])', t)
    return date(int(m.group(1)), int(m.group(2)), 1) if m else None


def recursos():
    vistos, out = set(), []
    for q in ['frota', 'renavam', 'frota de veiculos']:
        for pk in api('package_search', q=q, rows=100)['results']:
            if pk['name'] in vistos:
                continue
            vistos.add(pk['name'])
            print('pacote:', pk['name'], '|', len(pk.get('resources', [])), 'arquivos')
            for r in pk.get('resources', []):
                out.append(dict(r, pacote=pk['name']))
    return out


def baixar(url):
    """Baixa com curl (repete e retoma se a conexão cair: o portal derruba downloads longos)."""
    import subprocess
    print('baixando', url, flush=True)
    f = tempfile.NamedTemporaryFile(delete=False); f.close()
    for tentativa in range(8):
        r = subprocess.run(['curl', '-fsSL', '--retry', '5', '--retry-all-errors', '--retry-delay', '5', '-C', '-',
                            '-A', 'Mozilla/5.0', '-o', f.name, url])
        if r.returncode == 0:
            break
        print('  tentativa', tentativa + 1, 'falhou (curl', r.returncode, '), retomando...', flush=True)
    else:
        raise SystemExit('não foi possível baixar ' + url)
    print('  ', os.path.getsize(f.name), 'bytes')
    return f.name


def linhas_de(caminho):
    """Linhas de texto de um TXT/CSV, dentro ou fora de um ZIP (utf-8, com latin-1 de reserva)."""
    if zipfile.is_zipfile(caminho):
        z = zipfile.ZipFile(caminho)
        nomes = [n for n in z.namelist() if n.lower().endswith(('.txt', '.csv'))]
        fonte = z.open(nomes[0])
    else:
        fonte = open(caminho, 'rb')
    for b in fonte:
        try:
            yield b.decode('utf-8')
        except UnicodeDecodeError:
            yield b.decode('latin-1')


def chevrolet(rs):
    """Último arquivo RENAVAM por marca-modelo: soma por município a frota total e a Chevrolet."""
    cand = []
    for r in rs:
        txt = (r.get('name') or '') + ' ' + (r.get('url') or '')
        if not re.search(r'\.(zip|txt|csv)$', (r.get('url') or '').lower()):
            continue
        t = sem_acento(txt)
        if 'marca' not in t and 'renavam' not in r['pacote']:
            continue
        if 'tipo' in t or 'uf' == t.strip():
            continue
        d = mes_do_nome(txt)
        if d:
            cand.append((d, r['url']))
    if not cand:
        print('nenhum arquivo de marca-modelo encontrado')
        return None, {}
    ref, url = max(cand)
    arq = baixar(url)
    tot, chev, cab = {}, {}, None
    for i, ln in enumerate(linhas_de(arq)):
        c = [x.strip().strip('"') for x in ln.rstrip('\r\n').split(';')]
        if cab is None:
            cab = [sem_acento(x) for x in c]
            iu = next(k for k, x in enumerate(cab) if x == 'uf')
            im = next(k for k, x in enumerate(cab) if 'munic' in x)
            ik = next(k for k, x in enumerate(cab) if 'marca' in x)
            iq = len(cab) - 1 if not any('qtd' in x or 'quant' in x for x in cab) else next(k for k, x in enumerate(cab) if 'qtd' in x or 'quant' in x)
            print('colunas:', cab)
            continue
        if i <= 3:
            print('amostra:', c)
        if len(c) <= max(iu, im, ik, iq):
            continue
        uf = sigla(c[iu])
        if not uf:
            continue
        try:
            q = int(round(num(c[iq])))
        except ValueError:
            continue
        k = uf + '|' + norm(c[im])
        tot[k] = tot.get(k, 0) + q
        mm = c[ik].upper()
        if mm.startswith('GM/') or mm.startswith('CHEV') or mm.startswith('I/GM') or mm.startswith('I/CHEV') or mm.startswith('GM '):
            chev[k] = chev.get(k, 0) + q
    os.unlink(arq)
    print('marca-modelo', ref, len(tot), 'municípios; Chevrolet total', sum(chev.values()), 'de', sum(tot.values()))
    return ref, {k: (tot[k], chev.get(k, 0)) for k in tot}


def automoveis_govbr():
    """Páginas anuais da Senatran no gov.br: links de planilhas de frota por município e tipo."""
    import subprocess
    cand = []
    ano = date.today().year
    for a in (ano, ano - 1):
        for base in ('https://www.gov.br/transportes/pt-br/assuntos/transito/conteudo-Senatran/frota-de-veiculos-%d' % a,
                     'https://www.gov.br/transportes/pt-br/pt-br/assuntos/transito/conteudo-Senatran/frota-de-veiculos-%d' % a):
            r = subprocess.run(['curl', '-fsSL', '-A', 'Mozilla/5.0', '--max-time', '60', base], capture_output=True)
            if r.returncode != 0:
                print('gov.br sem página', base); continue
            html = r.stdout.decode('utf-8', 'ignore')
            for href, txt in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', html, flags=re.S):
                t = sem_acento(href + ' ' + re.sub('<[^>]+>', ' ', txt))
                arqn = sem_acento(href.split('/@@')[0].rsplit('/', 1)[-1])
                if 'munic' in arqn and 'tipo' in arqn and 'restricao' not in arqn and 'especie' not in arqn and re.search(r'\.(xlsx|xls|csv|zip)(/|$|\?)', href.lower()):
                    d = mes_do_nome(t) or date(a, 1, 1)
                    u = href if href.startswith('http') else 'https://www.gov.br' + href
                    print('gov.br:', d, u)
                    cand.append((d, u))
            if cand:
                break
    return cand


def automoveis(rs):
    """Planilha mais recente de frota por município e tipo: coluna AUTOMOVEL."""
    cand = []
    for r in rs:
        t = sem_acento((r.get('name') or '') + ' ' + (r.get('url') or ''))
        u = (r.get('url') or '').lower()
        if 'munic' in t and 'tipo' in t and re.search(r'\.(xlsx|xls|csv|zip)$', u):
            d = mes_do_nome(t)
            if d:
                cand.append((d, r['url']))
    if not cand:
        cand = automoveis_govbr()
    if not cand:
        print('nenhuma planilha de frota por município e tipo encontrada')
        return None, {}
    ref, url = max(cand)
    arq = baixar(url)
    import pandas as pd
    if re.search(r'\.xlsx?(/|$|\?)', url.lower()) or (zipfile.is_zipfile(arq) and any(n.startswith('xl/') for n in zipfile.ZipFile(arq).namelist())):
        bruto = pd.read_excel(arq, header=None, dtype=str)
    else:
        bruto = pd.DataFrame([l.rstrip('\r\n').split(';') for l in linhas_de(arq)])
    os.unlink(arq)
    # acha a linha de cabeçalho (a que tem AUTOMOVEL)
    h = next(i for i in range(min(40, len(bruto))) if any('automovel' == sem_acento(x).strip() for x in bruto.iloc[i].fillna('')))
    cab = [sem_acento(x).strip() for x in bruto.iloc[h].fillna('')]
    iu, im, ia = cab.index('uf'), next(k for k, x in enumerate(cab) if 'munic' in x), cab.index('automovel')
    out = {}
    for _, row in bruto.iloc[h + 1:].iterrows():
        uf = sigla(row[iu])
        if not uf:
            continue
        try:
            out[uf + '|' + norm(row[im])] = int(round(num(row[ia])))
        except ValueError:
            pass
    print('automóveis', ref, len(out), 'municípios; total', sum(out.values()))
    return ref, out


def main():
    rs = recursos()
    # tipos de arquivo publicados (sem mês/ano), para achar o de "município e tipo"
    tipos = {}
    for r in rs:
        n = re.sub(r'(janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro|20\d\d|\d+)', '#', sem_acento(r.get('name') or r.get('url') or ''))
        tipos.setdefault((r['pacote'], n), r.get('url'))
    for (pk, n), u in sorted(tipos.items()):
        if pk == 'registro-nacional-de-veiculos-automotores-renavam':
            print('arquivo:', n, '|', u)
    try:
        ref_a, auto = automoveis(rs)
    except Exception as e:  # sem a planilha de tipos, segue só com a Chevrolet
        import traceback; traceback.print_exc()
        print('automóveis: falhou', repr(e)); ref_a, auto = None, {}
    ref_c, mm = chevrolet(rs)
    if not auto and not mm:
        sys.exit('nada encontrado no portal: o layout pode ter mudado')
    m = {}
    for k in set(auto) | set(mm):
        t, c = mm.get(k, (0, 0))
        m[k] = [auto.get(k, 0), c, t]
    dados = {'ref_automoveis': ref_a.isoformat()[:7] if ref_a else None, 'ref_marca': ref_c.isoformat()[:7] if ref_c else None,
             'fonte': 'Senatran/RENAVAM - dados.transportes.gov.br', 'm': m}
    with open(SAIDA, 'w', encoding='utf-8') as f:
        json.dump(dados, f, separators=(',', ':'), ensure_ascii=False)
    print('gravado', SAIDA, len(m), 'municípios')


if __name__ == '__main__':
    main()
