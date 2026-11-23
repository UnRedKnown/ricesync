--- @sync entry
-- smart-right: Right arrow / l on the hovered item
--   folder        -> go into it (as before)
--   (in the file picker: picks the file instead, like Enter)
--   text / code   -> edit in $EDITOR (in root yazi: through sedit, as you) (takes over this window, back to yazi on exit)
--   archive       -> extract it next to itself with ouch, in the background
--   audio         -> play in the background with mpv; Right on it again stops it
--   anything else -> open with the normal default app (like Enter)

local ARCHIVE_EXT = {
	zip = true, ["7z"] = true, rar = true, tar = true, tgz = true, tbz2 = true, txz = true,
	gz = true, xz = true, zst = true, bz2 = true, lz4 = true, lzma = true, sz = true,
}
local AUDIO_EXT = {
	mp3 = true, flac = true, ogg = true, opus = true, wav = true, m4a = true, aac = true, wma = true,
}
local TEXT_MIME = {
	["application/json"] = true, ["application/xml"] = true, ["application/toml"] = true,
	["application/x-yaml"] = true, ["application/javascript"] = true, ["application/x-desktop"] = true,
	["application/x-shellscript"] = true, ["application/x-sh"] = true, ["application/x-subrip"] = true,
	["inode/empty"] = true, ["inode/x-empty"] = true, ["application/x-empty"] = true,
}

-- Plays $1 in the background. If that same file is already playing, stops it
-- instead; a different file replaces the one playing. Only ever stops the mpv
-- it started itself (checked by PID and process name).
local PLAY = [[sh -c '
f=${XDG_RUNTIME_DIR:-/tmp}/yazi-mpv
pid=$(sed -n 1p "$f" 2>/dev/null); cur=$(sed -n 2p "$f" 2>/dev/null)
if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = mpv ]; then
    kill "$pid"
    [ "$cur" = "$1" ] && { rm -f "$f"; exit 0; }
fi
mpv --no-video --no-terminal -- "$1" >/dev/null 2>&1 </dev/null &
echo "$!" > "$f"; echo "$1" >> "$f"
' play]]

local function kind(h)
	local mime = (h.mime and h:mime()) or ""
	local ext = (tostring(h.name or ""):match("%.([^.]+)$") or ""):lower()
	if mime:find("^audio/") or AUDIO_EXT[ext] then return "audio" end
	if ARCHIVE_EXT[ext] or mime:find("zip") or mime:find("compressed") or mime:find("x%-tar")
		or mime:find("x%-xz") or mime:find("zstd") or mime:find("x%-bzip") or mime:find("rar") then
		return "archive"
	end
	if mime:find("^text/") or TEXT_MIME[mime] then return "text" end
	return "other"
end

local function entry()
	local h = cx.active.current.hovered
	if not h then return end
	if h.cha.is_dir then
		-- through rootyazi: a folder you can't open offers root yazi
		ya.emit("plugin", { "rootyazi", "enter" })
		return
	end

	-- in the file picker (yazi-filechooser), never open anything: pick it
	if os.getenv("YAZI_FILECHOOSER") == "1" then
		ya.emit("open", { hovered = true })
		return
	end

	-- yazi treats % in shell commands as a placeholder (%s, %h, ...), so a
	-- literal % in a file name has to be written as %%
	local path = ya.quote(tostring(h.url)):gsub("%%", "%%%%")
	local k = kind(h)
	if k == "text" then
		-- in root yazi (sudo): sedit, so the editor runs as you on a copy;
		-- otherwise straight into $EDITOR
		if os.getenv("SUDO_USER") and os.getenv("USER") == "root" then
			ya.emit("shell", { "sedit -- " .. path, block = true })
		else
			local editor = os.getenv("EDITOR")
			if not editor or editor == "" then editor = "nano" end
			ya.emit("shell", { editor .. " -- " .. path, block = true })
		end
	elseif k == "archive" then
		-- --no: never overwrite anything that already exists
		ya.emit("shell", { "ouch decompress --no -- " .. path .. " </dev/null", orphan = true })
		ya.notify({ title = "Extracting", content = tostring(h.name), timeout = 3 })
	elseif k == "audio" then
		ya.emit("shell", { PLAY .. " " .. path, orphan = true })
		ya.notify({ title = "mpv", content = "Play / stop: " .. tostring(h.name), timeout = 2 })
	else
		ya.emit("open", { hovered = true })
	end
end

return { entry = entry }
