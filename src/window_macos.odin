// Native macOS window tweaks. SDL has no API for window corner radius, so
// we reach through to the NSWindow (exposed as a window property) and round
// its content layer: the clip covers the GPU swapchain and the ImGui
// overlay, including the title bar's top corners.
package main

import NS "core:sys/darwin/Foundation"
import "base:intrinsics"
import sdl "vendor:sdl3"

msgSend :: intrinsics.objc_send

// Close to AppKit's standard window corner radius.
WINDOW_CORNER_RADIUS :: 12.0

window_round_corners :: proc(window: ^sdl.Window) {
	nw := (^NS.Window)(
		sdl.GetPointerProperty(
			sdl.GetWindowProperties(window),
			sdl.PROP_WINDOW_COCOA_WINDOW_POINTER,
			nil,
		),
	)
	if nw == nil do return
	view := NS.Window_contentView(nw)
	if view == nil do return
	NS.View_setWantsLayer(view, true)
	layer := msgSend(^NS.Object, view, "layer")
	if layer == nil do return
	msgSend(nil, layer, "setCornerRadius:", f64(WINDOW_CORNER_RADIUS))
	msgSend(nil, layer, "setMasksToBounds:", NS.BOOL(true))
}
