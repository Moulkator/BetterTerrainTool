# BetterTerrainTool

Better Terrain Tool (BTT) adds a layer-based terrain painter to Dungeondraft: unlimited terrain slots, real brushes, procedural generation, groups, clipping masks, light painting, gradients and colour adjustments — all saved inside your map file.

---

## 1. Getting started
<p align="center">
<img width="290" height="198" alt="image" src="https://github.com/user-attachments/assets/cbafcb51-d103-4f2a-b6d9-4ad5230e2825" />


1. Enable the mod, open a map and pick **Better Terrain Tool** in the **Terrain** category (right after the vanilla Terrain brush).
2. Click **+** in the *Terrain Layers* list to add a slot, then pick a texture in the **Textures** tab of the right panel.
3. Paint on the map: **left click** paints, **right click** (or **Alt + click**) erases.

Everything you paint is stored in the map file, so it travels with the map and survives a reload.

> Tip: **Hide Vanilla Terrain** (bottom of the panel) hides Dungeondraft's own terrain layer and its tool on the current level, so BTT is the only terrain you see. It is saved per level. When the vanilla terrain is already disabled in its own tool, the switch reads **Hide Vanilla Terrain Brush Tool** and only hides the tool.

---

## 2. The layer list

Each row is a terrain slot: thumbnail, `z-layer: name`, blending icon and an eye.
<p align="center">
<img width="315" height="1089" alt="Screenshot3" src="https://github.com/user-attachments/assets/811b947f-1e37-455b-a9b3-f383e46f39ef" />



| Action | Result |
|---|---|
| Click a row | Select it |
| **Ctrl + click** | Add / remove the row from the selection |
| **Shift + click** | Select a range |
| Click the thumbnail | Select the slot and jump to its texture in the Textures tab |
| Double-click the name | Rename |
| Drag a row | Reorder (changes its z-layer) |
| **Alt + drag** a row | Duplicate it at the drop position (Photoshop style) |
| Blend icon (N / S / H) | Cycle the edge mode: **Normal**, **Smooth** (soft edges, adjustable smoothness), **Hard** (the texture's alpha acts as a height map) |
| Eye | Hide / show the slot |
| Header eye / header blend icon | Hide-show or force the blending of **every** slot at once |
| **+** / **−** | Add / remove slots (− removes the whole selection, after confirmation) |
| Right click on a row | Duplicate, Delete, Remove from group, group submenu, **Compact rows** |

**Compact rows** (right click) shrinks every row to the height of its text — handy on small screens. The list can be resized with the grip under it; in compact mode it hugs its content.

<p align="center">
<img width="371" height="375" alt="image" src="https://github.com/user-attachments/assets/b4be1a70-3a2c-46ae-84d6-1d73c553e28e" />
<p align="center">
<img width="370" height="276" alt="image" src="https://github.com/user-attachments/assets/f2369485-9382-4853-aeef-3cefa043b46e" />



Shortcuts on the list:

- **Ctrl + J** — duplicate the selection (copies stay selected).
- **Ctrl + G** — group the selection (see *Groups*).

With several slots selected, most properties (texture, opacity, colour settings, transform, procedural generation…) apply to all of them at once.

### Layer / Opacity

<p align="center">
<img width="316" height="76" alt="image" src="https://github.com/user-attachments/assets/c8b43f08-e62d-4e87-95d7-21d179ab04a1" />


- **Layer** slider or `<` `>` buttons: the z-layer the slot renders on. The `<` `>` buttons jump to the layers defined in the map (Terrain, Caves, User Layer 1, …).
- **Opacity**: overall opacity of the slot.

### Presets
<p align="center">
<img width="320" height="140" alt="image" src="https://github.com/user-attachments/assets/8cb96779-6a17-42a1-97a5-5a8f501dcbc5" />

**Layer presets** save the current level's slots (textures, order, settings — not the paint) under a name; **Load** adds them to any level. Useful to reuse a palette across maps.

---

## 3. Painting modes
<p align="center">
<img width="287" height="54" alt="image" src="https://github.com/user-attachments/assets/ab271001-d58d-4fa2-8315-781ceff3c904" />


The four icons above *Fill / Clear* choose how you paint:

| Mode | What it does |
|---|---|
| **Brush** | Stamp the selected brush. Left click paints, right click / Alt + click erases. |
| **Shape** | Rectangle, ellipse or polygon coverage. Right click erases, **Alt** draws from the centre, **Shift** keeps 1:1. Polygon: click to place points, **Shift + click** for curves, click the first point or double-click to close, **Esc** cancels. |
| **Fill** | Fills the region under the click, bounded by walls, paths and patterns. |
| **Move** | Drag the coverage of the selected slot(s) (or of a whole group) across the map. |

**Fill** / **Clear** fill or clear the whole selected slot(s).

---

## 4. The right panel

Two tabs, **Textures** and **Brushes**, with a search box and a **Show: All / Favorites / Hidden** view button (counts underneath). Right click an item to add it to favourites or hide it. Drag the panel's left edge to resize it.

### Textures

- **Use Plain Color** paints a solid colour instead of a texture.
- **Show patterns** also lists pattern and tileset textures.
- **Search by color**: click a swatch, pick a custom colour or use the eyedropper on the map; **Tolerance** widens the match. **Sort by** Color or Name.
<p align="center">
<img width="318" height="841" alt="image" src="https://github.com/user-attachments/assets/17e6f825-8261-42df-a525-f0894a58bd53" />


### Brushes

- Grayscale PNGs dropped in `User Folder → BetterTerrainTool/brushes` appear here (subfolders are fine).
- Right click a brush: favourite, hide, **invert**.
- Thumbnails are cached on disk, so even a very large library opens quickly after the first time.
- Drag the grip under the grid to make the library taller than the panel (double-click the grip to reset).

<p align="center">
<img width="314" height="948" alt="image" src="https://github.com/user-attachments/assets/ea8eb06c-da69-4c67-839b-1a719b53866e" />
<p align="center">
<img width="275" height="170" alt="image" src="https://github.com/user-attachments/assets/6b5a9c90-88dc-405b-a7ef-97053e30ed79" />


### Brush shortcuts (while painting)

| Input | Effect |
|---|---|
| Mouse wheel | Rotate the brush (10° steps) |
| **Z** + wheel / **Shift + Z** + wheel | Rotate in 5° / 1° steps |
| **Alt** + wheel, or **[** / **]** | Brush size |
| **Shift** + wheel | Step through the list shown in the right panel (textures or brushes) |
| **Alt + right-drag** | Live adjust: horizontal = hardness, vertical = roundness |
| **Esc** | Cancel the current shape / move |

### Brush settings
<p align="center">
<img width="313" height="412" alt="image" src="https://github.com/user-attachments/assets/9caf7bf0-6406-495b-a3ca-3959de6e54dc" />


- **Size**, **Hardness**, **Roundness** (0 = square window, 1 = round), **Intensity**.
- **Stroke**: *Additive* (stamps pile up), *Non-additive* (a stroke never exceeds the brush intensity), *Per stroke* (each stroke composites once).
- **Rotation** / **Ratio** with random dice: randomise per stamp; the lock keeps a fixed value.
- **Continuous paint**: keep stamping while the button is held, even without moving.
- **Quality**: mask resolution of the selected slot, from *Potato* to *Godlike*. Higher costs more memory and map size; *High* is plenty for soft terrain.
- **Display light shapes**: also list the Light tool's textures as brushes.

---

## 5. Procedural generation

Click **Procedural Generation** to fill the selected slot(s) with organic, noise-based coverage. The cog opens the settings:

- **Blob size** — scale of the shapes.
- **Detail** — high-frequency carving of the edges and the inside.
- **Coverage %** — how much of the slot is covered.

<p align="center">
<img width="311" height="158" alt="image" src="https://github.com/user-attachments/assets/3f6bb72b-f9bd-46f1-a30e-d6dab2502023" />


With several slots selected (**Procedural Generation (Multi)**), coverage is tapered by z: the lowest slot gets the requested coverage, the highest about 40 % of it, so upper slots never bury the ones below.

After a generation, a **Coverage %** slider appears under the button for every generated slot: release it to re-threshold the *same* noise at another coverage — the blobs keep their shape, only their extent changes. (It regenerates the whole mask, so paint added afterwards is replaced.)

---

## 6. Groups

Select several slots and press **Ctrl + G** (or right click → group submenu → *New group*). A group row appears; its members are indented and can be folded.

<p align="center">
<img width="309" height="229" alt="image" src="https://github.com/user-attachments/assets/40ee5488-10a4-4b26-be14-76f4fc32ac21" />
<p align="center">
<img width="311" height="311" alt="image" src="https://github.com/user-attachments/assets/4db1713d-7ade-42cb-9864-118ef1718093" />


- Click the group row to select the group. **Ctrl + click** it to select the member layers instead.
- Painting on a selected group edits its **fusion mask**: right click / Alt + click carves the group out, left click restores it. **Move** moves every member and the fusion mask together.
- The group has its own **Opacity**, **Smoothness**, **Blending** (Normal / Smooth / Hard — shapes the edge of the whole group), **Colour Settings**, **Gradient**, **Transform**, **Light Painting** and **Clipping Mask** — independent of the members' own settings.
- Everything else (texture, procedural generation, hide/show…) applies to every member.
- Right click the group row: **Rename**, **Dissolve group** (keeps the layers), **Delete group (with layers)** — the latter asks for confirmation; Ctrl + Z restores everything.
- Duplicating a grouped slot keeps the copy in the group.

---

## 7. Advanced slot options

### Clipping Mask

<p align="center">
<img width="315" height="267" alt="image" src="https://github.com/user-attachments/assets/9d469c78-54d9-485a-b57c-f22815ffffe4" />
<p align="center">
<img width="319" height="205" alt="image" src="https://github.com/user-attachments/assets/fb4055ab-a670-4bab-b542-0c4b8fdb7595" />


The slot only shows where the target objects are drawn (Photoshop-style clipping). Modes: **Same Layer**, **All Objects Below**, **All Objects Above**, **Single Object**. Use **Select Object** and click an object on the map to clip to it. Works on groups too.

### Light Painting

<p align="center">
<img width="315" height="86" alt="image" src="https://github.com/user-attachments/assets/fb076afd-11d1-48d9-baf0-c938bfa35c69" />

The slot becomes a painted *light*: it composites like the Light tool and the map's darkness reacts to it. **Intensity** controls the gain. Use a soft brush for glows, or a hard one for lit surfaces.

### Color Variants

<p align="center">
<img width="320" height="146" alt="image" src="https://github.com/user-attachments/assets/bf1c7ea2-8dfa-4a0f-9418-5c7ec4cd667b" />

Randomised per-stamp colour variation (hue / saturation / lightness ranges) so a single texture never looks tiled.

### Color Settings

<p align="center">
<img width="310" height="391" alt="image" src="https://github.com/user-attachments/assets/cacaff52-a98f-4b0c-9233-85abe4e5192c" />

Hue, saturation, lightness, gamma, contrast, tint (colour + amount), a blend mode against the map below, and Photoshop-style **Levels** with histogram and per-channel input/output. **Reset Colors** puts everything back. An **All** switch applies the panel to every slot.

### Gradient

<p align="center">
<img width="358" height="554" alt="image" src="https://github.com/user-attachments/assets/c52d6709-7512-490d-b1d5-a4a2a3f2e87a" />


A Photoshop-style **gradient overlay** on the slot (or the group), blended over its texture. Switch it **ON** to enable it and unfold its settings:

- **Draw Gradient**: then drag on the map — press where the gradient starts, release where it ends (for *Radial*: centre and radius). The axis and its direction are shown on the map while Draw mode is on; drag again to redo it, click the button again to leave the mode. **Reset Gradient** restores the default black → white gradient.
- The **preview bar** shows the result; **double-click** it to add a stop at that position.
- The **stops editor** underneath: drag a stop to move it, drag the small **diamond** between two stops to move their midpoint (where the 50 % mix sits, like Photoshop), **right-click** a stop to remove it. The row below edits the selected stop: **colour with alpha**, **position %**, **midpoint %**, **+** / **−**.
- **Type**: *Linear*, *Radial* or *Reflected* (mirrored on both sides of the start point). **Opacity %** fades the whole gradient.
- The gradient has its **own colour settings** — blend mode (how the gradient combines with the slot's texture), gamma, contrast, hue, saturation, lightness, tint and Levels — separate from the slot's Color Settings, which do not affect it. **Reset Gradient Colors** puts them back.

The gradient only changes colours, never the slot's opacity. It is saved with the map, copied with the slot (duplicate, clone, presets) and ignored in Light Painting mode.

### Transform

<p align="center">
<img width="296" height="189" alt="image" src="https://github.com/user-attachments/assets/16e12ac2-54ac-4c2a-b8d2-9e2fce1be4f5" />

Rotation, scale and offset of the slot's texture (a group's transform composes with its members').

---

## 8. Good to know

- **Undo / redo** works everywhere: strokes, fills, generation, layer edits, groups, clipping picks. Multi-deletes and group deletes are a single undo step.
- **Map resize** (Map → Change Map Size): the terrain follows the map content, including cells added or removed on the left / top.
- **Levels**: every level has its own terrain slots. **Clone Level** (New Level window) copies the source level's terrain too. On maps with several levels, **Clone terrain on:** (bottom of the panel) copies the current level's terrain onto another level (replacing that level's terrain, after confirmation). Layer presets carry textures, settings and gradients — not the paint.
- **File size**: masks are stored as compact single-channel PNGs. The main lever remains the slot **Quality** — *High* is four times lighter than *Ultra*.
- **Custom brushes**: grayscale PNG, white = paint. Big libraries are fine; thumbnails are built in the background.
- If you see a "shader is outdated" warning after an update, copy the new `shaders/terrain_layer.shader` from the mod folder and restart.

---

### Quick reference

| Shortcut | Action |
|---|---|
| Left click / Right click / Alt + click | Paint / erase / erase |
| Wheel · Z + wheel · Shift + Z + wheel | Rotate brush 10° · 5° · 1° |
| Alt + wheel · [ · ] | Brush size |
| Shift + wheel | Next / previous texture or brush |
| Alt + right-drag | Hardness (H) and roundness (V) |
| Esc | Cancel shape / move |
| Ctrl + click · Shift + click | Multi-select · range select |
| Ctrl + J | Duplicate selection |
| Ctrl + G | Group selection |
| Alt + drag a row | Duplicate at drop position |
| Double-click a name | Rename |
