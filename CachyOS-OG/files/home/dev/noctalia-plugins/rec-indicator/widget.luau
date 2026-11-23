--!nonstrict
-- Recording indicator: red dot + elapsed time while `capture` is recording.
-- Hidden when idle. Click to stop the recording.
--
-- Driven over IPC by the capture script:
--   noctalia msg plugin red/rec-indicator:indicator all start <unix-seconds>
--   noctalia msg plugin red/rec-indicator:indicator all stop
--
-- All callbacks are defined first, so they exist even if a later setup
-- step fails; setup is wrapped in pcall and logs instead of aborting.

local startedAt = nil
local color = "#e53935"

local function now()
    -- Prefer Noctalia's clock; fall back to os.time if available.
    local ok, value = pcall(function()
        return tonumber(noctalia.formatTime("%s"))
    end)
    if ok and value then
        return value
    end
    if os and os.time then
        return os.time()
    end
    return 0
end

local function format(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

local function render()
    if not startedAt then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)
    barWidget.setGlyph("point-filled")
    barWidget.setGlyphColor(color)
    barWidget.setText(format(math.max(0, now() - startedAt)))
    barWidget.setTooltip("Recording - click to stop")
end

-- Called by Noctalia ------------------------------------------------------

function onIpc(event, payload)
    if event == "start" then
        startedAt = tonumber(payload) or now()
    elseif event == "stop" then
        startedAt = nil
    end
    -- Share with this widget's copies on other monitors' bars.
    pcall(noctalia.state.set, "startedAt", startedAt or false)
    render()
end

function update()
    pcall(noctalia.setUpdateInterval, 1000)
    render()
end

function onClick()
    noctalia.runAsync("capture stop")
end

-- Setup -------------------------------------------------------------------

local function setup()
    local c = barWidget.getConfig("color")
    if c and c ~= "" then
        color = c
    end

    local saved = noctalia.state.get("startedAt")
    if saved then
        startedAt = saved
    end

    noctalia.state.watch("startedAt", function(value)
        startedAt = value or nil
        render()
    end)
end

local ok, err = pcall(setup)
if not ok then
    noctalia.log("rec-indicator setup failed: " .. tostring(err))
end

render()
