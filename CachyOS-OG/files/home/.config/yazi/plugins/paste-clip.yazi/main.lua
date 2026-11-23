-- paste-clip: Ctrl+V saves the clipboard as a file in the current folder
--   image -> "Pasted image.png" (extension from the image type: .jpg, .webp, ...)
--   text  -> "Pasted text.txt", exactly as copied
-- A box asks for the name. Enter on an empty box uses the name in its title;
-- a typed name without an extension gets that extension. A name that's
-- already taken is only replaced after you say so.
-- Needs: wl-clipboard (wl-paste)

local IMAGE_EXT = {
	["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/jpg"] = "jpg", ["image/webp"] = "webp",
	["image/gif"] = "gif", ["image/bmp"] = "bmp", ["image/svg+xml"] = "svg", ["image/avif"] = "avif",
	["image/tiff"] = "tiff", ["image/heic"] = "heic", ["image/jxl"] = "jxl",
}
local TEXT_TYPES = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT" }

local get_cwd = ya.sync(function() return tostring(cx.active.current.cwd) end)

local function notify(msg, level)
	ya.notify({ title = "Paste", content = msg, timeout = 4, level = level or "info" })
end

local function exists(path) return fs.cha(Url(path)) ~= nil end

local function has_ext(name) return name:match("^.+%.[%a][%w]*$") ~= nil end

-- the clipboard's best type: an image first, then text
local function pick_type()
	local out, err = Command("wl-paste"):arg("--list-types"):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then return nil, "wl-paste is missing (install wl-clipboard)" end
	if not out.status.success then return nil, "the clipboard is empty" end
	local types, set = {}, {}
	for t in out.stdout:gmatch("[^\n]+") do types[#types + 1] = t; set[t] = true end
	if set["image/png"] then return "image/png", "Pasted image", "png" end
	for _, t in ipairs(types) do
		if t:match("^image/") then
			return t, "Pasted image", IMAGE_EXT[t] or t:match("^image/([%w]+)") or "img"
		end
	end
	for _, t in ipairs(TEXT_TYPES) do
		if set[t] then return t, "Pasted text", "txt" end
	end
	for _, t in ipairs(types) do
		if t:match("^text/") then return t, "Pasted text", "txt" end
	end
	return nil, "the clipboard holds neither an image nor text"
end

-- "Pasted text.txt", or "Pasted text 2.txt", ... if that's taken
local function free_name(dir, base, ext)
	local name = base .. "." .. ext
	local n = 2
	while exists(dir .. "/" .. name) do
		name = string.format("%s %d.%s", base, n, ext)
		n = n + 1
	end
	return name
end

local function ask_overwrite(name)
	if ya.confirm then
		return ya.confirm({
			pos = { "center", w = 50, h = 7 },
			title = "Replace it?",
			body = '"' .. name .. '" already exists here.',
		})
	end
	local ans, ev = ya.input({
		title = '"' .. name .. '" exists. Replace it? (y/N)',
		pos = { "top-center", y = 3, w = 60 }, position = { "top-center", y = 3, w = 60 },
	})
	return ev == 1 and ans and ans:lower():match("^y") ~= nil
end

local function entry()
	local mime, base, ext = pick_type()
	if not mime then return notify(base, "warn") end

	local dir = get_cwd()
	local default = free_name(dir, base, ext)
	local value, event = ya.input({
		title = "Paste as (Enter = " .. default .. "):",
		value = "",
		pos = { "top-center", y = 3, w = 60 }, position = { "top-center", y = 3, w = 60 },
	})
	if event ~= 1 then return end

	local name = (value or ""):match("^%s*(.-)%s*$")
	if name == "" then
		name = default
	else
		if name:find("/") then return notify("A name can't contain /", "warn") end
		if not has_ext(name) then name = name .. "." .. ext end
		if exists(dir .. "/" .. name) and not ask_overwrite(name) then return end
	end

	local path = dir .. "/" .. name
	local out = Command("sh")
		:arg("-c")
		:arg('wl-paste --no-newline --type "$1" > "$2" || { rm -f -- "$2"; exit 1; }')
		:arg("paste")
		:arg(mime)
		:arg(path)
		:stderr(Command.PIPED)
		:output()
	if not out or not out.status.success then
		return notify("Couldn't save it: " .. ((out and out.stderr) or "?"), "error")
	end
	ya.emit("reveal", { path })
	notify("Saved " .. name)
end

return { entry = entry }
