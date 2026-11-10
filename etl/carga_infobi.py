"""Carga do arquivo único (infobi): abas de vendas, vendedores, estoque, catálogo e marcas.

- Vendas: substitui no banco só o período (primeira a última data) presente no arquivo; o resto do histórico fica.
  Datas antes de CORTE vão resumidas para bi_venda_hist (dia x dimensões x produto x cliente, sem NF).
- Estoque: substituído inteiro a cada carga. Peça parada = tem saldo e a última venda e a última compra
  são mais antigas que regras.dias_parado (padrão 270 dias, o mesmo critério da planilha antiga).
- Códigos fixos: dimensões, produtos (PN) e clientes (CODCLI) mantêm o id já gravado; valores novos
  ganham o próximo número. Produtos, clientes e dimensões que nenhuma linha usa mais são apagados no fim.
- Configuração do painel (meses, lojas, dados_ate) é recalculada a partir do banco depois da carga.

Os nomes das abas e colunas ficam em bi_config.mapa_colunas.infobi (fora deste repositório público), por exemplo:
  {"arquivo": "infobi", "abas": {"vendas": {"aba": "vendas", "colunas": {"data": "DATA", ...}}, ...}}
"""
import io
import json
from datetime import date, datetime, timezone

import pandas as pd

from carga_drive import (DIMS, MESES, PADROES, copiar, datas, log, normaliza, numero, sku_texto, texto, centavos)


def copiar_tab(cur, tabela, df):
    """Como copiar(), para tabelas temporárias (sem o prefixo public)."""
    buf = io.StringIO()
    df.to_csv(buf, index=False, header=False)
    with cur.copy(f"copy {tabela} ({', '.join(df.columns)}) from stdin with (format csv)") as cp:
        cp.write(buf.getvalue())

CORTE = date(2026, 1, 1)  # mesmo limite das constraints de bi_venda_det / bi_venda_hist
COLS_DET = ['dia', 'mes'] + DIMS + ['produto', 'cliente', 'nf', 'qtd', 'fat', 'custo', 'lb']
COLS_HIST = ['dia', 'mes'] + DIMS + ['produto', 'cliente', 'qtd', 'fat', 'custo', 'lb']
ATRIB = ('categoria', 'subcategoria', 'marca', 'montadora', 'linha', 'classificacao')
ABAS_OBRIG = ('vendas', 'estoque', 'catalogo', 'marcas', 'vendedores')


def ler_abas(nome, buf, spec):
    """Lê todas as abas de uma vez (o arquivo é aberto uma só vez) e renomeia para os nomes padrão."""
    from carga_drive import renomear
    abas = spec['abas']
    faltam = [a for a in ABAS_OBRIG if a not in abas]
    if faltam:
        raise ValueError(f'mapa_colunas.infobi sem as abas {faltam}')
    engine = 'pyxlsb' if nome.lower().endswith('.xlsb') else None
    nomes = {papel: s.get('aba', papel) for papel, s in abas.items()}
    lidas = pd.read_excel(buf, sheet_name=list(nomes.values()), engine=engine)
    out = {}
    for papel, s in abas.items():
        out[papel] = renomear(lidas[nomes[papel]], s['colunas'], papel)
        log(f'{papel}: {len(out[papel])} linhas lidas')
    return out


def _chave(serie):
    return sku_texto(serie).map(lambda x: normaliza(x) if isinstance(x, str) else x)


def preparar(dfs, regras):
    """Junta catálogo, marcas e vendedores às vendas e prepara o estoque (ainda com textos, sem ids)."""
    vazio = regras['vendedor_vazio']
    v = dfs['vendas'].copy()
    v['data'] = datas(v['data'])
    v = v.dropna(subset=['data'])
    v['sku'] = sku_texto(v['sku'])
    v = v.dropna(subset=['sku'])
    for c in ('fat', 'qtd', 'custo', 'lb'):
        v[c] = numero(v[c]) if c in v else 0.0
    if 'lb' not in dfs['vendas']:
        v['lb'] = v['fat'] - v['custo']
    for c in ('loja', 'canal', 'emitente', 'origem', 'linha', 'tipo_cliente', 'cidade', 'razao'):
        v[c] = texto(v[c]) if c in v else None
    v['codcli'] = sku_texto(v['codcli']).fillna('0') if 'codcli' in v else '0'
    v['nf'] = numero(v['nf']).astype('int64') if 'nf' in v else 0

    # vendedor: nome da aba vendedores pelo RE; sem cadastro, o nome da venda sem o número do RE no fim
    ven = dfs['vendedores'].copy()
    ven['re'] = _chave(ven['re'])
    ven = ven.dropna(subset=['re']).drop_duplicates('re').set_index('re')['nome']
    ven = texto(ven)
    re_v = _chave(v['re']) if 're' in v else pd.Series(None, index=v.index)
    nome_v = texto(v['nome_vendedor']) if 'nome_vendedor' in v else pd.Series(None, index=v.index)
    # a venda traz "NOME RE" (ex.: "VENDEDOR ECOMMERCE V-ECOM"): tira o RE do fim
    sufixo = ' ' + re_v.fillna('')
    tem = pd.Series([isinstance(n, str) and r != ' ' and normaliza(n).endswith(r) for n, r in zip(nome_v, sufixo)], index=v.index)
    nome_v = nome_v.where(~tem, [n[:len(n) - len(r)] if t else n for n, r, t in zip(nome_v, sufixo, tem)])
    nome_v = nome_v.str.strip().str.upper()
    v['vendedor'] = re_v.map(ven).fillna(nome_v).fillna(vazio)

    # catálogo por PN e marcas pela LINHA de cada venda
    cat = dfs['catalogo'].copy()
    cat['sku'] = sku_texto(cat['sku'])
    cat = cat.dropna(subset=['sku']).drop_duplicates('sku').set_index('sku')
    for c in ('categoria', 'subcategoria', 'montadora'):
        col = texto(cat[c]) if c in cat else pd.Series(None, index=cat.index)
        v[c] = v['sku'].map(col)
    mar = dfs['marcas'].copy()
    mar['linha'] = texto(mar['linha'])
    mar = mar.dropna(subset=['linha']).drop_duplicates('linha').set_index('linha')
    for c in ('marca', 'classificacao'):
        col = texto(mar[c]) if c in mar else pd.Series(None, index=mar.index)
        v[c] = v['linha'].map(col)
    for c in DIMS:
        v[c] = v[c].fillna('N/D')

    # estoque
    e = dfs['estoque'].copy()
    e['sku'] = sku_texto(e['sku'])
    e = e.dropna(subset=['sku'])
    lojas_v = {normaliza(x): x for x in v['loja'].unique()}
    for de, para in (regras.get('apelidos_loja') or {}).items():
        lojas_v[normaliza(de)] = para
    e['loja'] = texto(e['loja']).fillna('N/D').map(lambda x: lojas_v.get(normaliza(x), x))
    e['linha'] = texto(e['linha']) if 'linha' in e else None
    e['descricao'] = texto(e['descricao']).str.replace(r'\s+', ' ', regex=True) if 'descricao' in e else None
    e['est_fis'] = numero(e['est_fis'])
    e['est_custo'] = numero(e['est_custo']) if 'est_custo' in e else 0.0
    for c in ('dt_ult_vend', 'dt_ult_comp'):
        d = datas(e[c]) if c in e else pd.Series(pd.NaT, index=e.index)
        e[c] = d.where(d >= pd.Timestamp('2000-01-01'))
    # data de referência: a mais recente entre vendas e estoque (o estoque é uma foto do dia da exportação)
    ref = max(v['data'].max(), e[['dt_ult_vend', 'dt_ult_comp']].max().max()).normalize()
    ultimo = e[['dt_ult_vend', 'dt_ult_comp']].max(axis=1)
    dias = (ref - ultimo).dt.days
    e['parado'] = (e['est_fis'] > 0) & (dias.isna() | (dias > int(regras.get('dias_parado', 270))))
    e = e.groupby(['loja', 'sku'], as_index=False).agg(
        est_fis=('est_fis', 'sum'), est_custo=('est_custo', 'sum'), dt_ult_vend=('dt_ult_vend', 'max'),
        dt_ult_comp=('dt_ult_comp', 'max'), parado=('parado', 'any'), linha=('linha', 'first'), descricao=('descricao', 'first'))

    # produtos (vendas + estoque): catálogo; linha da venda de maior faturamento, senão a do estoque
    skus = pd.Index(sorted(set(v['sku']) | set(e['sku'])))
    g = v.groupby(['sku', 'linha'])['fat'].sum().reset_index().sort_values(['sku', 'fat'], ascending=[True, False])
    linha_p = g.drop_duplicates('sku').set_index('sku')['linha']
    linha_p = linha_p.reindex(skus).fillna(e.dropna(subset=['linha']).drop_duplicates('sku').set_index('sku')['linha'])
    prod = pd.DataFrame(index=skus)
    prod['linha'] = linha_p
    for c in ('categoria', 'subcategoria', 'montadora'):
        prod[c] = texto(cat[c]).reindex(skus) if c in cat else None
    for c in ('marca', 'classificacao'):
        prod[c] = prod['linha'].map(texto(mar[c])) if c in mar else None
    for c in ATRIB:
        prod[c] = prod[c].fillna('N/D')
    prod['nome'] = e.dropna(subset=['descricao']).drop_duplicates('sku').set_index('sku')['descricao'].reindex(skus)

    # clientes: dados da venda mais recente de cada código
    cli = v.sort_values('data').groupby('codcli').agg(razao=('razao', 'last'), tipo_cliente=('tipo_cliente', 'last'),
                                                      cidade=('cidade', 'last'))
    return v, e, prod, cli


# ---------------------------------------------------------------- códigos fixos
def ids_dims(cur, valores):
    """valores = {tipo: set(textos)} -> {tipo: {texto: id}}, mantendo os ids já gravados e acrescentando os novos."""
    cur.execute('select tipo, id, valor from public.bi_dim')
    atual = {}
    for tipo, id_, valor in cur.fetchall():
        atual.setdefault(tipo, {})[valor] = id_
    novos = []
    for tipo, vals in valores.items():
        m = atual.setdefault(tipo, {})
        prox = max(m.values(), default=0) + 1
        for x in sorted(vals - set(m)):
            m[x] = prox
            novos.append((tipo, prox, x))
            prox += 1
        if prox > 32000:
            raise ValueError(f'dimensão {tipo} com valores demais para o painel')
    if novos:
        cur.executemany('insert into public.bi_dim (tipo, id, valor) values (%s, %s, %s)', novos)
    return atual, len(novos)


def ids_chave(cur, tabela, coluna, chaves):
    cur.execute(f'select {coluna}, id from public.{tabela}')
    atual = dict(cur.fetchall())
    prox = max(atual.values(), default=0) + 1
    for k in sorted(set(chaves) - set(atual)):
        atual[k] = prox
        prox += 1
    return atual


# ---------------------------------------------------------------- gravação
def gravar_infobi(conn, dfs, regras, loja_info_atual, arq):
    agora = datetime.now(timezone.utc).isoformat()
    v, e, prod, cli = preparar(dfs, regras)
    ini, fim = v['data'].min().date(), v['data'].max().date()
    log(f'vendas do arquivo: {len(v)} linhas, {(fim - ini).days + 1} dias')

    with conn.transaction():
        cur = conn.cursor()
        cur.execute("""insert into public.bi_carga_controle (arquivo_id, arquivo_nome, modificado_em, md5, status)
                       values (%s, %s, %s, %s, 'processando') returning id""",
                    (arq['id'], arq['nome'], arq['modificado'], arq['md5']))
        id_carga = cur.fetchone()[0]

        valores = {t: set(v[t].unique()) for t in DIMS}
        for t in ATRIB:
            valores[t] |= set(prod[t].unique())
        valores['loja'] |= set(e['loja'].unique())
        dims, n_novos = ids_dims(cur, valores)

        # produtos: insere os novos e atualiza os atributos dos que vieram no arquivo (nome só se o estoque trouxe)
        pid = ids_chave(cur, 'bi_produto', 'pn', prod.index)
        p = pd.DataFrame({'id': prod.index.map(pid), 'pn': prod.index, 'nome': prod['nome']})
        for c in ATRIB:
            p[c] = prod[c].map(dims[c]).astype('int64')
        cur.execute('create temp table _p (like public.bi_produto) on commit drop')
        copiar_tab(cur, '_p', p)
        cur.execute(f"""update public.bi_produto b set nome = coalesce(t.nome, b.nome), {', '.join(f'{c} = t.{c}' for c in ATRIB)}
                        from _p t where b.id = t.id""")
        cur.execute(f"""insert into public.bi_produto (id, pn, nome, {', '.join(ATRIB)})
                        select id, pn, coalesce(nome, pn), {', '.join(ATRIB)} from _p t
                        where not exists (select 1 from public.bi_produto b where b.id = t.id)""")

        # clientes
        cid = ids_chave(cur, 'bi_cliente', 'codcli', cli.index)
        c = pd.DataFrame({'id': cli.index.map(cid), 'codcli': cli.index, 'razao': cli['razao'],
                          'tipo_cliente': cli['tipo_cliente'].fillna('N/D').map(dims['tipo_cliente']).astype('int64'),
                          'cidade': cli['cidade'].fillna('N/D').map(dims['cidade']).astype('int64')})
        cur.execute('create temp table _c (like public.bi_cliente) on commit drop')
        copiar_tab(cur, '_c', c)
        cur.execute("""update public.bi_cliente b set razao = coalesce(t.razao, b.razao), tipo_cliente = t.tipo_cliente,
                       cidade = t.cidade from _c t where b.id = t.id""")
        cur.execute("""insert into public.bi_cliente (id, codcli, razao, tipo_cliente, cidade)
                       select id, codcli, razao, tipo_cliente, cidade from _c t
                       where not exists (select 1 from public.bi_cliente b where b.id = t.id)""")

        # vendas do período do arquivo
        out = pd.DataFrame({'dia': v['data'].dt.date, 'mes': (v['data'].dt.year - 2000) * 100 + v['data'].dt.month})
        for t in DIMS:
            out[t] = v[t].map(dims[t]).astype('int64')
        out['produto'] = v['sku'].map(pid).astype('int64')
        out['cliente'] = v['codcli'].map(cid).astype('int64')
        out['nf'] = v['nf']
        out['qtd'] = v['qtd'].round().astype('int64')
        for col in ('fat', 'custo', 'lb'):
            out[col] = centavos(v[col])
        cur.execute('delete from public.bi_venda_det where dia between %s and %s', (ini, fim))
        cur.execute('delete from public.bi_venda_hist where dia between %s and %s', (ini, fim))
        det = out[out['dia'] >= CORTE]
        hist = out[out['dia'] < CORTE].groupby(COLS_HIST[:-4], as_index=False)[['qtd', 'fat', 'custo', 'lb']].sum()
        for df, nome in ((det, 'det'), (hist, 'hist')):
            if len(df) and df[['fat', 'custo', 'lb', 'qtd']].abs().max().max() >= 2**31:
                raise ValueError(f'valor acima do limite da base ({nome})')
        if len(det):
            copiar(cur, 'bi_venda_det', det[COLS_DET])
        if len(hist):
            copiar(cur, 'bi_venda_hist', hist[COLS_HIST])
        log(f'vendas gravadas: {len(det)} detalhadas, {len(hist)} resumidas (de {int((out["dia"] < CORTE).sum())} linhas)')

        # estoque inteiro, só quando o arquivo é o mais recente (um arquivo de anos anteriores não mexe no estoque atual)
        cur.execute('select max(dia) from public.bi_venda')
        ultimo = cur.fetchone()[0]
        trocar_estoque = ultimo is None or fim >= ultimo
        if not trocar_estoque:
            log('arquivo de período anterior: estoque atual mantido')
            e = e.iloc[0:0]
        else:
            cur.execute('delete from public.bi_estoque')
        est = pd.DataFrame({'loja': e['loja'].map(dims['loja']).astype('int64'), 'produto': e['sku'].map(pid).astype('int64'),
                            'est_fis': e['est_fis'].round(3), 'custo': e['est_custo'].round(2),
                            'dt_ult_vend': e['dt_ult_vend'].dt.strftime('%Y-%m-%d'),
                            'dt_ult_comp': e['dt_ult_comp'].dt.strftime('%Y-%m-%d'), 'parado': e['parado'].astype(bool)})
        if trocar_estoque:
            copiar(cur, 'bi_estoque', est)

        # limpeza: o que nenhuma linha usa mais
        cur.execute("""delete from public.bi_produto p where not exists (select 1 from public.bi_venda v where v.produto = p.id)
                       and not exists (select 1 from public.bi_estoque e where e.produto = p.id)""")
        cur.execute('delete from public.bi_cliente c where not exists (select 1 from public.bi_venda v where v.cliente = c.id)')
        usos = {t: [f'select distinct {t} from public.bi_venda'] for t in DIMS}
        for t in ATRIB:
            usos[t].append(f'select distinct {t} from public.bi_produto')
        usos['loja'].append('select distinct loja from public.bi_estoque')
        usos['tipo_cliente'].append('select distinct tipo_cliente from public.bi_cliente')
        usos['cidade'].append('select distinct cidade from public.bi_cliente')
        for t, qs in usos.items():
            cur.execute(f"delete from public.bi_dim d where d.tipo = %s and d.id not in ({' union '.join(qs)})", (t,))

        cur.execute('delete from public.bi_vendedor_loja')
        cur.execute("""insert into public.bi_vendedor_loja (vendedor, loja)
                       select distinct dv.valor, dl.valor from (select distinct vendedor, loja from public.bi_venda) v
                       join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = v.vendedor
                       join public.bi_dim dl on dl.tipo = 'loja' and dl.id = v.loja""")

        config, metas = config_do_banco(cur, regras, loja_info_atual)
        if metas is not None:
            cur.execute('delete from public.bi_meta_vendedor')
            cur.executemany('insert into public.bi_meta_vendedor (vendedor, meta) values (%s, %s)', metas)
        config['carga'] = {'carregado_em': agora, 'dados_ate': config.pop('_dados_ate'), 'origem': arq['nome']}
        for chave, valor in config.items():
            cur.execute("""insert into public.bi_config (chave, valor) values (%s, %s::jsonb)
                           on conflict (chave) do update set valor = excluded.valor""",
                        (chave, json.dumps(valor, ensure_ascii=False)))
        cur.execute('delete from public.bi_cache')
        cur.execute("update public.bi_carga_controle set status = 'ok', linhas = %s, concluido_em = now() where id = %s",
                    (int(len(v)), id_carga))
    log(f'{n_novos} valores novos de dimensão; {len(e)} itens de estoque, {int(e["parado"].sum())} parados')
    return config


def config_do_banco(cur, regras, loja_info_atual):
    cur.execute('select min(dia), max(dia) from public.bi_venda')
    ini, fim = cur.fetchone()
    meses = pd.period_range(pd.Timestamp(ini).to_period('M'), pd.Timestamp(fim).to_period('M'), freq='M')
    cur.execute("""select distinct on (dl.valor) dl.valor, dc.valor
                   from (select loja, canal, sum(fat) f from public.bi_venda where dia > %s - 365 group by 1, 2) v
                   join public.bi_dim dl on dl.tipo = 'loja' and dl.id = v.loja
                   join public.bi_dim dc on dc.tipo = 'canal' and dc.id = v.canal
                   order by dl.valor, v.f desc""", (fim,))
    canal = dict(cur.fetchall())
    cur.execute("select valor from public.bi_dim where tipo = 'loja' order by valor")
    lojas = [(l, canal.get(l)) for (l,) in cur.fetchall()]
    atual = loja_info_atual or {}
    loja_info = {l: atual.get(l) or {'fisica': 'COMMERCE' not in normaliza(canal or '')} for l, canal in lojas}
    n_meses = max(1.0, ((fim - ini).days + 1) / (365.25 / 12))
    metas = None
    fator = regras.get('meta_fator')
    if fator:
        # sem planilha de metas: média mensal dos últimos 12 meses x fator
        de = max(ini, (pd.Timestamp(fim) - pd.DateOffset(years=1) + pd.Timedelta(days=1)).date())
        n12 = max(1.0, ((fim - de).days + 1) / (365.25 / 12))
        cur.execute("""select dv.valor, sum(v.fat) / 100.0 from public.bi_venda v
                       join public.bi_dim dv on dv.tipo = 'vendedor' and dv.id = v.vendedor
                       where v.dia >= %s and dv.valor <> %s group by dv.valor order by 1""", (de, regras['vendedor_vazio']))
        metas = [(n, round(float(f) / n12 * fator, 2)) for n, f in cur.fetchall()]
    return {'months': [f'{p.year}-{p.month}' for p in meses], 'monthLabels': [MESES[p.month - 1] for p in meses],
            'lojas': [l for l, _ in lojas], 'lojaInfo': loja_info, 'mesesEfetivos': round(n_meses, 4),
            '_dados_ate': fim.isoformat()}, metas


def regras_infobi(mapa):
    spec = mapa['infobi']
    return {**PADROES, 'dias_parado': 270, **mapa.get('regras', {}), **spec.get('regras', {}),
            'apelidos_loja': spec.get('apelidos_loja', {})}
