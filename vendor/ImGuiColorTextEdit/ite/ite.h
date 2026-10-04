// Minimal C wrapper over goossens/ImGuiColorTextEdit for Odin consumption.
// The editor is C++; this exposes only what the shader editor needs.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void *ite_create(void);
void ite_destroy(void *ed);

// utf8 must be NUL-terminated.
void ite_set_text(void *ed, const char *utf8);
// Returned pointer is owned by the wrapper and stays valid until the next
// ite_get_text call on the same editor.
const char *ite_get_text(void *ed);

// Renders the editor; call every frame inside an ImGui window context.
// Returns true while the editor has focus.
bool ite_render(void *ed, const char *title, float width, float height);

void ite_set_language_hlsl(void *ed);
void ite_set_tab_size(void *ed, size_t size);
void ite_set_readonly(void *ed, bool readonly);
// When on, space/tab markers render only in the line's leading whitespace
// (indentation), not between tokens.
void ite_set_leading_whitespace_only(void *ed, bool on);
// Monotonic undo counter: changes when the document changes.
size_t ite_get_undo_index(void *ed);

// Debug: returns ImGui::GetCurrentContext() as seen by the wrapper TU.
void *ite_current_context(void);

// Mouse-position queries (ImGui coordinates, i.e. ImGui::GetMousePos()).
bool ite_is_mouse_over_text(void *ed, float x, float y);
// Writes the word under (x, y) into buf (NUL-terminated, truncated to cap-1).
// Returns the word length (0 if none).
size_t ite_get_word_at_mouse(void *ed, float x, float y, char *buf, size_t cap);
// Moves the cursor to the start of `line` (0-based) and scrolls it into view.
void ite_goto_line(void *ed, size_t line);

// Current cursor line of the first cursor (0-based); for tests.
size_t ite_get_cursor_line(void *ed);
// Current cursor glyph index (0-based) of the first cursor.
size_t ite_get_cursor_col(void *ed);
// Moves the cursor to (line, col) and scrolls it into view.
void ite_set_cursor_pos(void *ed, size_t line, size_t col);

// Duplicates the current line below itself (undo-preserving).
void ite_duplicate_line(void *ed);

// Glass mode: makes the editor's background palette entries (background,
// current-line highlight/border) translucent at `alpha` (0..1) while keeping
// text/keywords fully opaque. off restores the saved palette exactly.
void ite_set_glass(void *ed, bool on, float alpha);

// Content fade for the open/close animation: scales the alpha of every
// palette entry (0..1; >= 0.999 restores the pre-fade palette exactly).
// ImGui's style alpha doesn't reach the component's raw draw-list colors,
// so the fade must scale the palette itself.
void ite_set_fade(void *ed, float alpha);

// Themes: replace the whole palette. colors maps to the component's Color
// enum (text, keyword, declaration, number, string, punctuation,
// preprocessor, identifier, knownIdentifier, comment, background, cursor,
// selection, whitespace, matchingBracket*, lineNumber, currentLineNumber,
// currentLineHighlight, currentLineHighlightBorder — 24 entries, ABGR).
void ite_set_palette_u32(void *ed, const uint32_t *colors, size_t count);
void ite_use_dark_palette(void *ed);
void ite_use_light_palette(void *ed);

// Completion provider (LSP): the editor calls fn on the render thread when
// the autocomplete popup needs items. fn gets the word being typed plus the
// 0-based cursor line/col and fills buf with newline-separated suggestions,
// returning the item count. Runs synchronously; keep it fast.
typedef int (*IteCompletionFn)(const char *search_term, size_t line, size_t col, void *user, char *buf, size_t cap);
void ite_enable_completion(void *ed, IteCompletionFn fn, void *user);

// Fires on every document change (typing AND programmatic SetText); used to
// debounce LSP didChange syncs.
typedef void (*IteChangeFn)(void *user);
void ite_set_change_callback(void *ed, IteChangeFn fn, void *user);

// Error display: red squiggles under the offending range and red line-number
// markers; tooltips carry the compiler message. Lines/cols are 0-based.
void ite_clear_diagnostics(void *ed);
void ite_add_squiggle(void *ed, size_t line, size_t col, const char *msg);
// Exact range variant (LSP diagnostics carry start/end character).
void ite_add_squiggle_range(void *ed, size_t sl, size_t sc, size_t el, size_t ec, const char *msg);
void ite_add_error_marker(void *ed, size_t line, const char *msg);

// Installs the right-click context menu (Copy/Paste/Duplicate line/Go to
// definition/Rename symbol). "Go to definition" and "Rename symbol" are
// deferred to the host: each sets a pending flag + word, polled via the
// ite_take_* functions.
void ite_install_context_menu(void *ed);
// If the menu asked for a goto-definition, copies the word into buf and
// returns true (consuming the request).
bool ite_take_goto_word(void *ed, char *buf, size_t cap);
// Same for "Rename symbol".
bool ite_take_rename_word(void *ed, char *buf, size_t cap);

#ifdef __cplusplus
}
#endif
