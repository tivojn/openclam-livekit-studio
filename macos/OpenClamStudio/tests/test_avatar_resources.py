import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import avatar_resources


class AvatarResourcesTests(unittest.TestCase):
    def fixture(self, root):
        geometry=struct.pack('<9f',0,0,0,1,0,0,0,1,0)
        bitmap=io.BytesIO();Image.new('RGBA',(16,16),(30,80,140,128)).save(bitmap,'PNG')
        image=bitmap.getvalue();binary=geometry+image
        while len(binary)%4:binary+=b'\0'
        doc={'asset':{'version':'2.0'},'buffers':[{'byteLength':len(binary)}],
             'bufferViews':[{'buffer':0,'byteOffset':0,'byteLength':len(geometry)}, {'buffer':0,'byteOffset':len(geometry),'byteLength':len(image)}],
             'accessors':[{'bufferView':0,'componentType':5126,'count':3,'type':'VEC3','min':[0,0,0],'max':[1,1,0]}],
             'images':[{'bufferView':1,'mimeType':'image/png'}],
             'textures':[{'source':0}], 'materials':[{'alphaMode':'BLEND','pbrMetallicRoughness':{'baseColorTexture':{'index':0}}}],
             'meshes':[{'primitives':[{'attributes':{'POSITION':0},'material':0}]}],
             'nodes':[{'name':'Coat','mesh':0}],'scenes':[{'nodes':[0]}],
             'extras':{'openclamAvatar':{'outfits':[{'id':'coat','nodes':['Coat']}]}}}
        raw=json.dumps(doc).encode();raw+=b' '*((-len(raw))%4)
        data=struct.pack('<III',0x46546c67,2,28+len(raw)+len(binary))+struct.pack('<II',len(raw),0x4e4f534a)+raw+struct.pack('<II',len(binary),0x004e4942)+binary
        source=root/'source.glb';source.write_bytes(data)
        return source,geometry

    def test_split_preserves_original_geometry_alpha_and_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source,geometry=self.fixture(root);before=source.read_bytes()
            model=avatar_resources.build(source,root/'resident');doc=json.loads(model.read_text())
            self.assertEqual(before,source.read_bytes())
            self.assertEqual(doc['materials'][0]['alphaMode'],'BLEND')
            self.assertTrue(doc['meshes'][0]['extras']['openclamDeferred'])
            view=doc['bufferViews'][doc['accessors'][0]['bufferView']]
            buffer=(model.parent/doc['buffers'][view['buffer']]['uri']).read_bytes()
            self.assertEqual(buffer[view['byteOffset']:view['byteOffset']+view['byteLength']],geometry)
            image=Image.open(model.parent/doc['images'][0]['uri'])
            self.assertEqual(image.size,(1,1),'exactly uniform images need only one texel')
            self.assertEqual(image.getpixel((0,0)),(30,80,140,128))
            modified=model.stat().st_mtime_ns
            self.assertEqual(avatar_resources.build(source,root/'resident'),model)
            self.assertEqual(model.stat().st_mtime_ns,modified,'startup reuses cache without encoding')

    def test_revision_invalidates_derived_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source,_=self.fixture(root)
            model=avatar_resources.build(source,root/'resident');old=json.loads((model.parent/'source.json').read_text())['revision']
            import os
            st=source.stat();os.utime(source,ns=(st.st_atime_ns,st.st_mtime_ns+1000000))
            avatar_resources.build(source,root/'resident')
            self.assertNotEqual(json.loads((model.parent/'source.json').read_text())['revision'],old)


if __name__=='__main__':unittest.main()
