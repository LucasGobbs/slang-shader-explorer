// Minimal C wrapper over Nelarius/imnodes for Odin consumption (same pattern
// as ImGuiColorTextEdit's ite). One wrapper instance = one editor context;
// all graph state (nodes, links) lives on the Odin side.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Creates the imnodes context + one editor context. Call after the Dear
// ImGui context exists. The created context is made current and styled dark.
void *ine_create(void);
void ine_destroy(void *ed);

// Frame bracket: renders the grid workspace; nodes/links go in between.
// ine_editor_begin also re-sets the current contexts, so one instance is
// safe alongside other imgui components.
void ine_editor_begin(void *ed);
void ine_editor_end(void *ed);

// Mini-map overlay; location: 0=BottomLeft 1=BottomRight 2=TopLeft 3=TopRight.
void ine_minimap(void *ed, float size_fraction, int location);

// Node body. Title content (e.g. ImGui::Text from the host) goes between the
// title-bar calls, attributes after them.
void ine_begin_node(void *ed, int id);
void ine_end_node(void *ed);
void ine_title_bar_begin(void *ed);
void ine_title_bar_end(void *ed);

// Attributes (pins). shape: 0=Circle 1=CircleFilled 2=Triangle
// 3=TriangleFilled 4=Quad 5=QuadFilled. The host places ImGui widgets
// between begin/end.
void ine_input_attr_begin(void *ed, int id, int shape);
void ine_input_attr_end(void *ed);
void ine_output_attr_begin(void *ed, int id, int shape);
void ine_output_attr_end(void *ed);
void ine_static_attr_begin(void *ed, int id);
void ine_static_attr_end(void *ed);

// Renders a link between two attribute ids (order irrelevant for rendering).
void ine_link(void *ed, int id, int start_attr, int end_attr);

// Initial layout helper: positions the node on the grid (no-op semantics if
// the user already moved it — call once when the node is created).
void ine_set_node_grid_pos(void *ed, int id, float x, float y);

// Trackpad panning: read/adjust the editor panning vector directly (the
// host translates mouse-wheel deltas into pan deltas).
void ine_get_panning(void *ed, float *x, float *y);
void ine_reset_panning(void *ed, float x, float y);

// Current grid-space position of a node (for persisting layouts).
void ine_get_node_grid_pos(void *ed, int id, float *x, float *y);

// Event queries; call after ine_editor_end.
bool ine_is_link_created(void *ed, int *start_attr, int *end_attr);
bool ine_is_link_destroyed(void *ed, int *link_id);
int ine_num_selected_nodes(void *ed);
int ine_num_selected_links(void *ed);
// ids must hold at least the respective Num* count.
void ine_get_selected_nodes(void *ed, int *ids);
void ine_get_selected_links(void *ed, int *ids);
void ine_clear_node_selection(void *ed);
void ine_clear_link_selection(void *ed);
bool ine_is_editor_hovered(void *ed);
bool ine_is_node_hovered(void *ed, int *node_id);
bool ine_is_any_attribute_active(void *ed, int *attr_id);

// Styling. col indexes ImNodesCol_ (NodeBackground=0 .. MiniMapCanvasOutline=28).
void ine_push_color_style(void *ed, int col, uint32_t color);
void ine_pop_color_style(void *ed);

// Attribute flags: 1 = EnableLinkDetachWithDragClick,
// 2 = EnableLinkCreationOnSnap.
void ine_push_attribute_flag(void *ed, int flag);
void ine_pop_attribute_flag(void *ed);

#ifdef __cplusplus
}
#endif
