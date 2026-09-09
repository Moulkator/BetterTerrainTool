shader_type canvas_item;
render_mode blend_mix;
// BTT_GRP_V4 -- version marker checked by better_terrain_tool.gd at boot.

uniform sampler2D tile;
uniform sampler2D mask;
uniform vec2 tile_size = vec2(512.0, 512.0);
uniform vec2 map_size = vec2(1.0, 1.0);
uniform float opacity = 1.0;
uniform float opaque = 0.0;        // 1 = ignore the texture alpha
uniform float hue = 0.0;           // degrees
uniform float saturation = 1.0;    // multiplier
uniform float lightness = 0.0;     // additive
uniform float gamma = 1.0;
uniform float contrast = 1.0;
uniform vec4 tint = vec4(1.0, 1.0, 1.0, 0.0);   // rgb + amount
uniform float tex_rot = 0.0;                    // radians
uniform float tex_scale = 1.0;
uniform vec2 tex_offset = vec2(0.0, 0.0);       // world px
uniform float blend_mode = 0.0;                 // 0 normal, 1 smooth (wide blur), 2 hard (height map)
uniform float color_blend = 0.0;                // index in the blend-mode list (see CB_NAMES)
uniform float lv_on = 0.0;                      // Photoshop-style Levels (per channel + master)
uniform vec3 lv_in_lo = vec3(0.0, 0.0, 0.0);    // r, g, b input black points
uniform vec3 lv_in_hi = vec3(1.0, 1.0, 1.0);
uniform vec3 lv_gamma = vec3(1.0, 1.0, 1.0);
uniform vec3 lv_out_lo = vec3(0.0, 0.0, 0.0);
uniform vec3 lv_out_hi = vec3(1.0, 1.0, 1.0);
uniform float lv_m_in_lo = 0.0;                 // master
uniform float lv_m_in_hi = 1.0;
uniform float lv_m_gamma = 1.0;
uniform float lv_m_out_lo = 0.0;
uniform float lv_m_out_hi = 1.0;
uniform float light_gain = 1.0;                 // Light Painting intensity
uniform float clip_on = 0.0;                    // clipping mask enabled
uniform sampler2D clip_mask;                    // coverage this layer is clipped to
uniform vec2 clip_texel = vec2(0.0);            // 1 / stencil resolution
uniform float stroke_on = 0.0;                  // GPU stroke in progress
uniform sampler2D stroke_tex;                   // max brush weight reached this stroke
uniform float stroke_mode = 0.0;                // 0 = non-additive (max/min), 1 = per stroke
uniform float stroke_erase = 0.0;
uniform vec2 move_off = vec2(0.0);              // live offset of the Move mode
uniform vec2 mask_texel = vec2(0.0, 0.0);       // 1 mask px in mask UV (unused, kept for compat)
uniform sampler2D mask_blur;                    // live downscaled mask (smooth mode)
uniform vec2 blur_scale = vec2(1.0, 1.0);       // map UV -> blur texture UV
uniform vec2 blur_texel = vec2(0.0, 0.0);       // 1 texel of mask_blur, in blur UV
uniform float grp_on = 0.0;                     // this layer belongs to a group
uniform sampler2D grp_mask;                     // the group's own fusion mask
uniform float grp_opacity = 1.0;                // opacity of the whole group
uniform float grp_blend = 0.0;                  // group edges: 0 normal, 1 smooth, 2 hard
uniform sampler2D grp_blur;                     // downscaled group mask (smooth mode)
uniform vec2 grp_blur_scale = vec2(1.0, 1.0);
uniform vec2 grp_blur_texel = vec2(0.0, 0.0);
uniform float grp_hue = 0.0;                    // group colour settings, applied
uniform float grp_saturation = 1.0;             // AFTER the member's own pipeline
uniform float grp_lightness = 0.0;              // (independent of the layers)
uniform float grp_gamma = 1.0;
uniform float grp_contrast = 1.0;
uniform vec4 grp_tint = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec2 grp_move_off = vec2(0.0);          // live Move-mode offset of the group mask
uniform float grp_tex_rot = 0.0;                // group Transform, composed with the member's
uniform float grp_tex_scale = 1.0;
uniform vec2 grp_tex_offset = vec2(0.0, 0.0);
uniform float grp_light_on = 0.0;               // group Light Painting (overrides the member's blend)
uniform float grp_light_gain = 1.0;
uniform float grp_clip_on = 0.0;                // group clipping mask
uniform sampler2D grp_clip_mask;
uniform vec2 grp_clip_texel = vec2(0.0);
// Gradient overlay (Photoshop "Gradient Overlay"): a 1D LUT built by the
// host from the colour stops, projected on a map-space axis p0 -> p1 and
// blended over the layer's colour with one of the blend modes.
uniform float grad_on = 0.0;
uniform sampler2D grad_tex;
uniform float grad_type = 0.0;                  // 0 linear, 1 radial, 2 reflected
uniform vec2 grad_p0 = vec2(0.0);
uniform vec2 grad_p1 = vec2(1024.0, 0.0);
uniform float grad_repeat = 0.0;
uniform float grad_opacity = 1.0;
uniform float grad_blend = 0.0;
// Same thing at the group level, applied after the group's colour stage.
uniform float grp_grad_on = 0.0;
uniform sampler2D grp_grad_tex;
uniform float grp_grad_type = 0.0;
uniform vec2 grp_grad_p0 = vec2(0.0);
uniform vec2 grp_grad_p1 = vec2(1024.0, 0.0);
uniform float grp_grad_repeat = 0.0;
uniform float grp_grad_opacity = 1.0;
uniform float grp_grad_blend = 0.0;
uniform sampler2D grp_mblur;                    // member mask blurred at the GROUP's smoothness
uniform vec2 grp_mblur_scale = vec2(1.0, 1.0);
uniform vec2 grp_mblur_texel = vec2(0.0, 0.0);
uniform float glv_on = 0.0;                     // group Levels stage
uniform vec3 glv_in_lo = vec3(0.0, 0.0, 0.0);
uniform vec3 glv_in_hi = vec3(1.0, 1.0, 1.0);
uniform vec3 glv_gamma = vec3(1.0, 1.0, 1.0);
uniform vec3 glv_out_lo = vec3(0.0, 0.0, 0.0);
uniform vec3 glv_out_hi = vec3(1.0, 1.0, 1.0);
uniform float glv_m_in_lo = 0.0;
uniform float glv_m_in_hi = 1.0;
uniform float glv_m_gamma = 1.0;
uniform float glv_m_out_lo = 0.0;
uniform float glv_m_out_hi = 1.0;

varying vec2 world_pos;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void vertex() {
	// Node sits at the level origin, so local VERTEX == world position.
	// (Polygon2D drops its UV array when it has no texture, so UV is unusable.)
	world_pos = VERTEX;
}

float lum3(vec3 c) {
	return dot(c, vec3(0.3, 0.59, 0.11));
}

vec3 clip_color(vec3 c) {
	float l = lum3(c);
	float mn = min(c.r, min(c.g, c.b));
	float mx = max(c.r, max(c.g, c.b));
	if (mn < 0.0) {
		c = l + (c - l) * l / max(l - mn, 0.0001);
	}
	if (mx > 1.0) {
		c = l + (c - l) * (1.0 - l) / max(mx - l, 0.0001);
	}
	return c;
}

vec3 set_lum(vec3 c, float l) {
	return clip_color(c + (l - lum3(c)));
}

float sat3(vec3 c) {
	return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

vec3 levels3(vec3 x, vec3 in_lo, vec3 in_hi, vec3 g, vec3 out_lo, vec3 out_hi) {
	vec3 t = clamp((x - in_lo) / max(in_hi - in_lo, vec3(0.001)), vec3(0.0), vec3(1.0));
	t = pow(t, 1.0 / max(g, vec3(0.01)));
	return mix(out_lo, out_hi, t);
}

vec3 set_sat(vec3 c, float s) {
	float mn = min(c.r, min(c.g, c.b));
	float mx = max(c.r, max(c.g, c.b));
	if (mx <= mn + 0.0001) {
		return vec3(0.0);
	}
	return (c - mn) * s / (mx - mn);
}

// Photoshop-style blend of `sc` over the backdrop `d` (modes 1..22, see
// CB_NAMES in color_settings.gd). Mode 0 / unknown: returns `sc`.
vec3 blend_rgb(int m, vec3 d, vec3 sc) {
	vec3 r = sc;
	if (m == 1) {                       // Darken
		r = min(d, sc);
	} else if (m == 2) {                // Multiply
		r = d * sc;
	} else if (m == 3) {                // Color Burn
		r = 1.0 - clamp((1.0 - d) / max(sc, vec3(0.004)), vec3(0.0), vec3(1.0));
	} else if (m == 4) {                // Linear Burn
		r = clamp(d + sc - 1.0, 0.0, 1.0);
	} else if (m == 5) {                // Darker Color
		r = lum3(sc) < lum3(d) ? sc : d;
	} else if (m == 6) {                // Lighten
		r = max(d, sc);
	} else if (m == 7) {                // Screen
		r = 1.0 - (1.0 - d) * (1.0 - sc);
	} else if (m == 8) {                // Color Dodge
		r = clamp(d / max(1.0 - sc, vec3(0.004)), vec3(0.0), vec3(1.0));
	} else if (m == 9) {                // Linear Dodge (Add)
		r = clamp(d + sc, 0.0, 1.0);
	} else if (m == 10) {               // Lighter Color
		r = lum3(sc) > lum3(d) ? sc : d;
	} else if (m == 11) {               // Overlay
		vec3 lo = 2.0 * d * sc;
		vec3 hi = 1.0 - 2.0 * (1.0 - d) * (1.0 - sc);
		r = mix(lo, hi, step(vec3(0.5), d));
	} else if (m == 12) {               // Soft Light
		vec3 lo = d - (1.0 - 2.0 * sc) * d * (1.0 - d);
		vec3 hi = d + (2.0 * sc - 1.0) * (sqrt(d) - d);
		r = mix(lo, hi, step(vec3(0.5), sc));
	} else if (m == 13) {               // Hard Light
		vec3 lo = 2.0 * d * sc;
		vec3 hi = 1.0 - 2.0 * (1.0 - d) * (1.0 - sc);
		r = mix(lo, hi, step(vec3(0.5), sc));
	} else if (m == 14) {               // Vivid Light
		vec3 lo = 1.0 - clamp((1.0 - d) / max(2.0 * sc, vec3(0.004)), vec3(0.0), vec3(1.0));
		vec3 hi = clamp(d / max(2.0 * (1.0 - sc), vec3(0.004)), vec3(0.0), vec3(1.0));
		r = mix(lo, hi, step(vec3(0.5), sc));
	} else if (m == 15) {               // Linear Light
		r = clamp(d + 2.0 * sc - 1.0, 0.0, 1.0);
	} else if (m == 16) {               // Pin Light
		vec3 lo = min(d, 2.0 * sc);
		vec3 hi = max(d, 2.0 * sc - 1.0);
		r = mix(lo, hi, step(vec3(0.5), sc));
	} else if (m == 17) {               // Subtract
		r = clamp(d - sc, 0.0, 1.0);
	} else if (m == 18) {               // Inverse Subtract
		r = clamp(sc - d, 0.0, 1.0);
	} else if (m == 19) {               // Hue
		r = set_lum(set_sat(sc, sat3(d)), lum3(d));
	} else if (m == 20) {               // Saturation
		r = set_lum(set_sat(d, sat3(sc)), lum3(d));
	} else if (m == 21) {               // Color
		r = set_lum(sc, lum3(d));
	} else if (m == 22) {               // Luminosity
		r = set_lum(d, lum3(sc));
	}
	return r;
}

// Position along a gradient axis, in [0, 1] (or wrapped when repeating).
float grad_t(vec2 wp, vec2 p0, vec2 p1, float type, float rep) {
	vec2 d = p1 - p0;
	float len2 = max(dot(d, d), 1.0);
	float t;
	if (type > 1.5) {                              // reflected: mirrored around p0
		t = abs(dot(wp - p0, d) / len2);
	} else if (type > 0.5) {                       // radial: distance from p0
		t = length(wp - p0) / sqrt(len2);
	} else {                                       // linear
		t = dot(wp - p0, d) / len2;
	}
	if (rep > 0.5) {
		t = fract(t);
	}
	return clamp(t, 0.0, 1.0);
}

vec3 grad_apply(vec3 rgb, sampler2D lut, vec2 wp, vec2 p0, vec2 p1, float type, float rep, float opac, float mode) {
	vec4 gc = texture(lut, vec2(grad_t(wp, p0, p1, type, rep), 0.5));
	int m = int(mode + 0.5);
	vec3 top = (m >= 1 && m <= 22) ? blend_rgb(m, rgb, gc.rgb) : gc.rgb;
	return mix(rgb, top, clamp(gc.a * opac, 0.0, 1.0));
}

void fragment() {
	vec2 mwp = world_pos - move_off;
	float m = texture(mask, mwp / map_size).r;
	// Group Transform composes with the member's own (identity when the
	// layer is not grouped, whatever stale grp_* values the material holds).
	float g_rot = (grp_on > 0.5) ? grp_tex_rot : 0.0;
	float g_scl = (grp_on > 0.5) ? grp_tex_scale : 1.0;
	vec2 g_off = (grp_on > 0.5) ? grp_tex_offset : vec2(0.0);
	// Group Light Painting: the energy must stay linear in the brush alpha,
	// so both the member's and the group's edge shaping are bypassed.
	bool g_light = (grp_on > 0.5) && (grp_light_on > 0.5);
	float bm = g_light ? 0.0 : blend_mode;
	vec2 uv = world_pos - tex_offset - g_off;
	float cs = cos(tex_rot + g_rot);
	float sn = sin(tex_rot + g_rot);
	uv = vec2(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs);
	vec4 c = texture(tile, uv / (tile_size * max(tex_scale * g_scl, 0.01)));
	if (bm > 1.5) {
		// Hard: the texture's alpha acts as a height map.
		m = clamp(smoothstep(0.35, 0.65, m + (c.a - 0.5) * 0.6), 0.0, 1.0) * step(0.003, m);
	} else if (bm > 0.5) {
		// Smooth: 5x5 gaussian on a live, downscaled copy of the mask.
		// Taps are 1 small-texel apart, so no ghost-dot artifacts.
		vec2 buv = (mwp / map_size) * blur_scale;
		// Clamp the taps inside the map so the blur never fades at the borders.
		vec2 lo = blur_texel * 0.5;
		vec2 hi = blur_scale - blur_texel * 0.5;
		float acc = 0.0;
		float wsum = 0.0;
		for (int dy = -2; dy <= 2; dy++) {
			for (int dx = -2; dx <= 2; dx++) {
				vec2 d = vec2(float(dx), float(dy));
				float wgt = exp(-dot(d, d) * 0.35);
				vec2 uv2 = clamp(buv + d * blur_texel, lo, hi);
				acc += texture(mask_blur, uv2).r * wgt;
				wsum += wgt;
			}
		}
		m = acc / wsum;
	}
	if (stroke_on > 0.5) {
		// Live preview of a GPU-composited stroke (the CPU mask is untouched
		// until the mouse is released).
		float acc = texture(stroke_tex, world_pos / map_size).r;
		if (stroke_erase > 0.5) {
			m = max(m - acc, 0.0);          // erase removes the brush weight
		} else if (stroke_mode < 0.5) {
			m = max(m, acc);
		} else {
			m = mix(m, 1.0, acc);
		}
	}
	if (clip_on > 0.5) {
		// 3x3 tent blur on the stencil: softens the silhouette contours
		// beyond what plain bilinear filtering can do.
		vec2 cuv = world_pos / map_size;
		float ck = 0.0;
		float cw = 0.0;
		for (int cy = -1; cy <= 1; cy++) {
			for (int cx = -1; cx <= 1; cx++) {
				float wgt = (cx == 0 && cy == 0) ? 4.0 : ((cx == 0 || cy == 0) ? 2.0 : 1.0);
				ck += texture(clip_mask, cuv + vec2(float(cx), float(cy)) * clip_texel).r * wgt;
				cw += wgt;
			}
		}
		// Soft threshold pulled slightly INWARD: the blur no longer bleeds
		// outside the silhouette, and the asset's own soft alpha rim stays
		// covered by its body instead of showing at the edge.
		m *= smoothstep(0.42, 0.85, ck / cw);
	}
	float g_op = 1.0;
	if (grp_on > 0.5) {
		// Approximate group compositing: the member's coverage is multiplied
		// by the group's own fusion mask (with the GROUP's smooth / hard edge
		// shaping) and by the group's opacity. Unlike true offscreen
		// compositing, the members' color blend modes keep working against
		// the map below.
		vec2 gwp = world_pos - grp_move_off;
		float gm = texture(grp_mask, gwp / map_size).r;
		float gbm = g_light ? 0.0 : grp_blend;
		if (gbm > 1.5) {
			// Hard: the member texture's alpha acts as a height map, on the
			// group mask AND on the member's coverage (the group's blending
			// shapes the edge of the whole group, not only its fusion mask).
			gm = clamp(smoothstep(0.35, 0.65, gm + (c.a - 0.5) * 0.6), 0.0, 1.0) * step(0.003, gm);
			m = clamp(smoothstep(0.35, 0.65, m + (c.a - 0.5) * 0.6), 0.0, 1.0) * step(0.003, m);
		} else if (gbm > 0.5) {
			// Smooth: the member's coverage is replaced by its blur at the
			// group's smoothness (same 5x5 gaussian as the layers' Smooth).
			vec2 mbuv = (mwp / map_size) * grp_mblur_scale;
			vec2 mlo = grp_mblur_texel * 0.5;
			vec2 mhi = grp_mblur_scale - grp_mblur_texel * 0.5;
			float macc = 0.0;
			float mwsum = 0.0;
			for (int my = -2; my <= 2; my++) {
				for (int mx = -2; mx <= 2; mx++) {
					vec2 md = vec2(float(mx), float(my));
					float mwgt = exp(-dot(md, md) * 0.35);
					vec2 muv2 = clamp(mbuv + md * grp_mblur_texel, mlo, mhi);
					macc += texture(grp_mblur, muv2).r * mwgt;
					mwsum += mwgt;
				}
			}
			m = macc / mwsum;
			// Smooth: 5x5 gaussian on a live, downscaled copy of the group mask.
			vec2 gbuv = (gwp / map_size) * grp_blur_scale;
			vec2 glo = grp_blur_texel * 0.5;
			vec2 ghi = grp_blur_scale - grp_blur_texel * 0.5;
			float gacc = 0.0;
			float gwsum = 0.0;
			for (int gy = -2; gy <= 2; gy++) {
				for (int gx = -2; gx <= 2; gx++) {
					vec2 gd = vec2(float(gx), float(gy));
					float gwgt = exp(-dot(gd, gd) * 0.35);
					vec2 guv2 = clamp(gbuv + gd * grp_blur_texel, glo, ghi);
					gacc += texture(grp_blur, guv2).r * gwgt;
					gwsum += gwgt;
				}
			}
			gm = gacc / gwsum;
		}
		m *= gm;
		g_op = grp_opacity;
		if (grp_clip_on > 0.5) {
			// The group's own clipping stencil (same 3x3 tent blur + inward
			// threshold as the per-layer one), independent of the members'.
			vec2 gcuv = world_pos / map_size;
			float gck = 0.0;
			float gcw = 0.0;
			for (int cy = -1; cy <= 1; cy++) {
				for (int cx = -1; cx <= 1; cx++) {
					float wgt = (cx == 0 && cy == 0) ? 4.0 : ((cx == 0 || cy == 0) ? 2.0 : 1.0);
					gck += texture(grp_clip_mask, gcuv + vec2(float(cx), float(cy)) * grp_clip_texel).r * wgt;
					gcw += wgt;
				}
			}
			m *= smoothstep(0.42, 0.85, gck / gcw);
		}
	}
	vec3 rgb = c.rgb;
	if (hue != 0.0 || saturation != 1.0) {
		vec3 hsv = rgb2hsv(rgb);
		hsv.x = fract(hsv.x + hue / 360.0);
		hsv.y = clamp(hsv.y * saturation, 0.0, 1.0);
		rgb = hsv2rgb(hsv);
	}
	rgb = clamp(rgb + vec3(lightness), 0.0, 1.0);
	rgb = (rgb - vec3(0.5)) * contrast + vec3(0.5);
	rgb = pow(clamp(rgb, 0.0, 1.0), vec3(1.0 / max(gamma, 0.01)));
	rgb = mix(rgb, tint.rgb, tint.a);
	if (lv_on > 0.5) {
		rgb = levels3(rgb, lv_in_lo, lv_in_hi, lv_gamma, lv_out_lo, lv_out_hi);
		rgb = levels3(rgb, vec3(lv_m_in_lo), vec3(lv_m_in_hi), vec3(lv_m_gamma), vec3(lv_m_out_lo), vec3(lv_m_out_hi));
	}
	if (grad_on > 0.5 && color_blend < 22.5 && !g_light) {
		rgb = grad_apply(rgb, grad_tex, world_pos, grad_p0, grad_p1, grad_type, grad_repeat, grad_opacity, grad_blend);
	}
	if (grp_on > 0.5) {
		// The GROUP's own colour settings: a full second pipeline, applied on
		// top of the member's result. The members' dictionaries are never
		// touched, so layer and group settings stay independent.
		if (grp_hue != 0.0 || grp_saturation != 1.0) {
			vec3 ghsv = rgb2hsv(rgb);
			ghsv.x = fract(ghsv.x + grp_hue / 360.0);
			ghsv.y = clamp(ghsv.y * grp_saturation, 0.0, 1.0);
			rgb = hsv2rgb(ghsv);
		}
		rgb = clamp(rgb + vec3(grp_lightness), 0.0, 1.0);
		rgb = (rgb - vec3(0.5)) * grp_contrast + vec3(0.5);
		rgb = pow(clamp(rgb, 0.0, 1.0), vec3(1.0 / max(grp_gamma, 0.01)));
		rgb = mix(rgb, grp_tint.rgb, grp_tint.a);
		if (glv_on > 0.5) {
			rgb = levels3(rgb, glv_in_lo, glv_in_hi, glv_gamma, glv_out_lo, glv_out_hi);
			rgb = levels3(rgb, vec3(glv_m_in_lo), vec3(glv_m_in_hi), vec3(glv_m_gamma), vec3(glv_m_out_lo), vec3(glv_m_out_hi));
		}
		if (grp_grad_on > 0.5 && color_blend < 22.5 && !g_light) {
			rgb = grad_apply(rgb, grp_grad_tex, world_pos, grp_grad_p0, grp_grad_p1, grp_grad_type, grp_grad_repeat, grp_grad_opacity, grp_grad_blend);
		}
	}
	int cbm = int(color_blend + 0.5);
	float lgain = light_gain;
	if (g_light) {
		cbm = 23;
		lgain = grp_light_gain;
	}
	if (cbm > 0) {
		vec3 d = textureLod(SCREEN_TEXTURE, SCREEN_UV, 0.0).rgb;
		vec3 sc = rgb;
		if (cbm <= 22) {
			rgb = blend_rgb(cbm, d, sc);
		} else {                              // 23: painted light (our own light
			// system, DD-style, composited at the slot's z. The brush alpha
			// scales the ENERGY inside the exponential: each channel then
			// saturates at a different point along the falloff, which gives
			// the hue-shifting fringe of DD lights (white-hot core, coloured
			// rim), instead of one flat colour faded linearly.
			// Exactly DD's pipeline: scene * (1 + energy * light colour),
			// HARD clamped per channel. The clipping order of the channels
			// is what makes the look: with an orange light the red channel
			// clips first (red rim), then green (orange body), and the blue
			// one stays low -- yellow core, never washed white.
			float en = mix(c.a, 1.0, opaque) * m * opacity * g_op;
			rgb = clamp(d * (1.0 + sc * lgain * en), vec3(0.0), vec3(1.0));
		}
	}
	float a = mix(c.a, 1.0, opaque);
	float am = a * m * opacity * g_op;
	if (cbm == 23) {
		am = 1.0;   // the energy already carries the brush alpha (see above)
	}
	COLOR = vec4(rgb, am);
}
