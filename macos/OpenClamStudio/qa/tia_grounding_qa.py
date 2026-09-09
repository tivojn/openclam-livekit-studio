"""Validate private motion migration without modifying or exposing model assets."""
import argparse
import hashlib
import json
import struct
from pathlib import Path
import numpy as np

p=argparse.ArgumentParser()
for name in ('model','before','after'):p.add_argument('--'+name,required=True)
p.add_argument('--rebaked');p.add_argument('--report')
a=p.parse_args();raw=Path(a.model).read_bytes();n=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+n]);nodes=doc['nodes'];parents={c:i for i,node in enumerate(nodes) for c in node.get('children',[])};ids={node['name']:i for i,node in enumerate(nodes)}
def matrix(node):
    if 'matrix' in node:return np.array(node['matrix']).reshape(4,4).T
    x,y,z,w=node.get('rotation',[0,0,0,1]);m=np.eye(4)
    m[:3,:3]=np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])@np.diag(node.get('scale',[1,1,1]));m[:3,3]=node.get('translation',[0,0,0]);return m
rest=[matrix(node) for node in nodes]
def positions(clip):
    values=np.array(clip['frames']).reshape(-1,len(clip['bones']),3,4);slots={ids[b]:k for k,b in enumerate(clip['bones'])};world={}
    def pose(i):
        if i not in world:
            m=np.tile(rest[i],(len(values),1,1))
            if i in slots:m[:,:3,:]=values[:,slots[i]]
            world[i]=pose(parents[i])@m if i in parents else m
        return world[i]
    return np.stack([pose(ids[b])[:,:3,3] for b in clip['bones']],axis=1)
before=Path(a.before);after=Path(a.after)
old_index=json.loads((before/'library.json').read_text());new_index=json.loads((after/'library.json').read_text());assert old_index['clips']==new_index['clips']
report={'modelSHA256':hashlib.sha256(raw).hexdigest(),'clips':[]}
for entry in old_index['clips']:
    old=json.loads((before/entry['file']).read_text());new=json.loads((after/entry['file']).read_text());assert old['bones']==new['bones'] and old['fps']==new['fps']
    ov=np.array(old['frames']).reshape(-1,len(old['bones']),3,4);nv=np.array(new['frames']).reshape(ov.shape)
    assert np.isfinite(nv).all();assert np.array_equal(ov[:,:,:,:3],nv[:,:,:,:3]),entry['id']+' changed rotation/scale'
    op=positions(old);np_=positions(new);delta=np_-op
    assert abs(delta[:,:,1]).max()<2e-6,entry['id']+' changed grounded height/jumps'
    assert np.max(np.ptp(delta,axis=1))<3e-6,entry['id']+' stretched the skeleton'
    assert new['retargeting']['version']==2
    if entry['category']=='Walking':assert abs(delta[[0,-1]]).max()<2e-6,'walking must loop without net translation'
    low,high=np.array(new['bounds']);assert (np_>=low-1e-5).all() and (np_<=high+1e-5).all()
    item={'id':entry['id'],'frames':len(nv),'maxHorizontalCorrection':round(float(np.linalg.norm(delta[:,:,::2],axis=-1).max()),5)}
    if entry['id']=='joyful-sway':
        feet=[old['bones'].index(b) for b in ('foot.l','foot.r')]
        old_span=np.ptp(op[:,feet,0],axis=0);new_span=np.ptp(np_[:,feet,0],axis=0)
        assert (new_span<old_span*.25).all(),'planted feet should stop swinging under a fixed pelvis'
        item.update(oldFootSidewaysSpan=old_span.tolist(),newFootSidewaysSpan=new_span.tolist())
        if a.rebaked:
            baked=json.loads(Path(a.rebaked).read_text());error=float(abs(np_-positions(baked)).max());assert error<3e-5,error;item['maxDifferenceFromFullRebake']=error
    report['clips'].append(item)
assert len(report['clips'])==62
if a.report:Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('62 motion clips passed: unchanged rig rotations/scales, identical grounded height/jumps, coherent body translation, bounded framing, in-place walking and planted dance feet.')
print(json.dumps(next(c for c in report['clips'] if c['id']=='joyful-sway'),indent=2))
