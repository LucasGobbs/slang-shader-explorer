// Minimal LSP client for slangd (--stdio, JSON-RPC with Content-Length
// framing). Synchronous request/response: the editor's autocomplete callback
// runs on the render thread and slangd answers in milliseconds locally, so
// a blocking round trip is acceptable for the workbench (the async path —
// suggestionsPromise — is the follow-up if latency ever shows).
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

Lsp :: struct {
	process:      os.Process,
	stdin:        ^os.File,
	stdout:       ^os.File,
	next_id:      int,
	open_uri:     string, // document currently didOpen-ed
	version:      int,    // didChange version counter
	// Responses routed by lsp_drain (keyed by request id) and live
	// publishDiagnostics per file (keyed by rel path like "scenes/apple").
	pending:      map[int]string,
	diagnostics:  map[string][dynamic]LspDiagnostic,
	diag_version: int,
}

LspDiagnostic :: struct {
	line:      int, // 0-based
	col_start: int,
	end_line:  int,
	col_end:   int,
	severity:  int, // 1 error, 2 warning
	msg:       string,
}

LspCompletion :: struct {
	label:  string,
	detail: string,
}

lsp_write_msg :: proc(lsp: ^Lsp, body: string) -> bool {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	if _, err := os.write(lsp.stdin, transmute([]u8)header); err != nil {
		return false
	}
	_, err := os.write(lsp.stdin, transmute([]u8)body)
	return err == nil
}

// Reads one framed message. Blocks on the pipe; the caller bounds the wait
// by only calling this when a response is due.
lsp_read_msg :: proc(lsp: ^Lsp, buf: []u8) -> (n: int, ok: bool) {
	// Header: "Content-Length: N\r\n\r\n".
	header: [128]u8
	hn := 0
	for hn < len(header) - 1 {
		b: [1]u8
		rn, err := os.read(lsp.stdout, b[:])
		if err != nil || rn != 1 do return 0, false
		header[hn] = b[0]
		hn += 1
		if hn >= 4 && string(header[hn - 4:hn]) == "\r\n\r\n" do break
	}
	length := -1
	line := string(header[:hn])
	if strings.has_prefix(line, "Content-Length:") {
		num := strings.trim_space(line[len("Content-Length:"):])
		num = strings.trim_suffix(num, "\r\n\r\n")
		length, _ = strconv_parse_int(num)
	}
	if length <= 0 || length > len(buf) do return 0, false
	total := 0
	for total < length {
		rn, err := os.read(lsp.stdout, buf[total:length])
		if err != nil || rn <= 0 do return 0, false
		total += rn
	}
	return total, true
}

strconv_parse_int :: proc(s: string) -> (int, bool) {
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' do return 0, false
		n = n * 10 + int(ch - '0')
	}
	return n, true
}

lsp_request :: proc(lsp: ^Lsp, method: string, params: string) -> (id: int, ok: bool) {
	lsp.next_id += 1
	id = lsp.next_id
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}}`,
		id,
		method,
		params,
	)
	return id, lsp_write_msg(lsp, body)
}

lsp_notify :: proc(lsp: ^Lsp, method: string, params: string) -> bool {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","method":"%s","params":%s}}`, method, params)
	return lsp_write_msg(lsp, body)
}

// Non-blocking: routes every queued message — responses land in `pending`
// by id, publishDiagnostics land in `diagnostics` by file.
lsp_drain :: proc(lsp: ^Lsp) {
	for {
		has, err := os.pipe_has_data(lsp.stdout)
		if err != nil || !has do break
		buf := make([]u8, 256 * 1024, context.temp_allocator)
		n, ok := lsp_read_msg(lsp, buf)
		if !ok do break
		lsp_route_message(lsp, string(buf[:n]))
	}
}

lsp_route_message :: proc(lsp: ^Lsp, msg: string) {
	Env :: struct {
		id:     json.Value `json:"id"`,
		method: string `json:"method"`,
		params: json.Value `json:"params"`,
	}
	e: Env
	if json.unmarshal_string(msg, &e) != nil do return
	if id, is_int := e.id.(json.Integer); is_int {
		lsp.pending[int(id)] = strings.clone(msg)
		return
	}
	log.debugf("[lsp] notification: %s (%d bytes)", e.method, len(msg))
	if e.method == "textDocument/publishDiagnostics" {
		lsp_handle_diagnostics(lsp, e.params)
	}
}

lsp_handle_diagnostics :: proc(lsp: ^Lsp, params: json.Value) {
	obj, is_obj := params.(json.Object)
	if !is_obj do return
	uri_val, has_uri := obj["uri"]
	uri, is_str := uri_val.(string)
	if !has_uri || !is_str do return
	// Map the uri back to our rel path (".../src/shaders/scenes/apple.slang").
	rel := uri
	if idx := strings.index(rel, "src/shaders/"); idx >= 0 {
		rel = rel[idx + len("src/shaders/"):]
	}
	rel = strings.trim_suffix(rel, ".slang")
	for {
		dd := strings.index(rel, "/../")
		if dd < 0 do break
		prev := strings.last_index(rel[:dd], "/")
		if prev < 0 {
			rel = rel[dd + 4:]
			break
		}
		rel = strings.concatenate({rel[:prev], rel[dd + 3:]}, context.temp_allocator)
	}

	diags := make([dynamic]LspDiagnostic, context.temp_allocator)
	arr_val, has_arr := obj["diagnostics"]
	arr, is_arr := arr_val.(json.Array)
	if has_arr && is_arr {
		for dval in arr {
			dobj, is_dobj := dval.(json.Object)
			if !is_dobj do continue
			d := LspDiagnostic{severity = 1}
			if rng_val, has := dobj["range"]; has {
				if rng, is_rng := rng_val.(json.Object); is_rng {
					if st, ok2 := rng["start"].(json.Object); ok2 {
						d.line = lsp_json_int(st["line"])
						d.col_start = lsp_json_int(st["character"])
					}
					if en, ok3 := rng["end"].(json.Object); ok3 {
						d.end_line = lsp_json_int(en["line"])
						d.col_end = lsp_json_int(en["character"])
					}
				}
			}
			if sv, has := dobj["severity"]; has {
				d.severity = lsp_json_int(sv)
			}
			if ms, has := dobj["message"]; has {
				if s, is_s := ms.(string); is_s {
					d.msg = strings.clone(s)
				}
			}
			append(&diags, d)
		}
	}
	// Replace the file's set (an empty publish clears stale squiggles).
	if rel in lsp.diagnostics {
		delete(lsp.diagnostics[rel])
	}
	lsp.diagnostics[strings.clone(rel)] = diags
	lsp.diag_version += 1
}

lsp_json_int :: proc(v: json.Value) -> int {
	if iv, is_int := v.(json.Integer); is_int do return int(iv)
	return 0
}

// Reads messages until the response for `want_id` arrives; notifications
// (no id) are skipped. Returns the raw JSON of the response. slangd pretty-
// prints its JSON ("id" : 1, with spaces), so the id is parsed, not matched
// as text.
lsp_await_response :: proc(lsp: ^Lsp, want_id: int) -> (string, bool) {
	for i in 0 ..< 1000 {
		if msg, has := lsp.pending[want_id]; has {
			delete_key(&lsp.pending, want_id)
			return msg, true
		}
		lsp_drain(lsp)
		time.sleep(2 * time.Millisecond)
	}
	return "", false
}

lsp_start :: proc() -> ^Lsp {
	lsp := new(Lsp)
	in_r, in_w, in_err := os.pipe()
	out_r, out_w, out_err := os.pipe()
	if in_err != nil || out_err != nil {
		log.errorf("lsp: pipe failed: %v %v", in_err, out_err)
		return nil
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	handle, start_err := os.process_start(
		{
			working_dir = cwd,
			command = []string{"vendor/slang/bin/slangd", "--stdio"},
			stdin = in_r,
			stdout = out_w,
		},
	)
	if start_err != nil {
		log.errorf("lsp: failed to start slangd: %v", start_err)
		return nil
	}
	lsp.process = handle
	lsp.stdin = in_w
	lsp.stdout = out_r

	root := fmt.tprintf("file://%s", cwd)
	root_json, _ := json.marshal(root, allocator = context.temp_allocator)
	init_params := fmt.tprintf(
		`{{"processId":null,"rootUri":%s,"capabilities":{{"textDocument":{{"completion":{{"completionItem":{{"snippetSupport":false}}}},"publishDiagnostics":{{"relatedInformation":true,"versionSupport":true}}}}}}}}`,
		root_json,
	)
	id, ok := lsp_request(lsp, "initialize", init_params)
	if !ok {
		log.error("lsp: initialize write failed")
		return nil
	}
	init_resp, got := lsp_await_response(lsp, id)
	if !got {
		log.error("lsp: initialize response timeout")
		return nil
	}
	log.infof("[lsp] server capabilities: %s", init_resp[:min(400, len(init_resp))])
	lsp_notify(lsp, "initialized", `{}`)
	log.info("[lsp] slangd initialized")
	return lsp
}

lsp_escape_json :: proc(s: string) -> string {
	out, _ := json.marshal(s, allocator = context.temp_allocator)
	return string(out)
}

// Full-sync the document. slangd (2026.18.2) accumulates one compilation
// per didChange instead of replacing the document: every sync merges
// another copy of the file's declarations into the scope, producing
// phantom "conflicts with existing declaration" / "ambiguous reference"
// diagnostics on every top-level symbol (verified: 1 change = 2 copies,
// 2 changes = 3). The workaround is a reset cycle per sync: didClose,
// didOpen with an empty buffer, then one full-text didChange, which
// leaves exactly one compilation of the document on the server.
lsp_sync :: proc(lsp: ^Lsp, uri: string, text: string) {
	text_json := lsp_escape_json(text)
	uri_json := lsp_escape_json(uri)
	if lsp.open_uri == uri {
		params := fmt.tprintf(`{{"textDocument":{{"uri":%s}}}}`, uri_json)
		lsp_notify(lsp, "textDocument/didClose", params)
		delete(lsp.open_uri)
		lsp.open_uri = ""
	}
	if lsp.open_uri != uri {
		params := fmt.tprintf(
			`{{"textDocument":{{"uri":%s,"languageId":"slang","version":1,"text":""}}}}`,
			uri_json,
		)
		lsp_notify(lsp, "textDocument/didOpen", params)
		delete(lsp.open_uri)
		lsp.open_uri = strings.clone(uri)
		lsp.version = 1
	}
	lsp.version += 1
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":[{{"text":%s}}]}}`,
		uri_json,
		lsp.version,
		text_json,
	)
	lsp_notify(lsp, "textDocument/didChange", params)
}

// Completion at (line, col), 0-based. Returns labels (caller frees the slice's
// backing array with temp allocator).
lsp_complete :: proc(lsp: ^Lsp, uri: string, text: string, line, col: int) -> []LspCompletion {
	lsp_sync(lsp, uri, text)
	uri_json := lsp_escape_json(uri)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}}}`,
		uri_json,
		line,
		col,
	)
	id, ok := lsp_request(lsp, "textDocument/completion", params)
	if !ok do return nil
	resp, got := lsp_await_response(lsp, id)
	if !got do return nil

	// result may be CompletionItem[] or CompletionList { items: [] }.
	Resp :: struct {
		result: json.Value `json:"result"`,
	}
	r: Resp
	if json.unmarshal_string(resp, &r) != nil do return nil
	items_val: json.Value
	#partial switch v in r.result {
	case json.Array:
		items_val = r.result
	case json.Object:
		items_val = v["items"]
	}
	arr, is_arr := items_val.(json.Array)
	if !is_arr do return nil
	out := make([dynamic]LspCompletion, 0, len(arr), context.temp_allocator)
	for item_val in arr {
		obj, is_obj := item_val.(json.Object)
		if !is_obj do continue
		label: string
		if lv, has := obj["label"]; has {
			if s, is_str := lv.(string); is_str do label = s
		}
		if label == "" do continue
		detail: string
		if dv, has := obj["detail"]; has {
			if s, is_str := dv.(string); is_str do detail = s
		}
		append(&out, LspCompletion{label = strings.clone(label, context.temp_allocator), detail = strings.clone(detail, context.temp_allocator)})
	}
	return out[:]
}
