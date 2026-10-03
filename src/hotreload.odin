package main

import goose "../../goose/src"

// Runtime-loaded blobs are owned by the caller; baked blobs point into
// static #load data and must never be freed. Scene hot reload lives in
// scene_runtime.odin (scenes are data, not glue); this helper remains
// for the compiled infra shaders (blit, blit3d, ui).
free_blob_if_hot :: proc(glue: goose.GraphicsParameters) {
	when HOT_RELOAD {
		if glue.code.blob.size > 0 {
			delete(glue.code.blob.data[:glue.code.blob.size])
		}
	}
}
