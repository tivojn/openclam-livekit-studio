"""Preserve a Blender character's saved appearance during glTF preparation.

Run in Blender, through prepare-3d-avatar.py. Never execute embedded scripts.
Material arithmetic is evaluated by Cycles, not guessed from node names.
"""
import bpy
import numpy as np


def source_objects():
    """The saved view layer's visible character meshes and their skeletons."""
    renderable = set()
    def visit(layer):
        if layer.exclude or layer.collection.hide_render:
            return
        renderable.update(layer.collection.objects)
        for child in layer.children:
            visit(child)
    visit(bpy.context.view_layer.layer_collection)
    objects = {o for o in renderable
               if o.type == 'MESH' and o.visible_get() and not o.hide_render}
    pending = list(objects)
    while pending:
        obj = pending.pop()
        dependencies = [obj.parent] + [m.object for m in obj.modifiers
                                      if m.type == 'ARMATURE']
        for dependency in dependencies:
            if dependency and dependency not in objects:
                objects.add(dependency)
                pending.append(dependency)
    return objects


def apply_surface_modifiers(obj):
    """Evaluate every shape on the SAME subdivided topology, without skinning.

    Applying modifiers in the glTF exporter drops shape keys; disabling them
    exports the coarse control cage. Sampling each target retains both the
    author's render surface and the facial deltas, UVs and skin weights.
    """
    modifiers = [m for m in obj.modifiers if m.type != 'ARMATURE' and m.show_render]
    if not modifiers:
        return
    supported = {'SUBSURF', 'SMOOTH', 'CORRECTIVE_SMOOTH', 'WEIGHTED_NORMAL', 'NODES'}
    unsupported = [m.name for m in modifiers if m.type not in supported]
    if unsupported:
        raise ValueError(f'{obj.name}: unsupported surface modifiers: {unsupported}')
    source = obj.data
    keys = source.shape_keys
    if keys and not keys.use_relative:
        raise ValueError(f'{obj.name}: absolute shape keys need explicit conversion')
    samples = []
    if keys:
        for key in keys.key_blocks:
            coords = np.empty(len(source.vertices) * 3, dtype=np.float32)
            key.data.foreach_get('co', coords)
            samples.append((key.name, key.value, key.relative_key.name, key.mute,
                            key.slider_min, key.slider_max, coords))
    else:
        coords = np.empty(len(source.vertices) * 3, dtype=np.float32)
        source.vertices.foreach_get('co', coords)
        samples.append(('Basis', 0, 'Basis', False, 0, 1, coords))
    temp = obj.copy()
    temp.data = source.copy()
    bpy.context.scene.collection.objects.link(temp)
    temp.hide_render = False
    temp.hide_viewport = False
    temp.hide_set(False)
    if temp.data.shape_keys:
        temp.shape_key_clear()
    for modifier in temp.modifiers:
        modifier.show_viewport = modifier.type != 'ARMATURE' and modifier.show_render
        if modifier.type == 'SUBSURF':
            modifier.levels = modifier.render_levels
    graph = bpy.context.evaluated_depsgraph_get()
    evaluated_mesh = None
    positions = []
    try:
        for name, *_, coords in samples:
            temp.data.vertices.foreach_set('co', coords)
            temp.data.update()
            graph.update()
            mesh = bpy.data.meshes.new_from_object(temp.evaluated_get(graph),
                preserve_all_data_layers=True, depsgraph=graph)
            if evaluated_mesh and len(mesh.vertices) != len(evaluated_mesh.vertices):
                bpy.data.meshes.remove(mesh)
                raise ValueError(f'{obj.name}: modifier changes topology between shape keys')
            values = np.empty(len(mesh.vertices) * 3, dtype=np.float32)
            mesh.vertices.foreach_get('co', values)
            positions.append(values)
            if evaluated_mesh is None:
                evaluated_mesh = mesh
            else:
                bpy.data.meshes.remove(mesh)
        obj.data = evaluated_mesh
        if keys:
            for spec, coords in zip(samples, positions):
                name, value, relative, mute, low, high, _ = spec
                key = obj.shape_key_add(name=name, from_mix=False)
                key.data.foreach_set('co', coords)
                key.slider_min, key.slider_max = low, high
                key.value, key.mute = value, mute
            for spec in samples:
                obj.data.shape_keys.key_blocks[spec[0]].relative_key = obj.data.shape_keys.key_blocks[spec[2]]
        for modifier in list(obj.modifiers):
            if modifier.type != 'ARMATURE':
                obj.modifiers.remove(modifier)
        print(f'[fidelity] {obj.name}: {len(source.vertices)} -> {len(obj.data.vertices)} vertices; {len(samples)-1} morphs', flush=True)
    finally:
        scratch = temp.data
        bpy.data.objects.remove(temp, do_unlink=True)
        if scratch.users == 0:
            bpy.data.meshes.remove(scratch)


def output_node(mat):
    return mat.node_tree.get_output_node('CYCLES') or mat.node_tree.get_output_node('ALL')


def surface_shader(socket):
    if not socket.is_linked:
        return None
    node = socket.links[0].from_node
    if node.type in ('BSDF_PRINCIPLED', 'BSDF_GLASS'):
        return node
    if node.type == 'REROUTE':
        return surface_shader(node.inputs[0])
    if node.type == 'ADD_SHADER':
        linked = [s for s in node.inputs if s.is_linked]
        if len(linked) == 1:
            return surface_shader(linked[0])
    if node.type == 'MIX_SHADER' and not node.inputs[0].is_linked:
        factor = node.inputs[0].default_value
        if factor == 0:
            return surface_shader(node.inputs[1])
        if factor == 1:
            return surface_shader(node.inputs[2])
    raise ValueError(f'Cannot preserve shader {node.name}; bake/convert this surface explicitly')


def bake_channel(mat, socket, owners, size, label):
    """Bake the evaluated socket over all owners, including separate face parts."""
    scene = bpy.context.scene
    tree = mat.node_tree
    output = output_node(mat)
    image = bpy.data.images.new(f'{mat.name}_{label}_baked', size, size, alpha=False)
    image.colorspace_settings.name = 'sRGB' if label in ('Base Color', 'Emission Color') else 'Non-Color'
    engine, device, samples = scene.render.engine, scene.cycles.device, scene.cycles.samples
    original = [(l.from_socket, l.to_socket) for l in output.inputs['Surface'].links]
    emission = tree.nodes.new('ShaderNodeEmission')
    target = tree.nodes.new('ShaderNodeTexImage')
    target.image = image
    previous_active = tree.nodes.active
    other_targets = []
    modifiers = []
    try:
        scene.render.engine = 'CYCLES'
        scene.cycles.device = 'CPU'
        scene.cycles.samples = 1
        tree.links.new(socket.links[0].from_socket, emission.inputs['Color'])
        tree.links.new(emission.outputs[0], output.inputs['Surface'])
        tree.nodes.active = target
        # Non-target material slots need throwaway bake targets as well.
        others = {slot.material for obj in owners for slot in obj.material_slots
                  if slot.material and slot.material != mat and slot.material.node_tree}
        for other in others:
            node = other.node_tree.nodes.new('ShaderNodeTexImage')
            scratch = bpy.data.images.new('__openclam_bake_scratch', 16, 16)
            node.image = scratch
            other_targets.append((other, node, scratch, other.node_tree.nodes.active))
            other.node_tree.nodes.active = node
        for obj in owners:
            if not obj.data.uv_layers.active:
                raise ValueError(f'{obj.name}: a UV map is required to bake {mat.name}')
            for modifier in obj.modifiers:
                modifiers.append((modifier, modifier.show_render, modifier.show_viewport))
                modifier.show_render = modifier.show_viewport = False
        for index, obj in enumerate(owners):
            bpy.ops.object.select_all(action='DESELECT')
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.bake(type='EMIT', use_clear=index == 0, margin=8,
                                use_selected_to_active=False)
        image.pack()
        print(f'[fidelity] baked {mat.name} / {label} at {size}px', flush=True)
        return image
    finally:
        for modifier, render, viewport in modifiers:
            modifier.show_render, modifier.show_viewport = render, viewport
        for link in list(output.inputs['Surface'].links):
            tree.links.remove(link)
        for source, destination in original:
            tree.links.new(source, destination)
        tree.nodes.remove(target)
        tree.nodes.remove(emission)
        tree.nodes.active = previous_active
        for other, node, scratch, active in other_targets:
            other.node_tree.nodes.remove(node)
            other.node_tree.nodes.active = active
            bpy.data.images.remove(scratch)
        scene.render.engine, scene.cycles.device, scene.cycles.samples = engine, device, samples


def preserve_materials(objects, color_size, secondary_size, bake_specs=()):
    meshes = sorted((o for o in objects if o.type == 'MESH'), key=lambda o: o.name)
    materials = {slot.material for obj in meshes for slot in obj.material_slots if slot.material}
    forced = {}
    for spec in bake_specs:
        name, _, size = spec.partition('=')
        if name not in {m.name for m in materials}:
            raise ValueError(f'No exported mesh uses requested bake material {name}')
        forced[name] = int(size or color_size)
    for mat in sorted(materials, key=lambda m: m.name):
        if not mat.use_nodes or not output_node(mat):
            continue
        tree = mat.node_tree
        output = output_node(mat)
        shader = surface_shader(output.inputs['Surface'])
        if shader is None:
            continue
        if shader.type == 'BSDF_GLASS':
            # Export actual glass, not a white, nearly invisible alpha shell.
            glass = shader
            shader = tree.nodes.new('ShaderNodeBsdfPrincipled')
            for source, destination in [('Color', 'Base Color'), ('Roughness', 'Roughness'), ('IOR', 'IOR'), ('Normal', 'Normal')]:
                if glass.inputs[source].is_linked:
                    tree.links.new(glass.inputs[source].links[0].from_socket, shader.inputs[destination])
                else:
                    shader.inputs[destination].default_value = glass.inputs[source].default_value
            shader.inputs['Transmission Weight'].default_value = 1
            shader.inputs['Alpha'].default_value = 1
        owners = [obj for obj in meshes if any(slot.material == mat for slot in obj.material_slots)]
        # Direct texture links and constants are glTF-native. Every other
        # color/scalar graph is evaluated without losing tints or mix factors.
        for name in ('Base Color', 'Alpha', 'Roughness', 'Metallic', 'Emission Color', 'Specular IOR Level'):
            socket = shader.inputs.get(name)
            force = name == 'Base Color' and mat.name in forced
            if not socket or not socket.is_linked or (socket.links[0].from_node.type == 'TEX_IMAGE' and not force):
                continue
            size = color_size if name in ('Base Color', 'Alpha', 'Emission Color') else secondary_size
            if force:
                size = forced[mat.name]
            image = bake_channel(mat, socket, owners, size, name)
            node = tree.nodes.new('ShaderNodeTexImage')
            node.image = image
            tree.links.new(node.outputs['Color'], socket)
        # Use the shader which actually reaches the source render output.
        # Unused Principled nodes elsewhere in the graph are not substitutes.
        for node in tree.nodes:
            if node.type == 'OUTPUT_MATERIAL':
                node.is_active_output = False
        output.target = 'ALL'
        output.is_active_output = True
        tree.links.new(shader.outputs[0], output.inputs['Surface'])
