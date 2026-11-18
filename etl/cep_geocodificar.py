"""Bairro e coordenada dos CEPs dos clientes (tabela bi_cep do banco) para o mapa por bairro.

Só os CEPs saem daqui (nunca nomes, códigos ou valores de clientes). A tabela fica só no banco.
  1. CEP -> bairro, cidade e UF no ViaCEP; sem resposta, na BrasilAPI (que às vezes traz o ponto do CEP).
  2. Bairro -> ponto central no OpenStreetMap (Nominatim, 1 consulta por segundo), uma vez por bairro.
     O ponto só vale se cair dentro do município (contornos do IBGE em geo/UF.json).
  3. Na cidade de São Paulo, o ponto também diz o distrito (geo/SP_distritos.json).
Começa pelos CEPs dos clientes que mais compraram em 12 meses e para no limite de tempo;
a próxima execução continua de onde parou. O log é público: mostra só contagens.

Variáveis: SUPABASE_DB_URL. Uso: python etl/cep_geocodificar.py [--minutos 50] [--refazer]
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import psycopg
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rede_geocodificar import GEO, UA, achar_municipio, dentro, get, log  # noqa: E402

SP_CAPITAL = '3550308'
_distritos = []


def distrito_sp(lat, lon):
    if not _distritos:
        with open(os.path.join(GEO, 'SP_distritos.json'), encoding='utf-8') as f:
            _distritos.extend(json.load(f))
    for d in _distritos:
        for poli in d[4]:
            anel = poli[0]
            ok, j = False, len(anel) - 1
            for i in range(len(anel)):
                xi, yi = anel[i]
                xj, yj = anel[j]
                if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi + 1e-12) + xi:
                    ok = not ok
                j = i
            if ok:
                return d[1]
    return None


def consultar_cep(cep):
    """(bairro, cidade, uf, lat, lon) | 'nenhuma' (CEP não existe nas duas bases) | None (falha de rede: tenta depois)."""
    falhou = False
    for tent in range(3):
        try:
            r = requests.get(f'https://viacep.com.br/ws/{cep}/json/', headers=UA, timeout=15)
        except Exception:  # noqa: BLE001
            r = None
        if r is not None and r.status_code == 200:
            try:
                x = r.json()
            except ValueError:
                x = {}
            if x.get('localidade'):
                return (x.get('bairro') or '').strip(), x['localidade'].strip(), (x.get('uf') or '').strip(), None, None
            break  # {"erro": true}: tenta a BrasilAPI
        if r is not None and r.status_code == 400:
            break
        falhou = True
        time.sleep(2 * (tent + 1))
    x = get(f'https://brasilapi.com.br/api/cep/v2/{cep}')
    if x and x.get('city'):
        c = (x.get('location') or {}).get('coordinates') or {}
        try:
            lat, lon = float(c['latitude']), float(c['longitude'])
        except (KeyError, TypeError, ValueError):
            lat = lon = None
        return (x.get('neighborhood') or '').strip(), x['city'].strip(), (x.get('state') or '').strip(), lat, lon
    return None if falhou and x is None else 'nenhuma'


def ponto_bairro(bairro, m, uf):
    """Centro do bairro no OpenStreetMap, dentro do município; ignora respostas que são a própria cidade."""
    for q in (f'{bairro}, {m[1]} - {uf}, Brasil', f'{bairro}, {m[1]}, Brasil'):
        r = get('https://nominatim.openstreetmap.org/search',
                {'q': q, 'format': 'jsonv2', 'limit': 5, 'countrycodes': 'br'}, True)
        for x in r or []:
            if x.get('addresstype') in ('city', 'town', 'municipality', 'state', 'county', 'region', 'country'):
                continue
            lat, lon = float(x['lat']), float(x['lon'])
            if dentro(m, lat, lon, folga=0.005):
                return lat, lon
    return None


def main():
    args = sys.argv[1:]
    minutos = float(args[args.index('--minutos') + 1]) if '--minutos' in args else 50.0
    refazer = '--refazer' in args
    t0 = time.time()
    fim1, fim2 = t0 + minutos * 60 * 0.6, t0 + minutos * 60
    url = os.environ.get('SUPABASE_DB_URL')
    if not url:
        raise SystemExit('SUPABASE_DB_URL não definida')
    with psycopg.connect(url) as conn:
        cur = conn.cursor()
        cur.execute("""select to_regclass('public.bi_cep') is not null and exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'bi_cliente' and column_name = 'cep')""")
        if not cur.fetchone()[0]:
            log('o banco ainda não tem a tabela de CEPs (rode bairros.sql); nada a fazer')
            return
        if refazer:
            cur.execute("delete from public.bi_cep where fonte in ('nenhuma', 'sem_ponto')")
            conn.commit()

        # 1) CEP -> bairro: primeiro os CEPs dos clientes que mais compraram em 12 meses
        cur.execute("select to_regclass('public.bi_cliente_resumo') is not null")
        if cur.fetchone()[0]:
            cur.execute("""select c.cep from public.bi_cliente c left join public.bi_cliente_resumo r on r.cliente = c.id
                           where c.cep is not null and not exists (select 1 from public.bi_cep e where e.cep = c.cep)
                           group by c.cep order by sum(coalesce(r.f12, 0)) desc""")
        else:
            cur.execute("""select distinct c.cep from public.bi_cliente c
                           where c.cep is not null and not exists (select 1 from public.bi_cep e where e.cep = c.cep)""")
        ceps = [x[0] for x in cur.fetchall()]
        log(f'{len(ceps)} CEPs novos para consultar')
        cont, falhas_seg = {}, 0
        with ThreadPoolExecutor(4) as ex:
            for i in range(0, len(ceps), 40):
                if time.time() > fim1 or falhas_seg >= 3:
                    break
                lote = ceps[i:i + 40]
                res = list(ex.map(consultar_cep, lote))
                falhas = sum(r is None for r in res)
                falhas_seg = falhas_seg + 1 if falhas > len(lote) / 2 else 0
                for cep, r in zip(lote, res):
                    if r is None:
                        cont['falha'] = cont.get('falha', 0) + 1
                        continue
                    if r == 'nenhuma':
                        linha = (cep, None, None, None, None, None, None, 'nenhuma')
                    else:
                        bairro, cidade, uf, lat, lon = r
                        m = achar_municipio(uf, cidade) if uf else None
                        if lat is not None and not (m and dentro(m, lat, lon)):
                            lat = lon = None
                        fonte = 'cep' if lat is not None else 'pendente' if bairro else 'sem_ponto'
                        dist = distrito_sp(lat, lon) if lat is not None and m and str(m[2]) == SP_CAPITAL else None
                        linha = (cep, bairro or None, cidade, uf, lat, lon, dist, fonte)
                    cont[linha[-1]] = cont.get(linha[-1], 0) + 1
                    cur.execute("""insert into public.bi_cep (cep, bairro, cidade, uf, lat, lon, distrito, fonte)
                                   values (%s, %s, %s, %s, %s, %s, %s, %s) on conflict (cep) do nothing""", linha)
                conn.commit()
                if (i // 40) % 125 == 124:
                    log(f'{i + len(lote)} de {len(ceps)} CEPs')
        if falhas_seg >= 3:
            log('consultas de CEP falhando seguidamente; o restante fica para a próxima execução')
        log('CEPs: ' + (', '.join(f'{k} {v}' for k, v in sorted(cont.items())) or 'nenhum novo'))

        # 2) bairro -> ponto: reaproveita bairros já localizados e consulta o resto (os com mais clientes primeiro)
        cur.execute("""update public.bi_cep e set lat = b.lat, lon = b.lon, distrito = b.distrito, fonte = 'bairro', geo_em = now()
                       from (select distinct on (upper(bairro), upper(cidade), uf) upper(bairro) b, upper(cidade) c, uf, lat, lon, distrito
                             from public.bi_cep where fonte = 'bairro' order by 1, 2, 3, geo_em desc) b
                       where e.fonte = 'pendente' and upper(e.bairro) = b.b and upper(e.cidade) = b.c and e.uf = b.uf""")
        log(f'{cur.rowcount} CEPs com o ponto de um bairro já localizado')
        conn.commit()
        cur.execute("""select min(e.bairro), min(e.cidade), e.uf from public.bi_cep e
                       join public.bi_cliente c on c.cep = e.cep
                       where e.fonte = 'pendente' group by upper(e.bairro), upper(e.cidade), e.uf order by count(*) desc""")
        bairros = cur.fetchall()
        log(f'{len(bairros)} bairros para localizar')
        cont = {}
        for i, (bairro, cidade, uf) in enumerate(bairros, 1):
            if time.time() > fim2:
                break
            m = achar_municipio(uf, cidade)
            p = ponto_bairro(bairro, m, uf) if m else None
            dist = distrito_sp(*p) if p and str(m[2]) == SP_CAPITAL else None
            k = 'bairro' if p else 'sem_ponto'
            cont[k] = cont.get(k, 0) + 1
            cur.execute("""update public.bi_cep set lat = %s, lon = %s, distrito = %s, fonte = %s, geo_em = now()
                           where fonte = 'pendente' and upper(bairro) = upper(%s) and upper(cidade) = upper(%s) and uf = %s""",
                        (p[0] if p else None, p[1] if p else None, dist, k, bairro, cidade, uf))
            if i % 20 == 0:
                conn.commit()
            if i % 500 == 0:
                log(f'{i} de {len(bairros)} bairros')
        conn.commit()
        log('bairros: ' + (', '.join(f'{k} {v}' for k, v in sorted(cont.items())) or 'nenhum novo'))
        cur.execute("select fonte, count(*) from public.bi_cep group by 1 order by 1")
        log('situação: ' + ', '.join(f'{k} {v}' for k, v in cur.fetchall()))


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as ex:  # noqa: BLE001
        log(f'falha ({type(ex).__name__}); o que já foi gravado fica')
        sys.exit(1)
