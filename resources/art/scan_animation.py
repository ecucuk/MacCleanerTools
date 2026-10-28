"""Renders the scan animation: a brand-gradient ring with a sweeping arc.

Run headless:
  Blender -b --factory-startup -P resources/art/scan_animation.py -- <frames_dir>
then encode with tools/build_art.sh. Every frame is transparent so the
clip sits on any background, light or dark.
"""
import math
import sys

import bpy

out_dir = sys.argv[sys.argv.index("--") + 1]
FRAMES = 48  # 2 s at 24 fps; the scene repeats exactly every 48 frames

BLUE = (0.012, 0.107, 0.846, 1.0)   # #1c5ced in linear sRGB
TEAL = (0.016, 0.468, 0.730, 1.0)   # #21b5de in linear sRGB

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in {
    e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items
} else "BLENDER_EEVEE"
scene.render.resolution_x = scene.render.resolution_y = 240
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"
scene.frame_start, scene.frame_end = 1, FRAMES

world = bpy.data.worlds.new("w")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
scene.world = world


def material(name, color, emission=0.0, roughness=0.3):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    if emission:
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = emission
    return m


def gradient_material():
    m = material("ring", BLUE)
    nodes, links = m.node_tree.nodes, m.node_tree.links
    coord = nodes.new("ShaderNodeTexCoord")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = BLUE
    ramp.color_ramp.elements[1].color = TEAL
    links.new(coord.outputs["Generated"], sep.inputs[0])
    links.new(sep.outputs["X"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    return m


# Static ring, tilted towards the camera.
bpy.ops.mesh.primitive_torus_add(major_radius=1.0, minor_radius=0.12, major_segments=96, minor_segments=24)
ring = bpy.context.object
ring.data.materials.append(gradient_material())
ring.rotation_euler = (math.radians(62), 0, 0)
bpy.ops.object.shade_smooth()

# The sweeping arc: a glowing partial torus that spins once per loop.
bpy.ops.mesh.primitive_torus_add(major_radius=1.0, minor_radius=0.135, major_segments=96, minor_segments=24)
arc = bpy.context.object
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="DESELECT")
bpy.ops.object.mode_set(mode="OBJECT")
for v in arc.data.vertices:
    angle = math.atan2(v.co.y, v.co.x)
    v.select = angle > math.radians(-60)  # keep a 120-degree arc
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.delete(type="VERT")
bpy.ops.object.mode_set(mode="OBJECT")
arc.data.materials.append(material("arc", (0.05, 0.45, 1.0, 1.0), emission=0.9))
bpy.ops.object.shade_smooth()


def spinner(name):
    """An empty tilted into the ring's plane, with a child that turns in it."""
    tilt = bpy.data.objects.new(name + "_tilt", None)
    scene.collection.objects.link(tilt)
    tilt.rotation_euler = ring.rotation_euler
    turn = bpy.data.objects.new(name, None)
    scene.collection.objects.link(turn)
    turn.parent = tilt
    return turn


pivot = spinner("pivot")
arc.parent = pivot

# Three dots orbiting the centre, a third of a loop apart.
dots = spinner("dots")
for i in range(3):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.07, segments=24, ring_count=12)
    dot = bpy.context.object
    a = i * 2 * math.pi / 3
    dot.location = (0.55 * math.cos(a), 0.55 * math.sin(a), 0)
    dot.data.materials.append(material("dot%d" % i, TEAL, emission=1.0))
    bpy.ops.object.shade_smooth()
    dot.parent = dots


def spin(obj, turns):
    for frame, z in ((1, 0.0), (FRAMES + 1, turns * 2 * math.pi)):
        obj.rotation_euler[2] = z
        obj.keyframe_insert("rotation_euler", index=2, frame=frame)


# Constant speed, so frame 48 flows into frame 1 without an ease.
bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
spin(pivot, -1)
spin(dots, 1 / 3)  # a third turn swaps identical dots: seamless loop

light = bpy.data.objects.new("key", bpy.data.lights.new("key", "AREA"))
light.data.energy = 300
light.data.size = 3
light.location = (2, -3, 4)
scene.collection.objects.link(light)
light.rotation_euler = (math.radians(40), 0, math.radians(30))

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.location = (0, -5.2, 0)
cam.rotation_euler = (math.radians(90), 0, 0)
cam.data.lens = 70
scene.collection.objects.link(cam)
scene.camera = cam

scene.render.filepath = out_dir.rstrip("/") + "/f_"
bpy.ops.render.render(animation=True)
