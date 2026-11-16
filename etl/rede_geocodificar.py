"""Coordenadas da rede Chevrolet (tabela bi_rede do banco) para a camada "Concessionárias Chevrolet" do mapa.

A lista fica só no banco (não neste repositório público). Para cada loja ainda sem coordenada:
  1. endereço (logradouro e número) + cidade no OpenStreetMap (Nominatim);
  2. CEP no OpenStreetMap;
  3. CEP na BrasilAPI;
  4. sem nada disso, o centro do município (marcado como aproximado).
Um ponto só é aceito se cair dentro do município da loja (contornos do IBGE em geo/UF.json).
O log é público: mostra só contagens, nunca nomes ou endereços.

Variáveis: SUPABASE_DB_URL. Uso: python etl/rede_geocodificar.py [--todas]
"""
import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime, timezone

import psycopg
import requests

UA = {'User-Agent': 'nova-bi-mapa/1.0 (github.com/leandromarquescoelho-stack/nova)', 'Accept-Language': 'pt-BR'}
GEO = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'geo')
_ult = [0.0]


def log(msg):
    print(f'[{datetime.now(timezone.utc):%H:%M:%S}] {msg}', flush=True)


def norm(s):
    s = unicodedata.normalize('NFKD', str(s or ''))
    s = ''.join(c for c in s if not unicodedata.combining(c)).upper()
    return re.sub(r'[^A-Z0-9 ]', ' ', re.sub(r"[\'`´]", '', s)).split()


_ufs = {}


def municipios(uf):
    if uf not in _ufs:
        try:
            with open(os.path.join(GEO, f'{uf}.json'), encoding='utf-8') as f:
                _ufs[uf] = {chave(norm(m[1])): m for m in json.load(f)}
        except OSError:
            _ufs[uf] = {}
    return _ufs[uf]


def chave(tokens):
    # sem espaços e com a grafia antiga unificada: "Sant' Ana" = "Santana", "Moji" = "Mogi"
    return ''.join(tokens).replace('MOGI', 'MOJI')


def achar_municipio(uf, local):
    """O trecho da cidade às vezes vem com o bairro na frente: tenta do texto inteiro até a última palavra."""
    ms, t = municipios(uf), norm(local)
    for i in range(len(t)):
        m = ms.get(chave(t[i:]))
        if m:
            return m
    return None


def dentro(m, lat, lon, folga=0.02):
    """Ponto dentro do município (com folga de ~2 km na caixa, para endereço na divisa)."""
    for poli in m[4]:
        anel = poli[0]
        xs, ys = [p[0] for p in anel], [p[1] for p in anel]
        if not (min(xs) - folga <= lon <= max(xs) + folga and min(ys) - folga <= lat <= max(ys) + folga):
            continue
        ok = False
        j = len(anel) - 1
        for i in range(len(anel)):
            xi, yi = anel[i]
            xj, yj = anel[j]
            if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi + 1e-12) + xi:
                ok = not ok
            j = i
        if ok:
            return True
        # na divisa: aceita se estiver a menos de ~1,5 km de algum vértice
        if any(abs(p[0] - lon) < 0.015 and abs(p[1] - lat) < 0.015 for p in anel):
            return True
    return False


def get(url, params=None, nominatim=False):
    if nominatim:  # política de uso do Nominatim: no máximo 1 consulta por segundo
        espera = 1.1 - (time.time() - _ult[0])
        if espera > 0:
            time.sleep(espera)
        _ult[0] = time.time()
    try:
        r = requests.get(url, params=params, headers=UA, timeout=20)
        return r.json() if r.status_code == 200 else None
    except Exception:  # noqa: BLE001
        return None


def nominatim(**params):
    r = get('https://nominatim.openstreetmap.org/search', {**params, 'format': 'json', 'limit': 3, 'countrycodes': 'br'}, True)
    return [(float(x['lat']), float(x['lon'])) for x in (r or [])]


def logradouro(endereco, local):
    """'AV. ARICANDUVA, 5555 JARDIM X, SAO PAULO-SP 03527-908' -> 'AV. ARICANDUVA, 5555'."""
    e = re.sub(r'-[A-Z]{2}\s+[\d.\-]+\s*$', '', endereco).strip()
    m = re.match(r'^(.*?\d+)\b', e)
    base = m.group(1) if m else e.split(',')[0]
    return re.sub(r'\s+', ' ', base.replace(' S/N', '')).strip(' ,')


def geocodificar(r):
    endereco, cep, uf, local = r['endereco'] or '', r['cep'] or '', r['uf'], r['local'] or ''
    m = achar_municipio(uf, local) if uf else None
    cidade = m[1] if m else local.title()
    tentativas = []
    if endereco:
        tentativas.append(('endereco', lambda: nominatim(q=f'{logradouro(endereco, local)}, {cidade} - {uf}, Brasil')))
    if len(cep) == 8:
        tentativas.append(('cep', lambda: nominatim(postalcode=f'{cep[:5]}-{cep[5:]}', country='Brasil')))
        def brasilapi():
            x = get(f'https://brasilapi.com.br/api/cep/v2/{cep}') or {}
            c = ((x.get('location') or {}).get('coordinates') or {})
            try:
                return [(float(c['latitude']), float(c['longitude']))]
            except (KeyError, TypeError, ValueError):
                return []
        tentativas.append(('cep', brasilapi))
    for fonte, f in tentativas:
        for lat, lon in f():
            if m is None or dentro(m, lat, lon):
                return lat, lon, fonte
    if m:
        return m[3][0], m[3][1], 'municipio'
    return None


def main():
    todas = '--todas' in sys.argv
    url = os.environ.get('SUPABASE_DB_URL')
    if not url:
        raise SystemExit('SUPABASE_DB_URL não definida')
    with psycopg.connect(url) as conn:
        cur = conn.cursor()
        cur.execute("select to_regclass('public.bi_rede') is not null")
        if not cur.fetchone()[0]:
            log('tabela bi_rede não existe; nada a fazer')
            return
        cur.execute('select codigo, endereco, cep, uf, local from public.bi_rede' + ('' if todas else ' where lat is null or geo_fonte = %s'),
                    () if todas else ('municipio',))
        cols = [d.name for d in cur.description]
        lojas = [dict(zip(cols, x)) for x in cur.fetchall()]
        log(f'{len(lojas)} lojas para localizar')
        cont = {}
        for i, r in enumerate(lojas, 1):
            g = geocodificar(r)
            fonte = g[2] if g else 'sem'
            cont[fonte] = cont.get(fonte, 0) + 1
            if g:
                cur.execute('update public.bi_rede set lat = %s, lon = %s, geo_fonte = %s, geo_em = now() where codigo = %s',
                            (round(g[0], 6), round(g[1], 6), g[2], r['codigo']))
            if i % 50 == 0:
                conn.commit()
                log(f'{i} de {len(lojas)}')
        conn.commit()
        log('resultado: ' + ', '.join(f'{k} {v}' for k, v in sorted(cont.items())))


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as ex:  # noqa: BLE001
        log(f'falha ({type(ex).__name__}); nada mais foi gravado')
        sys.exit(1)
