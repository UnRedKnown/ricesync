-- perms: change permissions or owner of the selected files (or the hovered one)
--   e p  chmod: 755, 644, u+x, g-w, a=r, ...   (-R 755: folders with all inside)
--   e o  chown: user, user:group, :group        (-R red: the same, for folders)
-- The box's title shows what the first file has now. If it needs root, the
-- same command runs again with sudo, in the terminal (asks for your password).

local get_files = ya.sync(function()
	local t = {}
	-- (entries can be file objects, whose path is in .url)
	local function path(u)
		local ok, url = pcall(function() return u.url end)
		return tostring(ok and url or u)
	end
	for _, u in pairs(cx.active.selected) do t[#t + 1] = path(u) end
	local h = cx.active.current.hovered
	if #t == 0 and h then t[1] = tostring(h.url) end
	return t
end)

local function notify(msg, level)
	ya.notify({ title = "Permissions", content = msg, timeout = 5, level = level or "info" })
end

-- "rw-r--r-- 644 @USER@:@USER@" for one file
local function now_of(path)
	local out = Command("stat"):arg("-c"):arg("%A %a %U:%G"):arg("--"):arg(path):stdout(Command.PIPED):output()
	if not out or not out.status.success then return nil end
	local s, oct, owner = out.stdout:match("^.(%S+) (%d+) (%S+)")
	return s, oct, owner
end

local function valid_mode(m)
	if m:match("^[0-7][0-7][0-7][0-7]?$") then return true end
	for part in (m .. ","):gmatch("([^,]*),") do
		if not part:match("^[ugoa]*[-+=][rwxXst]*$") and not part:match("^[ugoa]*[-+=][ugo]$") then return false end
	end
	return true
end

local function valid_owner(o)
	local name = "[%a_][%w_.-]*%$?"
	return o:match("^" .. name .. "$") or o:match("^" .. name .. ":" .. name .. "$")
		or o:match("^:" .. name .. "$") or o:match("^%d+$") or o:match("^%d+:%d+$")
end

local function entry(_, job)
	local what = job and job.args and job.args[1] or "mode"
	local files = get_files()
	if #files == 0 then return end

	local s, oct, owner = now_of(files[1])
	local name = files[1]:match("([^/]+)/?$") or files[1]
	local which = #files == 1 and name or string.format("%s and %d more", name, #files - 1)
	local title
	if what == "owner" then
		title = string.format("chown %s (now %s):", which, owner or "?")
	else
		title = string.format("chmod %s (now %s %s):", which, s or "?", oct or "?")
	end

	local value, event = ya.input({
		title = title,
		value = "",
		pos = { "top-center", y = 3, w = 64 }, position = { "top-center", y = 3, w = 64 },
	})
	if event ~= 1 then return end
	value = (value or ""):match("^%s*(.-)%s*$")
	if value == "" then return end

	local recursive = false
	if value:match("^%-R%s+") then recursive = true; value = value:gsub("^%-R%s+", "") end
	local tool = what == "owner" and "chown" or "chmod"
	if what == "owner" then
		if not valid_owner(value) then return notify("Not an owner: " .. value .. "  (user, user:group or :group)", "warn") end
	elseif not valid_mode(value) then
		return notify("Not a mode: " .. value .. "  (like 755, 644, u+x, g-w)", "warn")
	end

	local cmd = Command(tool)
	if recursive then cmd = cmd:arg("-R") end
	cmd = cmd:arg("--"):arg(value)
	for _, f in ipairs(files) do cmd = cmd:arg(f) end
	local out = cmd:stdin(Command.NULL):stderr(Command.PIPED):output()
	if out and out.status.success then
		return notify(string.format("%s %s%s: done", tool, recursive and "-R " or "", value))
	end

	-- not allowed: the same again with sudo, in the terminal
	local err = out and out.stderr or ""
	if err:find("not permitted") or err:find("Permission denied") then
		local line = tool .. (recursive and " -R" or "") .. " -- " .. ya.quote(value)
		for _, f in ipairs(files) do line = line .. " " .. ya.quote(f) end
		ya.emit("shell", { "sudo " .. line:gsub("%%", "%%%%"), block = true })
		return
	end
	notify(tool .. " failed: " .. err, "error")
end

return { entry = entry }
