-- dotsync-rule: e then s puts the selected files (or the hovered one) in
-- dotsync.list: s = SYNC, d = DIFF, x = IGNORE. The menu shows each file's
-- rule now and why; picking one changes the file's own line in the list or
-- adds one at the end, then commits and pushes (all done by `dotsync rule`).
-- Needs: dotsync with REPO set in ~/.config/dotsync/config

local WORD = { S = "SYNC", D = "DIFF", X = "IGNORE", ["-"] = "not in the list" }

local get_paths = ya.sync(function()
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

local function notify(msg, level, timeout)
	ya.notify({ title = "dotsync", content = msg, timeout = timeout or 5, level = level or "info" })
end

local function run(args)
	local cmd = Command("dotsync"):arg("rule")
	for _, a in ipairs(args) do cmd = cmd:arg(a) end
	local out = cmd:stdin(Command.NULL):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then return nil, "dotsync is missing" end
	if not out.status.success then return nil, (out.stderr ~= "" and out.stderr or out.stdout) end
	return out.stdout
end

local function entry()
	local paths = get_paths()
	if #paths == 0 then return end

	-- each file's rule now: "listpath<TAB>S|D|X|-<TAB>why"
	local args = { "--porcelain" }
	for _, p in ipairs(paths) do args[#args + 1] = p end
	local out, err = run(args)
	if not out then return notify(err, "error") end
	local rows, count = {}, { S = 0, D = 0, X = 0, ["-"] = 0 }
	for line in out:gmatch("[^\n]+") do
		local lp, r, why = line:match("^(.-)\t(.-)\t(.*)$")
		if lp then
			rows[#rows + 1] = { path = lp, rule = r, why = why }
			count[r] = (count[r] or 0) + 1
		end
	end
	if #rows == 0 then return end

	-- what it is now: shown next to the menu
	local now = {}
	for i, r in ipairs(rows) do
		if i > 8 then now[#now + 1] = string.format("… and %d more", #rows - 8); break end
		now[#now + 1] = string.format("%s\nnow: %s — %s", r.path, WORD[r.rule] or r.rule, r.why)
	end
	notify(table.concat(now, "\n\n"), "info", 15)

	local function label(letter)
		local n = count[letter] or 0
		if #rows == 1 then return WORD[letter] .. (n == 1 and "   (current)" or "") end
		if n == #rows then return WORD[letter] .. "   (current for all)" end
		if n > 0 then return string.format("%s   (current for %d of %d)", WORD[letter], n, #rows) end
		return WORD[letter]
	end
	local idx = ya.which({
		cands = {
			{ on = "s", desc = label("S") },
			{ on = "d", desc = label("D") },
			{ on = "x", desc = label("X") },
		},
	})
	if not idx then return end
	local letter = ({ "S", "D", "X" })[idx]
	if (count[letter] or 0) == #rows then return notify("Already " .. WORD[letter] .. ", nothing to change") end

	local set = { "--set", letter }
	for _, p in ipairs(paths) do set[#set + 1] = p end
	notify("Updating the list…", "info", 3)
	local res, err2 = run(set)
	if not res then return notify(err2, "error", 10) end
	notify((res:gsub("%s+$", "")), "info", 6)
end

return { entry = entry }
