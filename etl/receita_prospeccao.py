"""Prospecção: empresas ativas do ramo automotivo (tabela bi_prospect do banco), a partir dos dados abertos de CNPJ da Receita.

Lê só os arquivos públicos da Receita Federal (Estabelecimentos, Empresas e Municípios); nada da base de clientes sai daqui.
  1. Estabelecimentos: fica com os ativos das UFs pedidas cujo CNAE principal (ou secundário) é do ramo.
  2. Empresas: razão social e porte desses CNPJs.
  3. Município da Receita -> código IBGE pelo nome (contornos em geo/UF.json).
  4. Troca de uma vez as linhas dessas UFs no banco. O log é público: mostra só contagens.

Variáveis: SUPABASE_DB_URL. Uso: python etl/receita_prospeccao.py [--ufs SP,MG] [--ref 2026-11]
"""
import csv
import io
import os
import re
import sys
import tempfile
import time
import zipfile
from datetime import date

import psycopg
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rede_geocodificar import chave, log, municipios, norm  # noqa: E402

BASES = ['https://arquivos.receitafederal.gov.br/dados/cnpj/dados_abertos_cnpj/',
         'https://dadosabertos.rfb.gov.br/CNPJ/dados_abertos_cnpj/']
if os.environ.get('RECEITA_BASE'):   # testes locais
    BASES = [os.environ['RECEITA_BASE']]
UA = {'User-Agent': 'nova-bi-prospeccao/1.0 (github.com/leandromarquescoelho-stack/nova)'}

# CNAE -> entra na lista. A descrição fica no site.
CNAES = {
    4530701, 4530703,                 # comércio de peças e acessórios: atacado, varejo
    4530702, 4530704,                 # pneus e câmaras: atacado, varejo
    4520001, 4520002, 4520003,        # mecânica; lanternagem/funilaria e pintura; elétrica
    4520004, 4520007,                 # alinhamento e balanceamento; instalação de acessórios
}
# do secundário só os principais do ramo (peças, mecânica, funilaria), para não inflar a lista
CNAES_SEC = {4530701, 4530703, 4520001, 4520002}
LIMITE = 400_000   # proteção do espaço do banco (plano gratuito)


def baixar(url, destino):
    for tent in range(4):
        try:
            with requests.get(url, headers=UA, stream=True, timeout=60, auth=AUTH[0]) as r:
                r.raise_for_status()
                with open(destino, 'wb') as f:
                    for bloco in r.iter_content(1 << 20):
                        f.write(bloco)
            return os.path.getsize(destino)
        except Exception as ex:  # noqa: BLE001
            log(f'falha ao baixar {url.rsplit("/", 1)[-1]} ({type(ex).__name__}); tentativa {tent + 1} de 4')
            time.sleep(15 * (tent + 1))
    raise SystemExit('não foi possível baixar os arquivos da Receita')


AUTH = [None]   # compartilhamento Nextcloud da Receita: usuário = token, senha vazia
HOST = 'https://arquivos.receitafederal.gov.br'
TOKENS = [t for t in (os.environ.get('RECEITA_TOKEN'), 'YggdBLfdninEJX9', 'gn672Ad4CF8N6TK') if t]


def _meses(ref):
    if ref:
        return [ref]
    h = date.today()
    return [f'{(h.year * 12 + h.month - 1 - k) // 12}-{(h.year * 12 + h.month - 1 - k) % 12 + 1:02d}' for k in range(4)]


def _existe(url, auth=None):
    try:
        r = requests.head(url, headers=UA, timeout=60, allow_redirects=True, auth=auth)
        return r.status_code
    except Exception as ex:  # noqa: BLE001
        return type(ex).__name__


def achar_pasta(ref):
    """URL da pasta do mês mais recente (ou do mês pedido) que tem os arquivos. O log mostra o que foi tentado."""
    # 1) endereço antigo (pastas AAAA-MM com listagem)
    for base in BASES:
        meses = []
        try:
            r = requests.get(base, headers=UA, timeout=60)
            log(f'{base} -> {r.status_code} ({r.url})')
            meses = sorted(set(re.findall(r'(\d{4}-\d{2})/', r.text)), reverse=True)
            achados = re.findall(r'/s/([A-Za-z0-9]{10,20})', r.url + ' ' + r.text)   # redireciona para um compartilhamento
            for t in achados:
                if t not in TOKENS:
                    TOKENS.insert(0, t)
        except Exception as ex:  # noqa: BLE001
            log(f'{base} -> {type(ex).__name__}')
        for m in ([ref] if ref else meses[:4] or _meses(None)):
            st = _existe(f'{base}{m}/Estabelecimentos0.zip')
            log(f'  {m}: {st}')
            if st == 200:
                return f'{base}{m}/', m
    # 2) compartilhamento Nextcloud (WebDAV público)
    for t in TOKENS:
        dav = f'{HOST}/public.php/webdav/'
        meses = []
        try:
            r = requests.request('PROPFIND', dav, headers={**UA, 'Depth': '1'}, auth=(t, ''), timeout=60)
            meses = sorted(set(re.findall(r'(\d{4}-\d{2})/?</d:href>', r.text)), reverse=True)
            log(f'compartilhamento {t[:4]}…: {r.status_code}; meses {",".join(meses[:3]) or "nenhum"}')
        except Exception as ex:  # noqa: BLE001
            log(f'compartilhamento {t[:4]}…: {type(ex).__name__}')
        for m in ([ref] if ref else meses[:4] or _meses(None)):
            st = _existe(f'{dav}{m}/Estabelecimentos0.zip', (t, ''))
            log(f'  {m}: {st}')
            if st == 200:
                AUTH[0] = (t, '')
                return f'{dav}{m}/', m
    raise SystemExit('pasta dos dados abertos de CNPJ não encontrada')


def linhas_zip(caminho):
    with zipfile.ZipFile(caminho) as z:
        for nome in z.namelist():
            with z.open(nome) as f:
                yield from csv.reader(io.TextIOWrapper(f, encoding='latin-1', newline=''), delimiter=';', quotechar='"')


def tel(ddd, num):
    ddd, num = re.sub(r'\D', '', ddd or ''), re.sub(r'\D', '', num or '')
    if not num:
        return None
    num = f'{num[:-4]}-{num[-4:]}' if len(num) > 4 else num
    return f'({ddd}) {num}' if ddd else num


def data8(s):
    s = (s or '').strip()
    return f'{s[:4]}-{s[4:6]}-{s[6:8]}' if len(s) == 8 and s.isdigit() and s != '00000000' else None


def main():
    args = sys.argv[1:]
    ufs = [u.strip().upper() for u in (args[args.index('--ufs') + 1] if '--ufs' in args else 'SP').split(',') if u.strip()]
    ref = args[args.index('--ref') + 1] if '--ref' in args else None
    url_db = os.environ.get('SUPABASE_DB_URL')
    if not url_db:
        raise SystemExit('SUPABASE_DB_URL não definida')
    with psycopg.connect(url_db) as conn:
        cur = conn.cursor()
        cur.execute("select to_regclass('public.bi_prospect') is not null")
        if not cur.fetchone()[0]:
            log('o banco ainda não tem a tabela de prospecção (rode prospeccao_receita.sql); nada a fazer')
            return
    pasta, mes = achar_pasta(ref)
    log(f'dados da Receita de {mes}; UFs: {",".join(ufs)}')
    tmp = tempfile.mkdtemp()

    # municípios da Receita (código próprio) -> nome
    p = os.path.join(tmp, 'mun.zip')
    baixar(pasta + 'Municipios.zip', p)
    mun_rf = {r[0].strip(): r[1].strip() for r in linhas_zip(p) if len(r) >= 2}
    os.remove(p)

    est, lidos = {}, 0
    for i in range(10):
        p = os.path.join(tmp, f'est{i}.zip')
        mb = baixar(f'{pasta}Estabelecimentos{i}.zip', p) / 1e6
        for r in linhas_zip(p):
            lidos += 1
            if len(r) < 28 or r[5] != '02' or r[19] not in ufs:
                continue
            try:
                cp = int(r[11] or 0)
            except ValueError:
                continue
            sec = False
            if cp not in CNAES:
                secs = [int(x) for x in (r[12] or '').split(',') if x.strip().isdigit()]
                achou = next((x for x in secs if x in CNAES_SEC), None)
                if achou is None:
                    continue
                cp, sec = achou, True
            end = ' '.join(x for x in (r[13].strip(), r[14].strip()) if x)
            if r[15].strip() and r[15].strip().upper() not in ('S/N', 'SN'):
                end += ', ' + r[15].strip()
            if r[16].strip():
                end += ' - ' + r[16].strip()
            tels = [t for t in (tel(r[21], r[22]), tel(r[23], r[24])) if t]
            est[r[0] + r[1] + r[2]] = [r[0], r[4].strip() or None, cp, sec, data8(r[10]), end or None, r[17].strip() or None,
                                       re.sub(r'\D', '', r[18]) or None, r[20].strip(), r[19], ' / '.join(dict.fromkeys(tels)) or None,
                                       (r[27].strip().lower() or None), r[3] == '1']
        os.remove(p)
        log(f'Estabelecimentos{i}: {mb:.0f} MB; {len(est)} empresas do ramo até aqui')
        if len(est) > LIMITE:
            raise SystemExit(f'mais de {LIMITE} empresas: limite de espaço do banco; reduza as UFs')
    log(f'{lidos} estabelecimentos lidos; {len(est)} ativos do ramo')

    basicos = {v[0] for v in est.values()}
    emp = {}
    for i in range(10):
        p = os.path.join(tmp, f'emp{i}.zip')
        baixar(f'{pasta}Empresas{i}.zip', p)
        for r in linhas_zip(p):
            if r and r[0] in basicos and len(r) >= 6:
                emp[r[0]] = (r[1].strip() or None, int(r[5]) if r[5].strip().isdigit() and r[5].strip() != '00' else None)
        os.remove(p)
    log(f'razão social de {len(emp)} empresas')

    sem_ibge, linhas = 0, []
    for cnpj, v in est.items():
        nome_mun = mun_rf.get(v[8], '')
        m = municipios(v[9]).get(chave(norm(nome_mun))) if nome_mun else None
        if not m:
            sem_ibge += 1
        rz, porte = emp.get(v[0], (None, None))
        nm = ' '.join(norm(nome_mun)) or None
        linhas.append((cnpj, rz, v[1], v[2], v[3], v[4], v[5], v[6], v[7], int(m[2]) if m else None, nm, v[9], v[10], v[11], porte, v[12]))
    log(f'{sem_ibge} sem município IBGE pelo nome (ficam pelo nome da Receita)')

    with psycopg.connect(url_db) as conn:
        cur = conn.cursor()
        cur.execute('create temp table _p (like public.bi_prospect) on commit drop')
        with cur.copy('copy _p (cnpj, razao, fantasia, cnae, sec, inicio, endereco, bairro, cep, ibge, municipio, uf, tel, email, porte, matriz) from stdin') as cp:
            for ln in linhas:
                cp.write_row(ln)
        cur.execute('delete from public.bi_prospect where uf = any(%s)', (ufs,))
        cur.execute('insert into public.bi_prospect select * from _p on conflict (cnpj) do nothing')
        cur.execute('select count(*) from public.bi_prospect')
        total = cur.fetchone()[0]
        cur.execute("""insert into public.bi_prospect_info (id, ref, linhas, em) values (1, %s, %s, now())
                       on conflict (id) do update set ref = excluded.ref, linhas = excluded.linhas, em = excluded.em""", (mes, total))
        conn.commit()
        cur.execute("select pg_size_pretty(pg_total_relation_size('public.bi_prospect')), pg_size_pretty(pg_database_size(current_database()))")
        t, db = cur.fetchone()
    log(f'gravadas {len(linhas)} empresas ({total} no total); tabela {t}, banco {db}')


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as ex:  # noqa: BLE001
        log(f'falha ({type(ex).__name__})')
        sys.exit(1)
