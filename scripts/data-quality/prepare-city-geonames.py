import sys,json,re,unicodedata,zipfile,math,collections,time
from pathlib import Path
D=Path(sys.argv[1]) # cities.json plus the official allCountries.zip
rows=json.loads((D/'cities.json').read_text()); active=[c for c in rows if not c['duplicate_of_id']]
def norm(s):
 s=str(s or '').casefold().replace('ß','ss').replace('æ','ae').replace('ø','o').replace('œ','oe').replace('ł','l')
 return re.sub(r'[^\w]+',' ',''.join(c for c in unicodedata.normalize('NFD',s) if not unicodedata.combining(c)),flags=re.UNICODE).strip()
def names(c):
 ns=[c['name'],c['name_en'],c['name_de'],c['name_local']]
 if isinstance(c['name_i18n'],dict):ns+=list(c['name_i18n'].values())
 return set(norm(x) for x in ns if isinstance(x,str) and x.strip())
keys=collections.defaultdict(set)
for c in active:
 for n in names(c):keys[c['country_code']].add(n)
matched=[];start=time.time()
with zipfile.ZipFile(D/'allCountries.zip') as z:
 with z.open('allCountries.txt') as f:
  for i,raw in enumerate(f):
   a=raw.decode('utf8').rstrip('\n').split('\t')
   if len(a)<19 or a[8] not in keys:continue
   nms=[a[1],a[2]] + (a[3].split(',') if a[6] in ['P','A'] else [])
   hits=set(norm(n) for n in nms if n) & keys[a[8]]
   if hits:
    matched.append({'id':a[0],'name':a[1],'ascii':a[2],'keys':list(hits),'lat':float(a[4]),'lng':float(a[5]),'class':a[6],'code':a[7],'country':a[8],'admin1':a[10],'admin2':a[11],'population':int(a[14] or 0)})
   if i%1000000==0:print(f'Gazetteer {i:,} records scanned; {len(matched):,} name matches',flush=True)
(D/'geonames-matches.json').write_text(json.dumps(matched,ensure_ascii=False));print(f'{len(matched)} matching gazetteer records, {time.time()-start:.1f}s',flush=True)
idx=collections.defaultdict(list)
for g in matched:
 for k in g['keys']:idx[(g['country'],k)].append(g)
def distance(a,b):
 if a['latitude'] is None or a['longitude'] is None:return None
 lat1,lng1,lat2,lng2=map(math.radians,[float(a['latitude']),float(a['longitude']),b['lat'],b['lng']])
 return 6371000*2*math.asin(min(1,math.sqrt(math.sin((lat2-lat1)/2)**2+math.cos(lat1)*math.cos(lat2)*math.sin((lng2-lng1)/2)**2)))
out=[]
for c in active:
 candidates={g['id']:g for n in names(c) for g in idx[(c['country_code'],n)]}
 found=[dict(g,distance_m=distance(c,g)) for g in candidates.values()]
 found.sort(key=lambda g:g['distance_m'] if g['distance_m'] is not None else 1e15)
 nearby=[g for g in found if g['distance_m'] is not None and g['distance_m']<=10000]
 out.append({'id':c['id'],'name':c['name'],'country':c['country_code'],'qid':c['wikidata_qid'],'matches':nearby or found[:3],'has_nearby':bool(nearby)})
(D/'geonames-audit.json').write_text(json.dumps(out,ensure_ascii=False));print(collections.Counter(('nearby-'+x['matches'][0]['code']) if x['has_nearby'] else 'unresolved' for x in out))
