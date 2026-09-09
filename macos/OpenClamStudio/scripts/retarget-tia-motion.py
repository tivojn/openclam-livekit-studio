"""Bake a Meshy SMPL-H FBX through Tia's original Auto-Rig Pro controls.

Run with Blender --factory-startup -b --python this-file -- --blend SOURCE
--model ORIGINAL.glb --motion walk.fbx --output walk.json --name walk.
Inputs are read-only. No geometry, skin weights, materials or bind matrices
are changed. Private source assets and generated clips stay outside Git.
"""
import argparse
import json
import math
import statistics
import struct
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector

parser = argparse.ArgumentParser()
for key in ('blend', 'model', 'motion', 'output', 'name'):
    parser.add_argument('--' + key, required=True)
parser.add_argument('--preset', action='store_true', help='Transfer a Meshy preset rig and preserve airborne motion')
parser.add_argument('--in-place', action='store_true', help='Remove net locomotion; preserve weight shift for screen-space walking')
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
bpy.ops.wm.open_mainfile(filepath=args.blend)
scene = bpy.context.scene
arm = bpy.data.objects['Fem-A_Tia_RIG']
scene.frame_set(0)
bpy.context.view_layer.update()
C = Matrix.Rotation(-math.pi / 2, 4, 'X')
rest_world = {p.name: C @ arm.matrix_world @ p.matrix @ C.inverted()
              for p in arm.pose.bones if p.bone.use_deform}
control_rest = {p.name: p.matrix.copy() for p in arm.pose.bones}
bases = {p.name: p.matrix_basis.copy() for p in arm.pose.bones}
arm.animation_data_create().action = None
# Only the rig is evaluated for baking. Unreferenced render meshes make each
# constraint update unnecessarily evaluate millions of vertices. Discard them
# from this temporary Blender session; source files are never saved.
referenced = {constraint.target for pb in arm.pose.bones for constraint in pb.constraints
              if getattr(constraint,'target',None)}
for obj in list(bpy.data.objects):
    if obj.type in ('MESH','CURVE') and obj not in referenced:
        bpy.data.objects.remove(obj,do_unlink=True)

before = set(bpy.data.objects)
bpy.ops.import_scene.fbx(filepath=args.motion)
donor = next(o for o in bpy.data.objects if o not in before and o.type == 'ARMATURE')
if args.preset:
    # Meshy preset rigs use a different convention from SMPL-H text motions.
    # Rename only the temporary donor, never the original Tia hierarchy.
    aliases = {'Hips':'Pelvis','Spine02':'Spine1','Spine01':'Spine2','Spine':'Spine3','neck':'Neck'}
    for side, prefix in [('Left','L'),('Right','R')]:
        aliases.update({side+name:prefix+'_'+target for name,target in [
            ('Shoulder','Collar'),('Arm','Shoulder'),('ForeArm','Elbow'),('Hand','Wrist'),
            ('UpLeg','Hip'),('Leg','Knee'),('Foot','Ankle'),('ToeBase','Foot')]})
    for old,new in aliases.items():
        if old in donor.data.bones:donor.data.bones[old].name=new
action = donor.animation_data.action
start, end = map(int, action.frame_range)
fps = scene.render.fps / scene.render.fps_base
donor_rest = {b.name: donor.matrix_world @ b.matrix_local for b in donor.data.bones}

def supported_head_delta(chest, rotation, soft_degrees, fallback_degrees):
    """Fade an impossible source look back to the animated torso.

    Some donor clips keep the head world-facing during a body turn. Copying
    that track verbatim twists Tia's neck backwards. Preserve ordinary looks,
    but smoothly inherit the chest for invalid ones. Fading out before 180
    degrees also avoids a left/right snap at the quaternion branch cut.
    """
    relative = chest.inverted() @ rotation
    angle = math.degrees(relative.angle)
    angle = min(angle, 360 - angle)
    u = max(0.0, min(1.0, (angle - soft_degrees) / (fallback_degrees - soft_degrees)))
    weight = 1 - u*u*(3 - 2*u)
    return chest @ Quaternion().slerp(relative, weight)
mapping = [('c_root_master.x', 'Pelvis'), ('c_root.x', 'Pelvis'),
           ('c_spine_01.x', 'Spine1'), ('c_spine_02.x', 'Spine1'),
           ('c_spine_03.x', 'Spine2'), ('c_spine_04.x', 'Spine2'),
           ('c_spine_05.x', 'Spine3'), ('c_subneck_1.x', 'Neck'),
           ('c_neck.x', 'Neck'), ('c_head.x', 'Head')]
align = {}
for side, prefix in [('l', 'L'), ('r', 'R')]:
    for control, source in [('c_shoulder', 'Collar'), ('c_arm_fk', 'Shoulder'),
                            ('c_forearm_fk', 'Elbow'), ('c_hand_fk', 'Wrist'),
                            ('c_thigh_fk', 'Hip'), ('c_leg_fk', 'Knee'),
                            ('c_foot_fk', 'Ankle'), ('c_toes_fk', 'Foot')]:
        name = control + '.' + side
        mapping.append((name, prefix + '_' + source))
    # Match the neutral limb directions before transferring animation. Tia
    # has an A-pose; the donor uses a T-pose. Copying deltas alone doubles
    # the arm drop and can put the hands through the legs.
    for target, target_end, source, source_end in [
        ('c_arm_fk', 'c_forearm_fk', 'Shoulder', 'Elbow'),
        ('c_forearm_fk', 'c_hand_fk', 'Elbow', 'Wrist'),
        ('c_thigh_fk', 'c_leg_fk', 'Hip', 'Knee'),
        ('c_leg_fk', 'c_foot_fk', 'Knee', 'Ankle')]:
        a, b = target + '.' + side, target_end + '.' + side
        tv = control_rest[b].translation - control_rest[a].translation
        dv = donor_rest[prefix + '_' + source_end].translation - donor_rest[prefix + '_' + source].translation
        align[a] = tv.normalized().rotation_difference(dv.normalized())
    # The wrist follows the calibrated forearm basis; finger articulation
    # uses Tia's authored neutral hand until a hand pose is selected.
    align['c_hand_fk.' + side] = align['c_forearm_fk.' + side]
    # A preset FBX's bind pose can be the first running/kicking frame. Its
    # ankle and toe bases are therefore not necessarily standing flat. Match
    # the anatomical foot directions too; copying only their deltas makes a
    # supporting foot curl upwards when the donor leaves that initial pose.
    foot = arm.pose.bones['foot.' + side]
    toe = arm.pose.bones['toes_01.' + side]
    donor_foot = donor_rest[prefix + '_Foot']
    donor_ankle = donor_rest[prefix + '_Ankle']
    align['c_foot_fk.' + side] = (foot.tail-foot.head).normalized().rotation_difference(
        (donor_foot.translation-donor_ankle.translation).normalized())
    if args.preset:
        toe_direction = donor_foot.to_3x3() @ Vector((0, 1, 0))
    else:
        # SMPL-H terminal joints have arbitrary display-bone tails (often
        # straight up), not toe-tip landmarks. Their neutral toes point along
        # the footprint; joint rotation deltas still supply the articulation.
        toe_direction = donor_foot.translation-donor_ankle.translation
        toe_direction.z = 0
    align['c_toes_fk.' + side] = (toe.tail-toe.head).normalized().rotation_difference(toe_direction.normalized())
    for control in ['c_foot_ik.', 'c_hand_ik.']:
        arm.pose.bones[control + side]['ik_fk_switch'] = 1.0

with open(args.model, 'rb') as f:
    f.seek(12)
    length, kind = struct.unpack('<II', f.read(8))
    document = json.loads(f.read(length))
library = document['extras']['openclamAvatar']
if set(library['rest']) != set(rest_world):
    raise ValueError('Tia source and avatar pose library do not match')
nodes = document['nodes']
parents = {child: i for i, n in enumerate(nodes) for child in n.get('children', [])}
def node_matrix(n):
    if 'matrix' in n:
        return Matrix([n['matrix'][i:i + 4] for i in range(0, 16, 4)]).transposed()
    q = n.get('rotation', [0, 0, 0, 1])
    return Matrix.LocRotScale(Vector(n.get('translation', [0, 0, 0])),
                              Quaternion((q[3], *q[:3])), Vector(n.get('scale', [1, 1, 1])))
worlds = {}
def world(i):
    if i not in worlds:
        worlds[i] = (world(parents[i]) if i in parents else Matrix.Identity(4)) @ node_matrix(nodes[i])
    return worlds[i]
for i in range(len(nodes)):
    world(i)
bone_ids = [i for i, n in enumerate(nodes) if n.get('name') in rest_world]
bone_names = [nodes[i]['name'] for i in bone_ids]
frames = []
envelope_min = Vector((math.inf,math.inf,math.inf))
envelope_max = Vector((-math.inf,-math.inf,-math.inf))
# Keep long catalog presets within the runtime limit without speeding them up.
samples = min(900, end-start+1)
frame_times = [start+(end-start)*i/(samples-1) for i in range(samples)]
output_fps = (samples-1)*fps/(end-start)
scene.frame_set(start)
bpy.context.view_layer.update()
root_start = (donor.matrix_world @ donor.pose.bones['Pelvis'].matrix).translation.copy()
# Transfer the pelvis trajectory in all three axes, scaled to Tia's leg
# length. Keeping X/Y fixed makes planted feet swing around a suspended hip.
tia_leg = sum((control_rest[b+'.l'].translation-control_rest[a+'.l'].translation).length
              for a,b in [('c_thigh_fk','c_leg_fk'),('c_leg_fk','c_foot_fk')])
donor_leg = sum((donor_rest['L_'+b].translation-donor_rest['L_'+a].translation).length
                for a,b in [('Hip','Knee'),('Knee','Ankle')])
travel_scale = tia_leg / donor_leg

scene.frame_set(end);bpy.context.view_layer.update()
root_drift = (donor.matrix_world @ donor.pose.bones['Pelvis'].matrix).translation-root_start
donor_floor = {}
if args.preset:
    for frame in frame_times:
        scene.frame_set(math.floor(frame),subframe=frame%1)
        donor_floor[frame] = min((donor.matrix_world @ donor.pose.bones[s+'_Ankle'].matrix).translation.z for s in ('L','R'))
    floor_base = min(donor_floor.values())
min_feet = min(control_rest['c_foot_fk.' + s].translation.z for s in ('l', 'r'))
foot_samples = []
for frame_index,frame in enumerate(frame_times):
    scene.frame_set(math.floor(frame),subframe=frame%1)
    for pb in arm.pose.bones:
        pb.matrix_basis = bases[pb.name]
    bpy.context.view_layer.update()
    pose_world = {p.name: donor.matrix_world @ p.matrix for p in donor.pose.bones}
    deltas = {name: pose_world[name].to_quaternion() @ donor_rest[name].to_quaternion().inverted() for name in pose_world}
    pelvis_delta = deltas['Pelvis']
    chest_delta = pelvis_delta @ Quaternion().slerp(pelvis_delta.inverted() @ deltas['Spine3'], .65)
    chest_correction = chest_delta @ deltas['Spine3'].inverted()
    # Evaluate head and neck in the torso frame, before retargeting the
    # original controls. Hair, face and eyes then inherit the same rig motion.
    deltas['Head'] = supported_head_delta(deltas['Spine3'], deltas['Head'], 45, 95)
    deltas['Neck'] = supported_head_delta(deltas['Spine3'], deltas['Neck'], 25, 65)
    for target, source in mapping:
        pb = arm.pose.bones[target]
        rotation = deltas[source]
        # Keep the generated movement within the fitted coat's torso range.
        # Apply the same correction to shoulders, arms and head so the
        # anatomical chains remain continuous. Geometry stays untouched.
        if source.startswith('Spine'):
            rotation = pelvis_delta @ Quaternion().slerp(pelvis_delta.inverted() @ rotation, .65)
        elif source in ('Neck', 'Head') or any(source.endswith('_' + part) for part in ('Collar', 'Shoulder', 'Elbow', 'Wrist')):
            rotation = chest_correction @ rotation
        rotation = rotation @ align.get(target, Quaternion()) @ control_rest[target].to_quaternion()
        if target.startswith('c_arm_fk.'):
            # Tia's hips and sleeves are wider than the motion donor. A small
            # rest-space clearance keeps a lowered hand outside her skirt.
            rest_direction = control_rest[target.replace('c_arm_fk.', 'c_forearm_fk.')].translation - control_rest[target].translation
            direction = rotation @ (control_rest[target].to_quaternion().inverted() @ rest_direction.normalized())
            clearance = max(0.0, min(1.0, -direction.z)) * .24
            rotation = Quaternion((0, 1, 0), -clearance if target.endswith('.l') else clearance) @ rotation
        current = pb.matrix.copy()
        position = current.translation
        if target == 'c_root_master.x':
            position = control_rest[target].translation.copy()
            travel = pose_world['Pelvis'].translation-root_start
            if args.in_place:travel -= root_drift*(frame_index/(samples-1))
            position += travel*travel_scale
        pb.matrix = Matrix.LocRotScale(position, rotation, control_rest[target].to_scale())
        bpy.context.view_layer.update()
    # Keep the supporting foot on the original floor. Retargeted leg lengths
    # differ from the donor; adjust the root, never stretch the geometry.
    deps = bpy.context.evaluated_depsgraph_get()
    evaluated = arm.evaluated_get(deps)
    floor = min(evaluated.pose.bones['foot.' + s].matrix.translation.z for s in ('l', 'r'))
    root = arm.pose.bones['c_root_master.x']
    m = root.matrix.copy()
    airborne = max(0, donor_floor[frame]-floor_base) if args.preset else 0
    m.translation.z += min_feet + airborne - floor
    root.matrix = m
    bpy.context.view_layer.update()
    evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
    foot_samples.append([(C @ evaluated.matrix_world @ evaluated.pose.bones['foot.'+side].matrix).translation.copy() for side in ('l','r')])
    targets = {}
    for i in bone_ids:
        name = nodes[i]['name']
        posed = C @ evaluated.matrix_world @ evaluated.pose.bones[name].matrix @ C.inverted()
        targets[i] = posed @ rest_world[name].inverted() @ worlds[i]
        point=targets[i].translation
        for axis in range(3):
            envelope_min[axis]=min(envelope_min[axis],point[axis])
            envelope_max[axis]=max(envelope_max[axis],point[axis])
    # Bake local matrices for the *exported* hierarchy, which deliberately
    # flattens some Blender constraint chains. Preserve all affine terms.
    values = []
    for i in bone_ids:
        parent = parents.get(i)
        pm = targets.get(parent, worlds.get(parent, Matrix.Identity(4)))
        local = pm.inverted() @ targets[i]
        values.extend(round(float(local[r][c]), 7) for r in range(3) for c in range(4))
    frames.append(values)
    if frame_index % 30 == 0:
        print('BAKED', args.name, frame - start, 'of', end - start + 1, flush=True)
forward_speed = math.hypot(root_drift.x,root_drift.y)*travel_scale/max(.001,(end-start)/fps)
speed_source = 'root-trajectory'
if args.in_place and forward_speed < .1:
    # Some presets are already in place. Their supporting foot travels
    # backwards relative to the hip at the intended forward running speed.
    supporting_speeds = []
    for before,after in zip(foot_samples,foot_samples[1:]):
        heights = [(before[s].y+after[s].y)/2 for s in (0,1)]
        for side in (0,1):
            speed = (before[side].z-after[side].z)*output_fps
            if speed > .05 and heights[side] <= min(heights)+tia_leg*.06:
                supporting_speeds.append(speed)
    if supporting_speeds:
        forward_speed = statistics.median(supporting_speeds)
        speed_source = 'supporting-foot'
result = {'version': 1, 'id': args.name, 'label': args.name.title(),
          'source': ('Meshy preset' if args.preset else 'Meshy text-to-motion') + ', retargeted to the original Tia rig',
          'retargeting': {'version': 3, 'pelvisTranslation': 'xyz', 'travelScale': round(travel_scale, 7), 'inPlace': args.in_place,
                          'forwardSpeed': round(forward_speed,7) if args.in_place else 0, 'forwardSpeedSource': speed_source,
                          'headReference': 'torso', 'invalidHeadTrack': 'smooth-fallback',
                          'footBasis': 'anatomical-ankle-and-toe'},
          'fps': output_fps, 'bones': bone_names, 'frames': frames,
          'bounds': [[round(v-.12,5) for v in envelope_min], [round(v+.12,5) for v in envelope_max]],
          'loop': args.name in ('walk', 'dance')}
Path(args.output).write_text(json.dumps(result, separators=(',', ':')))
print('DONE', args.output, len(frames), 'frames', len(bone_names), 'bones', flush=True)
