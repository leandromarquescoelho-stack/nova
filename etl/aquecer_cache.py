"""Deixa prontas no banco as respostas da abertura do painel (login, dashboard e aba Vendedores) de cada usuário ativo.

A carga limpa a memória de respostas (bi_cache); sem isto, o primeiro acesso de cada perfil depois da carga
espera o banco calcular tudo. Aqui cada consulta roda uma vez com o escopo de cada usuário, do mesmo jeito que o
site pede, e fica guardada. Usuários com o mesmo escopo aproveitam a mesma resposta.
O log é público: mostra só contagens e tempos.

Variáveis: SUPABASE_DB_URL. Uso: python etl/aquecer_cache.py [--minutos 6]
"""
import json
import os
import sys
import time
from datetime import date, timedelta

import psycopg


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def periodo(fim):
    """Período padrão do site (últimos 30 dias até o último dia com dados) e as comparações que ele envia."""
    d = lambda x: x.isoformat()
    ini = fim - timedelta(days=29)
    return {'ini': d(ini), 'fim': d(fim), 'pini': d(ini - timedelta(days=30)), 'pfim': d(ini - timedelta(days=1)),
            's7i': d(fim - timedelta(days=6)), 's7f': d(fim), 'p7i': d(fim - timedelta(days=13)), 'p7f': d(fim - timedelta(days=7))}


def main():
    args = sys.argv[1:]
    minutos = float(args[args.index('--minutos') + 1]) if '--minutos' in args else 6.0
    limite = time.time() + minutos * 60
    url = os.environ.get('SUPABASE_DB_URL')
    if not url:
        raise SystemExit('SUPABASE_DB_URL não definida')
    t0 = time.time()
    with psycopg.connect(url, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute('set statement_timeout = 120000')
        cur.execute('select id from public.profiles where active order by id')
        usuarios = [str(x[0]) for x in cur.fetchall()]
        log(f'{len(usuarios)} usuários ativos')
        ok = falhas = 0
        produtos = False
        for uid in usuarios:
            if time.time() > limite:
                log('limite de tempo; o restante fica para o primeiro acesso')
                break
            try:
                cur.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps({'sub': uid, 'role': 'authenticated'}),))
                cur.execute('select public.bi_meta_leve()::jsonb -> %s ->> 1', ('dias',))
                fim = cur.fetchone()[0]
                if not fim:
                    continue
                per = periodo(date.fromisoformat(fim[:10]))
                curto = {'ini': per['ini'], 'fim': per['fim']}
                f = '{}'
                cur.execute("select public.bi_painel(%s::jsonb, '{}'::jsonb, 'a')", (f,))
                cur.execute("select public.bi_painel(%s::jsonb, %s::jsonb, 'c')", (f, json.dumps(per)))
                cur.execute('select public.bi_kpis(%s::jsonb, %s::jsonb)', (f, json.dumps(per)))
                cur.execute('select public.bi_hoje(%s::jsonb, %s::date)', (f, per['fim']))
                cur.execute('select public.bi_loja_mes(%s::jsonb)', (f,))
                cur.execute('select public.bi_vendedores(%s::jsonb, %s::jsonb)', (f, json.dumps(curto)))
                if not produtos:
                    cur.execute('select public.bi_produtos()')
                    produtos = True
                ok += 1
            except Exception as ex:  # noqa: BLE001  (perfil sem acesso, função ausente etc.: segue para o próximo)
                falhas += 1
                log(f'um usuário não aqueceu ({type(ex).__name__})')
        log(f'pronto: {ok} usuários aquecidos, {falhas} com falha, {time.time() - t0:.0f} s')


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as ex:  # noqa: BLE001
        log(f'falha ({type(ex).__name__}); o site calcula no primeiro acesso')
