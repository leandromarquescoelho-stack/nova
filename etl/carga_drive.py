"""Carga Google Drive -> Supabase do painel Nova Chevrolet BI.

Lê as planilhas da pasta do Drive, recalcula as tabelas bi_* e grava tudo no banco
numa única transação (quem estiver usando o painel continua vendo a carga anterior
até o fim). Só processa quando a data de modificação de alguma planilha mudou.

Nenhum dado da empresa fica neste repositório: os nomes das colunas e das planilhas
ficam no próprio banco (bi_config.mapa_colunas) e os logs só mostram contagens,
porque os logs do GitHub Actions deste repositório são públicos.

Variáveis de ambiente (segredos do GitHub):
  GDRIVE_FOLDER_ID   id da pasta do Drive
  GOOGLE_SA_JSON     JSON da conta de serviço do Google com acesso de leitura à pasta
  SUPABASE_DB_URL    string de conexão Postgres do Supabase (usuário postgres)

Uso local para teste: python carga_drive.py --pasta-local ./planilhas --simular
"""
import argparse
import io
import json
import os
import re
import sys
from datetime import datetime, timezone

import pandas as pd
import psycopg

MESES = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']
EXTENSOES = ('.xlsb', '.xlsx', '.xlsm', '.xls', '.csv')
MIME_SHEETS = 'application/vnd.google-apps.spreadsheet'
MIME_XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

# Regras de negócio (as mesmas da carga inicial, conferidas contra os dados de 25/09/2026)
PADROES = {
    'top_skus': 2000,            # SKUs individuais; o resto vira um item "Outros" por loja
    'meses_estoque_min': 1.5,    # estoque mínimo = venda média mensal x 1,5
    'limite_critico': 0.5,       # estoque < 50% do mínimo = crítico; < 100% = atenção
    'nome_formato': '{sku} - {descricao}',
    'meta_fator': None,          # sem planilha de metas: meta = média mensal x fator (a carga inicial usou 1,12)
}


def log(msg):
    print(f'[{datetime.now(timezone.utc):%H:%M:%S}] {msg}', flush=True)


# ---------------------------------------------------------------- origem dos arquivos
class FonteDrive:
    def __init__(self, pasta_id, sa_json):
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
        cred = service_account.Credentials.from_service_account_info(
            json.loads(sa_json), scopes=['https://www.googleapis.com/auth/drive.readonly'])
        self.api = build('drive', 'v3', credentials=cred, cache_discovery=False)
        self.pasta_id = pasta_id

    def listar(self):
        arquivos, token = [], None
        while True:
            r = self.api.files().list(
                q=f"'{self.pasta_id}' in parents and trashed = false",
                fields='nextPageToken, files(id, name, mimeType, modifiedTime, md5Checksum)',
                pageSize=200, pageToken=token,
                supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
            arquivos += r.get('files', [])
            token = r.get('nextPageToken')
            if not token:
                break
        return [{'id': f['id'], 'nome': f['name'], 'mime': f['mimeType'],
                 'modificado': f['modifiedTime'], 'md5': f.get('md5Checksum')}
                for f in arquivos
                if f['mimeType'] == MIME_SHEETS or f['name'].lower().endswith(EXTENSOES)]

    def baixar(self, arq):
        from googleapiclient.http import MediaIoBaseDownload
        if arq['mime'] == MIME_SHEETS:
            req = self.api.files().export_media(fileId=arq['id'], mimeType=MIME_XLSX)
            nome = arq['nome'] + '.xlsx'
        else:
            req = self.api.files().get_media(fileId=arq['id'], supportsAllDrives=True)
            nome = arq['nome']
        buf = io.BytesIO()
        dl = MediaIoBaseDownload(buf, req, chunksize=32 * 1024 * 1024)
        done = False
        while not done:
            _, done = dl.next_chunk()
        buf.seek(0)
        return nome, buf


class FonteLocal:
    """Para testes: uma pasta no computador no lugar da pasta do Drive."""
    def __init__(self, pasta):
        self.pasta = pasta

    def listar(self):
        out = []
        for n in sorted(os.listdir(self.pasta)):
            p = os.path.join(self.pasta, n)
            if n.lower().endswith(EXTENSOES):
                mt = datetime.fromtimestamp(os.path.getmtime(p), timezone.utc).isoformat()
                out.append({'id': 'local:' + n, 'nome': n, 'mime': '', 'modificado': mt, 'md5': None})
        return out

    def baixar(self, arq):
        with open(os.path.join(self.pasta, arq['nome']), 'rb') as f:
            return arq['nome'], io.BytesIO(f.read())


# ---------------------------------------------------------------- leitura das planilhas
def ler_planilha(nome, buf, aba=None, cabecalho=0):
    n = nome.lower()
    if n.endswith('.csv'):
        raw = buf.read()
        for enc in ('utf-8-sig', 'latin-1'):
            try:
                txt = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        sep = ';' if txt[:2000].count(';') > txt[:2000].count(',') else ','
        return pd.read_csv(io.StringIO(txt), sep=sep, dtype=str, header=cabecalho)
    engine = 'pyxlsb' if n.endswith('.xlsb') else None
    return pd.read_excel(buf, sheet_name=aba if aba is not None else 0, header=cabecalho, engine=engine)


def normaliza(s):
    return re.sub(r'\s+', ' ', str(s)).strip().upper()


def renomear(df, colunas, origem):
    """colunas = {nome_padrao: 'Nome da coluna na planilha'}; compara sem diferenciar maiúsculas/espaços."""
    reais = {normaliza(c): c for c in df.columns}
    faltando = [padrao for padrao, col in colunas.items() if col and normaliza(col) not in reais]
    if faltando:
        raise ValueError(f'planilha de {origem}: colunas não encontradas para {faltando}')
    df = df[[reais[normaliza(col)] for col in colunas.values() if col]].copy()
    df.columns = [padrao for padrao, col in colunas.items() if col]
    return df


def numero(serie):
    if serie.dtype.kind in 'if':
        return serie.astype(float).fillna(0.0)
    s = serie.astype(str).str.strip().str.replace('R$', '', regex=False).str.replace(' ', '', regex=False)
    virg, ponto = s.str.rfind(','), s.str.rfind('.')
    br = virg > ponto  # 1.234,56 ou 12,5 -> vírgula decimal
    us = (virg >= 0) & ~br  # 1,234.56 -> vírgula de milhar
    s = s.where(~br, s.str.replace('.', '', regex=False).str.replace(',', '.', regex=False))
    s = s.where(~us, s.str.replace(',', '', regex=False))
    milhar = s.str.fullmatch(r'-?\d{1,3}(\.\d{3})+')  # 3.000 -> três mil
    s = s.where(~milhar, s.str.replace('.', '', regex=False))
    return pd.to_numeric(s, errors='coerce').fillna(0.0)


def datas(serie):
    if serie.dtype.kind in 'if':  # número de série do Excel (pyxlsb devolve assim)
        return pd.to_datetime(serie, unit='D', origin='1899-12-30', errors='coerce')
    return pd.to_datetime(serie, dayfirst=True, errors='coerce')


def texto(serie):
    s = serie.astype(str).str.strip()
    return s.mask(s.isin(['', 'nan', 'None', 'NaT']))


def sku_texto(serie):
    if serie.dtype.kind == 'f':
        serie = serie.map(lambda v: '' if pd.isna(v) else (str(int(v)) if float(v).is_integer() else str(v)))
    return texto(serie)


# ---------------------------------------------------------------- regras de negócio
def principal(df, chave, attr):
    """Valor de `attr` com maior faturamento para cada `chave`."""
    g = df.dropna(subset=[attr]).groupby([chave, attr], sort=False)['fat'].sum().reset_index()
    g = g.sort_values([chave, 'fat'], ascending=[True, False]).drop_duplicates(chave)
    return g.set_index(chave)[attr]


def status_estoque(est, est_min, limite):
    if est is None or est <= 0:
        return 'zerado'
    if est_min <= 0 or est >= est_min:
        return 'normal'
    return 'critico' if est / est_min < limite else 'atencao'


def transformar(vendas, estoque, metas, cfg, loja_info_atual):
    regras = {**PADROES, **cfg.get('regras', {})}

    v = vendas.copy()
    v['data'] = datas(v['data'])
    v = v.dropna(subset=['data'])
    v['sku'] = sku_texto(v['sku'])
    v = v.dropna(subset=['sku'])
    for c in ('fat', 'qtd', 'custo', 'lb'):
        v[c] = numero(v[c]) if c in v else 0.0
    for c in ('descricao', 'marca', 'categoria', 'montadora', 'loja', 'vendedor', 'canal', 'origem'):
        v[c] = texto(v[c]) if c in v else None
    if 'lb' not in vendas:
        v['lb'] = v['fat'] - v['custo']

    # meses contínuos do primeiro ao último mês com venda
    ini, fim = v['data'].min(), v['data'].max()
    meses = pd.period_range(ini.to_period('M'), fim.to_period('M'), freq='M')
    chaves_mes = [f'{p.year}-{p.month}' for p in meses]
    rotulos = [MESES[p.month - 1] for p in meses]
    v['mi'] = (v['data'].dt.year - ini.year) * 12 + (v['data'].dt.month - ini.month)

    # totais por SKU e atributos "principais" (o de maior faturamento)
    tot = v.groupby('sku')[['fat', 'qtd', 'custo', 'lb']].sum()
    attrs = {a: principal(v, 'sku', a) for a in ('descricao', 'marca', 'categoria', 'montadora', 'loja', 'vendedor', 'canal', 'origem')}
    mf = v.pivot_table(index='sku', columns='mi', values='fat', aggfunc='sum', fill_value=0.0).reindex(columns=range(len(meses)), fill_value=0.0)
    mq = v.pivot_table(index='sku', columns='mi', values='qtd', aggfunc='sum', fill_value=0.0).reindex(columns=range(len(meses)), fill_value=0.0)

    # estoque por SKU (soma das lojas)
    est = None
    if estoque is not None:
        e = estoque.copy()
        e['sku'] = sku_texto(e['sku'])
        e = e.dropna(subset=['sku'])
        e['est_fis'] = numero(e['est_fis'])
        e['est_custo'] = numero(e['est_custo']) if 'est_custo' in e else 0.0
        agg = {'est_fis': 'sum', 'est_custo': 'sum'}
        if 'dias_sem_giro' in e:
            e['dias_sem_giro'] = pd.to_numeric(numero(e['dias_sem_giro']), errors='coerce')
            agg['dias_sem_giro'] = 'min'
        if 'parado' in e:
            sim = {normaliza(x) for x in cfg.get('estoque', {}).get('valores_parado', ['S', 'SIM', 'TRUE', '1', 'X'])}
            e['parado'] = texto(e['parado']).map(lambda x: normaliza(x) in sim if isinstance(x, str) else False)
            agg['parado'] = 'any'  # parado em qualquer loja
        est = e.groupby('sku').agg(agg)

    n_meses = max(1, len(meses))
    ordem = tot.sort_values('fat', ascending=False).index
    top = list(ordem[:regras['top_skus']])
    cauda = list(ordem[regras['top_skus']:])

    def est_de(skus):
        if est is None:
            return None, None, None, False
        sub = est.reindex(skus).dropna(how='all')
        if sub.empty:
            return 0.0, 0.0, None, False
        dias = sub['dias_sem_giro'].min() if 'dias_sem_giro' in sub and len(skus) == 1 else None
        parado = bool(sub['parado'].any()) if 'parado' in sub and len(skus) == 1 else False
        return float(sub['est_fis'].sum()), float(sub['est_custo'].sum()), (None if dias is None or pd.isna(dias) else float(dias)), parado

    def linha(id_, nome, at, skus, bucket_count=None):
        t = tot.loc[skus].sum()
        fis, custo_est, dias, parado = est_de(skus)
        # mínimo por SKU (arredondado) somado; no item "Outros" é a soma dos SKUs da cauda
        est_min = round(sum(round(float(q) / n_meses * regras['meses_estoque_min'], 1) for q in tot.loc[skus, 'qtd']), 1)
        return {
            'id': id_, 'nome': nome, **at,
            'fat': round(float(t['fat']), 2), 'qtd': round(float(t['qtd']), 3),
            'custo': round(float(t['custo']), 2), 'lb': round(float(t['lb']), 2),
            'mfat': [round(float(x), 2) for x in mf.loc[skus].sum().tolist()],
            'mqtd': [round(float(x), 3) for x in mq.loc[skus].sum().tolist()],
            'est_fis': fis, 'est_custo': None if custo_est is None else round(custo_est, 2),
            'est_min': est_min, 'dias_sem_giro': dias, 'parado': parado,
            'status': status_estoque(fis, est_min, regras['limite_critico']) if fis is not None else None,
            'is_bucket': bucket_count is not None, 'bucket_count': bucket_count,
        }

    produtos = []
    for sku in top:
        at = {a: (None if pd.isna(attrs[a].get(sku)) else attrs[a].get(sku)) for a in attrs}
        desc = at.pop('descricao') or ''
        nome = regras['nome_formato'].format(sku=sku, descricao=desc).strip(' -')
        for k in ('marca', 'categoria', 'montadora', 'origem'):
            at[k] = at[k] or 'N/D'
        produtos.append(linha(sku, nome, at, [sku]))

    # cauda longa: um item "Outros" por loja principal
    if cauda:
        loja_cauda = attrs['loja'].reindex(cauda).fillna('SEM LOJA')
        for loja, skus in loja_cauda.groupby(loja_cauda).groups.items():
            skus = list(skus)
            sub = v[v['sku'].isin(skus)]
            canal = principal(sub.assign(_k=1), '_k', 'canal')
            at = {'marca': 'Diversas', 'categoria': 'Outros', 'montadora': 'Diversas', 'loja': loja,
                  'vendedor': 'Diversos', 'canal': canal.iloc[0] if len(canal) else None, 'origem': 'Diversas'}
            id_ = 'OUTROS_' + re.sub(r'\W+', '_', normaliza(loja)).strip('_')
            nome = f'Outros itens — {loja} (cauda longa · {len(skus)} SKUs)'
            produtos.append(linha(id_, nome, at, skus, bucket_count=len(skus)))

    # curva diária da empresa: peso de cada dia no total do seu mês
    dia = v.groupby(v['data'].dt.normalize())[['fat', 'qtd']].sum()
    dia = dia[(dia['fat'] != 0) | (dia['qtd'] != 0)]
    mes_tot = dia.groupby([dia.index.year, dia.index.month]).transform('sum')
    peso = pd.DataFrame({'w_fat': dia['fat'] / mes_tot['fat'].replace(0, pd.NA),
                         'w_qtd': dia['qtd'] / mes_tot['qtd'].replace(0, pd.NA)}).fillna(0.0)
    pesos = [{'d': d.date().isoformat(), 'w_fat': round(float(r.w_fat), 10), 'w_qtd': round(float(r.w_qtd), 10)}
             for d, r in peso.iterrows()]

    # lojas: mantém o que já está no banco (física ou marketplace); loja nova = física se o canal não for e-commerce
    lojas = sorted({p['loja'] for p in produtos if p['loja']})
    loja_info = {}
    canal_loja = principal(v, 'loja', 'canal')
    for l in lojas:
        if l in loja_info_atual:
            loja_info[l] = loja_info_atual[l]
        else:
            loja_info[l] = {'fisica': 'COMMERCE' not in normaliza(canal_loja.get(l, ''))}

    metas_out = None
    if metas is None and regras.get('meta_fator'):
        # sem planilha de metas: meta = venda média mensal atribuída ao vendedor x fator
        soma = {}
        for p in produtos:
            if not p['is_bucket'] and p['vendedor']:
                soma[p['vendedor']] = soma.get(p['vendedor'], 0.0) + p['fat']
        metas_out = [{'vendedor': k, 'meta': round(x / n_meses * regras['meta_fator'], 2)} for k, x in sorted(soma.items())]
    if metas is not None:
        m = metas.copy()
        m['vendedor'] = texto(m['vendedor'])
        m['meta'] = numero(m['meta'])
        m = m.dropna(subset=['vendedor']).groupby('vendedor')['meta'].sum()
        metas_out = [{'vendedor': k, 'meta': round(float(x), 2)} for k, x in m.items()]

    return {
        'produtos': produtos, 'pesos': pesos, 'metas': metas_out,
        'config': {'months': chaves_mes, 'monthLabels': rotulos, 'lojas': lojas, 'lojaInfo': loja_info},
        'dados_ate': fim.date().isoformat(),
        'linhas_vendas': int(len(v)), 'linhas_estoque': 0 if estoque is None else int(len(estoque)),
    }


# ---------------------------------------------------------------- banco
def ler_config(cur):
    cur.execute("select chave, valor from public.bi_config where chave in ('mapa_colunas','lojaInfo')")
    cfg = dict(cur.fetchall())
    if 'mapa_colunas' not in cfg:
        raise SystemExit('bi_config.mapa_colunas não está configurado no banco.')
    return cfg['mapa_colunas'], cfg.get('lojaInfo') or {}


def ja_carregado(cur, arq):
    cur.execute("""select 1 from public.bi_carga_controle
                   where arquivo_id = %s and modificado_em >= %s and status = 'ok' limit 1""",
                (arq['id'], arq['modificado']))
    return cur.fetchone() is not None


def gravar(conn, res, usados):
    agora = datetime.now(timezone.utc).isoformat()
    with conn.transaction():
        cur = conn.cursor()
        ids = []
        for papel, arq in usados.items():
            cur.execute("""insert into public.bi_carga_controle (arquivo_id, arquivo_nome, modificado_em, md5, status)
                           values (%s, %s, %s, %s, 'processando') returning id""",
                        (arq['id'], arq['nome'], arq['modificado'], arq['md5']))
            ids.append((cur.fetchone()[0], papel))

        cur.execute('delete from public.bi_produtos')
        cols = ['id', 'nome', 'marca', 'categoria', 'montadora', 'loja', 'vendedor', 'canal', 'origem',
                'fat', 'qtd', 'custo', 'lb', 'mfat', 'mqtd', 'est_fis', 'est_custo', 'est_min',
                'dias_sem_giro', 'parado', 'status', 'is_bucket', 'bucket_count']
        cur.executemany(
            f"insert into public.bi_produtos ({', '.join(cols)}) values ({', '.join(['%s'] * len(cols))})",
            [[p[c] for c in cols] for p in res['produtos']])

        cur.execute('delete from public.bi_peso_diario')
        cur.executemany('insert into public.bi_peso_diario (d, w_fat, w_qtd) values (%s, %s, %s)',
                        [(p['d'], p['w_fat'], p['w_qtd']) for p in res['pesos']])

        if res['metas'] is not None:
            cur.execute('delete from public.bi_meta_vendedor')
            cur.executemany('insert into public.bi_meta_vendedor (vendedor, meta) values (%s, %s)',
                            [(m['vendedor'], m['meta']) for m in res['metas']])

        carga = {'carregado_em': agora, 'dados_ate': res['dados_ate'],
                 'origem': ' + '.join(a['nome'] for a in usados.values())}
        for chave, valor in {**res['config'], 'carga': carga}.items():
            cur.execute("""insert into public.bi_config (chave, valor) values (%s, %s::jsonb)
                           on conflict (chave) do update set valor = excluded.valor""",
                        (chave, json.dumps(valor, ensure_ascii=False)))

        linhas = {'vendas': res['linhas_vendas'], 'estoque': res['linhas_estoque'],
                  'metas': len(res['metas'] or [])}
        for id_, papel in ids:
            cur.execute("""update public.bi_carga_controle set status = 'ok', linhas = %s, concluido_em = now()
                           where id = %s""", (linhas.get(papel), id_))


def registrar_erro(db_url, usados, erro):
    try:
        with psycopg.connect(db_url, autocommit=True) as conn, conn.cursor() as cur:
            for arq in usados.values():
                cur.execute("""insert into public.bi_carga_controle
                               (arquivo_id, arquivo_nome, modificado_em, md5, status, mensagem, concluido_em)
                               values (%s, %s, %s, %s, 'erro', %s, now())""",
                            (arq['id'], arq['nome'], arq['modificado'], arq['md5'], erro[:1000]))
    except Exception as ex:  # noqa: BLE001
        log(f'não foi possível registrar o erro no banco ({type(ex).__name__})')


# ---------------------------------------------------------------- principal
def escolher(arquivos, padrao):
    """Arquivo mais recente cujo nome contém `padrao` (sem diferenciar maiúsculas)."""
    cand = [a for a in arquivos if normaliza(padrao) in normaliza(a['nome'])]
    return max(cand, key=lambda a: a['modificado']) if cand else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--forcar', action='store_true', help='recarrega mesmo sem planilha nova')
    ap.add_argument('--pasta-local', help='usa uma pasta local no lugar do Drive (teste)')
    ap.add_argument('--simular', action='store_true', help='processa mas não grava no banco')
    ap.add_argument('--saida-json', help='com --simular, salva o resultado neste arquivo (teste local)')
    a = ap.parse_args()

    db_url = os.environ.get('SUPABASE_DB_URL')
    mapa_arquivo = os.environ.get('MAPA_COLUNAS_ARQUIVO')  # teste local sem banco
    if mapa_arquivo:
        with open(mapa_arquivo, encoding='utf-8') as f:
            mapa, loja_info = json.load(f), {}
        conn = None
    else:
        if not db_url:
            raise SystemExit('SUPABASE_DB_URL não definido.')
        conn = psycopg.connect(db_url, autocommit=True)  # gravar() abre a própria transação
        mapa, loja_info = ler_config(conn.cursor())

    fonte = FonteLocal(a.pasta_local) if a.pasta_local else FonteDrive(os.environ['GDRIVE_FOLDER_ID'], os.environ['GOOGLE_SA_JSON'])
    arquivos = fonte.listar()
    log(f'{len(arquivos)} planilha(s) na pasta')

    usados = {}
    for papel in ('vendas', 'estoque', 'metas'):
        spec = mapa.get(papel)
        if not spec:
            continue
        arq = escolher(arquivos, spec['arquivo'])
        if arq is None and papel == 'vendas':
            raise SystemExit('planilha de vendas não encontrada na pasta.')
        if arq is not None:
            usados[papel] = arq

    if conn is not None and not a.forcar and all(ja_carregado(conn.cursor(), arq) for arq in usados.values()):
        log('nenhuma planilha nova desde a última carga; nada a fazer')
        return

    try:
        dfs = {}
        for papel, arq in usados.items():
            spec = mapa[papel]
            nome, buf = fonte.baixar(arq)
            df = ler_planilha(nome, buf, spec.get('aba'), spec.get('linha_cabecalho', 0))
            dfs[papel] = renomear(df, spec['colunas'], papel)
            log(f'{papel}: {len(df)} linhas lidas')
        res = transformar(dfs['vendas'], dfs.get('estoque'), dfs.get('metas'), mapa, loja_info)
        log(f"resultado: {len(res['produtos'])} produtos, {len(res['pesos'])} dias, "
            f"{len(res['metas']) if res['metas'] is not None else 'sem'} metas, {len(res['config']['months'])} meses")
        if a.simular:
            if a.saida_json:
                with open(a.saida_json, 'w', encoding='utf-8') as f:
                    json.dump(res, f, ensure_ascii=False)
            log('simulação: nada gravado')
            return
        gravar(conn, res, usados)
        log('carga concluída')
    except Exception as ex:  # noqa: BLE001
        msg = f'{type(ex).__name__}: {ex}'
        if conn is not None and not a.simular:
            registrar_erro(db_url, usados, msg)
        # o detalhe fica só no banco; o log público mostra apenas o tipo do erro
        log(f'falha na carga ({type(ex).__name__}); detalhe registrado em bi_carga_controle')
        sys.exit(1)


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as ex:  # noqa: BLE001
        # o log do GitHub Actions é público: nunca imprimir traceback, que pode citar valores das planilhas
        log(f'falha inesperada ({type(ex).__name__}); nada foi gravado')
        sys.exit(1)
