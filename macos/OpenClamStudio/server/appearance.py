"""Validated, optional appearance packs. Runtime assets only; no authoring code."""
from __future__ import annotations
import hashlib,ipaddress,json,math,os,re,shutil,socket,tempfile,threading,urllib.parse,urllib.request,zipfile
from pathlib import Path
from PIL import Image

MAX_BYTES=384*1024*1024
MAX_FILE_BYTES=32*1024*1024
NAME=re.compile(r'^[a-z0-9][a-z0-9._-]{0,79}$')
ID=re.compile(r'^[a-z0-9][a-z0-9-]{0,47}$')
SHA=re.compile(r'^[a-f0-9]{64}$')
KINDS={'clothes','hair','texture','expression'}
_lock=threading.Lock()

class AppearanceError(ValueError):pass

def digest(path):
    with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def validate(manifest):
    if not isinstance(manifest,dict) or manifest.get('format')!='openclam-appearance' or manifest.get('version')!=1:raise AppearanceError('Choose an OpenClam appearance pack.')
    if not ID.fullmatch(str(manifest.get('id',''))) or not SHA.fullmatch(str(manifest.get('modelSHA256',''))):raise AppearanceError('Invalid pack identity.')
    if not isinstance(manifest.get('label'),str) or not 1<=len(manifest['label'])<=80:raise AppearanceError('Invalid pack name.')
    files=manifest.get('files')
    if not isinstance(files,dict) or not 1<=len(files)<=256:raise AppearanceError('Invalid pack contents.')
    total=0
    for name,entry in files.items():
        if not NAME.fullmatch(name) or name=='appearance.json' or Path(name).suffix not in {'.png','.jpg','.bin','.json'}:raise AppearanceError('Unsupported asset path.')
        if not isinstance(entry,dict) or type(entry.get('bytes'))is not int or not 0<entry['bytes']<=MAX_FILE_BYTES or not SHA.fullmatch(str(entry.get('sha256',''))):raise AppearanceError('Invalid asset size or checksum.')
        total+=entry['bytes']
    if total>MAX_BYTES:raise AppearanceError('Appearance pack is too large.')
    items=manifest.get('items',[])
    if not isinstance(items,list) or len(items)>256:raise AppearanceError('Too many appearance choices.')
    ids=set()
    for item in items:
        if not isinstance(item,dict) or not ID.fullmatch(str(item.get('id',''))) or item['id'] in ids or item.get('kind') not in KINDS:raise AppearanceError('Invalid appearance choice.')
        ids.add(item['id'])
        if item.get('slot') is not None and (not isinstance(item['slot'],str) or not ID.fullmatch(item['slot'])):raise AppearanceError('Invalid texture slot.')
        if item.get('region') is not None and item['region'] not in {'mouth','eyes','brows'}:raise AppearanceError('Invalid facial region.')
        if not isinstance(item.get('label'),str) or not 1<=len(item['label'])<=80:raise AppearanceError('Invalid appearance label.')
        if item.get('file')is not None and item['file'] not in files:raise AppearanceError('Missing appearance asset.')
        if item['kind'] in {'texture','expression'} and not item.get('file'):raise AppearanceError('Missing appearance data.')
        if item['kind']=='texture' and (not isinstance(item.get('material'),str) or Path(item['file']).suffix not in {'.png','.jpg'}):raise AppearanceError('Invalid texture choice.')
        if item['kind']=='expression' and not item['file'].endswith('.json'):raise AppearanceError('Invalid facial data.')
        for key in ['nodes','hideNodes']:
            if key in item and (not isinstance(item[key],list) or len(item[key])>64 or any(not isinstance(n,str) or not 0<len(n)<=160 for n in item[key])):raise AppearanceError('Invalid wardrobe selection.')
    env=manifest.get('environment')
    if env is not None:
        if not isinstance(env,dict) or env.get('file') not in files or any(type(env.get(k))is not int or not 1<=env[k]<=1024 for k in ['width','height']) or files[env['file']]['bytes']!=env['width']*env['height']*8:raise AppearanceError('Invalid studio environment.')
        if env.get('rotation') is not None and (not isinstance(env['rotation'],(int,float)) or not math.isfinite(env['rotation'])):raise AppearanceError('Invalid environment rotation.')
    return manifest

def index(root):
    path=Path(root)/'index.json'
    if not path.exists():return {'version':1,'packs':[]}
    if path.stat().st_size>2*1024*1024:raise AppearanceError('Invalid installed appearance index.')
    value=json.loads(path.read_text())
    if value.get('version')!=1 or not isinstance(value.get('packs'),list) or len(value['packs'])>16:raise AppearanceError('Invalid installed appearance index.')
    return value

def install(archive,root,model):
    root=Path(root);archive=Path(archive)
    if archive.is_symlink() or not archive.is_file() or not 0<archive.stat().st_size<=MAX_BYTES:raise AppearanceError('Appearance pack is empty or too large.')
    with zipfile.ZipFile(archive) as z:
        entries=z.infolist()
        if not 2<=len(entries)<=257 or len({e.filename for e in entries})!=len(entries):raise AppearanceError('Invalid archive entries.')
        for e in entries:
            if not NAME.fullmatch(e.filename) or e.is_dir() or e.flag_bits&1 or ((e.external_attr>>16)&0o170000)not in {0,0o100000}:raise AppearanceError('Unsupported archive entry.')
            if not 0<e.file_size<=MAX_FILE_BYTES:raise AppearanceError('Asset exceeds the size limit.')
        if sum(e.file_size for e in entries)>MAX_BYTES:raise AppearanceError('Expanded pack is too large.')
        info=z.getinfo('appearance.json')
        if info.file_size>512*1024:raise AppearanceError('Appearance manifest is too large.')
        manifest=validate(json.loads(z.read(info)))
        if set(manifest['files'])|{'appearance.json'}!={e.filename for e in entries}:raise AppearanceError('Unexpected pack files.')
        if digest(model)!=manifest['modelSHA256']:raise AppearanceError('This pack was made for a different model. Import its matching avatar package first.')
        root.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.install-',dir=root) as temporary:
            stage=Path(temporary)
            for name,entry in manifest['files'].items():
                if z.getinfo(name).file_size!=entry['bytes']:raise AppearanceError('Asset size does not match the manifest.')
                h=hashlib.sha256();count=0
                with z.open(name) as src,(stage/name).open('wb') as dest:
                    while chunk:=src.read(1024*1024):
                        count+=len(chunk)
                        if count>entry['bytes']:raise AppearanceError('Asset exceeded its declared size.')
                        h.update(chunk);dest.write(chunk)
                if count!=entry['bytes'] or h.hexdigest()!=entry['sha256']:raise AppearanceError('Asset integrity check failed.')
                if Path(name).suffix in {'.png','.jpg'}:
                    with Image.open(stage/name) as image:
                        if image.format not in {'PNG','JPEG'} or max(image.size)>2048:raise AppearanceError('Appearance textures must be PNG/JPEG and no larger than 2048 pixels.')
            revision=digest(archive)[:20];folder=manifest['id']+'-'+revision
            with _lock:
                current=index(root)
                previous=[p.get('directory','') for p in current['packs'] if p['id']==manifest['id']]
                packs=[p for p in current['packs'] if p['id']!=manifest['id']]
                if len(packs)>=16:raise AppearanceError('Remove an appearance pack before adding another.')
                target=root/folder
                if target.exists() and any(not (target/n).is_file() or (target/n).is_symlink() or digest(target/n)!=f['sha256'] for n,f in manifest['files'].items()):
                    # Repair into a fresh immutable directory, then switch the index.
                    folder+='-'+os.urandom(4).hex();target=root/folder
                packs.append({**manifest,'directory':folder})
                encoded=json.dumps({'version':1,'packs':packs},separators=(',',':'))
                if len(encoded.encode())>2*1024*1024:raise AppearanceError('Installed appearance catalogue is too large.')
                if not target.exists():shutil.copytree(stage,target)
                tmp=root/'index.json.partial';tmp.write_text(encoded);os.replace(tmp,root/'index.json')
                for old in previous:
                    if old!=folder and NAME.fullmatch(old):shutil.rmtree(root/old,ignore_errors=True)
    return manifest

def remove(root,pack_id):
    if not ID.fullmatch(pack_id):raise AppearanceError('Invalid pack identifier.')
    root=Path(root)
    with _lock:
        if not root.exists():return {'version':1,'packs':[]}
        current=index(root);old=[p for p in current['packs'] if p['id']==pack_id]
        value={'version':1,'packs':[p for p in current['packs'] if p['id']!=pack_id]}
        tmp=root/'index.json.partial';tmp.write_text(json.dumps(value));os.replace(tmp,root/'index.json')
        # Renderer releases the active resources on refresh; detached version
        # directories can then be removed without touching the avatar model.
        for p in old:
            if NAME.fullmatch(p.get('directory','')):shutil.rmtree(root/p['directory'],ignore_errors=True)
    return value

def check_download_url(value):
    u=urllib.parse.urlsplit(value)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.fragment:raise AppearanceError('Use a direct HTTPS link to an appearance pack.')
    try:
        addresses=socket.getaddrinfo(u.hostname,u.port or 443,type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global for a in addresses):raise AppearanceError('Use a public HTTPS download link; import local packs from Files.')
    except (OSError,ValueError)as e:raise AppearanceError('The download address could not be verified.')from e
    return value

class _Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        return super().redirect_request(req,fp,code,msg,headers,check_download_url(newurl))

def download(url,destination,cancelled=lambda:False,progress=lambda received,total:None):
    opener=urllib.request.build_opener(_Redirects(),urllib.request.ProxyHandler({}))
    with opener.open(check_download_url(url),timeout=30)as response,open(destination,'wb')as out:
        if int(response.headers.get('Content-Length')or 0)>MAX_BYTES:raise AppearanceError('The download is too large.')
        received=0
        while chunk:=response.read(1024*1024):
            if cancelled():raise AppearanceError('Download cancelled.')
            received+=len(chunk)
            if received>MAX_BYTES:raise AppearanceError('The download exceeded the size limit.')
            out.write(chunk)
            progress(received,int(response.headers.get('Content-Length')or 0))
        if not received:raise AppearanceError('The download was empty.')
