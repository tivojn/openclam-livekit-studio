"""Blender integration regression: visibility, shader baking, surface + morphs.

blender --factory-startup -b --python-exit-code 1 --python qa/prepare_3d_fidelity_qa.py
"""
import sys
import json
import struct
import tempfile
from pathlib import Path
import bpy
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from prepare_3d_fidelity import (source_objects, preserve_materials, apply_surface_modifiers,
                                 bone_attachments, attach_exported_rigs)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_plane_add()
obj = bpy.context.object
obj.name = 'Visible character'
hidden = obj.copy()
hidden.data = obj.data.copy()
bpy.context.scene.collection.objects.link(hidden)
hidden.hide_set(True)
render_hidden = obj.copy()
bpy.context.scene.collection.objects.link(render_hidden)
render_hidden.hide_render = True
assert source_objects() == {obj}, 'Hidden alternate outfits must not be exported'

mat = bpy.data.materials.new('Evaluated mix')
mat.use_nodes = True
obj.data.materials.append(mat)
tree = mat.node_tree
pbr = tree.nodes.get('Principled BSDF')
mix = tree.nodes.new('ShaderNodeMixRGB')
mix.inputs[0].default_value = .25
mix.inputs[1].default_value = (1, 0, 0, 1)
mix.inputs[2].default_value = (0, 0, 1, 1)
tree.links.new(mix.outputs[0], pbr.inputs['Base Color'])
preserve_materials({obj}, 32, 32)
image = pbr.inputs['Base Color'].links[0].from_node.image
pixel = np.array(image.pixels[:]).reshape(32, 32, 4)[16, 16, :3]
# Byte color images expose sRGB pixels. Decode before comparing linear math.
linear = np.where(pixel <= .04045, pixel / 12.92, ((pixel + .055) / 1.055) ** 2.4)
assert np.allclose(linear, [.75, 0, .25], atol=.015), f'Mix must be evaluated, not choose one branch: {pixel}'

basis = obj.shape_key_add(name='Basis')
mouth = obj.shape_key_add(name='vrc.v_aa')
for vertex in mouth.data:
    vertex.co.z += .25
mouth.value = .4
group = obj.vertex_groups.new(name='head')
group.add(list(range(4)), 1, 'REPLACE')
sub = obj.modifiers.new('Source smoothing', 'SUBSURF')
sub.levels = 0
sub.render_levels = 2
apply_surface_modifiers(obj)
assert len(obj.data.vertices) > 4, 'Export must retain render subdivision'
keys = obj.data.shape_keys.key_blocks
assert abs(keys['vrc.v_aa'].value - .4) < 1e-6
delta = np.array([v.co[:] for v in keys['vrc.v_aa'].data]) - np.array([v.co[:] for v in keys['Basis'].data])
assert np.allclose(delta[:, 2], .25), 'Subdivision must preserve facial deltas'
assert all(abs(v.groups[0].weight - 1) < 1e-6 for v in obj.data.vertices), 'Skin weights must survive'
assert not obj.modifiers, 'Export must not apply subdivision a second time'
print('PASS: saved visibility, evaluated material mix, subdivision, morph deltas and skin weights')

# A hairstyle with its own skin can follow a non-deforming head controller in
# Blender. glTF drops that constraint and the controller, leaving it static.
bpy.ops.object.armature_add()
body = bpy.context.object
body.name = 'Body rig'
bpy.ops.object.mode_set(mode='EDIT')
control = body.data.edit_bones[0]
control.name = 'Head controller'
control.use_deform = False
head = body.data.edit_bones.new('Head deform')
head.head, head.tail, head.parent = control.head, control.tail, control
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.armature_add()
hair = bpy.context.object
hair.name = 'Accessory rig'
link = hair.constraints.new('CHILD_OF')
link.target, link.subtarget = body, control.name
bpy.context.view_layer.update()
attachments = bone_attachments({hair, body})
assert attachments == [('Accessory rig', 'Body rig', 'Head deform')]
link.influence = .5
try:
    bone_attachments({hair, body})
    raise AssertionError('Partial constraints cannot be replaced by rigid parenting')
except ValueError:
    pass
link.influence = 1
link.mute = True
assert bone_attachments({hair, body}) == [], 'Disabled constraints must stay disabled'
link.mute = False
body.hide_set(True)
obj.parent = hair
assert body in source_objects(), 'An attachment target must remain in the export selection'

# Nontrivial existing parents, rotations and scale expose an incorrect offset.
document = {'asset': {'version': '2.0'}, 'scene': 0, 'scenes': [{'nodes': [0, 3]}],
    'nodes': [
        {'name': 'Body rig', 'translation': [2, 3, -1], 'children': [1]},
        {'name': 'Head deform', 'translation': [0, 1.5, 0],
         'rotation': [0, .5, 0, 3 ** .5 / 2]},
        {'name': 'Accessory rig', 'translation': [1, 2, 3], 'scale': [2, 2, 2], 'children': [4, 5]},
        {'name': 'Accessory group', 'translation': [-3, 1, 0], 'children': [2]},
        {'name': 'Accessory joint', 'translation': [0, 2, 0]},
        {'name': 'Accessory mesh', 'skin': 0, 'mesh': 0}],
    'skins': [{'joints': [4], 'inverseBindMatrices': 0}], 'meshes': [{'primitives': []}]}
binary = struct.pack('<2I', 4, 0x004E4942) + b'abcd'
def read_glb(path):
    data = path.read_bytes()
    size = struct.unpack_from('<I', data, 12)[0]
    assert struct.unpack_from('<I', data, 8)[0] == len(data)
    assert data[20 + size:] == binary, 'Skin/texture/geometry bytes must remain identical'
    return json.loads(data[20:20 + size])

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'attachment.glb'
    encoded = json.dumps(document).encode()
    encoded += b' ' * (-len(encoded) % 4)
    path.write_bytes(struct.pack('<5I', 0x46546C67, 2, 20 + len(encoded) + len(binary),
                                 len(encoded), 0x4E4F534A) + encoded + binary)
    attach_exported_rigs(path, attachments)
    fixed = read_glb(path)
    assert fixed['nodes'][1]['children'] == [2]
    assert fixed['nodes'][3]['children'] == []
    assert fixed['nodes'][2]['children'] == [4, 5], 'Attach the whole rig, including skin joints'
    assert fixed['skins'] == document['skins']
    # Head world transform multiplied by the new offset must equal the old
    # accessory world transform: translation (-2, 3, 3), uniform scale 2.
    from mathutils import Matrix, Quaternion, Vector
    head_world = Matrix.Translation((2, 4.5, -1)) @ Quaternion((3 ** .5 / 2, 0, .5, 0)).to_matrix().to_4x4()
    values = fixed['nodes'][2]['matrix']
    local = Matrix([values[i::4] for i in range(4)])
    expected = Matrix.LocRotScale(Vector((-2, 3, 3)), Quaternion(), Vector((2, 2, 2)))
    assert np.allclose(np.array(head_world @ local), np.array(expected), atol=1e-5)
    once = path.read_bytes()
    attach_exported_rigs(path, attachments)
    assert path.read_bytes() == once, 'Repeated repair must not add motion or offset'
    try:
        attach_exported_rigs(path, [('Body rig', 'Body rig', 'Head deform')])
        raise AssertionError('Cycles must be rejected')
    except ValueError:
        assert path.read_bytes() == once, 'A failed repair must not modify the model'
print('PASS: separate accessory skeleton follows its authored bone with bind pose and binary data preserved')
