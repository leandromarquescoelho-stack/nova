"""Concessionárias Chevrolet a partir do OpenStreetMap (dados abertos, licença ODbL).
O site da Chevrolet bloqueia acesso automatizado, então usamos o OSM. Imprime cada registro (só dados públicos) com o prefixo CONC|."""
import json, sys, time, urllib.request, urllib.parse
UFS = sys.argv[1:] or ['SP']
def consulta(uf):
    q = f'''[out:json][timeout:120];
area["ISO3166-2"="BR-{uf}"]->.a;
( nwr["shop"~"^(car|car_parts|car_repair)$"]["brand"~"chevrolet",i](area.a);
  nwr["shop"~"^(car|car_parts|car_repair)$"]["name"~"chevrolet",i](area.a);
  nwr["shop"~"^(car|car_parts|car_repair)$"]["brand:wikidata"="Q29570"](area.a); );
out center tags;'''
    req = urllib.request.Request('https://overpass-api.de/api/interpreter', data=urllib.parse.urlencode({'data': q}).encode(),
                                 headers={'User-Agent': 'bi-mapa-concessionarias/1.0'})
    return json.load(urllib.request.urlopen(req, timeout=180))
for uf in UFS:
    for tent in range(3):
        try:
            d = consulta(uf); break
        except Exception as e:
            print(uf, 'erro', type(e).__name__, e, flush=True); time.sleep(20); d = None
    if not d: continue
    n = 0
    for e in d.get('elements', []):
        t = e.get('tags', {}); c = e.get('center') or {}
        lat = e.get('lat', c.get('lat')); lon = e.get('lon', c.get('lon'))
        if lat is None: continue
        n += 1
        print('CONC|' + json.dumps({'uf': uf, 'n': t.get('name', ''), 'shop': t.get('shop'), 'brand': t.get('brand', ''), 'cid': t.get('addr:city', ''),
              'end': ' '.join(x for x in [t.get('addr:street', ''), t.get('addr:housenumber', '')] if x),
              'lat': round(lat, 5), 'lon': round(lon, 5), 'tel': t.get('phone', '') or t.get('contact:phone', '')}, ensure_ascii=False))
    print(uf, n, 'registros', d.get('remark', ''), flush=True)
    time.sleep(5)
