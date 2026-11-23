-- In root yazi: a red ROOT tag at the top left, so you always know
if (ya.uid and ya.uid() == 0) or os.getenv("USER") == "root" then
	Header:children_add(function()
		return ui.Span(" ROOT "):fg("black"):bg("red"):bold()
	end, 500, Header.LEFT)
end

-- In root yazi: what you yanked in your own yazi, top right (yazi's own
-- yank tag can't show it, the files were yanked in the other yazi).
-- Gone once it's been pasted as a cut, or when you yank something here.
do
	local dir = os.getenv("ROOTYAZI_DIR")
	local f = dir and io.open(dir .. "/yank")
	if f then
		local n = 0
		for _ in f:lines() do n = n + 1 end
		f:close()
		local c = io.open(dir .. "/cut")
		local cut = c ~= nil
		if c then c:close() end
		if n > 0 then
			Header:children_add(function()
				local ok, len = pcall(function() return #cx.yanked end)
				if rootyazi_carried_used or (ok and len > 0) then return ui.Line("") end
				return ui.Span(string.format(" %s %d yanked ", cut and "cut" or "copy", n))
					:fg("black"):bg(cut and "red" or "green")
			end, 1000, Header.RIGHT)
		end
	end
end

-- In root yazi: select what you had selected in your own yazi
require("rootyazi"):setup()
