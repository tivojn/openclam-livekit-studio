"""Optimise a rigged character for the OpenClam 3D avatar renderer.

Run inside Blender (headless):

    blender -b --python scripts/prepare-3d-avatar.py -- \
        --input  ~/Downloads/Character.glb \
        --output ~/Desktop/character-openclam.glb \
        [--texture-size 2048] [--drop 'Weap|floor|cs_'] [--blend-scene]

What it does:

* Imports a GLB/glTF/FBX or opens a .blend project.
* Exports the saved view layer's visible character meshes and their skeletons.
  Hidden outfit alternatives remain hidden unless explicitly included.
* Deletes objects whose names match ``--drop`` (weapons, floors, rig widgets).
* Keeps only the face shape keys the renderer can drive: the Oculus/Meta XR
  15-viseme set (``vrc.v_*``, ``v_*``, ``viseme_*``), the ARKit 52 set,
  VRM/VRoid ``Fcl_*`` keys and blink keys.  Every other key is baked into the
  basis at its current value, so clothing-fit or body-proportion keys keep
  their effect without shipping their vertex data.
* Downsamples colour textures to ``--texture-size`` (default 2048 px) and
  normal/roughness/metal/AO maps to ``--secondary-size`` (default 1024 px),
  then re-encodes them as WebP (``EXT_texture_webp``), which keeps alpha and
  is decoded natively by the Chromium-based renderer.
* Bakes evaluated material color/scalar graphs and retains render subdivision
  on every facial target, including UVs and interpolated skin weights.
* Exports one self-contained GLB without morph normals or animations.

Final size and GPU cost depend on the source render subdivision and the
number of retained facial targets; inspect the exported model before import.
"""
import argparse
import os
import re
import sys

import bpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prepare_3d_fidelity import source_objects, apply_surface_modifiers, preserve_materials

ARKIT_52 = {
    "eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft",
    "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft", "eyeBlinkRight",
    "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight",
    "eyeSquintRight", "eyeWideRight", "jawForward", "jawLeft", "jawRight",
    "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthRight",
    "mouthLeft", "mouthSmileLeft", "mouthSmileRight", "mouthFrownRight",
    "mouthFrownLeft", "mouthDimpleLeft", "mouthDimpleRight",
    "mouthStretchLeft", "mouthStretchRight", "mouthRollLower",
    "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthPressLeft",
    "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthUpperUpLeft", "mouthUpperUpRight", "browDownLeft", "browDownRight",
    "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff",
    "cheekSquintLeft", "cheekSquintRight", "noseSneerLeft", "noseSneerRight",
    "tongueOut",
}
KEEP_PATTERNS = re.compile(
    r"^(vrc\.v_|vrc\.blink|vrc\.lowerlid|v_|viseme_|Fcl_|blink|Blink|"
    r"eyeBlink|A$|I$|U$|E$|O$|aa$|ih$|ou$|ee$|oh$)")
DEFAULT_DROP = r"^(Weap|cs_|floor|Camera|bevelCurve|NurbsCurve|Plane$|Cube\.\d+$)"


def log(*parts):
    print("[prepare-3d-avatar]", *parts, flush=True)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--texture-size", type=int, default=2048,
                        help="max edge for colour/albedo textures")
    parser.add_argument("--secondary-size", type=int, default=1024,
                        help="max edge for normal/roughness/metal/AO maps")
    parser.add_argument("--image-format", default="WEBP",
                        choices=("WEBP", "AUTO", "JPEG"),
                        help="WEBP keeps alpha and is decoded natively by the renderer")
    parser.add_argument("--drop", default=DEFAULT_DROP,
                        help="regex of object names to delete")
    parser.add_argument("--include", default="",
                        help="regex of object names to force into the export even if "
                             "the file hides them or keeps them out of the view layer")
    parser.add_argument("--keep-all-shape-keys", action="store_true")
    parser.add_argument("--bake", action="append", default=[],
                        help="MATERIAL[=SIZE]: bake that material's base colour to one "
                             "texture (for node graphs the glTF exporter cannot flatten)")
    parser.add_argument("--no-simplify", action="store_true",
                        help="leave material node graphs untouched")
    parser.add_argument("--legacy-simplify", action="store_true",
                        help="use the old lossy image-selection material conversion")
    parser.add_argument("--control-cage", action="store_true",
                        help="omit render surface modifiers (changes the authored silhouette)")
    parser.add_argument("--base-color", action="append", default=[],
                        help="MATERIAL=IMAGE: wire a specific image (by Blender image "
                             "name) straight into that material's base colour, e.g. a "
                             "painted face map the file leaves unconnected")
    parser.add_argument("--parent-to-bone", action="append", default=[],
                        help="REGEX=ARMATURE:BONE: parent unskinned pieces (a hairstyle "
                             "without weights) to a bone so they follow the head")
    parser.add_argument("--assign-material", action="append", default=[],
                        help="REGEX=MATERIAL[@IMAGE]: give objects matching REGEX the "
                             "named material; creates a Principled material from IMAGE "
                             "when it does not exist (hair pieces shipped without one)")
    parser.add_argument("--image-quality", type=int, default=82)
    return parser.parse_args(argv)


def load(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".blend":
        bpy.ops.wm.open_mainfile(filepath=path)
        return
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    else:
        raise SystemExit(f"unsupported input {ext}")


def include_objects(pattern):
    """Link hidden / excluded outfit pieces into the scene and unhide them."""
    if not pattern:
        return
    regex = re.compile(pattern)
    scene = bpy.context.scene
    for obj in bpy.data.objects:
        if not regex.search(obj.name):
            continue
        if obj.name not in scene.collection.objects and not any(
                obj.name in c.objects for c in scene.collection.children_recursive):
            scene.collection.objects.link(obj)
        for collection in obj.users_collection:
            collection.hide_render = False
            collection.hide_viewport = False
        # Excluded collections keep their objects out of the view layer;
        # linking to the scene root above makes them visible regardless.
        obj.hide_render = False
        obj.hide_viewport = False
        try:
            obj.hide_set(False)
        except RuntimeError:
            scene.collection.objects.link(obj)
            obj.hide_set(False)
        log("include", obj.type, obj.name)


def drop_objects(pattern):
    if not pattern:
        return
    regex = re.compile(pattern)
    doomed = [o for o in bpy.data.objects if regex.search(o.name)]
    for obj in doomed:
        log("drop", obj.type, obj.name)
        bpy.data.objects.remove(obj, do_unlink=True)


def keep_key(name):
    return name in ARKIT_52 or bool(KEEP_PATTERNS.match(name))


def prune_shape_keys(obj):
    keys = obj.data.shape_keys
    if not keys or len(keys.key_blocks) < 2:
        return
    blocks = keys.key_blocks
    basis = blocks[0]
    kept = [k for k in blocks[1:] if keep_key(k.name)]
    dropped = [k for k in blocks[1:] if not keep_key(k.name)]
    if not dropped:
        return
    active = [k for k in dropped if abs(k.value) > 1e-4 and not k.mute]
    if active:
        # Bake the dropped keys at their current values into the basis and
        # shift every kept key by the same delta, so kept deltas stay intact.
        log(f"{obj.name}: baking {len(active)} active key(s):",
            ", ".join(f"{k.name}={k.value:.2f}" for k in active))
        saved = {k.name: k.value for k in kept}
        for k in kept:
            k.value = 0.0
        mix = obj.shape_key_add(name="__openclam_mix", from_mix=True)
        count = len(basis.data)
        deltas = [mix.data[i].co - basis.data[i].co for i in range(count)]
        for k in kept:
            for i in range(count):
                k.data[i].co += deltas[i]
        for i in range(count):
            basis.data[i].co += deltas[i]
        obj.shape_key_remove(mix)
        for k in kept:
            k.value = saved[k.name]
    for k in dropped:
        obj.shape_key_remove(k)
    log(f"{obj.name}: kept {len(kept)} shape keys, removed {len(dropped)}")


SECONDARY_MAP = re.compile(r"(normal|nrm|rough|rou|metal|spec|_ao|ao\d|occlusion|height|bump)", re.I)


# -------------------------------------------------------------- materials
#
# The glTF exporter only understands an image wired straight into a
# Principled input.  Character packs usually route colour through mix nodes
# (variant pickers), hue/saturation tweaks and shader mixes.  Collapse each
# input to the image the current factors select, so the export keeps the
# authored look instead of a flat default colour.

COLOUR_PASSTHROUGH = {"HUE_SAT", "BRIGHTCONTRAST", "GAMMA", "CURVE_RGB", "INVERT",
                      "RGBTOBW", "MIX_SHADER", "ADD_SHADER"}


def _mix_branches(node):
    if node.type == "MIX_RGB":
        return node.inputs[0], node.inputs[1], node.inputs[2]
    if node.type == "MIX":
        by_id = {sock.identifier: sock for sock in node.inputs}
        kind = getattr(node, "data_type", "RGBA")
        return (by_id.get("Factor_Float") or node.inputs[0],
                by_id.get(f"A_{'Color' if kind == 'RGBA' else 'Float'}") or by_id.get("A_Color"),
                by_id.get(f"B_{'Color' if kind == 'RGBA' else 'Float'}") or by_id.get("B_Color"))
    return None


def _resolve_image(socket, depth=0):
    """Follow a link back to the image node the current factors select."""
    if not socket.is_linked or depth > 12:
        return None
    link = socket.links[0]
    node = link.from_node
    if node.type == "TEX_IMAGE":
        return node, link.from_socket.name
    branches = _mix_branches(node)
    if branches:
        factor, first, second = branches
        if factor.is_linked or first is None or second is None:
            chosen = first if first is not None and first.is_linked else second
        else:
            chosen = second if float(factor.default_value) >= .5 else first
        found = _resolve_image(chosen, depth + 1)
        if found:
            return found
        other = first if chosen is second else second
        return _resolve_image(other, depth + 1)
    if node.type in ("MIX_SHADER", "ADD_SHADER"):
        for inp in node.inputs:
            if inp.type == "SHADER" and inp.is_linked:
                found = _resolve_image(inp, depth + 1)
                if found:
                    return found
        return None
    for inp in node.inputs:
        if inp.is_linked and inp.type in ("RGBA", "VALUE", "SHADER"):
            found = _resolve_image(inp, depth + 1)
            if found:
                return found
    return None


CLEAR_MATERIAL = re.compile(r"(^|[^a-z])(clr|clear|cornea|glass|tear|lens)", re.I)


def simplify_material(mat, skip_base=False):
    tree = mat.node_tree
    if not tree:
        return
    principled = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    transmission = principled.inputs.get("Transmission Weight") if principled else None
    if principled and (CLEAR_MATERIAL.search(mat.name)
                       or (transmission and not transmission.is_linked
                           and float(transmission.default_value) > .5)):
        # Cornea / glass shells: glTF has no cheap transmission, so export
        # them as a faint blended layer instead of an opaque white cap.
        alpha = principled.inputs.get("Alpha")
        if alpha:
            for link in list(alpha.links):
                tree.links.remove(link)
            alpha.default_value = .1
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "BLENDED"
        else:
            mat.blend_method = "BLEND"
        log(f"material {mat.name}: exported as clear layer")
    output = next((n for n in tree.nodes if n.type == "OUTPUT_MATERIAL" and n.is_active_output), None) \
        or next((n for n in tree.nodes if n.type == "OUTPUT_MATERIAL"), None)
    if not principled or not output:
        return
    surface = output.inputs["Surface"]
    if not surface.is_linked or surface.links[0].from_node is not principled:
        for link in list(surface.links):
            tree.links.remove(link)
        tree.links.new(principled.outputs["BSDF"], surface)
    for name in ("Base Color", "Alpha", "Roughness", "Metallic", "Emission Color"):
        if name == "Base Color" and skip_base:
            continue
        sock = principled.inputs.get(name)
        if not sock or not sock.is_linked:
            continue
        source = sock.links[0].from_node
        if source.type == "TEX_IMAGE":
            continue
        found = _resolve_image(sock)
        for link in list(sock.links):
            tree.links.remove(link)
        if found:
            node, out_name = found
            out_name = out_name if out_name in node.outputs else "Color"
            if name == "Alpha" and out_name == "Color":
                # Alpha authored as a separate greyscale image: keep it a
                # separate texture, the exporter merges it into the base map.
                pass
            tree.links.new(node.outputs[out_name], sock)
            log(f"material {mat.name}: {name} <- {node.image.name if node.image else '?'}")
        else:
            log(f"material {mat.name}: {name} left as constant")
    normal = principled.inputs.get("Normal")
    if normal and normal.is_linked and normal.links[0].from_node.type != "NORMAL_MAP":
        found = _resolve_image(normal)
        for link in list(normal.links):
            tree.links.remove(link)
        if found:
            nm = tree.nodes.new("ShaderNodeNormalMap")
            tree.links.new(found[0].outputs["Color"], nm.inputs["Color"])
            tree.links.new(nm.outputs["Normal"], normal)


def bake_base_color(mat, size):
    """Bake the evaluated base colour of one material to a fresh texture."""
    owners = [o for o in bpy.data.objects if o.type == "MESH"
              and any(s.material is mat for s in o.material_slots)]
    if not owners:
        log(f"bake: no mesh uses {mat.name}")
        return
    obj = max(owners, key=lambda o: len(o.data.vertices))
    scene = bpy.context.scene
    engine = scene.render.engine
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 4
    bake = scene.render.bake
    bake.use_pass_direct = False
    bake.use_pass_indirect = False
    bake.use_pass_color = True
    bake.margin = 8
    image = bpy.data.images.new(f"{mat.name}_basecolor", size, size, alpha=False)
    image.colorspace_settings.name = "sRGB"
    temporary = []
    for slot in obj.material_slots:
        m = slot.material
        if not m or not m.node_tree:
            continue
        node = m.node_tree.nodes.new("ShaderNodeTexImage")
        node.image = image if m is mat else bpy.data.images.new(f"__scratch_{m.name}", 16, 16)
        m.node_tree.nodes.active = node
        temporary.append((m, node))
    for o in bpy.data.objects:
        o.select_set(False)
    obj.hide_set(False)
    obj.hide_viewport = False
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    log(f"bake: {mat.name} on {obj.name} at {size}px")
    bpy.ops.object.bake(type="DIFFUSE", margin=8, use_clear=True)
    image.pack()
    for m, node in temporary:
        if m is mat:
            principled = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
            if principled:
                base = principled.inputs["Base Color"]
                for link in list(base.links):
                    m.node_tree.links.remove(link)
                m.node_tree.links.new(node.outputs["Color"], base)
        else:
            scratch = node.image
            m.node_tree.nodes.remove(node)
            bpy.data.images.remove(scratch)
    scene.render.engine = engine


EXPLICIT_BASE = set()


def wire_base_colors(specs):
    for spec in specs:
        name, _, image_name = spec.partition("=")
        mat = bpy.data.materials.get(name)
        image = bpy.data.images.get(image_name)
        if not mat or not mat.node_tree or not image:
            log(f"base-color: unknown material or image in {spec}")
            continue
        tree = mat.node_tree
        principled = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if not principled:
            continue
        node = next((n for n in tree.nodes if n.type == "TEX_IMAGE" and n.image is image), None)
        if node is None:
            node = tree.nodes.new("ShaderNodeTexImage")
            node.image = image
        base = principled.inputs["Base Color"]
        for link in list(base.links):
            tree.links.remove(link)
        tree.links.new(node.outputs["Color"], base)
        EXPLICIT_BASE.add(mat.name)
        log(f"material {mat.name}: Base Color <- {image.name} (explicit)")


def parent_to_bones(specs):
    for spec in specs:
        pattern, _, target = spec.partition("=")
        armature_name, _, bone_name = target.partition(":")
        armature = bpy.data.objects.get(armature_name)
        if not armature or armature.type != "ARMATURE" or bone_name not in armature.data.bones:
            log(f"parent-to-bone: unknown armature/bone in {spec}")
            continue
        regex = re.compile(pattern)
        for obj in bpy.data.objects:
            if obj.type != "MESH" or not regex.search(obj.name):
                continue
            if any(m.type == "ARMATURE" and m.object for m in obj.modifiers):
                continue
            world = obj.matrix_world.copy()
            obj.parent = armature
            obj.parent_type = "BONE"
            obj.parent_bone = bone_name
            obj.matrix_world = world
            log(f"parent {obj.name} -> {armature_name}:{bone_name}")


def assign_materials(specs):
    for spec in specs:
        pattern, _, target = spec.partition("=")
        material_name, _, image_name = target.partition("@")
        mat = bpy.data.materials.get(material_name)
        if mat is None:
            mat = bpy.data.materials.new(material_name)
            mat.use_nodes = True
            principled = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
            principled.inputs["Roughness"].default_value = 0.55
            image = bpy.data.images.get(image_name) if image_name and not image_name.startswith("#") else None
            if image:
                node = mat.node_tree.nodes.new("ShaderNodeTexImage")
                node.image = image
                mat.node_tree.links.new(node.outputs["Color"], principled.inputs["Base Color"])
            elif image_name.startswith("#") and len(image_name) == 7:
                # A flat sRGB colour, e.g. "#c9a15a" for a hair cap without a
                # usable strand texture.
                rgb = [int(image_name[i:i + 2], 16) / 255 for i in (1, 3, 5)]
                linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
                principled.inputs["Base Color"].default_value = (*linear, 1.0)
                principled.inputs["Roughness"].default_value = 0.6
            log(f"material {material_name}: created"
                + (f" from {image.name}" if image else f" as {image_name}" if image_name else ""))
        regex = re.compile(pattern)
        for obj in bpy.data.objects:
            if obj.type != "MESH" or not regex.search(obj.name):
                continue
            if obj.data.materials:
                for index in range(len(obj.data.materials)):
                    obj.data.materials[index] = mat
            else:
                obj.data.materials.append(mat)
            log(f"assign {mat.name} -> {obj.name}")


def prepare_materials(bake_specs, simplify=True):
    baked = set()
    for spec in bake_specs:
        name, _, size = spec.partition("=")
        mat = bpy.data.materials.get(name)
        if not mat:
            log(f"bake: unknown material {name}")
            continue
        bake_base_color(mat, int(size or 2048))
        baked.add(mat.name)
    if not simplify:
        return
    used = {s.material for o in bpy.data.objects if o.type == "MESH"
            for s in o.material_slots if s.material}
    for mat in used:
        simplify_material(mat, skip_base=mat.name in baked or mat.name in EXPLICIT_BASE)


def downsample_images(limit, secondary_limit):
    for image in bpy.data.images:
        if image.size[0] == 0:
            try:
                # Packed glTF images stay unloaded until their pixels are read.
                _ = len(image.pixels)
            except Exception:
                continue
        width, height = image.size
        if width == 0:
            continue
        cap = secondary_limit if SECONDARY_MAP.search(image.name or "") else limit
        if max(width, height) <= cap:
            continue
        scale = cap / max(width, height)
        new_w, new_h = max(1, round(width * scale)), max(1, round(height * scale))
        image.scale(new_w, new_h)
        log(f"texture {image.name}: {width}x{height} -> {new_w}x{new_h}")


def summarise():
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    verts = sum(len(o.data.vertices) for o in meshes)
    keys = sum(len(o.data.shape_keys.key_blocks) - 1
               for o in meshes if o.data.shape_keys)
    bones = sum(len(o.data.bones) for o in bpy.data.objects if o.type == "ARMATURE")
    log(f"{len(meshes)} meshes, {verts} vertices, {keys} shape keys, {bones} bones")


def main():
    args = parse_args()
    load(os.path.abspath(args.input))
    include_objects(args.include)
    drop_objects(args.drop)
    objects = source_objects()
    meshes = [o for o in objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no visible character meshes in the saved view layer")
    if not args.keep_all_shape_keys:
        for obj in meshes:
            prune_shape_keys(obj)
    parent_to_bones(args.parent_to_bone)
    # Explicit bone parenting may introduce another skeleton dependency.
    objects = source_objects()
    assign_materials(args.assign_material)
    wire_base_colors(args.base_color)
    if args.legacy_simplify or args.no_simplify:
        prepare_materials(args.bake, simplify=not args.no_simplify)
    else:
        preserve_materials(objects, args.texture_size, args.secondary_size, args.bake)
    if not args.control_cage:
        for obj in meshes:
            apply_surface_modifiers(obj)
    downsample_images(args.texture_size, args.secondary_size)
    summarise()
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.hide_set(False)
        obj.select_set(True)
    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=output,
        export_format="GLB",
        export_apply=False,
        export_morph=True,
        export_morph_normal=False,
        export_morph_tangent=False,
        export_skins=True,
        export_def_bones=True,
        export_animations=False,
        export_image_format=args.image_format,
        export_image_quality=args.image_quality,
        export_jpeg_quality=args.image_quality,
        export_yup=True,
        use_selection=True,
    )
    log(f"wrote {output} ({os.path.getsize(output) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
