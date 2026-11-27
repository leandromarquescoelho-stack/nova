"""Deixa prontas no banco as respostas da abertura do painel (tela de entrada Vendas de hoje, painel geral e aba Vendedores) de cada usuário ativo.

A carga limpa a memória de respostas (bi_cache); sem isto, o primeiro acesso de cada perfil depois da carga
espera o banco calcular tudo. Aqui cada consulta roda uma vez por escopo (usuários com o mesmo acesso usam a mesma resposta guardada),
do mesmo jeito que o site pede, e fica guardada.
O log é público: mostra só contagens e tempos.

Variáveis: SUPABASE_DB_URL. Uso: python etl/aquecer_cache.py [--minutos 6] [--paralelo 1]
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def periodo(fim):
    """Período padrão do site (últimos 30 dias até o último dia com dados) e as comparações que ele envia."""
    d = lambda x: x.isoformat()
    ini = fim - timedelta(days=29)
    return {'ini': d(ini), 'fim': d(fim), 'pini': d(ini - timedelta(days=30)), 'pfim': d(ini - timedelta(days=1)),
            's7i': d(fim - timedelta(days=6)), 's7f': d(fim), 'p7i': d(fim - timedelta(days=13)), 'p7f': d(fim - timedelta(days=7))}


def conectar(url, uid):
    conn = psycopg.connect(url, autocommit=True)
    cur = conn.cursor()
    cur.execute('set statement_timeout = 120000')
    cur.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps({'sub': uid, 'role': 'authenticated', 'aal': 'aal2'}),))
    return conn, cur


def miudo(sql):
    """Roda a consulta no banco (a resposta fica guardada no bi_cache) mas devolve só 1 número, não a resposta inteira:
    sem isto cada aquecimento trazia megabytes do banco para o GitHub (Egress do Shared Pooler)."""
    return 'select octet_length((' + sql + ')::text)'   # subconsulta escalar: o banco é obrigado a calcular


def entrada_sql(hoje, canais, ae=None):
    """O que o site pede logo depois do login (mesmos parâmetros, para usar a mesma resposta guardada).
    Primeiro o ticker dos visuais BF/BF2 (filtro Atacado + E-commerce): são as TVs, que pedem tudo ao mesmo tempo logo após a carga."""
    f, d = '{}', hoje.isoformat()
    entrada = []
    if ae:
        fae = json.dumps({'canal': ae})
        entrada += [('select public.bi_ticker(%s::jsonb, %s::date)', (fae, d)),
                    ('select public.bi_vendas_hoje_estoque(%s::jsonb, %s::date)', (fae, d)),
                    ('select public.bi_vendas_destaques(%s::jsonb, %s::date)', (fae, d))]
    entrada += [('select public.bi_metas_vend()', ()),
               ('select public.bi_vendas_hoje(%s::jsonb, %s::date)', (f, d)),
               ('select public.bi_vendas_hoje_estoque(%s::jsonb, %s::date)', (f, d)),
               ('select public.bi_ticker(%s::jsonb, %s::date)', (f, d)),
               ('select public.bi_vendas_destaques(%s::jsonb, %s::date)', (f, d)),
               ("select public.bi_painel(%s::jsonb, '{}'::jsonb, 'a')", (f,))]
    if canais[0]:
        entrada.append(("select public.bi_painel(%s::jsonb, '{}'::jsonb, 'a')", (json.dumps({'canal': canais[0]}),)))
    if canais[1]:
        entrada.append(("select public.bi_painel(%s::jsonb, '{}'::jsonb, 'a')", (json.dumps({'canal': canais[1]}),)))
    return entrada


def aquecer_escopo(url, uid, hoje, canais, limite, com_produtos, fase, ae=None):
    """Uma conexão por escopo. Fase 1: tela de entrada (Vendas de hoje, ticker, destaques, metas).
    Fase 2: painel geral e aba Vendedores, enquanto houver tempo."""
    conn, cur = conectar(url, uid)
    try:
        f = '{}'
        cur.execute('select public.bi_meta_leve()::jsonb -> %s ->> 1', ('dias',))
        fim = cur.fetchone()[0]
        if not fim:
            return False
        if fase == 1:
            for sql, par in entrada_sql(hoje, canais, ae):
                try:
                    cur.execute(miudo(sql), par)
                except psycopg.Error:   # função ausente ou sem permissão ainda: segue com as outras
                    pass
            return True
        per = periodo(date.fromisoformat(fim[:10]))
        curto = {'ini': per['ini'], 'fim': per['fim']}
        for sql, par in (("select public.bi_painel(%s::jsonb, %s::jsonb, 'c')", (f, json.dumps(per))),
                         ('select public.bi_kpis(%s::jsonb, %s::jsonb)', (f, json.dumps(per))),
                         ('select public.bi_hoje(%s::jsonb, %s::date)', (f, per['fim'])),
                         ('select public.bi_loja_mes(%s::jsonb)', (f,)),
                         ('select public.bi_vendedores(%s::jsonb, %s::jsonb)', (f, json.dumps(curto)))):
            if time.time() > limite:
                return True
            cur.execute(miudo(sql), par)
        if com_produtos and time.time() <= limite:
            cur.execute(miudo('select public.bi_produtos()'))
        return True
    finally:
        conn.close()


def main():
    args = sys.argv[1:]
    minutos = float(args[args.index('--minutos') + 1]) if '--minutos' in args else 6.0
    paralelo = int(args[args.index('--paralelo') + 1]) if '--paralelo' in args else 1
    limite = time.time() + minutos * 60
    url = os.environ.get('SUPABASE_DB_URL')
    if not url:
        raise SystemExit('SUPABASE_DB_URL não definida')
    t0 = time.time()
    hoje = datetime.now(ZoneInfo('America/Sao_Paulo')).date()   # o site sempre pede o dia de hoje
    with psycopg.connect(url, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute('select id from public.profiles where active order by id')
        usuarios = [str(x[0]) for x in cur.fetchall()]
        # canais do site: lojas físicas x e-commerce (mesma divisão que o painel pede)
        cur.execute("select id, valor from public.bi_dim where tipo = 'canal' order by id")
        dims = cur.fetchall()
        on = [i for i, v in dims if v == 'ECOMMERCE']
        canais = ([i for i, v in dims if v != 'ECOMMERCE'], on)
        ae = sorted(i for i, v in dims if ''.join(ch for ch in str(v).upper() if ch.isalpha()) in ('ATACADO', 'ECOMMERCE'))   # mesmo filtro do ticker BF/BF2
        # usuários com o mesmo acesso usam as mesmas respostas guardadas: aquece um só por acesso
        escolhidos, vistos = [], set()
        for uid in usuarios:
            cur.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps({'sub': uid, 'role': 'authenticated', 'aal': 'aal2'}),))
            try:
                cur.execute("select private.bi_where('{}'::jsonb) || '|' || coalesce((select role::text from public.profiles where id = %s), '')", (uid,))
                escopo = cur.fetchone()[0]
            except Exception:  # noqa: BLE001  (sem acesso ou sem a função)
                escopo = uid
            if escopo not in vistos:
                vistos.add(escopo)
                escolhidos.append(uid)
    log(f'{len(usuarios)} usuários ativos, {len(escolhidos)} acessos diferentes')
    ok = falhas = 0
    # uma consulta pesada por vez (o banco é pequeno e os usuários continuam usando o site durante o aquecimento);
    # primeiro a tela de entrada de todos os acessos, depois o resto enquanto houver tempo
    for fase in (1, 2):
        with ThreadPoolExecutor(max_workers=max(1, paralelo)) as ex:
            tarefas = [ex.submit(aquecer_escopo, url, uid, hoje, canais, limite, i == 0, fase, ae) for i, uid in enumerate(escolhidos)]
            for t in tarefas:
                try:
                    ok += 1 if (t.result() and fase == 1) else 0
                except Exception as e:  # noqa: BLE001  (perfil sem acesso, tempo esgotado etc.: segue)
                    falhas += 1
                    log(f'um acesso não aqueceu na fase {fase} ({type(e).__name__})')
        log(f'fase {fase} ({"tela de entrada" if fase == 1 else "painel geral"}): {time.time() - t0:.0f} s')
    log(f'pronto: {ok} acessos aquecidos, {falhas} com falha, {time.time() - t0:.0f} s')


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as ex:  # noqa: BLE001
        log(f'falha ({type(ex).__name__}); o site calcula no primeiro acesso')
