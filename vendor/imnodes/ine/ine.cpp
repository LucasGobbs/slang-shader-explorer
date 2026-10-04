// Minimal C wrapper over Nelarius/imnodes for Odin consumption.
// imnodes_internal first: it defines IMGUI_DEFINE_MATH_OPERATORS before
// imgui.h (needed by the screen->grid conversion at the bottom).
#include <imnodes_internal.h>
#include "ine.h"

#include <imnodes.h>

struct IneState {
    ImNodesContext *ctx;
    ImNodesEditorContext *editor;
};

static IneState *S(void *ed) { return static_cast<IneState *>(ed); }

void *ine_create(void) {
    IneState *s = new IneState();
    s->ctx = ImNodes::CreateContext();
    ImNodes::SetCurrentContext(s->ctx);
    s->editor = ImNodes::EditorContextCreate();
    ImNodes::EditorContextSet(s->editor);
    ImNodes::StyleColorsDark();
    return s;
}

void ine_destroy(void *ed) {
    if (!ed) return;
    IneState *s = S(ed);
    ImNodes::SetCurrentContext(s->ctx);
    ImNodes::EditorContextFree(s->editor);
    ImNodes::DestroyContext(s->ctx);
    delete s;
}

void ine_editor_begin(void *ed) {
    IneState *s = S(ed);
    ImNodes::SetCurrentContext(s->ctx);
    ImNodes::EditorContextSet(s->editor);
    ImNodes::BeginNodeEditor();
}

void ine_editor_end(void *) { ImNodes::EndNodeEditor(); }

void ine_minimap(void *, float size_fraction, int location) {
    ImNodes::MiniMap(size_fraction, static_cast<ImNodesMiniMapLocation>(location));
}

void ine_begin_node(void *, int id) { ImNodes::BeginNode(id); }
void ine_end_node(void *) { ImNodes::EndNode(); }
void ine_title_bar_begin(void *) { ImNodes::BeginNodeTitleBar(); }
void ine_title_bar_end(void *) { ImNodes::EndNodeTitleBar(); }

void ine_input_attr_begin(void *, int id, int shape) {
    ImNodes::BeginInputAttribute(id, static_cast<ImNodesPinShape>(shape));
}
void ine_input_attr_end(void *) { ImNodes::EndInputAttribute(); }
void ine_output_attr_begin(void *, int id, int shape) {
    ImNodes::BeginOutputAttribute(id, static_cast<ImNodesPinShape>(shape));
}
void ine_output_attr_end(void *) { ImNodes::EndOutputAttribute(); }
void ine_static_attr_begin(void *, int id) { ImNodes::BeginStaticAttribute(id); }
void ine_static_attr_end(void *) { ImNodes::EndStaticAttribute(); }

void ine_link(void *, int id, int start_attr, int end_attr) {
    ImNodes::Link(id, start_attr, end_attr);
}

void ine_set_node_grid_pos(void *, int id, float x, float y) {
    ImNodes::SetNodeGridSpacePos(id, ImVec2(x, y));
}

void ine_get_panning(void *, float *x, float *y) {
    ImVec2 p = ImNodes::EditorContextGetPanning();
    *x = p.x;
    *y = p.y;
}
void ine_reset_panning(void *, float x, float y) {
    ImNodes::EditorContextResetPanning(ImVec2(x, y));
}

void ine_get_node_grid_pos(void *, int id, float *x, float *y) {
    ImVec2 p = ImNodes::GetNodeGridSpacePos(id);
    *x = p.x;
    *y = p.y;
}

bool ine_is_link_created(void *, int *start_attr, int *end_attr) {
    return ImNodes::IsLinkCreated(start_attr, end_attr);
}
bool ine_is_link_destroyed(void *, int *link_id) {
    return ImNodes::IsLinkDestroyed(link_id);
}
int ine_num_selected_nodes(void *) { return ImNodes::NumSelectedNodes(); }
int ine_num_selected_links(void *) { return ImNodes::NumSelectedLinks(); }
void ine_get_selected_nodes(void *, int *ids) { ImNodes::GetSelectedNodes(ids); }
void ine_get_selected_links(void *, int *ids) { ImNodes::GetSelectedLinks(ids); }
void ine_clear_node_selection(void *) { ImNodes::ClearNodeSelection(); }
void ine_clear_link_selection(void *) { ImNodes::ClearLinkSelection(); }
bool ine_is_editor_hovered(void *) { return ImNodes::IsEditorHovered(); }
bool ine_is_node_hovered(void *, int *node_id) { return ImNodes::IsNodeHovered(node_id); }
bool ine_is_any_attribute_active(void *, int *attr_id) {
    return ImNodes::IsAnyAttributeActive(attr_id);
}

void ine_push_color_style(void *, int col, uint32_t color) {
    ImNodes::PushColorStyle(static_cast<ImNodesCol>(col), color);
}
void ine_pop_color_style(void *) { ImNodes::PopColorStyle(); }

void ine_push_attribute_flag(void *, int flag) {
    ImNodes::PushAttributeFlag(static_cast<ImNodesAttributeFlags>(flag));
}
void ine_pop_attribute_flag(void *) { ImNodes::PopAttributeFlag(); }

// Screen -> grid space conversion (for spawning nodes at the mouse).
void ine_screen_to_grid(void *ed, float sx, float sy, float *gx, float *gy) {
    IneState *s = S(ed);
    ImNodes::SetCurrentContext(s->ctx);
    ImNodes::EditorContextSet(s->editor);
    const ImNodesEditorContext &editor = ImNodes::EditorContextGet();
    *gx = sx - GImNodes->CanvasOriginScreenSpace.x - editor.Panning.x;
    *gy = sy - GImNodes->CanvasOriginScreenSpace.y - editor.Panning.y;
}
