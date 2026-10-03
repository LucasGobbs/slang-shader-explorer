package main

import "core:math"

// Camera data written into SceneUniforms. Matrices are column-major to
// match `column_major float4x4` in Slang.
CameraUniforms :: struct {
	view_projection: [16]f32,
	position:        [3]f32,
	right:           [3]f32,
	up:              [3]f32,
	forward:         [3]f32,
}

camera_dot :: proc(a, b: [3]f32) -> f32 {
	return a.x*b.x + a.y*b.y + a.z*b.z
}

camera_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {
		a.y*b.z - a.z*b.y,
		a.z*b.x - a.x*b.z,
		a.x*b.y - a.y*b.x,
	}
}

camera_normalize :: proc(v: [3]f32) -> [3]f32 {
	l := math.sqrt(camera_dot(v, v))
	return v / l
}

// Column-major matrix multiplication: result = a * b.
mat4_mul :: proc(a, b: [16]f32) -> (out: [16]f32) {
	for col in 0 ..< 4 {
		for row in 0 ..< 4 {
			for k in 0 ..< 4 {
				out[col*4 + row] += a[k*4 + row] * b[col*4 + k]
			}
		}
	}
	return
}

// Orbit camera around the origin. View-space z is positive forward; the
// projection maps near..far to Metal/D3D NDC z [0,1].
camera_orbit :: proc(yaw, pitch, aspect: f32) -> CameraUniforms {
	DIST :: 2.6
	FOV_SCALE :: 1.2 // 1 / tan(fov/2)
	NEAR :: 0.5
	FAR :: 5.0

	cy, sy := math.cos(yaw), math.sin(yaw)
	cp, sp := math.cos(pitch), math.sin(pitch)
	position := [3]f32{DIST*cp*sy, DIST*sp, DIST*cp*cy}
	forward := camera_normalize(-position)
	right := camera_normalize(camera_cross(forward, {0, 1, 0}))
	up := camera_cross(right, forward)

	// View rows: right, up, forward, then translation. Stored by columns.
	view := [16]f32 {
		right.x, up.x, forward.x, 0,
		right.y, up.y, forward.y, 0,
		right.z, up.z, forward.z, 0,
		-camera_dot(right, position),
		-camera_dot(up, position),
		-camera_dot(forward, position),
		1,
	}

	a: f32 = FAR / (FAR - NEAR)
	b: f32 = -NEAR * FAR / (FAR - NEAR)
	projection := [16]f32 {
		FOV_SCALE / aspect, 0, 0, 0,
		0, FOV_SCALE, 0, 0,
		0, 0, a, 1,
		0, 0, b, 0,
	}

	return {
		view_projection = mat4_mul(projection, view),
		position = position,
		right = right,
		up = up,
		forward = forward,
	}
}
