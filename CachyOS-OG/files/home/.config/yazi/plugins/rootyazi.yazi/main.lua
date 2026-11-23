-- rootyazi: root yazi on the spot, in this terminal, and every key that may
-- need root asks for it instead of starting a task that hangs.
--
--   e r  plugin rootyazi root    switch: root yazi here / back to yours
--   g h  plugin rootyazi home    your home, also from root yazi
--   and the guarded keys: plugin rootyazi ACTION (list in keymap.toml)
--
-- In your own yazi, a guarded key checks first whether you may do it here.
-- If yes, it's just yazi's own command. If not, it offers root yazi, opened
-- on the same file, with what you yanked and selected carried over, and
-- does the same thing there straight away (delete still asks yazi's own
-- "are you sure"). Opening a folder you can't: root yazi opens inside it.
-- Leaving root yazi (e r) brings you back to the folder it was in.
-- In root yazi, the keys are simply yazi's own commands.
-- Root yazi uses your yazi config and editors in it run as you (sedit).

-- what each guarded key does, and what it needs:
--   here    write access to the current folder
--   targets write access to the folders of the selected (or hovered) files
--   read    read access to the hovered file (folders: open them)
local ACTIONS = {
	open       = { "read",    "open",     {} },
	enter      = { "read",    "enter",    {} },
	paste      = { "here",    "paste",    {} },
	paste_over = { "here",    "paste",    { force = true } },
	trash      = { "targets", "remove",   {} },
	delete     = { "targets", "remove",   { permanently = true } },
	rename     = { "targets", "rename",   { cursor = "before_ext" } },
	create     = { "here",    "create",   {} },
	link       = { "here",    "link",     {} },
	link_rel   = { "here",    "link",     { relative = true } },
	hardlink   = { "here",    "hardlink", {} },
	pack       = { "here",    "plugin",   { "pack" } },
	paste_clip = { "here",    "plugin",   { "paste-clip" } },
}

local get_state = ya.sync(function()
	-- (entries can be file objects, whose path is in .url)
	local function path(u)
		local ok, url = pcall(function() return u.url end)
		return tostring(ok and url or u)
	end
	local sel = {}
	for _, u in pairs(cx.active.selected) do sel[#sel + 1] = path(u) end
	local yanked = {}
	for _, u in pairs(cx.yanked) do yanked[#yanked + 1] = path(u) end
	local h = cx.active.current.hovered
	return {
		cwd = tostring(cx.active.current.cwd),
		hovered = h and tostring(h.url) or nil,
		hovered_dir = h and h.cha.is_dir or false,
		selected = sel,
		yanked = yanked,
		cut = cx.yanked.is_cut,
	}
end)

-- (root yazi) yank carried over from your yazi: used up after a cut-paste
local carried_used = ya.sync(function(st) return st.carried_used end)
local set_carried_used = ya.sync(function(st)
	st.carried_used = true
	rootyazi_carried_used = true    -- (global: hides the yank tag from init.lua)
end)

local function is_root() return (ya.uid and ya.uid() == 0) or os.getenv("USER") == "root" end

local function notify(msg, level)
	ya.notify({ title = "Root", content = msg, timeout = 5, level = level or "info" })
end

local function confirm(title, body)
	if ya.confirm then
		return ya.confirm({ pos = { "center", w = 64, h = 8 }, title = title, body = body })
	end
	local ans, ev = ya.input({
		title = title .. " (y/N)",
		pos = { "top-center", y = 3, w = 64 }, position = { "top-center", y = 3, w = 64 },
	})
	return ev == 1 and ans and ans:lower():match("^y") ~= nil
end

local function test(...)
	local cmd = Command("test"):cwd("/")
	for _, a in ipairs({ ... }) do cmd = cmd:arg(a) end
	local out = cmd:output()
	return out and out.status.success
end

local function parent(p)
	local d = p:match("^(.*)/[^/]+/?$")
	return (d == nil or d == "") and "/" or d
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a"); f:close()
	return s
end

local function write_file(path, s)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(s); f:close()
	return true
end

-- Run root yazi on PATH (a folder, or a file to put the cursor on), with the
-- yank and selection carried over, and ACTION (if given) done there right
-- away; when it closes, go where it was.
local function root_yazi(path, st, action)
	local out = Command("mktemp"):cwd("/"):arg("-d"):arg("/tmp/rootyazi.XXXXXX"):stdout(Command.PIPED):output()
	if not out or not out.status.success then return notify("Couldn't make a temp folder", "error") end
	local dir = out.stdout:gsub("%s+$", "")
	if #st.yanked > 0 then
		write_file(dir .. "/yank", table.concat(st.yanked, "\n") .. "\n")
		if st.cut then write_file(dir .. "/cut", "") end
	end
	if #st.selected > 0 then
		write_file(dir .. "/select", table.concat(st.selected, "\n") .. "\n")
	end
	-- the key that needed root: root yazi does it right away
	if action then write_file(dir .. "/action", action .. "\n") end
	local cfg = os.getenv("YAZI_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config/yazi")

	local permit = (ui and ui.hide or ya.hide)()
	-- (started in /: from a folder you can't open, like /boot, starting
	-- anything there fails with "permission denied", code 13)
	local child = Command("sudo"):cwd("/")
		:arg("--preserve-env=EDITOR,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY,ROOTYAZI_DIR")
		:arg("YAZI_CONFIG_HOME=" .. cfg)
		:arg("yazi"):arg("--cwd-file=" .. dir .. "/cwd"):arg("--"):arg(path)
		:env("ROOTYAZI_DIR", dir)
		:stdin(Command.INHERIT):stdout(Command.INHERIT):stderr(Command.INHERIT)
		:spawn()
	local status = child and child:wait()
	if not status or not status.success then
		-- keep the error (wrong password, ...) readable
		Command("sh"):cwd("/"):arg("-c"):arg('printf "\\nRoot yazi failed. Enter to go back "; read x')
			:stdin(Command.INHERIT):stdout(Command.INHERIT):stderr(Command.INHERIT):output()
	end
	permit:drop()

	local back = read_file(dir .. "/cwd")
	if back and back ~= "" then ya.emit("cd", { (back:gsub("%s+$", "")) }) end
	if read_file(dir .. "/moved") then ya.emit("unyank", {}) end
	Command("rm"):cwd("/"):arg("-rf"):arg("--"):arg(dir):output()
end

-- (root yazi) paste what was yanked in your yazi, if nothing is yanked here
local function paste_carried(st, force)
	local dir = os.getenv("ROOTYAZI_DIR")
	local list = dir and read_file(dir .. "/yank")
	if not list or carried_used() then return false end
	local cut = read_file(dir .. "/cut") ~= nil
	local files = {}
	for line in list:gmatch("[^\n]+") do files[#files + 1] = line end
	if #files == 0 then return false end

	if not force then
		for _, f in ipairs(files) do
			local name = f:match("([^/]+)/?$")
			if fs.cha(Url(st.cwd .. "/" .. name)) then
				if not confirm("Replace it?", name .. " already exists here.") then return true end
				break
			end
		end
	end
	local cmd = (cut and Command("mv") or Command("cp"):arg("-r"):arg("--preserve=mode,timestamps")):cwd("/")
	cmd = cmd:arg("--")
	for _, f in ipairs(files) do cmd = cmd:arg(f) end
	local out = cmd:arg(st.cwd .. "/"):stderr(Command.PIPED):output()
	if not out or not out.status.success then
		notify("Paste failed: " .. ((out and out.stderr) or "?"), "error")
		return true
	end
	if cut then
		set_carried_used()
		write_file(dir .. "/moved", "")
	end
	notify((cut and "Moved " or "Copied ") .. #files .. " item(s) here")
	return true
end

local function run(spec)
	local _, action, args = spec[1], spec[2], spec[3]
	if action == "plugin" then return ya.emit("plugin", { args[1] }) end
	ya.emit(action, args)
end

local function entry(_, job)
	local what = job and job.args and job.args[1] or "root"
	local st = get_state()

	if what == "root" then
		if is_root() then return ya.emit("quit", {}) end
		return root_yazi(st.cwd, st)
	end

	if what == "home" then
		local user = os.getenv("SUDO_USER")
		local home = (is_root() and user and user ~= "root") and ("/home/" .. user) or os.getenv("HOME")
		return ya.emit("cd", { home })
	end

	local spec = ACTIONS[what]
	if not spec then return notify("rootyazi: unknown action " .. what, "error") end

	-- Enter / Right on a folder goes into it
	if (what == "open" or what == "enter") and st.hovered_dir then spec = ACTIONS.enter end
	if what == "enter" and not st.hovered_dir then return end

	if is_root() then
		if spec[2] == "paste" and #st.yanked == 0 and paste_carried(st, spec[3].force) then return end
		return run(spec)
	end

	-- your yazi: allowed here?
	local need, ok = spec[1], true
	if need == "here" then
		ok = test("-w", st.cwd)
	elseif need == "read" then
		ok = not st.hovered or (st.hovered_dir and test("-r", st.hovered, "-a", "-x", st.hovered))
			or (not st.hovered_dir and test("-r", st.hovered))
	else
		local files = #st.selected > 0 and st.selected or { st.hovered }
		for _, f in ipairs(files) do
			if f and not test("-w", parent(f)) then ok = false; break end
		end
	end
	if ok then return run(spec) end

	local where = need == "here" and st.cwd or (st.hovered or st.cwd)
	if confirm("No permission for that here", where .. " needs root. Switch to root yazi?") then
		-- (enter: root yazi already opens inside that folder)
		root_yazi(st.hovered or st.cwd, st, what ~= "enter" and what or nil)
	end
end

-- (root yazi) select again what was selected in your yazi, then do what
-- you were doing when root was needed (paste, delete, ...). Called from
-- init.lua. yazi can only select the file under the cursor, so once root
-- yazi shows its folder, the cursor visits each of them, selects it, and
-- goes back where it was.
local function setup()
	if not is_root() then return end
	local dir = os.getenv("ROOTYAZI_DIR")
	if not dir then return end
	local list = read_file(dir .. "/select") or ""
	local action = (read_file(dir .. "/action") or ""):match("^%s*(%S+)")
	if action and not ACTIONS[action] then action = nil end
	local want, n = {}, 0
	for line in list:gmatch("[^\n]+") do want[line] = true; n = n + 1 end
	if n == 0 and not action then return end

	local done = false
	ps.sub("hover", function()
		if done then return end
		local folder = cx.active.current
		-- (no files yet: still loading, or an empty folder, where a paste or
		-- a new file can go ahead)
		if #folder.files == 0 and not (n == 0 and action and ACTIONS[action][1] == "here") then return end
		done = true
		pcall(ps.unsub, "hover")
		local found = {}
		for i = 1, #folder.files do
			if want[tostring(folder.files[i].url)] then found[#found + 1] = i - 1 end
		end
		local cur = folder.cursor
		local pos = cur
		for _, i in ipairs(found) do
			ya.emit("arrow", { i - pos })
			ya.emit("toggle", { state = "on" })
			pos = i
		end
		if pos ~= cur then ya.emit("arrow", { cur - pos }) end
		if #found < n then
			notify(string.format("Selected %d of %d: the others aren't in this folder", #found, n), "warn")
		end
		-- then the key that brought you here (after the selection: yazi
		-- runs these in order)
		if action then ya.emit("plugin", { "rootyazi", action }) end
	end)
end

return { setup = setup, entry = entry }
