"""Restore discarded horizontal pelvis motion in version-1 Tia clips.

Blender --factory-startup -b --python this-file -- --blend SOURCE.blend
--model ORIGINAL.glb --clips MOTION_DIR --fbx FBX_DIR --output NEW_DIR

Only motion translations change. Original model and clips remain read-only.
The full retargeter produces this same trajectory for future imports.
"""
import argparse
import json
import math
import struct
import sys
from pathlib import Path
import bpy
from mathutils import Matrix, Quaternion, Vector

parser = argparse.ArgumentParser()
for key in ('blend', 'model', 'clips', 'output'):
    parser.add_argument('--'+key, required=True)
parser.add_argument('--fbx', action='append', required=True, help='Donor directories; may be repeated')
a = parser.parse_args(sys.argv[sys.argv.index('--')+1:])
bpy.ops.wm.open_mainfile(filepath=a.blend)
scene = bpy.context.scene
scene.frame_set(0)
bpy.context.view_layer.update()
arm = bpy.data.objects['Fem-A_Tia_RIG']
tia_leg = sum((arm.pose.bones[y+'.l'].matrix.translation-arm.pose.bones[x+'.l'].matrix.translation).length
              for x,y in [('c_thigh_fk','c_leg_fk'),('c_leg_fk','c_foot_fk')])
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
with open(a.model, 'rb') as f:
    f.seek(12); size, kind = struct.unpack('<II', f.read(8)); doc = json.loads(f.read(size))
nodes = doc['nodes']
ids = {n['name']:i for i,n in enumerate(nodes)}
parents = {child:i for i,n in enumerate(nodes) for child in n.get('children', [])}
def matrix(n):
    if 'matrix' in n:return Matrix([n['matrix'][i:i+4] for i in range(0,16,4)]).transposed()
    q = n.get('rotation',[0,0,0,1])
    return Matrix.LocRotScale(Vector(n.get('translation',[0,0,0])),Quaternion((q[3],*q[:3])),Vector(n.get('scale',[1,1,1])))
locals = [matrix(n) for n in nodes]
rest = {}
def world(i):
    if i not in rest:rest[i] = (world(parents[i]) if i in parents else Matrix.Identity(4)) @ locals[i]
    return rest[i]
for i in range(len(nodes)):world(i)
output = Path(a.output); output.mkdir(parents=True, exist_ok=True)
index = json.loads((Path(a.clips)/'library.json').read_text())
receipt = []
for entry in index['clips']:
    source = Path(a.clips)/entry['file']
    fbx = next((Path(d)/(entry['id']+'.fbx') for d in a.fbx if (Path(d)/(entry['id']+'.fbx')).is_file()), None)
    if fbx is None:raise FileNotFoundError('Missing donor: '+entry['id'])
    clip = json.loads(source.read_text())
    if clip.get('retargeting',{}).get('version',1) != 1:raise ValueError('Already repaired: '+str(source))
    bpy.ops.import_scene.fbx(filepath=str(fbx))
    donor = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    preset = 'Hips' in donor.data.bones
    names = ['Hips','LeftUpLeg','LeftLeg','LeftFoot'] if preset else ['Pelvis','L_Hip','L_Knee','L_Ankle']
    dr = {name: donor.matrix_world @ donor.data.bones[name].matrix_local for name in names}
    donor_leg = sum((dr[y].translation-dr[x].translation).length for x,y in zip(names[1:-1],names[2:]))
    scale = tia_leg/donor_leg
    start,end = donor.animation_data.action.frame_range
    scene.frame_set(int(start));bpy.context.view_layer.update()
    origin = (donor.matrix_world@donor.pose.bones[names[0]].matrix).translation.copy()
    scene.frame_set(int(end));bpy.context.view_layer.update()
    drift = (donor.matrix_world@donor.pose.bones[names[0]].matrix).translation-origin
    in_place = entry.get('category') == 'Walking'

    bone_ids = [ids[b] for b in clip['bones']]; bone_slots = {i:k for k,i in enumerate(bone_ids)}
    roots = [(k, rest[parents[i]].to_3x3().inverted() if i in parents else Matrix.Identity(3))
             for k,i in enumerate(bone_ids) if parents.get(i) not in bone_slots]
    lo = Vector((math.inf,)*3); hi = Vector((-math.inf,)*3); travel=[]
    for frame, values in enumerate(clip['frames']):
        t = start+(end-start)*frame/(len(clip['frames'])-1)
        scene.frame_set(math.floor(t),subframe=t%1);bpy.context.view_layer.update()
        delta = (donor.matrix_world@donor.pose.bones[names[0]].matrix).translation-origin
        # The desktop companion supplies locomotion in screen space. Strip
        # only the net walking trajectory, keeping step-to-step weight shift.
        if in_place:delta -= drift*(frame/(len(clip['frames'])-1))
        delta *= scale
        # Blender Z-up -> glTF Y-up. Vertical grounding/jumps were already
        # baked correctly and must remain exactly as authored in the clip.
        delta = Vector((delta.x,0,-delta.y));travel.append(list(delta))
        for k,parent_inverse in roots:
            offset = parent_inverse@delta
            for axis in range(3): values[k*12+axis*4+3] = round(values[k*12+axis*4+3]+offset[axis],7)
        posed = {}
        def pose(i):
            if i not in posed:
                m = locals[i]
                if i in bone_slots:
                    k = bone_slots[i]*12
                    m = Matrix([values[k:k+4],values[k+4:k+8],values[k+8:k+12],[0,0,0,1]])
                posed[i] = (pose(parents[i]) if i in parents else Matrix.Identity(4))@m
            return posed[i]
        for i in bone_ids:
            p = pose(i).translation
            for axis in range(3):lo[axis]=min(lo[axis],p[axis]);hi[axis]=max(hi[axis],p[axis])
    clip['bounds'] = [[round(v-.12,5) for v in lo],[round(v+.12,5) for v in hi]]
    clip['retargeting'] = {'version':2,'pelvisTranslation':'xyz','travelScale':round(scale,7),'inPlace':in_place}
    (output/entry['file']).write_text(json.dumps(clip,separators=(',',':')))
    receipt.append({'id':entry['id'],'frames':len(clip['frames']),'maxTranslation':round(max(Vector(v).length for v in travel),5)})
    print('REPAIRED',receipt[-1],flush=True)
    for obj in list(bpy.data.objects):bpy.data.objects.remove(obj,do_unlink=True)
    bpy.data.orphans_purge(do_recursive=True)
index['retargetingRevision'] = 2
(output/'library.json').write_text(json.dumps(index,indent=2)+'\n')
(output/'repair-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
