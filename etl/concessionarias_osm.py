"""Concessionárias Chevrolet no Brasil a partir do OpenStreetMap (dados abertos, licença ODbL).
O site da Chevrolet bloqueia acesso automatizado, então usamos o OSM. Gera concessionarias.json (só dados públicos)."""
import json, urllib.request, urllib.parse
Q = '''[out:json][timeout:180];
area["ISO3166-1"="BR"][admin_level=2]->.br;
( nwr["shop"="car"]["brand"~"chevrolet",i](area.br);
  nwr["shop"="car"]["name"~"chevrolet",i](area.br);
  nwr["shop"="car"]["brand:wikidata"="Q29570"](area.br);
  nwr["shop"="car_parts"]["name"~"chevrolet",i](area.br);
  nwr["shop"="car_repair"]["name"~"chevrolet",i](area.br); );
out center tags;'''
req = urllib.request.Request('https://overpass-api.de/api/interpreter', data=urllib.parse.urlencode({'data': Q}).encode(),
                             headers={'User-Agent': 'bi-mapa-concessionarias/1.0'})
d = json.load(urllib.request.urlopen(req, timeout=240))
out = []
for e in d['elements']:
    t = e.get('tags', {}); lat = e.get('lat') or (e.get('center') or {}).get('lat'); lon = e.get('lon') or (e.get('center') or {}).get('lon')
    if lat is None: continue
    out.append({'n': t.get('name', ''), 'shop': t.get('shop'), 'uf': t.get('addr:state', ''), 'cid': t.get('addr:city', ''),
                'end': ' '.join(x for x in [t.get('addr:street', ''), t.get('addr:housenumber', '')] if x),
                'lat': round(lat, 5), 'lon': round(lon, 5), 'brand': t.get('brand', ''),
                'pecas': t.get('service:vehicle:parts') or t.get('service:vehicle:car_parts') or '', 'tel': t.get('phone', '') or t.get('contact:phone', '')})
json.dump(out, open('concessionarias.json', 'w'), ensure_ascii=False)
print(len(out), 'registros')
from collections import Counter
print(Counter(o['shop'] for o in out)); print(Counter(o['uf'] for o in out).most_common(10))
for o in out[:15]: print(o)
