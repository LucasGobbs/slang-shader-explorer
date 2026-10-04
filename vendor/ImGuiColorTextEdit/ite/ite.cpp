#include "ite.h"

// The component's clipboard ops (copy/paste) are private and the public API
// has no text insertion path, so the context menu and duplicate-line need
// this scoped hack. Access specifiers are compile-time only — class layout
// and mangled names are unchanged, so linking against the normally-compiled
// TextEditor.o is safe.
#define private public
#define protected public
#include "../TextEditor.h"
#undef protected
#undef private

#include <cstring>
#include <string>

struct IteState {
	TextEditor editor;
	std::string buffer; // owned copy backing ite_get_text's return
	bool goto_pending = false;
	std::string goto_word;
	bool rename_pending = false;
	std::string rename_word;
	TextEditor::Palette saved_palette;
	bool palette_saved = false;
	bool glass = false;
	TextEditor::Palette fade_saved_palette;
	bool fade_active = false;
	// Completion provider (LSP bridge).
	IteCompletionFn completion_fn = nullptr;
	void *completion_user = nullptr;
	TextEditor::AutoCompleteConfig completion_cfg;
	// Change notification (LSP live sync).
	IteChangeFn change_fn = nullptr;
	void *change_user = nullptr;
};

static IteState *S(void *ed) { return static_cast<IteState *>(ed); }

void *ite_create(void) {
	IteState *s = new IteState();
	s->editor.SetLanguage(TextEditor::Language::Hlsl());
	return s;
}

void ite_destroy(void *ed) { delete S(ed); }

void ite_set_text(void *ed, const char *utf8) {
	S(ed)->editor.SetText(std::string_view(utf8 ? utf8 : ""));
}

const char *ite_get_text(void *ed) {
	IteState *s = S(ed);
	s->buffer = s->editor.GetText();
	return s->buffer.c_str();
}

bool ite_render(void *ed, const char *title, float width, float height) {
	return S(ed)->editor.Render(title, ImVec2(width, height));
}

void ite_set_language_hlsl(void *ed) { S(ed)->editor.SetLanguage(TextEditor::Language::Hlsl()); }

void ite_set_tab_size(void *ed, size_t size) { S(ed)->editor.SetTabSize(size); }

void ite_set_readonly(void *ed, bool readonly) { S(ed)->editor.SetReadOnlyEnabled(readonly); }

size_t ite_get_undo_index(void *ed) { return S(ed)->editor.GetUndoIndex(); }

// Debug: what context does this translation unit see?
void *ite_current_context(void) { return (void *)ImGui::GetCurrentContext(); }

bool ite_is_mouse_over_text(void *ed, float x, float y) {
	return S(ed)->editor.IsMousePosOverTextArea(ImVec2(x, y));
}

size_t ite_get_word_at_mouse(void *ed, float x, float y, char *buf, size_t cap) {
	if (cap == 0) return 0;
	std::string w = S(ed)->editor.GetWordAtMousePos(ImVec2(x, y));
	size_t n = w.size() < cap - 1 ? w.size() : cap - 1;
	memcpy(buf, w.data(), n);
	buf[n] = '\0';
	return w.size();
}

void ite_goto_line(void *ed, size_t line) {
	TextEditor &e = S(ed)->editor;
	e.SetCursor(TextEditor::DocPos(line, 0));
	e.ScrollToLine(line);
}

size_t ite_get_cursor_line(void *ed) {
	return S(ed)->editor.GetCursorPosition(0).line;
}

size_t ite_get_cursor_col(void *ed) {
	return S(ed)->editor.GetCursorPosition(0).index;
}

void ite_set_cursor_pos(void *ed, size_t line, size_t col) {
	TextEditor &e = S(ed)->editor;
	e.SetCursor(TextEditor::DocPos(line, col));
	e.ScrollToLine(line);
}

void ite_duplicate_line(void *ed) {
	TextEditor &e = S(ed)->editor;
	TextEditor::DocPos cur = e.GetCursorPosition(0);
	std::string lt = e.GetLineText(cur.line);
	// Route through paste() so the duplication is a real (undoable)
	// transaction; swap the clipboard around it.
	const char *old_clip = ImGui::GetClipboardText();
	std::string saved = old_clip ? old_clip : "";
	std::string payload = lt + "\n";
	ImGui::SetClipboardText(payload.c_str());
	e.SetCursor(TextEditor::DocPos(cur.line + 1, 0));
	e.paste();
	ImGui::SetClipboardText(saved.c_str());
}

void ite_set_palette_u32(void *ed, const uint32_t *colors, size_t count) {
	IteState *s = S(ed);
	TextEditor::Palette p = s->editor.GetPalette();
	size_t n = count < p.size() ? count : p.size();
	for (size_t i = 0; i < n; i++) p[i] = colors[i];
	s->editor.SetPalette(p);
	// A theme change invalidates the glass-mode restore point.
	s->palette_saved = false;
	s->glass = false;
}

void ite_use_dark_palette(void *ed) {
	S(ed)->editor.SetPalette(TextEditor::GetDarkPalette());
	S(ed)->palette_saved = false;
	S(ed)->glass = false;
}

void ite_use_light_palette(void *ed) {
	S(ed)->editor.SetPalette(TextEditor::GetLightPalette());
	S(ed)->palette_saved = false;
	S(ed)->glass = false;
}

void ite_set_glass(void *ed, bool on, float alpha) {
	IteState *s = S(ed);
	if (on == s->glass && s->palette_saved) return;
	// Re-save on every transition into glass so theme changes are preserved.
	if (on && !s->glass) {
		s->saved_palette = s->editor.GetPalette();
		s->palette_saved = true;
	}
	if (on) {
		TextEditor::Palette p = s->saved_palette;
		const ImU32 a = (ImU32)(alpha * 255.0f) << 24;
		auto dim = [&](TextEditor::Color c) {
			size_t i = static_cast<size_t>(c);
			p[i] = (p[i] & 0x00FFFFFFu) | a;
		};
		dim(TextEditor::Color::background);
		dim(TextEditor::Color::currentLineHighlight);
		dim(TextEditor::Color::currentLineHighlightBorder);
		s->editor.SetPalette(p);
	} else {
		s->editor.SetPalette(s->saved_palette);
	}
	s->glass = on;
}

void ite_set_leading_whitespace_only(void *ed, bool on) {
	S(ed)->editor.SetShowLeadingWhitespacesOnly(on);
}

void ite_set_fade(void *ed, float alpha) {
	IteState *s = S(ed);
	if (alpha >= 0.999f) {
		if (s->fade_active) {
			s->editor.SetPalette(s->fade_saved_palette);
			s->fade_active = false;
		}
		return;
	}
	if (!s->fade_active) {
		s->fade_saved_palette = s->editor.GetPalette();
		s->fade_active = true;
	}
	TextEditor::Palette p = s->fade_saved_palette;
	const ImU32 fade = (ImU32)(alpha * 255.0f);
	for (size_t i = 0; i < p.size(); i++) {
		const ImU32 a = (((p[i] >> 24) & 0xFF) * fade) / 255;
		p[i] = (p[i] & 0x00FFFFFFu) | (a << 24);
	}
	s->editor.SetPalette(p);
}

static const ImU32 ITE_ERROR_RED = IM_COL32(230, 60, 60, 255);
// Line-body highlight for errors: a translucent tint of the same red, so the
// code on the offending line stays readable (the line-number cell and the
// squiggle carry the strong color).
static const ImU32 ITE_ERROR_LINE_TINT = IM_COL32(230, 60, 60, 38);

void ite_clear_diagnostics(void *ed) {
	S(ed)->editor.ClearSquiggles();
	S(ed)->editor.ClearMarkers();
}

void ite_add_squiggle(void *ed, size_t line, size_t col, const char *msg) {
	TextEditor::DocPos start(line, col);
	// SIZE_MAX index: AddSquiggle normalizes/clamps to the end of the line.
	TextEditor::DocPos end(line, (size_t)-1);
	S(ed)->editor.AddSquiggle(start, end, 0, ITE_ERROR_RED, msg ? msg : "");
}

void ite_add_squiggle_range(void *ed, size_t sl, size_t sc, size_t el, size_t ec, const char *msg) {
	S(ed)->editor.AddSquiggle(
		TextEditor::DocPos(sl, sc),
		TextEditor::DocPos(el, ec),
		0,
		ITE_ERROR_RED,
		msg ? msg : ""
	);
}

void ite_add_error_marker(void *ed, size_t line, const char *msg) {
	S(ed)->editor.AddMarker(line, ITE_ERROR_RED, ITE_ERROR_LINE_TINT, "compile error", msg ? msg : "");
}

void ite_install_context_menu(void *ed) {
	IteState *s = S(ed);
	s->editor.SetTextContextMenuCallback([s](TextEditor::PopupData &data) {
		TextEditor &e = s->editor;
		if (ImGui::MenuItem("Copy", "Cmd+C")) e.copy();
		if (ImGui::MenuItem("Paste", "Cmd+V")) e.paste();
		if (ImGui::MenuItem("Duplicate line", "Cmd+Shift+D")) ite_duplicate_line(s);
		ImGui::Separator();
		if (ImGui::MenuItem("Go to definition", "Cmd+Click")) {
			std::string w = e.GetWordAtMousePos(ImGui::GetMousePos());
			if (!w.empty()) {
				s->goto_pending = true;
				s->goto_word = w;
			}
		}
		if (ImGui::MenuItem("Rename symbol", "")) {
			std::string w = e.GetWordAtMousePos(ImGui::GetMousePos());
			if (!w.empty()) {
				s->rename_pending = true;
				s->rename_word = w;
			}
		}
	});
}

bool ite_take_goto_word(void *ed, char *buf, size_t cap) {
	IteState *s = S(ed);
	if (!s->goto_pending || cap == 0) return false;
	s->goto_pending = false;
	size_t n = s->goto_word.size() < cap - 1 ? s->goto_word.size() : cap - 1;
	memcpy(buf, s->goto_word.data(), n);
	buf[n] = '\0';
	return true;
}

bool ite_take_rename_word(void *ed, char *buf, size_t cap) {
	IteState *s = S(ed);
	if (!s->rename_pending || cap == 0) return false;
	s->rename_pending = false;
	size_t n = s->rename_word.size() < cap - 1 ? s->rename_word.size() : cap - 1;
	memcpy(buf, s->rename_word.data(), n);
	buf[n] = '\0';
	return true;
}

void ite_set_change_callback(void *ed, IteChangeFn fn, void *user) {
	IteState *s = S(ed);
	s->change_fn = fn;
	s->change_user = user;
	if (fn == nullptr) {
		s->editor.ClearChangeCallback();
		return;
	}
	s->editor.SetChangeCallback([s]() { s->change_fn(s->change_user); });
}

void ite_enable_completion(void *ed, IteCompletionFn fn, void *user) {
	IteState *s = S(ed);
	s->completion_fn = fn;
	s->completion_user = user;
	if (fn == nullptr) {
		s->editor.SetAutoCompleteConfig(nullptr);
		return;
	}
	s->completion_cfg = TextEditor::AutoCompleteConfig();
	s->completion_cfg.userData = s;
	s->completion_cfg.callback = [s](TextEditor::AutoCompleteState &state) {
		// The editor does NOT clear the suggestion list between callbacks;
		// stale items from previous triggers must go (a "d"-era dryBrush
		// must not survive into a "ler" popup).
		state.suggestions.clear();
		if (s->completion_fn == nullptr) return;
		char buf[64 * 1024];
		int count = s->completion_fn(
			state.searchTerm.c_str(),
			state.searchTermStart.line,
			state.searchTermStart.index,
			s->completion_user,
			buf,
			sizeof(buf)
		);
		if (count <= 0) return;
		// Split the newline-separated buffer into the suggestions vector.
		const char *p = buf;
		for (int i = 0; i < count && *p; i++) {
			const char *nl = strchr(p, '\n');
			if (nl) {
				state.suggestions.emplace_back(p, nl - p);
				p = nl + 1;
			} else {
				state.suggestions.emplace_back(p);
				break;
			}
		}
	};
	s->editor.SetAutoCompleteConfig(&s->completion_cfg);
}
