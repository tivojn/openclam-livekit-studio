"""Bake a Meshy SMPL-H FBX through Tia's original Auto-Rig Pro controls.

Run with Blender --factory-startup -b --python this-file -- --blend SOURCE
--model ORIGINAL.glb --motion walk.fbx --output walk.json --name walk.
Inputs are read-only. No geometry, skin weights, materials or bind matrices
are changed. Private source assets and generated clips stay outside Git.
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
for key in ('blend', 'model', 'motion', 'output', 'name'):
    parser.add_argument('--' + key, required=True)
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

before = set(bpy.data.objects)
bpy.ops.import_scene.fbx(filepath=args.motion)
donor = next(o for o in bpy.data.objects if o not in before and o.type == 'ARMATURE')
action = donor.animation_data.action
start, end = map(int, action.frame_range)
fps = scene.render.fps / scene.render.fps_base
donor_rest = {b.name: donor.matrix_world @ b.matrix_local for b in donor.data.bones}
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
scene.frame_set(start)
bpy.context.view_layer.update()
root_start = (donor.matrix_world @ donor.pose.bones['Pelvis'].matrix).translation.copy()
min_feet = min(control_rest['c_foot_fk.' + s].translation.z for s in ('l', 'r'))
for frame in range(start, end + 1):
    scene.frame_set(frame)
    for pb in arm.pose.bones:
        pb.matrix_basis = bases[pb.name]
    bpy.context.view_layer.update()
    pose_world = {p.name: donor.matrix_world @ p.matrix for p in donor.pose.bones}
    deltas = {name: pose_world[name].to_quaternion() @ donor_rest[name].to_quaternion().inverted() for name in pose_world}
    pelvis_delta = deltas['Pelvis']
    chest_delta = pelvis_delta @ Quaternion().slerp(pelvis_delta.inverted() @ deltas['Spine3'], .65)
    chest_correction = chest_delta @ deltas['Spine3'].inverted()
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
            position.z += (pose_world['Pelvis'].translation.z - root_start.z)
        pb.matrix = Matrix.LocRotScale(position, rotation, control_rest[target].to_scale())
        bpy.context.view_layer.update()
    # Keep the supporting foot on the original floor. Retargeted leg lengths
    # differ from the donor; adjust the root, never stretch the geometry.
    deps = bpy.context.evaluated_depsgraph_get()
    evaluated = arm.evaluated_get(deps)
    floor = min(evaluated.pose.bones['foot.' + s].matrix.translation.z for s in ('l', 'r'))
    root = arm.pose.bones['c_root_master.x']
    m = root.matrix.copy()
    m.translation.z += min_feet - floor
    root.matrix = m
    bpy.context.view_layer.update()
    evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
    targets = {}
    for i in bone_ids:
        name = nodes[i]['name']
        posed = C @ evaluated.matrix_world @ evaluated.pose.bones[name].matrix @ C.inverted()
        targets[i] = posed @ rest_world[name].inverted() @ worlds[i]
    # Bake local matrices for the *exported* hierarchy, which deliberately
    # flattens some Blender constraint chains. Preserve all affine terms.
    values = []
    for i in bone_ids:
        parent = parents.get(i)
        pm = targets.get(parent, worlds.get(parent, Matrix.Identity(4)))
        local = pm.inverted() @ targets[i]
        values.extend(round(float(local[r][c]), 7) for r in range(3) for c in range(4))
    frames.append(values)
    if (frame - start) % 30 == 0:
        print('BAKED', args.name, frame - start, 'of', end - start + 1, flush=True)
result = {'version': 1, 'id': args.name, 'label': args.name.title(),
          'source': 'Meshy text-to-motion, retargeted to the original Tia rig',
          'fps': fps, 'bones': bone_names, 'frames': frames,
          'loop': args.name in ('walk', 'dance')}
Path(args.output).write_text(json.dumps(result, separators=(',', ':')))
print('DONE', args.output, len(frames), 'frames', len(bone_names), 'bones', flush=True)
