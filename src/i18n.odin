package main

// UI internationalization via core:text/i18n. English is the source
// language: UI code passes English keys to tr(), and with no catalog
// active (EN) the key is returned unchanged. ES and PT catalogs are
// built in code below (no .mo/.ts toolchain); missing keys fall back
// to English. Only FIXED UI vocabulary is translated: anything coming
// from user shaders (scene names, param names, pin names) stays as-is.
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:text/i18n"

tr :: i18n.get
trn :: i18n.get_n

// Translated key as a null-terminated cstring for ImGui calls (temp
// allocator, per-frame).
trc :: proc(key: string) -> cstring {
	return fmt.ctprintf("%s", tr(key))
}

Language :: enum {
	EN,
	ES,
	PT,
}

app_language: Language

LANGUAGE_TAGS := [Language]string{.EN = "EN", .ES = "ES", .PT = "PT"}

// key = English source string; single = translation; plural optional
// (used with trn for countable strings).
I18nEntry :: struct {
	key:    string,
	single: string,
	plural: string,
}

i18n_build :: proc(entries: []I18nEntry) -> ^i18n.Translation {
	cat := new(i18n.Translation)
	cat.k_v = make(map[string]i18n.Section)
	section := make(i18n.Section)
	for e in entries {
		forms := make([]string, 2 if e.plural != "" else 1)
		forms[0] = strings.clone(e.single)
		if e.plural != "" do forms[1] = strings.clone(e.plural)
		section[strings.clone(e.key)] = forms
	}
	cat.k_v[strings.clone("")] = section
	// ES and PT share the English rule: singular for 1, plural otherwise.
	cat.pluralize = proc(n: int) -> int { return 0 if n == 1 else 1 }
	return cat
}

I18N_LANG_FILE :: "assets/i18n.lang"

i18n_set_language :: proc(lang: Language) {
	app_language = lang
	i18n.destroy()
	i18n.ACTIVE = nil
	switch lang {
	case .EN:
	case .ES:
		i18n.ACTIVE = i18n_build(ES_STRINGS)
	case .PT:
		i18n.ACTIVE = i18n_build(PT_STRINGS)
	}
	buf := [1]u8{u8(lang) + '0'}
	if err := os.write_entire_file(I18N_LANG_FILE, buf[:]); err != nil {
		log.errorf("i18n: could not write %s", I18N_LANG_FILE)
	}
}

i18n_init :: proc() {
	lang := Language.EN
	if data, err := os.read_entire_file(I18N_LANG_FILE, context.temp_allocator); err == nil && len(data) >= 1 {
		if data[0] >= '0' && data[0] <= '2' do lang = Language(data[0] - '0')
	}
	i18n_set_language(lang)
}

// ---------------------------------------------------------------------
// Catalogs. Keys are the exact English strings passed to tr()/trn() in
// the UI code. Keep sorted by key.

ES_STRINGS := []I18nEntry{
	{"%d frames @ %d fps", "%d cuadros @ %d fps", ""},
	{"%s params", "parámetros de %s", ""},
	{"%s: definition in %s.slang:%d", "%s: definición en %s.slang:%d", ""},
	{"%s: no definition found", "%s: definición no encontrada", ""},
	{"+ new", "+ nuevo", ""},
	{"3D view", "vista 3D", ""},
	{"3d object", "objeto 3d", ""},
	{"Rename", "Renombrar", ""},
	{"Rename symbol", "Renombrar símbolo", ""},
	{"Shader editor", "Editor de shaders", ""},
	{"Uniforms", "Uniforms", ""},
	{"autorotate", "rotación automática", ""},
	{"back to %s:%d:%d", "volver a %s:%d:%d", ""},
	{"build failed", "compilación fallida", ""},
	{"burst", "explosión", ""},
	{"choose image", "elegir imagen", ""},
	{"choose model", "elegir modelo", ""},
	{"click the scene to sample", "clic en la escena para muestrear", ""},
	{"color", "color", ""},
	{"compute", "compute", ""},
	{"compute pass", "pass compute", ""},
	{"controls", "controles", ""},
	{"could not read %s", "no se pudo leer %s", ""},
	{"create pass", "crear pass", ""},
	{"create resource", "crear recurso", ""},
	{"debug", "depuración", ""},
	{"delete node", "eliminar nodo", ""},
	{"develop", "revelar", ""},
	{"develop style", "estilo de revelado", ""},
	{"develop transition", "transición de revelado", ""},
	{"dissolve", "disolver", ""},
	{"editor font", "fuente del editor", ""},
	{"effects", "efectos", ""},
	{"end (s)", "fin (s)", ""},
	{"ERROR writing %s", "ERROR escribiendo %s", ""},
	{"export", "exportar", ""},
	{"export gif", "exportar gif", ""},
	{"export png", "exportar png", ""},
	{"frame at t = %.2f s", "cuadro en t = %.2f s", ""},
	{"full", "completo", ""},
	{"gen %.2f ms", "gen %.2f ms", ""},
	{"glass", "vidrio", ""},
	{"graph pan friction", "fricción del paneo del grafo", ""},
	{"graph pan max speed", "velocidad máx. del paneo del grafo", ""},
	{"graphics", "graphics", ""},
	{"graphics 2d", "graphics 2d", ""},
	{"graphics 3d", "graphics 3d", ""},
	{"graphics pass", "pass graphics", ""},
	{"grid", "cuadrícula", ""},
	{"image", "imagen", ""},
	{"ink particles", "partículas de tinta", ""},
	{"interaction", "interacción", ""},
	{"iris", "iris", ""},
	{"language", "idioma", ""},
	{"learn", "aprender", ""},
	{"← all trails", "← todas las guías", ""},
	{"mesh", "malla", ""},
	{"mouse rotation", "rotación con ratón", ""},
	{"no previous position", "sin posición anterior", ""},
	{"nothing to save", "nada que guardar", ""},
	{"off (static)", "apagado (estático)", ""},
	{"output", "salida", ""},
	{"paper grain", "grano de papel", ""},
	{"params", "params", ""},
	{"pixel inspector", "inspector de píxeles", ""},
	{"preview", "vista previa", ""},
	{"previews", "vistas previas", ""},
	{"random", "aleatorio", ""},
	{"rename '%s' to:", "renombrar '%s' a:", ""},
	{"renamed %s → %s: %d occurrence(s) in %d file(s)", "renombrado %s → %s: %d ocurrencia(s) en %d archivo(s)", ""},
	{"restore last compiled", "restaurar última compilación", ""},
	{"restored last compiled version of %s", "restaurada la última versión compilada de %s", ""},
	{"return debug_* from the shader", "devuelve debug_* desde el shader", ""},
	{"refusing to rename keyword %s", "no se renombra la palabra clave %s", ""},
	{"saved %d file(s) at %02d:%02d:%02d", "%d archivo(s) guardado(s) a las %02d:%02d:%02d", ""},
	{"scene '%s' failed to load", "la escena '%s' no pudo cargarse", ""},
	{"shared", "compartidos", ""},
	{"show 2d", "show 2d", ""},
	{"sound", "sonido", ""},
	{"springs", "resortes", ""},
	{"start (s)", "inicio (s)", ""},
	{"subtle", "sutil", ""},
	{"texture", "textura", ""},
	{"theme", "tema", ""},
	{"time (s)", "tiempo (s)", ""},
	{"transparency", "transparencia", ""},
	{"ui font", "fuente de la UI", ""},
	{"waiting for GPU...", "esperando la GPU...", ""},
	{"apply", "aplicar", ""},
	{"cancel", "cancelar", ""},
	{"invalid changes keep the last valid pipeline", "los cambios inválidos conservan el último pipeline válido", ""},
	{"last valid pipeline remains active", "el último pipeline válido sigue activo", ""},
	{"pixel provenance", "procedencia del píxel", ""},
	{"reading pass outputs...", "leyendo salidas de los passes...", ""},
}

PT_STRINGS := []I18nEntry{
	{"%d frames @ %d fps", "%d quadros @ %d fps", ""},
	{"%s params", "parâmetros de %s", ""},
	{"%s: definition in %s.slang:%d", "%s: definição em %s.slang:%d", ""},
	{"%s: no definition found", "%s: definição não encontrada", ""},
	{"+ new", "+ novo", ""},
	{"3D view", "visão 3D", ""},
	{"3d object", "objeto 3d", ""},
	{"Rename", "Renomear", ""},
	{"Rename symbol", "Renomear símbolo", ""},
	{"Shader editor", "Editor de shaders", ""},
	{"Uniforms", "Uniforms", ""},
	{"autorotate", "rotação automática", ""},
	{"back to %s:%d:%d", "de volta a %s:%d:%d", ""},
	{"build failed", "build falhou", ""},
	{"burst", "explosão", ""},
	{"choose image", "escolher imagem", ""},
	{"choose model", "escolher modelo", ""},
	{"click the scene to sample", "clique na cena para amostrar", ""},
	{"color", "cor", ""},
	{"compute", "compute", ""},
	{"compute pass", "pass compute", ""},
	{"controls", "controles", ""},
	{"could not read %s", "não foi possível ler %s", ""},
	{"create pass", "criar pass", ""},
	{"create resource", "criar recurso", ""},
	{"debug", "depuração", ""},
	{"delete node", "excluir nó", ""},
	{"develop", "revelar", ""},
	{"develop style", "estilo de revelação", ""},
	{"develop transition", "transição de revelação", ""},
	{"dissolve", "dissolver", ""},
	{"editor font", "fonte do editor", ""},
	{"effects", "efeitos", ""},
	{"end (s)", "fim (s)", ""},
	{"ERROR writing %s", "ERRO ao escrever %s", ""},
	{"export", "exportar", ""},
	{"export gif", "exportar gif", ""},
	{"export png", "exportar png", ""},
	{"frame at t = %.2f s", "quadro em t = %.2f s", ""},
	{"full", "completo", ""},
	{"gen %.2f ms", "ger %.2f ms", ""},
	{"glass", "vidro", ""},
	{"graph pan friction", "atrito do pan do grafo", ""},
	{"graph pan max speed", "velocidade máx. do pan do grafo", ""},
	{"graphics", "graphics", ""},
	{"graphics 2d", "graphics 2d", ""},
	{"graphics 3d", "graphics 3d", ""},
	{"graphics pass", "pass graphics", ""},
	{"grid", "grade", ""},
	{"image", "imagem", ""},
	{"ink particles", "partículas de tinta", ""},
	{"interaction", "interação", ""},
	{"iris", "íris", ""},
	{"language", "idioma", ""},
	{"learn", "aprender", ""},
	{"← all trails", "← todas as trilhas", ""},
	{"mesh", "malha", ""},
	{"mouse rotation", "rotação com mouse", ""},
	{"no previous position", "sem posição anterior", ""},
	{"nothing to save", "nada para salvar", ""},
	{"off (static)", "desligado (estático)", ""},
	{"output", "saída", ""},
	{"paper grain", "grão de papel", ""},
	{"params", "params", ""},
	{"pixel inspector", "inspetor de pixels", ""},
	{"preview", "prévia", ""},
	{"previews", "prévias", ""},
	{"random", "aleatório", ""},
	{"rename '%s' to:", "renomear '%s' para:", ""},
	{"renamed %s → %s: %d occurrence(s) in %d file(s)", "renomeado %s → %s: %d ocorrência(s) em %d arquivo(s)", ""},
	{"restore last compiled", "restaurar última compilação", ""},
	{"restored last compiled version of %s", "restaurada a última versão compilada de %s", ""},
	{"return debug_* from the shader", "retorne debug_* no shader", ""},
	{"refusing to rename keyword %s", "recusando renomear a palavra-chave %s", ""},
	{"saved %d file(s) at %02d:%02d:%02d", "%d arquivo(s) salvo(s) às %02d:%02d:%02d", ""},
	{"scene '%s' failed to load", "a cena '%s' falhou ao carregar", ""},
	{"shared", "compartilhados", ""},
	{"show 2d", "show 2d", ""},
	{"sound", "som", ""},
	{"springs", "molas", ""},
	{"start (s)", "início (s)", ""},
	{"subtle", "sutil", ""},
	{"texture", "textura", ""},
	{"theme", "tema", ""},
	{"time (s)", "tempo (s)", ""},
	{"transparency", "transparência", ""},
	{"ui font", "fonte da UI", ""},
	{"waiting for GPU...", "aguardando a GPU...", ""},
	{"apply", "aplicar", ""},
	{"cancel", "cancelar", ""},
	{"invalid changes keep the last valid pipeline", "mudanças inválidas mantêm a última pipeline válida", ""},
	{"last valid pipeline remains active", "a última pipeline válida permanece ativa", ""},
	{"pixel provenance", "proveniência do pixel", ""},
	{"reading pass outputs...", "lendo saídas dos passes...", ""},
}
