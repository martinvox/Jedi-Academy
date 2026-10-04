class_name JAVfs
extends RefCounted
## Virtual filesystem over a Jedi Academy install, mirroring the search order
## of FS_AddGameDirectory (code/qcommon/files_pc.cpp):
##   - inside a game dir, .pk3 files sort case-insensitively and later names
##     override earlier ones; all pk3s override loose files in that dir
##   - a mod dir (fs_game) mounted after "base" overrides it
## Paths are case-insensitive and use forward slashes, as in the original.

# lowercase path -> [source_index, real_path]
var _index: Dictionary = {}
# each source is either a ZIPReader or a String (loose directory root)
var _sources: Array = []


## Mounts <gamedata>/<game_dir> (e.g. "base"). Call once per game dir,
## base first, then the mod dir.
func mount_game_dir(gamedata_path: String, game_dir: String) -> int:
	var root := gamedata_path.path_join(game_dir)
	if not DirAccess.dir_exists_absolute(root):
		push_error("JAVfs: game dir not found: %s" % root)
		return ERR_FILE_NOT_FOUND
	mount_directory(root)
	var paks: Array[String] = []
	for f in DirAccess.get_files_at(root):
		if f.get_extension().to_lower() == "pk3":
			paks.append(f)
	paks.sort_custom(func(a: String, b: String) -> bool: return a.nocasecmp_to(b) < 0)
	for p in paks:
		mount_pk3(root.path_join(p))
	return OK


## Indexes every loose file below `root`.
func mount_directory(root: String) -> void:
	var src := _sources.size()
	_sources.append(root)
	_index_dir(src, root, "")


func mount_pk3(path: String) -> int:
	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		push_error("JAVfs: cannot open %s (%s)" % [path, error_string(err)])
		return err
	var src := _sources.size()
	_sources.append(zip)
	for f in zip.get_files():
		if not f.ends_with("/"):
			_index[_normalize(f)] = [src, f]
	return OK


func exists(path: String) -> bool:
	return _index.has(_normalize(path))


func read_file(path: String) -> PackedByteArray:
	var entry = _index.get(_normalize(path))
	if entry == null:
		return PackedByteArray()
	var src = _sources[entry[0]]
	if src is ZIPReader:
		return (src as ZIPReader).read_file(entry[1])
	return FileAccess.get_file_as_bytes((src as String).path_join(entry[1]))


func read_text(path: String) -> String:
	return read_file(path).get_string_from_utf8()


## Returns all indexed paths (lowercase) under `dir` with extension `ext`
## (without dot), sorted. Matches FS_ListFiles semantics loosely.
func list_files(dir: String, ext: String) -> PackedStringArray:
	var prefix := _normalize(dir)
	if not prefix.is_empty() and not prefix.ends_with("/"):
		prefix += "/"
	var dot_ext := "." + ext.to_lower()
	var out := PackedStringArray()
	for k: String in _index.keys():
		if k.begins_with(prefix) and k.ends_with(dot_ext):
			out.append(k)
	out.sort()
	return out


## Finds an image for a Q3 texture name, trying the extensions the original
## renderer accepts (R_FindImageFile tries .tga/.jpg/.png).
func find_image(name: String) -> String:
	var base := _normalize(name)
	if exists(base) and base.get_extension() in ["tga", "jpg", "png"]:
		return base
	var stem := base.get_basename() if base.get_extension() in ["tga", "jpg", "png"] else base
	for ext in ["tga", "jpg", "png"]:
		var candidate: String = stem + "." + ext
		if exists(candidate):
			return candidate
	return ""


func file_count() -> int:
	return _index.size()


func _index_dir(src: int, root: String, rel: String) -> void:
	var abs_dir := root.path_join(rel) if not rel.is_empty() else root
	for f in DirAccess.get_files_at(abs_dir):
		var r := rel.path_join(f) if not rel.is_empty() else f
		_index[_normalize(r)] = [src, r]
	for d in DirAccess.get_directories_at(abs_dir):
		_index_dir(src, root, rel.path_join(d) if not rel.is_empty() else d)


static func _normalize(path: String) -> String:
	var p := path.replace("\\", "/").to_lower()
	while p.begins_with("/"):
		p = p.substr(1)
	return p
