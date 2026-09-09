import hashlib,json,sys,tempfile,unittest,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import appearance as A

class AppearanceTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.model=self.root/'model.glb';self.model.write_bytes(b'unchanged model');self.library=self.root/'library'
  self.manifest={'format':'openclam-appearance','version':1,'id':'example','label':'Example','modelSHA256':A.digest(self.model),'files':{'asset.bin':{'bytes':4,'sha256':hashlib.sha256(b'test').hexdigest()}},'items':[{'id':'hair','label':'Original hair','kind':'hair','nodes':['hair']} ]}
 def tearDown(self):self.temp.cleanup()
 def pack(self,manifest=None,extra=None):
  path=self.root/'pack.oclook'
  with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED)as z:
   z.writestr('appearance.json',json.dumps(manifest or self.manifest));z.writestr('asset.bin',b'test')
   if extra:z.writestr(extra,b'bad')
  return path
 def test_install_is_optional_and_model_is_unchanged(self):
  before=A.digest(self.model);A.install(self.pack(),self.library,self.model)
  self.assertEqual(A.digest(self.model),before);self.assertEqual(A.index(self.library)['packs'][0]['id'],'example')
  A.remove(self.library,'example');self.assertEqual(A.index(self.library)['packs'],[]);self.assertEqual(A.digest(self.model),before)
 def test_failed_replacement_keeps_installed_index(self):
  A.install(self.pack(),self.library,self.model);before=(self.library/'index.json').read_bytes()
  self.manifest['files']['asset.bin']['sha256']='0'*64
  with self.assertRaises(A.AppearanceError):A.install(self.pack(),self.library,self.model)
  self.assertEqual((self.library/'index.json').read_bytes(),before)
 def test_reimport_repairs_corrupt_installed_asset(self):
  archive=self.pack();A.install(archive,self.library,self.model)
  first=A.index(self.library)['packs'][0]['directory'];(self.library/first/'asset.bin').write_bytes(b'bad')
  A.install(archive,self.library,self.model);second=A.index(self.library)['packs'][0]['directory']
  self.assertNotEqual(first,second);self.assertEqual((self.library/second/'asset.bin').read_bytes(),b'test');self.assertFalse((self.library/first).exists())
 def test_oversized_texture_is_rejected_before_decode(self):
  from PIL import Image
  import io
  out=io.BytesIO();Image.new('RGB',(4096,1)).save(out,format='PNG');data=out.getvalue()
  self.manifest['files']={'large.png':{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}}
  path=self.root/'large.oclook'
  with zipfile.ZipFile(path,'w') as z:
   z.writestr('appearance.json',json.dumps(self.manifest));z.writestr('large.png',data)
  with self.assertRaisesRegex(A.AppearanceError,'2048'):A.install(path,self.library,self.model)
  self.assertFalse((self.library/'index.json').exists())
 def test_download_cancel_does_not_install(self):
  from unittest.mock import patch,MagicMock
  response=MagicMock();response.__enter__.return_value=response;response.headers={};response.read.return_value=b'part'
  with patch.object(A,'check_download_url',return_value='https://example.com/a'),patch.object(A.urllib.request,'build_opener') as opener:
   opener.return_value.open.return_value=response
   with self.assertRaisesRegex(A.AppearanceError,'cancelled'):A.download('https://example.com/a',self.root/'download',cancelled=lambda:True)
  self.assertFalse(self.library.exists())
 def test_app_import_download_and_remove_endpoints(self):
  import asyncio,importlib,io,shutil
  from unittest.mock import patch
  from starlette.datastructures import UploadFile
  server=importlib.import_module('server.app')
  archive=self.pack()
  async def check():
   with patch.object(server,'_appearance_paths',return_value=(str(self.library),str(self.model))):
    value=await server.api_appearance_import(UploadFile(file=io.BytesIO(archive.read_bytes()),filename='test.oclook'))
    self.assertEqual(value,{'installed':'Example'})
    await server.api_appearance_remove('example');self.assertEqual(A.index(self.library)['packs'],[])
    def fetch(url,target,cancel,progress):
     shutil.copyfile(archive,target);progress(archive.stat().st_size,archive.stat().st_size)
    with patch.object(server.APPEARANCE,'download',side_effect=fetch):
     response=await server.api_appearance_download(server.AppearanceDownloadRequest(url='https://example.com/test.oclook'))
     events=[json.loads(chunk) async for chunk in response.body_iterator]
    self.assertEqual(events[-1],{'installed':'Example','done':True});self.assertTrue(events[0]['received']>0)
    self.assertEqual(A.index(self.library)['packs'][0]['id'],'example')
  asyncio.run(check())
 def test_wrong_model_rejected(self):
  self.manifest['modelSHA256']='0'*64
  with self.assertRaisesRegex(A.AppearanceError,'different model'):A.install(self.pack(),self.library,self.model)
  self.assertFalse(self.library.exists())
 def test_path_traversal_rejected(self):
  with self.assertRaises(A.AppearanceError):A.install(self.pack(extra='../escape'),self.library,self.model)
  self.assertFalse((self.root.parent/'escape').exists())
 def test_executable_asset_rejected(self):
  self.manifest['files']['code.js']={'bytes':4,'sha256':'0'*64}
  with self.assertRaises(A.AppearanceError):A.validate(self.manifest)
 def test_expression_file_must_exist(self):
  self.manifest['items']=[{'id':'smile','label':'Smile','kind':'expression','file':'missing.json'}]
  with self.assertRaises(A.AppearanceError):A.validate(self.manifest)
 def test_non_https_and_credentials_rejected(self):
  for url in ['file:///etc/passwd','http://example.com/pack','https://user:secret@example.com/pack']:
   with self.assertRaises(A.AppearanceError):A.check_download_url(url)

if __name__=='__main__':unittest.main()
