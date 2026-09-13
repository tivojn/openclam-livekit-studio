"""Derived, disposable GPU assets. Original GLB geometry/materials stay unchanged.

Split independent meshes and images so GLTFLoader need only fetch the selected
wardrobe. Optional Basis Universal conversion is an offline authoring step;
normal imports work with lossless PNG and never compile textures at startup.
"""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
from PIL import Image

VERSION = 1
_lock = threading.Lock()


def build(source, destination, encoder=None):
    source, destination = Path(source), Path(destination)
    revision = f'{source.stat().st_mtime_ns:x}-{source.stat().st_size:x}'
    marker = destination / 'source.json'
    with _lock:
        if marker.exists():
            saved = json.loads(marker.read_text())
            if saved.get('revision') == revision and saved.get('version') == VERSION and (not encoder or saved.get('compressed')):
                return destination / 'model.gltf'
        data = source.read_bytes()
        if data[:4] != b'glTF' or struct.unpack_from('<I', data, 4)[0] != 2:
            raise ValueError('Expected glTF 2 binary')
        length, kind = struct.unpack_from('<II', data, 12)
        if kind != 0x4e4f534a:
            raise ValueError('Missing glTF JSON')
        doc = json.loads(data[20:20+length])
        offset = 20 + length
        n, kind = struct.unpack_from('<II', data, offset)
        if kind != 0x004e4942:
            raise ValueError('Missing glTF binary')
        binary = memoryview(data)[offset+8:offset+8+n]
        if any(b.get('uri') for b in doc.get('buffers', [])):
            raise ValueError('External source buffers are not supported')
        destination.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='.resident-', dir=destination.parent))
        try:
            views = doc.get('bufferViews', [])
            image_views = {im['bufferView'] for im in doc.get('images', []) if 'bufferView' in im}
            # Identify independent optional mesh buffers. Shared rig/accessor
            # data remains resident; it is never discarded under another mesh.
            library = doc.get('extras', {}).get('openclamAvatar', {})
            optional_names = {name for kind in ['outfits', 'props'] for choice in library.get(kind, []) for name in choice.get('nodes', [])}
            optional_meshes = {node['mesh'] for node in doc.get('nodes', []) if node.get('name') in optional_names and 'mesh' in node}
            owners = {}
            mesh_accessors = {}
            for mi, mesh in enumerate(doc.get('meshes', [])):
                indices = set()
                for primitive in mesh.get('primitives', []):
                    indices.update(primitive.get('attributes', {}).values())
                    if 'indices' in primitive: indices.add(primitive['indices'])
                    for target in primitive.get('targets', []): indices.update(target.values())
                mesh_accessors[mi] = indices
                for ai in indices:
                    accessor = doc['accessors'][ai]
                    if 'sparse' in accessor: optional_meshes.discard(mi)
                    if 'bufferView' in accessor: owners.setdefault(accessor['bufferView'], set()).add(mi)
            groups = {}
            for vi, view in enumerate(views):
                if vi in image_views: continue
                own = owners.get(vi, set())
                key = f'mesh-{next(iter(own))}' if len(own) == 1 and next(iter(own)) in optional_meshes else 'rig'
                groups.setdefault(key, []).append(vi)
            doc['buffers'] = []
            for key, indices in groups.items():
                blob = bytearray()
                bi = len(doc['buffers'])
                for vi in indices:
                    view = views[vi]
                    start, size = view.get('byteOffset', 0), view['byteLength']
                    while len(blob) % 4: blob.append(0)
                    view['byteOffset'], view['buffer'] = len(blob), bi
                    blob.extend(binary[start:start+size])
                name = key + '.bin'
                (stage / name).write_bytes(blob)
                doc['buffers'].append({'uri':name, 'byteLength':len(blob)})
            for mi in optional_meshes:
                vi = {doc['accessors'][ai].get('bufferView') for ai in mesh_accessors[mi]}
                independent = all(owners.get(i) == {mi} for i in vi if i is not None)
                if independent:
                    doc['meshes'][mi].setdefault('extras', {})['openclamDeferred'] = True
            # Image index stays stable. All derived URLs are local siblings.
            for texture in doc.get('textures',[]):
                for ext in ['EXT_texture_webp','EXT_texture_avif']:
                    value=texture.get('extensions',{}).pop(ext,None)
                    if value:texture['source']=value['source']
            for key in ['extensionsUsed','extensionsRequired']:
                if key in doc:doc[key]=[e for e in doc[key] if e not in ['EXT_texture_webp','EXT_texture_avif']]
            color_images=set()
            def collect_color(value, key=''):
                if isinstance(value,dict):
                    if key in ['baseColorTexture','emissiveTexture','specularColorTexture','sheenColorTexture'] and 'index' in value:
                        color_images.add(doc['textures'][value['index']]['source'])
                    for k,v in value.items():collect_color(v,k)
                elif isinstance(value,list):
                    for v in value:collect_color(v)
            collect_color(doc.get('materials',[]))
            for ii, image in enumerate(doc.get('images', [])):
                vi = image.pop('bufferView', None)
                if vi is None: raise ValueError('Expected embedded image')
                v = views[vi]
                raw = bytes(binary[v.get('byteOffset', 0):v.get('byteOffset', 0)+v['byteLength']])
                im = Image.open(io.BytesIO(raw)).convert('RGBA')
                if max(im.size) > 8192: raise ValueError('Texture too large')
                uniform = all(low == high for low, high in im.getextrema())
                if uniform: im = Image.new('RGBA',(1,1),im.getpixel((0,0)))
                variants = []
                sizes = sorted(set([min(max(im.size), size) for size in [512,1024,2048,4096,8192]]))
                for size in sizes:
                    scaled = im.copy()
                    scaled.thumbnail((size,size), Image.Resampling.LANCZOS)
                    name = f'image-{ii}-{size}.png'
                    scaled.save(stage/name, compress_level=3)
                    variant={'size':size,'uri':name}
                    if encoder:
                        out = f'image-{ii}-{size}.ktx2'
                        # High quality UASTC, no RDO; retain authored alpha.
                        result=subprocess.run([str(encoder), '-ktx2', '-uastc', '-uastc_level', '2', *([] if ii in color_images else ['-linear']), '-mipmap', '-no_multithreading', '-file',str(stage/name),'-output_file',str(stage/out)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
                        if result.returncode: raise RuntimeError(result.stdout.decode(errors='replace')[-2000:])
                        variant['compressed']=out
                    variants.append(variant)
                image.pop('mimeType', None)
                image['uri'] = variants[-1]['uri']
                image.setdefault('extras', {})['openclamVariants'] = variants
            # Image views are now unreferenced; remove and remap accessors.
            remap={old:new for new,old in enumerate(i for i in range(len(views)) if i not in image_views)}
            doc['bufferViews']=[v for i,v in enumerate(views) if i not in image_views]
            for accessor in doc.get('accessors', []):
                if 'bufferView' in accessor: accessor['bufferView']=remap[accessor['bufferView']]
                for value in accessor.get('sparse', {}).values():
                    if isinstance(value,dict) and 'bufferView' in value:value['bufferView']=remap[value['bufferView']]
            doc.setdefault('extras', {})['openclamResources']={'version':VERSION}
            (stage/'model.gltf').write_text(json.dumps(doc,separators=(',',':')))
            (stage/'source.json').write_text(json.dumps({'version':VERSION,'revision':revision,'compressed':bool(encoder),'sha256':hashlib.sha256(data).hexdigest()}))
            if destination.exists(): shutil.rmtree(destination)
            os.replace(stage,destination)
            return destination/'model.gltf'
        finally:
            if stage.exists():shutil.rmtree(stage)


def compress_existing(destination, encoder):
    """Offline compression can resume without rebuilding lossless geometry."""
    destination=Path(destination)
    doc=json.loads((destination/'model.gltf').read_text())
    color=set()
    def visit(v,key=''):
        if isinstance(v,dict):
            if key in ['baseColorTexture','emissiveTexture','specularColorTexture','sheenColorTexture'] and 'index' in v:
                color.add(doc['textures'][v['index']]['source'])
            for k,x in v.items():visit(x,k)
        elif isinstance(v,list):
            for x in v:visit(x)
    visit(doc.get('materials',[]))
    for ii,image in enumerate(doc['images']):
        for variant in image['extras']['openclamVariants']:
            if variant['size']<4:continue
            name=Path(variant['uri']).with_suffix('.ktx2').name
            target=destination/name
            if not target.exists():
                command=[str(encoder),'-ktx2','-uastc','-uastc_level','2',
                    *([] if ii in color else ['-linear']),'-mipmap','-no_multithreading',
                    '-file',str(destination/variant['uri']),'-output_file',str(target)]
                result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
                if result.returncode:
                    target.unlink(missing_ok=True)
                    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
                if result.returncode:raise RuntimeError(f'Encoder failed: {result.returncode}, {name}')
            variant['compressed']=name
        temporary=destination/'model.next.json'
        temporary.write_text(json.dumps(doc,separators=(',',':')))
        os.replace(temporary,destination/'model.gltf')
        print(f'Compressed image {ii+1}/{len(doc["images"])}',flush=True)
    marker=destination/'source.json';meta=json.loads(marker.read_text());meta['compressed']=True
    marker.write_text(json.dumps(meta))


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('source');parser.add_argument('destination');parser.add_argument('--encoder');parser.add_argument('--compress-existing',action='store_true')
    args=parser.parse_args()
    if args.compress_existing:compress_existing(args.destination,args.encoder)
    else:print(build(args.source,args.destination,args.encoder))
