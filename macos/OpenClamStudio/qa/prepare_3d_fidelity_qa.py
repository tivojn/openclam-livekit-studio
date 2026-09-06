"""Blender integration regression: visibility, shader baking, surface + morphs.

blender --factory-startup -b --python-exit-code 1 --python qa/prepare_3d_fidelity_qa.py
"""
import sys
from pathlib import Path
import bpy
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from prepare_3d_fidelity import source_objects, preserve_materials, apply_surface_modifiers

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
