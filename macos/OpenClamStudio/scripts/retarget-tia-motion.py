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
parser.add_argument('--gait-clearance', action='store_true', help='Calibrate locomotion posture and keep the feet in separate anatomical lanes')
parser.add_argument('--walk-cycle', action='store_true', help='Use the normal walking arm clearance for a complete locomotion cycle')
parser.add_argument('--frame-start', type=int)
parser.add_argument('--frame-end', type=int)
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
if args.walk_cycle and not (args.in_place and args.gait_clearance and args.preset):
    parser.error('--walk-cycle requires a preset, --in-place and --gait-clearance')
if args.gait_clearance and not args.in_place:
    parser.error('--gait-clearance requires --in-place locomotion')
bpy.ops.wm.open_mainfile(filepath=args.blend)
scene = bpy.context.scene
arm = bpy.data.objects['Fem-A_Tia_RIG']
scene.frame_set(0)
bpy.context.view_layer.update()
C = Matrix.Rotation(-math.pi / 2, 4, 'X')
rest_world = {p.name: C @ arm.matrix_world @ p.matrix @ C.inverted()
              for p in arm.pose.bones if p.bone.use_deform}
control_rest = {p.name: p.matrix.copy() for p in arm.pose.bones}
rest_directions = {p.name: (p.tail-p.head).copy() for p in arm.pose.bones}
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
source_range = [start, end]
start = args.frame_start if args.frame_start is not None else start
end = args.frame_end if args.frame_end is not None else end
if not source_range[0] <= start < end <= source_range[1]:
    parser.error("The cycle range must lie within the source animation")
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

def calibrate_posture(pose_world):
    # A preset's bind pose may already be leaning/running. Rotation deltas
    # alone discard that lean; use the donor's actual pelvis-to-chest vector.
    # Correct the upper-body controls together so arms/head keep their motion.
    evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
    current = evaluated.pose.bones['spine_05.x'].head - evaluated.pose.bones['root.x'].head
    desired = arm.matrix_world.inverted().to_3x3() @ (pose_world['Spine3'].translation - pose_world['Pelvis'].translation)
    correction = current.normalized().rotation_difference(desired.normalized())
    upper = [(target, arm.pose.bones[target].matrix.copy()) for target, source in mapping
             if source.startswith('Spine') or source in ('Neck', 'Head')
             or any(source.endswith('_' + part) for part in ('Collar', 'Shoulder', 'Elbow', 'Wrist'))]
    for target, original in upper:
        pb = arm.pose.bones[target]
        pb.matrix = Matrix.LocRotScale(pb.matrix.translation, correction @ original.to_quaternion(), original.to_scale())
        bpy.context.view_layer.update()

def calibrate_gait(pose_world):
    calibrate_posture(pose_world)
    # Hello Run's donor crosses the ankles. Proportional FK transfer preserves
    # that crossing, but Tia's boots then intersect. Solve only the necessary
    # lateral clearance with the original limb lengths and bend direction.
    hips = [arm.pose.bones['c_thigh_fk.' + side].matrix.translation.copy() for side in ('l', 'r')]
    center = (hips[0] + hips[1]) * .5
    lateral = hips[0] - hips[1]
    lateral.z = 0
    half_width = lateral.length * .4
    lateral.normalize()
    for side, sign in [('l', 1), ('r', -1)]:
        thigh, shin, foot = [arm.pose.bones[name + '.' + side] for name in ('c_thigh_fk', 'c_leg_fk', 'c_foot_fk')]
        originals = [pb.matrix.copy() for pb in (thigh, shin, foot)]
        hip, knee, ankle = [m.translation.copy() for m in originals]
        gap = sign * (ankle - center).dot(lateral) - half_width
        # Smooth max keeps the constraint's entry/exit continuous in the clip.
        correction_distance = .5 * (math.sqrt(gap * gap + .005 ** 2) - gap)
        goal = ankle + lateral * (sign * correction_distance)
        upper_length, lower_length = (knee - hip).length, (ankle - knee).length
        direction = (goal - hip).normalized()
        reach = min((goal - hip).length, upper_length + lower_length - .0005)
        goal = hip + direction * reach
        along = (upper_length ** 2 - lower_length ** 2 + reach ** 2) / (2 * reach)
        bend = knee - hip
        bend -= direction * bend.dot(direction)
        if bend.length < 1e-6:
            bend = Vector((0, -1, 0)); bend -= direction * bend.dot(direction)
        bend.normalize()
        new_knee = hip + direction * along + bend * math.sqrt(max(0, upper_length ** 2 - along ** 2))
        swing = (knee - hip).normalized().rotation_difference((new_knee - hip).normalized())
        thigh.matrix = Matrix.LocRotScale(hip, swing @ originals[0].to_quaternion(), originals[0].to_scale())
        bpy.context.view_layer.update()
        actual_knee, actual_ankle = shin.matrix.translation.copy(), foot.matrix.translation.copy()
        swing = (actual_ankle - actual_knee).normalized().rotation_difference((goal - actual_knee).normalized())
        shin.matrix = Matrix.LocRotScale(actual_knee, swing @ shin.matrix.to_quaternion(), originals[1].to_scale())
        bpy.context.view_layer.update()
        foot.matrix = Matrix.LocRotScale(foot.matrix.translation, originals[2].to_quaternion(), originals[2].to_scale())
        bpy.context.view_layer.update()

def calibrate_walking(pose_world):
    """Keep the donor's stride, with relaxed arms and a weight-bearing leg.

    The broad arm clearance and lateral-only leg correction are useful for
    running, but pull walking elbows out and rotate the shins sideways. Fit
    the walking controls as complete chains instead of offsetting the ankle
    under an unchanged knee plane. Only rig controls are changed.
    """
    # FBX bind is a stride frame, not a neutral pelvis. Restore the source's
    # actual hip roll/yaw before solving limbs, rather than retaining the
    # first frame's one-sided offset throughout the entire loop.
    evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
    current=evaluated.pose.bones['thigh.l'].head-evaluated.pose.bones['thigh.r'].head
    desired=arm.matrix_world.inverted().to_3x3()@(pose_world['L_Hip'].translation-pose_world['R_Hip'].translation)
    correction=current.normalized().rotation_difference(desired.normalized())
    root=arm.pose.bones['c_root_master.x'];m=root.matrix.copy()
    root.matrix=Matrix.LocRotScale(m.translation,correction@m.to_quaternion(),m.to_scale())
    bpy.context.view_layer.update()
    calibrate_posture(pose_world)
    hips = [arm.pose.bones['c_thigh_fk.'+s].matrix.translation.copy() for s in ('l','r')]
    right = hips[0]-hips[1];right.z=0;right.normalize()
    forward = right.cross(Vector((0,0,1))).normalized()
    source_to_rig = arm.matrix_world.inverted().to_3x3()
    for side,prefix,sign in [('l','L',1),('r','R',-1)]:
        upper,lower,hand = [arm.pose.bones[n+'.'+side] for n in ('c_arm_fk','c_forearm_fk','c_hand_fk')]
        source_upper=source_to_rig@(pose_world[prefix+'_Elbow'].translation-pose_world[prefix+'_Shoulder'].translation)
        source_lower=source_to_rig@(pose_world[prefix+'_Wrist'].translation-pose_world[prefix+'_Elbow'].translation)
        # Retain forward/back arm swing. Relax lateral abduction, including
        # the donor's own wide-arm bind pose, with a continuous soft limit.
        outward=sign*source_upper.dot(right)
        limit=max(.001,abs(source_upper.z))*math.tan(math.radians(10))
        relaxed=limit*math.tanh(max(0,outward)/limit)
        desired=source_upper+right*(sign*relaxed-source_upper.dot(right))
        swing=source_upper.normalized().rotation_difference(desired.normalized())
        desired_lower=swing@source_lower
        # Preserve the source elbow articulation: straightening it removes
        # the forward half of this preset's hand swing.
        for control,start_name,end_name,direction in [
            (upper,'c_arm_stretch.','c_forearm_stretch.',desired),
            (lower,'c_forearm_stretch.','hand.',desired_lower)]:
            for _ in range(4):
                evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
                actual=evaluated.pose.bones[end_name+side].head-evaluated.pose.bones[start_name+side].head
                correction=actual.normalized().rotation_difference(direction.normalized())
                original=control.matrix.copy()
                control.matrix=Matrix.LocRotScale(original.translation,correction@original.to_quaternion(),original.to_scale())
                bpy.context.view_layer.update()

    chains=[];center=(hips[0]+hips[1])*.5
    source_center=(pose_world['L_Hip'].translation+pose_world['R_Hip'].translation)*.5
    source_right=pose_world['L_Hip'].translation-pose_world['R_Hip'].translation;source_right.z=0;source_right.normalize()
    source_forward=source_right.cross(Vector((0,0,1))).normalized()
    for side,prefix,sign in [('l','L',1),('r','R',-1)]:
        bones=[arm.pose.bones[n+'.'+side] for n in ('c_thigh_fk','c_leg_fk','c_foot_fk')]
        evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
        hip,knee,ankle=[evaluated.pose.bones[n+'.'+side].head.copy() for n in ('thigh','leg','foot')]
        source_offset=pose_world[prefix+'_Ankle'].translation-source_center
        # Retarget the ankle trajectory in anatomical pelvis coordinates.
        # Reusing the pre-fit FK endpoint retains left/right control offsets
        # and delays one heel landing even when the rotations are symmetric.
        source_leg=sum((pose_world[prefix+'_'+b].translation-pose_world[prefix+'_'+a].translation).length for a,b in [('Hip','Knee'),('Knee','Ankle')])
        leg_scale=((knee-hip).length+(ankle-knee).length)/source_leg
        goal=center+forward*(source_offset.dot(source_forward)*leg_scale)+Vector((0,0,source_offset.z*leg_scale))
        # Fit the donor's lateral stride to Tia's pelvis. Copying the broad
        # source stance plus the FK control offsets splayed her lower legs.
        lateral=source_offset.dot(source_right)*walking_lane_scale
        runway_stride=Path(args.motion).stem=='walking-woman'
        half_lane=(hips[0]-hips[1]).length*(.32 if runway_stride else .44)
        variation=half_lane*(.30 if runway_stride else .12)
        lateral=sign*(half_lane+variation*math.tanh((sign*lateral-half_lane)/variation))
        goal+=right*(lateral-(goal-center).dot(right))
        a,b=(knee-hip).length,(ankle-knee).length
        reach=math.sqrt(a*a+b*b+2*a*b*math.cos(math.radians(9)))
        flat=goal-hip;flat.z=0
        height=math.sqrt(max(.001,reach*reach-flat.length_squared))
        chains.append((side,prefix,bones,goal,a,b,goal.z+height-hip.z))
    # These presets arrive with persistently bent support knees. Raise the
    # pelvis only as far as both legs can reach; keep the source ankle paths
    # and stride timing. The sole pass then establishes the common floor.
    rise=max(0,min(chain[-1] for chain in chains))
    root=arm.pose.bones['c_root_master.x'];m=root.matrix.copy();m.translation.z+=rise;root.matrix=m
    bpy.context.view_layer.update()
    for side,prefix,bones,goal,a,b,_ in chains:
        thigh,shin,foot=bones
        evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
        hip=evaluated.pose.bones['thigh.'+side].head.copy()
        direction=(goal-hip).normalized();reach=min((goal-hip).length,a+b-.0001)
        goal=hip+direction*reach
        along=(a*a-b*b+reach*reach)/(2*reach)
        pole=forward-direction*forward.dot(direction);pole.normalize()
        knee=hip+direction*along+pole*math.sqrt(max(0,a*a-along*along))
        for _ in range(3):
            evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
            current=evaluated.pose.bones['leg.'+side].head-hip
            correction=current.normalized().rotation_difference((knee-hip).normalized())
            m=thigh.matrix.copy();thigh.matrix=Matrix.LocRotScale(m.translation,correction@m.to_quaternion(),m.to_scale())
            bpy.context.view_layer.update()
        for _ in range(3):
            evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
            actual_knee=evaluated.pose.bones['leg.'+side].head.copy()
            current=evaluated.pose.bones['foot.'+side].head-actual_knee
            correction=current.normalized().rotation_difference((goal-actual_knee).normalized())
            m=shin.matrix.copy();shin.matrix=Matrix.LocRotScale(m.translation,correction@m.to_quaternion(),m.to_scale())
            bpy.context.view_layer.update()
        # The left/right FK foot controls are NOT mirrored. Match complete
        # anatomical frames on the evaluated deform bones, including twist;
        # a single-vector alignment of the controls leaves one shoe turned in.
        toe_direction=source_to_rig@(pose_world[prefix+'_Foot'].to_3x3()@Vector((0,1,0)))
        source_yaw=math.atan2(toe_direction.dot(source_right),toe_direction.dot(source_forward))
        sign=1 if side=='l' else -1
        yaw=sign*math.radians(5)+math.radians(4)*math.tanh((source_yaw-walking_toe_yaw[prefix])/math.radians(4))
        yaw+=math.atan2(forward.x,-forward.y)
        for control,deform,direction in [
            (foot,'foot',source_to_rig@(pose_world[prefix+'_Foot'].translation-pose_world[prefix+'_Ankle'].translation)),
            (arm.pose.bones['c_toes_fk.'+side],'toes_01',toe_direction)]:
            pitch=math.atan2(direction.z,direction.dot(source_forward))
            pitch+=walking_rest_pitch[deform]-walking_neutral_pitch[deform]
            desired=Vector((math.sin(yaw)*math.cos(pitch),-math.cos(yaw)*math.cos(pitch),math.sin(pitch)))
            name=deform+'.'+side
            rest_direction=rest_directions[name]
            def anatomical_frame(direction, right_axis):
                y=direction.normalized();x=(right_axis-y*right_axis.dot(y)).normalized();z=x.cross(y).normalized()
                return Matrix((x,y,z)).transposed().to_quaternion()
            delta=anatomical_frame(desired,Vector((math.cos(yaw),math.sin(yaw),0)))@anatomical_frame(rest_direction,Vector((1,0,0))).inverted()
            desired_rotation=delta@control_rest[name].to_quaternion()
            for _ in range(3):
                evaluated=arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
                correction=desired_rotation@evaluated.pose.bones[name].matrix.to_quaternion().inverted()
                m=control.matrix.copy()
                control.matrix=Matrix.LocRotScale(m.translation,correction@m.to_quaternion(),m.to_scale())
                bpy.context.view_layer.update()

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
walking_widths=[]
walking_toe_yaws={'L':[],'R':[]}
walking_contact_samples=[]
if args.preset:
    for frame in frame_times:
        scene.frame_set(math.floor(frame),subframe=frame%1)
        donor_floor[frame] = min((donor.matrix_world @ donor.pose.bones[s+'_Ankle'].matrix).translation.z for s in ('L','R'))
        if args.walk_cycle:
            source={p.name:donor.matrix_world@p.matrix for p in donor.pose.bones}
            lateral=source['L_Hip'].translation-source['R_Hip'].translation;lateral.z=0;lateral.normalize()
            forward=lateral.cross(Vector((0,0,1))).normalized()
            walking_widths.append(abs((source['L_Ankle'].translation-source['R_Ankle'].translation).dot(lateral)))
            for prefix in ('L','R'):
                direction=source[prefix+'_Foot'].to_3x3()@Vector((0,1,0))
                walking_toe_yaws[prefix].append(math.atan2(direction.dot(lateral),direction.dot(forward)))
                ankle=source[prefix+'_Ankle'].translation;toe=source[prefix+'_Foot'].translation
                foot_direction=toe-ankle
                walking_contact_samples.append({'height':ankle.z,'foot':math.atan2(foot_direction.z,foot_direction.dot(forward)),
                    'toes_01':math.atan2(direction.z,direction.dot(forward))})
    floor_base = min(donor_floor.values())
if args.walk_cycle:
    walking_lane_scale=(control_rest['c_thigh_fk.l'].translation-control_rest['c_thigh_fk.r'].translation).length*.875/statistics.mean(walking_widths)
    walking_toe_yaw={p:statistics.mean(v) for p,v in walking_toe_yaws.items()}
    # The donor's ankle-to-ball bone points down ~63 degrees on a flat
    # supporting foot; Tia's points down ~43. Absolute pitch transfer makes
    # her tiptoe. Transfer articulation relative to each rig's flat sole.
    low=sorted(walking_contact_samples,key=lambda x:x['height'])[:max(4,len(walking_contact_samples)//3)]
    walking_neutral_pitch={k:statistics.median(x[k] for x in low) for k in ('foot','toes_01')}
    walking_rest_pitch={k:statistics.mean(math.atan2(rest_directions[k+'.'+side].z,-rest_directions[k+'.'+side].y) for side in ('l','r')) for k in ('foot','toes_01')}
    print('WALK_FLAT_SOLE_REFERENCE', {k:round(math.degrees(v),2) for k,v in walking_neutral_pitch.items()},flush=True)
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
            clearance = max(0.0, min(1.0, -direction.z)) * (0 if args.walk_cycle else .24)
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
    if args.walk_cycle:
        calibrate_walking(pose_world)
    elif args.gait_clearance:
        calibrate_gait(pose_world)
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
seam_rotation = 0.0
seam_distance = 0.0
for offset in range(0,len(frames[0]),12):
    matrices = [Matrix([f[offset:offset+4],f[offset+4:offset+8],f[offset+8:offset+12],[0,0,0,1]]) for f in [frames[0],frames[-1]]]
    q = matrices[0].to_quaternion().rotation_difference(matrices[1].to_quaternion())
    angle = math.degrees(q.angle);seam_rotation=max(seam_rotation,min(angle,360-angle))
    seam_distance=max(seam_distance,(matrices[0].translation-matrices[1].translation).length)
loop_blend = 0 if seam_rotation < .25 and seam_distance < .0005 else .1
result = {'version': 1, 'id': args.name, 'label': args.name.title(),
          'source': ('Meshy preset' if args.preset else 'Meshy text-to-motion') + ', retargeted to the original Tia rig',
          'retargeting': {'version': 8 if args.walk_cycle else 4 if args.gait_clearance else 3,
                          **({'walkingFit':'source-hip-and-arm-swing-with-neutral-sole-reference'} if args.walk_cycle else {}),
                          'sourceFrameRange': [start,end], 'walkingCycle': args.walk_cycle,
                          'loopBlendSeconds': loop_blend if args.walk_cycle else .2, 'seamRotationDegrees': round(seam_rotation,4), 'pelvisTranslation': 'xyz', 'travelScale': round(travel_scale, 7), 'inPlace': args.in_place,
                          'forwardSpeed': round(forward_speed,7) if args.in_place else 0, 'forwardSpeedSource': speed_source,
                          'headReference': 'torso', 'invalidHeadTrack': 'smooth-fallback',
                          'gaitClearance': args.gait_clearance,
                          'footBasis': 'anatomical-ankle-and-toe'},
          'fps': output_fps, 'bones': bone_names, 'frames': frames,
          'bounds': [[round(v-.12,5) for v in envelope_min], [round(v+.12,5) for v in envelope_max]],
          'loop': args.walk_cycle or args.name in ('walk', 'dance')}
Path(args.output).write_text(json.dumps(result, separators=(',', ':')))
print('DONE', args.output, len(frames), 'frames', len(bone_names), 'bones', flush=True)
