-- pack: e then c packs the selected files (or the hovered one) into an
-- archive in the current folder, with ouch.
-- A box asks for the name. Enter on an empty box uses the name in its title;
-- a typed name without an extension gets .zip. The extension picks the format
-- (.zip, .tar.gz, .tar.zst, .7z, ...). A name that's already taken is only
-- replaced after you say so.
-- Needs: ouch

local DEFAULT_EXT = "zip"

local get_state = ya.sync(function()
	local files = {}
	-- (entries can be file objects, whose path is in .url)
	local function path(u)
		local ok, url = pcall(function() return u.url end)
		return tostring(ok and url or u)
	end
	for _, u in pairs(cx.active.selected) do files[#files + 1] = path(u) end
	local h = cx.active.current.hovered
	if #files == 0 and h then files[1] = tostring(h.url) end
	local first_is_dir = false
	if #files == 1 and h and tostring(h.url) == files[1] then first_is_dir = h.cha.is_dir end
	return tostring(cx.active.current.cwd), files, first_is_dir
end)

local function notify(msg, level)
	ya.notify({ title = "Pack", content = msg, timeout = 4, level = level or "info" })
end

local function exists(path) return fs.cha(Url(path)) ~= nil end

-- an extension like .zip or .tar.gz (not just any dot, e.g. "v1.2 notes")
local function has_ext(name) return name:match("^.+%.[%a][%w]*$") ~= nil end

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
	local dir, files, is_dir = get_state()
	if #files == 0 then return notify("Nothing to pack", "warn") end

	-- one file: its name ("notes.txt" -> notes.zip, folder "photos" -> photos.zip)
	local base = "Archive"
	if #files == 1 then
		base = files[1]:match("([^/]+)/?$") or "Archive"
		if not is_dir then base = base:match("^(.+)%.[^.]+$") or base end
	end
	local default = free_name(dir, base, DEFAULT_EXT)

	local value, event = ya.input({
		title = string.format("Pack %d item%s as (Enter = %s):", #files, #files == 1 and "" or "s", default),
		value = "",
		pos = { "top-center", y = 3, w = 64 }, position = { "top-center", y = 3, w = 64 },
	})
	if event ~= 1 then return end

	local name = (value or ""):match("^%s*(.-)%s*$")
	local replace = false
	if name == "" then
		name = default
	else
		if name:find("/") then return notify("A name can't contain /", "warn") end
		if not has_ext(name) then name = name .. "." .. DEFAULT_EXT end
		if exists(dir .. "/" .. name) then
			if not ask_overwrite(name) then return end
			replace = true
		end
	end

	-- files in this folder by their own names, so the archive doesn't hold
	-- the whole path to them
	local cmd = Command("ouch"):cwd(dir):arg("compress")
	for _, f in ipairs(files) do
		local rel = f:sub(1, #dir + 1) == dir .. "/" and f:sub(#dir + 2) or f
		cmd = cmd:arg(rel)
	end
	cmd = cmd:arg(name)
	if replace then cmd = cmd:arg("--yes") end

	notify("Packing into " .. name .. "…")
	local out, err = cmd:stdin(Command.NULL):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then return notify("ouch is missing (install ouch)", "error") end
	if not out.status.success then
		return notify("Failed: " .. (out.stderr ~= "" and out.stderr or out.stdout), "error")
	end
	ya.emit("reveal", { dir .. "/" .. name })
	notify("Packed into " .. name)
end

return { entry = entry }
