-- Growtopia - Break GUI
-- Sidebar + dashboard layout, monochrome theme (see GUI_STYLE_GUIDE.md).
--
-- Server rules (verified live, PlaceVersion 714):
--   * a hit = act kind 6 (hit tile) + act kind 1 (punch), both at tile center
--   * hit cooldown is GLOBAL per player: >=0.17s accepted, <=0.14s hit dropped
--   * hit count is per tile and remembered (you can rotate between tiles)
--   * reach: tile center <= 4 tiles from you (5 rejected)
--   * break = Net.tile {id = 0} sent with the final hit; server echoes
--     tileChanged with the old id ONLY when it rejects the break
--
-- v973: every client->server call moved to ByteNet (Net.tile / Net.call / Net.take / Net.drop).
-- ReplicatedStorage.WorldRemotes.* is now bait (DisableAntiCheat, DupeItem, GodMode, ... and the
-- old SetTile / TakeDrop / GetInventory / LeaveWorld): the real client never fires them, so firing
-- one = kick "unexpected client behaviour" (267). Only ever LISTEN / getconnections on WorldRemotes.
--
-- Fast Break: client is told every block is 1 hit (one click); real hits are padded.
-- Auto Break: hits the nearest selected block in reach, then the next, forever.
--   Walk to blocks: <= 2 left in reach -> path bot to the next spot where new blocks (through
--   walls) or their drops come in reach; hitting goes on while walking.
--   Reach = the game's own punch box (2.5 + worn `reach`), like the real client.
-- Auto Collect: stood still 1s -> walks onto the nearest drop (path bot); the game's touch pickup takes it.
-- Auto Farm: stand still; places a block from your bag beside you, breaks it, steps / hops onto
--   its drops, repeat.
--   Fetch: out of the block -> walk (path bot) to the nearest dropped pile of it, come back.
--   Auto drop: a farmed seed hits 200 -> walk to a stash tile 5+ away, drop it, come back.
--   A rejected place re-syncs the bag from the server (never refunds: phantom-block loop).
-- Row Farm: a row of up to 20 blocks in your own row, on flat floor: walk out placing each block on
--   the tile you just left (a wall behind you), walk back breaking them (stepping into a broken
--   tile = the touch pickup takes its drops), repeat. Own block pick / Fetch / Auto drop (seed pile
--   5+ tiles off the row); trips only between laps. Leftovers of a stopped run get cleared first.
-- Auto Harvest: walks (path bot) to ripe rows, walks along them harvesting 2 columns ahead,
--   picks drops up as it passes; leftover drops get a walk trip.
--   A harvested seed/block hits 200 -> menu Respawn -> walk to the drop spot (set by standing
--   on it, or auto near spawn) -> drop the full stacks -> back to harvesting.
-- Auto Plant: walks rows planting the picked seed on "Tree spots" (where trees were, remembered
--   + saved per world) or everywhere a seed fits; out of seeds -> fetch a dropped pile of them.
-- Auto Rotate: every farm world in turn: harvest -> farm the block (Auto Farm, or Row Farm) -> plant -> leftover seeds to a
--   storage world -> next ready world (none ready: wait in a random world). Settings + progress in
--   growblox_auto.json; autoexec/growblox_autoload.lua re-runs this after a world's teleport.
-- Path: click a drop; plans a route with a copy of the game's physics and walks it via the
--   game's own input (MobileControls.dir/jumping), then collects it.
-- Safety (always): no teleports (every bot walks + jumps with the game's own input), no drop is
--   ever moved (pickups = the game's touch pickup with you on the drop), hits / places at the real
--   client's rate, punch-box reach, humanizer on by default. FarmCheck (v1045 "Are you still
--   there?" popup): every auto mode holds until you answer it yourself.

local replicatedStorage = game:GetService("ReplicatedStorage")
local userInputService = game:GetService("UserInputService")
local players = game:GetService("Players")
local textService = game:GetService("TextService")

-- v1208-v1210: the game ran hidden copies of its modules (nil-parented, random names, listed in
-- getrenv().shared[RS.Qz]) while ReplicatedStorage.Shared.Net and .ItemDB sat idle: that Net has its
-- own seq counter (our sends would be numbered apart from the game's) and none of the game's
-- listeners; that ItemDB misses the live grow event. v1220 is back on the named RS ones. So: by
-- shape, a hidden copy wins, and a Net only counts if the game listens on it.
-- v1444: a 2nd hidden table has ItemDB's shape (7,438 entries next to ItemDB's 11,738), and taking it
-- crashed the load (an item id missing): among equally hidden ones the biggest wins.
local itemDB, net
do
	local dbN, dbHidden = 0, false
	for _ = 1, 120 do -- after a teleport the game can still be starting
		for _, m in ipairs(getloadedmodules()) do
			local ok, v = pcall(require, m)
			if ok and type(v) == "table" then
				local two, hidden = rawget(v, 2), not m:IsDescendantOf(replicatedStorage)
				if type(rawget(v, "act")) == "table" and type(rawget(v, "tile")) == "table" and rawget(v, "CALLS") then
					local live, l = pcall(function() return v.treeChanged.getListeners() end)
					if live and type(l) == "table" and next(l) and (hidden or not net) then net = v end
				elseif type(two) == "table" and two.hits ~= nil and two.name ~= nil and (hidden or not dbHidden) then
					local n = 0
					for _ in pairs(v) do n += 1 end
					if hidden ~= dbHidden or n > dbN then itemDB, dbN, dbHidden = v, n, hidden end
				end
			end
		end
		if net and itemDB then break end
		task.wait(1)
	end
end
assert(net and itemDB, "Growblox: the game's network / item modules weren't found")
-- listen only, never fire (see header). v1558 removed the folder: an empty stand-in keeps every
-- old-path fallback (FindFirstChild on it) quietly finding nothing.
local worldRemotes = replicatedStorage:FindFirstChild("WorldRemotes") or Instance.new("Folder")

-- Config.
local TOGGLE_KEY = Enum.KeyCode.RightShift
local HIT_GAP = 0.19 -- the real client's held punch (v1210 + v1348: actAt = hit + 0.19); server floor ~0.15s (v714)
local REACH = 4
-- Humanizer (Player page toggle, on by default). Every draw only ADDS time on top of the floors
-- (HIT_GAP, PLACE_GAP), so it can slow a run but never push a limit.
local HUMAN = {
	seed = nil, -- nil = new seed per run (shown on the Player page); set it to replay that run's draws
	jitter = 0.12, -- gap = base × (1 + |N(0, jitter)|) ...
	tailP = 0.07, tailAlpha = 1.6, tailMax = 4, -- ... + with tailP a Pareto(alpha) tail, capped at tailMax × base
	walkHold = { 0.6, 2.4 }, -- s the walk key stays held before a chance to let go
	releaseP = 0.25, release = { 0.08, 0.35 }, -- chance per hold of letting go, and for how long
	driftEvery = { 8, 15 }, -- cycles between drift events (late start / whiffed swing / overshoot + step back)
	lateStart = { 0.25, 0.7 }, overshoot = { 0.1, 0.16 }, -- s; 0.16 s ≈ 1.1 tiles at 7.2 t/s
	react = { 1, 4 }, -- s before reacting to: stack full -> trip, trees ripening while idle, drop got -> leave
	dropReact = { 0.15, 0.6 }, -- s a new drop lies there before Auto Collect walks to it
	micro = { every = { 20, 60 }, len = { 0.4, 3 } }, -- s
	medium = { every = { 300, 900 }, len = { 8, 45 } }, -- s
	session = { 2400, 7200 }, -- s of running, then every auto mode switches off
	rest = { 60, 120 }, -- s Auto Rotate rests after a session ends, then goes on (user 11-12: max 2 min, was 5-15 min)
	backoff = { clean = { 25, 60 }, slow = 1.15, len = { 180, 480 } }, -- cycles / gap × / s
	fcResume = { 2, 6 }, -- s every auto mode keeps holding after you answer "Are you still there?"
}
local LOGO_ASSET_ID = 135044169500758
local LOGO_ASSET = "rbxthumb://type=Asset&id=" .. LOGO_ASSET_ID .. "&w=150&h=150"
-- Monochrome palette (black / white / grays).
local ACCENT = Color3.fromRGB(240, 240, 240)
local BG = Color3.fromRGB(10, 10, 12)
local SIDEBAR = Color3.fromRGB(15, 15, 17)
local PANEL = Color3.fromRGB(26, 26, 30)
local PANEL2 = Color3.fromRGB(34, 34, 39)
local STROKE = Color3.fromRGB(48, 48, 54)
local TEXT = Color3.fromRGB(238, 238, 240)
local MUTED = Color3.fromRGB(135, 135, 145)

-- Shared runtime state. Lives in getgenv so hooks (installed once per session)
-- keep reading live values across re-runs.
local fb = getgenv().__gtFB or {}
getgenv().__gtFB = fb
if fb.net ~= net then -- hooks and captured sends from a load on another Net copy don't carry over
	fb.net, fb.origTile, fb.hooked2, fb.hooked3, fb.hooked4, fb.realHits = net, nil, nil, nil, nil, nil
end
fb.on = false -- legacy flag read by v1 hooks; keep false so they stay inert
fb.fastOn = false
fb.autoOn = false
fb.pend2 = fb.pend2 or {}
fb.broken = fb.broken or 0
fb.reverts = fb.reverts or 0
fb.lastHit = fb.lastHit or 0
fb.selected = fb.selected or {}
fb.blocked = {} -- "x,y" -> os.clock() until which we skip it (server rejected)
fb.botInput = nil -- path bot: never inherit a running walk from an older run
fb.placeGapTest = nil -- a re-run always goes back to PLACE_GAP
fb.collectT = nil -- Auto Farm pickup step (its thread clears it)
fb.farmCheckOpen = false
fb.gen = (fb.gen or 0) + 1
local myGen = fb.gen

-- ===== Humanizer runtime =====
-- What the server can see of us (Growblox v1033, ByteNet): our own `act` / `tile` packets per
-- hit / place / plant (timing = these gaps), `move` packets the game sends from its physics
-- (15/s moving, 1/s idle; ours only through the MobileControls keys or world.goTo hops), and
-- `take` per pickup. Everything below shapes only those. Off = every function returns the old
-- fixed value, so behaviour is exactly as before.
local human = { on = true, slow = 1, stoppers = {}, status = "" } -- on: matches state.Humanize
do
	human.seed = HUMAN.seed or (os.time() * 1000 + math.floor(os.clock() * 1000)) % 2147483647
	-- Random is a Roblox datatype: works at any thread identity (botFrame runs at identity 2).
	-- Same seed = same sequence of draws; the run itself still depends on ping / world events.
	local rng = Random.new(human.seed)
	local function range(r) return rng:NextNumber(r[1], r[2]) end
	human.range = range
	function human.int(a, b) return rng:NextInteger(a, b) end
	function human.chance(p) return human.on and rng:NextNumber() < p end
	-- base, mostly a little over it, now and then a lot over it (never under: base is the floor)
	function human.gap(base)
		if not human.on then return base end
		if human.slowUntil and os.clock() > human.slowUntil then human.slow, human.slowUntil = 1, nil end
		local n = math.sqrt(-2 * math.log(1 - rng:NextNumber())) * math.cos(2 * math.pi * rng:NextNumber())
		local g = base * (1 + math.abs(n) * HUMAN.jitter)
		if rng:NextNumber() < HUMAN.tailP then
			g += base * math.min((1 - rng:NextNumber()) ^ (-1 / HUMAN.tailAlpha) - 1, HUMAN.tailMax)
		end
		return g * human.slow
	end
	function human.react() return human.on and range(HUMAN.react) or 0 end
	-- Auto Collect: true once drop d has lain there its own reaction time
	function human.seen(d, now)
		if not human.on then return true end
		if not d.seenAt then d.seenAt, d.react = now, range(HUMAN.dropReact) end
		return now - d.seenAt >= d.react
	end
	-- Called by each auto loop between steps. true = a pause is running (skip this step).
	-- Session over = every auto mode is switched off through its registered stopper.
	function human.idle()
		if fb.farmCheckOpen or os.clock() < (fb.fcResumeAt or 0) then -- "Are you still there?": hold
			human.status = fb.farmCheckOpen and "Are you still there? · answer the popup yourself (paused)"
				or "answered · resuming in a moment"
			return true
		end
		if not human.on then return false end
		local now = os.clock()
		if now - (human.lastIdle or -1e9) > 60 then human.endAt = nil end -- nothing ran for 1 min: new session
		human.lastIdle = now
		if now < (human.holdUntil or 0) then return true end
		human.endAt = human.endAt or now + range(HUMAN.session)
		if now >= human.endAt then
			human.endAt = nil
			for _, f in pairs(human.stoppers) do pcall(f, "session over · stopped (humanizer)") end
			return true
		end
		-- Player page "Short & long pauses" (state.HumanPauses, off since 11-11: the user's middle way, ~15%
		-- of the time). Off keeps the jittered gaps, the reject backoff and the session stop above.
		if not human.pauses then return false end
		human.microAt = human.microAt or now + range(HUMAN.micro.every) -- timers restart after each pause
		human.medAt = human.medAt or now + range(HUMAN.medium.every)
		local len
		if now >= human.medAt then
			len, human.medAt, human.microAt = range(HUMAN.medium.len), nil, nil
		elseif now >= human.microAt then
			len, human.microAt = range(HUMAN.micro.len), nil
		end
		if not len then return false end
		human.holdUntil = now + len
		human.status = string.format("pause %.1fs (humanizer)", len)
		return true
	end
	-- One unit of work done (w = weight: a row = 1, a block = 0.1). A server reject since the last
	-- one (hit / place / plant / pull-back; drop takes are range, not behaviour) or N clean units:
	-- every gap × backoff.slow for a while + a medium pause now.
	function human.cycle(w)
		if not human.on then return end
		local now = os.clock()
		local r = fb.reverts + (fb.pullbacks or 0) + (fb.placeRejects or 0) + (fb.plRejects or 0) - (fb.plBurstRej or 0) -- burst refusals are expected
		local hit = human.rej ~= nil and r > human.rej
		human.rej = r
		human.clean = hit and 0 or (human.clean or 0) + (w or 1)
		human.cleanN = human.cleanN or range(HUMAN.backoff.clean)
		if hit or human.clean >= human.cleanN then
			human.clean, human.cleanN = 0, nil
			if human.slow == 1 then human.medAt = now end -- once per backoff
			human.slow, human.slowUntil = HUMAN.backoff.slow, now + range(HUMAN.backoff.len)
		end
		human.driftIn = (human.driftIn or range(HUMAN.driftEvery)) - (w or 1)
	end
	function human.drift() -- true once per driftEvery cycles
		if not human.on or (human.driftIn or 1) > 0 then return false end
		human.driftIn = nil
		return true
	end
	function human.text()
		local now = os.clock()
		if fb.farmCheckOpen then return "paused · answer \"Are you still there?\"" end
		if now < (fb.fcResumeAt or 0) then return "answered · resuming in a moment" end
		if not human.on then return "off · seed " .. human.seed end
		local p = (human.holdUntil or 0) > now and string.format("paused %.0fs", human.holdUntil - now)
		local e = human.endAt and string.format(" · stop in %dm", math.ceil((human.endAt - now) / 60)) or ""
		return string.format("%s · gaps ×%.2f%s · seed %d", p or "on", human.slow, e, human.seed)
	end
	-- Hit cooldown shared by every hitter: the drawn gap, and never under HIT_GAP after any hit
	-- (fb.lastHit is also stamped by the act.send hook for your manual punches).
	local function hitReadyAt() return math.max(fb.hitAt or 0, fb.lastHit + HIT_GAP) end
	function human.hitReady() return os.clock() >= hitReadyAt() end
	function human.hitWait()
		local wait = hitReadyAt() - os.clock()
		if wait > 0 then task.wait(wait) end
	end
	function human.hitDone(base) -- base: a slower floor than HIT_GAP for this hit (harvest)
		fb.lastHit = os.clock()
		fb.hitAt = fb.lastHit + human.gap(base or HIT_GAP)
	end
end
fb.human = human -- for in-client checks (get-data-by-code)

-- FarmCheck (v1045): the server's "Are you still there?" popup (PlayerGui.FarmCheckGui, enabled by the
-- game's own FarmCheck LocalScript). While it's open every auto mode holds (human.idle, sweeps, trips,
-- hits) and you get a notification. The script never answers it: it's a check that a person is
-- there, so a person answers it. You answer -> the game hides it -> modes hold fcResume more, then go on.
-- Each check is logged, since the server side can't be seen: when it came, what it asked, how long
-- it gave, how long you took (late = after its timer). Kept in fb.fcLog and saved to
-- growblox_farmcheck_log.json in the executor workspace.
do
	local loaded = os.clock()
	fb.fcLog = fb.fcLog or {}
	local check -- the check on screen: { at, t, kind, secs, runMin }
	pcall(function() -- an extra listener next to the game's own (Net.on adds, it never replaces)
		-- v1045: (item ids, wanted id, secs) = "tap the item"; v1047: (_, _, secs, "math", question)
		-- = a spoken sum you type the answer to. secs is 3rd in both.
		net.on("FarmCheck", function(a, _, secs, kind)
			if fb.gen ~= myGen then return end
			check = {
				at = os.time(), t = os.clock(), secs = tonumber(secs),
				kind = type(a) == "table" and "tap item" or tostring(kind or "?"),
				runMin = math.floor((os.clock() - loaded) / 60),
			}
		end, function() return fb.world and fb.world.name or "" end)
	end)
	local function logAnswered()
		if not check then return end
		local took = os.clock() - check.t
		local e = { at = check.at, kind = check.kind, secs = check.secs, runMin = check.runMin,
			tookS = math.floor(took * 10) / 10, late = check.secs ~= nil and took > check.secs }
		check = nil
		table.insert(fb.fcLog, e)
		pcall(writefile, "growblox_farmcheck_log.json", game:GetService("HttpService"):JSONEncode(fb.fcLog))
	end
	function human.fcText()
		local n, last = #fb.fcLog, fb.fcLog[#fb.fcLog]
		if fb.farmCheckOpen then return string.format("on screen now · %d before", n) end
		if not last then return "none yet" end
		return string.format("%d · last: %s, answered in %.0fs%s", n, last.kind or "?", last.tookS, last.late and " (late)" or "")
	end
	local function watch(gui)
		local function sync()
			if fb.gen ~= myGen then return end
			-- v1045: the ScreenGui itself (child "Panel") is the popup, Enabled = shown. v1047: the
			-- ScreenGui is always enabled and a Panel-module layer "FarmCheck" inside it is shown /
			-- hidden. Neither child yet (the game is still building it) = not open.
			local layer, old = gui:FindFirstChild("FarmCheck"), gui:FindFirstChild("Panel")
			local open = gui.Enabled and ((layer ~= nil and layer.Visible) or (old ~= nil and layer == nil))
			if not open and fb.farmCheckOpen then -- answered: log it, hold a little longer
				logAnswered()
				fb.fcResumeAt = os.clock() + human.range(HUMAN.fcResume)
			end
			if open and not fb.farmCheckOpen then
				pcall(function()
					game:GetService("StarterGui"):SetCore("SendNotification", {
						Title = "Are you still there?",
						Text = "Auto modes paused. Answer the popup yourself to go on.",
						Duration = 15,
					})
				end)
			end
			fb.farmCheckOpen = open
		end
		gui:GetPropertyChangedSignal("Enabled"):Connect(sync)
		local function hook(c)
			if c:IsA("GuiObject") then c:GetPropertyChangedSignal("Visible"):Connect(sync) end
			sync()
		end
		for _, c in ipairs(gui:GetChildren()) do hook(c) end
		gui.ChildAdded:Connect(hook)
		sync()
	end
	local pg = players.LocalPlayer:WaitForChild("PlayerGui")
	if pg:FindFirstChild("FarmCheckGui") then watch(pg.FarmCheckGui) end
	pg.ChildAdded:Connect(function(c)
		if fb.gen == myGen and c.Name == "FarmCheckGui" then watch(c) end
	end)
end

-- Real hit counts, captured once (before we ever patch ItemDB).
if not fb.realHits then
	fb.realHits = {}
	for id, it in pairs(itemDB) do
		if type(it) == "table" and type(it.hits) == "number" and it.hits > 1 then
			fb.realHits[id] = it.hits
		end
	end
end

local function findWorld()
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and type(rawget(t, "fg")) == "table" and rawget(t, "bg") and rawget(t, "w") then
			return t
		end
	end
end

local function setPatched(on)
	for id, h in pairs(fb.realHits) do
		itemDB[id].hits = on and 1 or h
	end
end
setPatched(false) -- clean slate on re-run
fb.world = findWorld() or fb.world -- getgc can miss it transiently; never drop a good ref

-- Real hits needed for an item id, or nil if we shouldn't/can't break it. Mirrors the client's hit path
-- (Game v1210 / v1348): seeds (growing trees) 20; a worn item with `dig` (Pickaxe, ...) = ×6/8 rounded
-- up for the rest (4 -> 3, 2 stays 2); the OneHitUntil buff (a server time) = 1 hit, except locks,
-- areas, vends, displays and world keys. handPower is always 1 there, so no damage gear to count.
local function hitsFor(id)
	local it = itemDB[id]
	if not it or it.lock or it.area then return nil end
	if it.kind == "seed" then return 20 end
	local h = fb.realHits[id] or it.hits
	if type(h) ~= "number" or h <= 0 then return nil end
	local ok, dig = pcall(function() return fb.avatar and fb.avatar.handDig() or 0 end)
	if ok and (tonumber(dig) or 0) > 0 then h = math.max(1, math.ceil(h * 6 / 8 - 1e-6)) end
	if not (it.guildLock or it.vend or it.display or it.displayOne or it.worldKey)
		and (players.LocalPlayer:GetAttribute("OneHitUntil") or 0) > workspace:GetServerTimeNow() then
		h = 1
	end
	return h
end

-- One hit = hit + punch packets, respecting the global cooldown.
-- Where the real client's punch packet (act kind 1) aims: your cursor, wherever on the tile you
-- clicked. v1159 packet log (manual break / place / plant / harvest): hit (6), build (2) and plant (3)
-- sit on the tile center; only the punch (1) carries the cursor offset. Every gated send (act, tile,
-- drop, take, ...) is followed by Net's own seq {n} packet (Net.lua ~2425 wraps send), ours included.
local function aim(x, y)
	return x + 0.5 + human.range({ -0.32, 0.32 }), y + 0.5 + human.range({ -0.32, 0.32 })
end

-- mid(): the breaking hit's tile packet. The real client sends it between that hit's kind 6 and its
-- punch (v1159 packet log: act 6, tile id 0, act 1).
local function hitTile(x, y, mid)
	human.hitWait()
	net.act.send({ kind = 6, x = x + 0.5, y = y + 0.5 })
	if mid then mid() end
	local ax, ay = aim(x, y)
	net.act.send({ kind = 1, x = ax, y = ay })
	human.hitDone()
end

-- The game's own tile packet (its setTile sends exactly this). Captured once per session,
-- before Fast Break wraps net.tile.send.
fb.origTile = fb.origTile or net.tile.send
local function sendTile(layer, x, y, id)
	fb.origTile({ layer = layer == "bg" and 2 or 1, x = x, y = y, id = id, flip = false })
end

-- Send the break, then run the game's own tileChanged locally so the tile disappears
-- on screen (server doesn't echo successful breaks to us).
local function finishBreak(layer, x, y, localToo)
	fb.pend2[x .. "," .. y] = os.clock()
	fb.broken += 1
	sendTile(layer, x, y, 0)
	if localToo then fb.world.tileChanged(layer, x, y, 0) end
end

if not fb.hooked2 then
	fb.hooked2 = true
	-- Stamp every game hit (kind 6) so our cooldown accounts for manual punches,
	-- and grab our position from the game's own move packets.
	local origAct, origMove = net.act.send, net.move.send
	net.act.send = function(d)
		if d.kind == 6 then fb.lastHit = os.clock() end
		return origAct(d)
	end
	net.move.send = function(d)
		fb.pos = d
		return origMove(d)
	end
end
-- v973 hooks (own guard: sessions that ran the v714 build already have hooked2).
if not fb.hooked3 then
	fb.hooked3 = true
	-- Fast Break: game thinks block is 1 hit and sends the break tile packet right after
	-- its first hit (before clearing the tile locally); swallow it and pad the real hits first.
	net.tile.send = function(d)
		if fb.fastOn and d.id == 0 then
			local layer = d.layer == 2 and "bg" or "fg"
			local grid = fb.world and fb.world[layer]
			local cur = grid and grid[d.y] and grid[d.y][d.x]
			local n = cur and fb.realHits[cur]
			if n then
				task.spawn(function()
					local brk = function() finishBreak(layer, d.x, d.y, false) end -- game already cleared it locally
					for i = 2, n do hitTile(d.x, d.y, i == n and brk) end
					if n < 2 then brk() end
				end)
				return
			end
		end
		return fb.origTile(d)
	end
	-- Rejected break: server echoes the old id back (ByteNet tileChanged since v973).
	net.tileChanged.listen(function(d)
		local x, y, id = d.x, d.y, d.id
		if id == 0 then return end
		local k = x .. "," .. y
		local t = fb.pend2[k]
		if t then
			fb.pend2[k] = nil
			if os.clock() - t < 3 then
				fb.reverts += 1
				fb.blocked[k] = os.clock() + 10
			end
		end
	end)
end

-- Can we hit tile (x, y) standing with feet at (px, py)? Either the server reach verified live
-- (REACH from your feet, v714), or the game's own punch rule (Game.lua input: a box of
-- punchRange() = 2.5 + the best worn `reach`, e.g. Cyclopean Visor +1, around your body center
-- (px, py - 0.475)) - exactly what a normal client sends, diagonals included (~4.9 at 3.5).
-- fb.punchRange is refreshed by the live updater.
local function canHit(x, y, px, py)
	local dx = x + 0.5 - px
	local r = fb.punchRange or 2.5
	return math.abs(dx) <= r and math.abs(y + 0.5 - (py - 0.475)) <= r
end

-- Nearest selected tile we can hit: {layer, x, y, id}, + how many there are. fg wins; bg only
-- when fg is empty.
local function pickTarget()
	local w, p = fb.world, fb.pos
	if not (w and p) then return nil, 0 end
	local px, py = p.x, p.y
	local best, bestD, n = nil, nil, 0
	local now = os.clock()
	for y = math.floor(py) - REACH - 1, math.floor(py) + REACH + 1 do
		local fgRow, bgRow = w.fg[y], w.bg[y]
		if fgRow then
			for x = math.floor(px) - REACH - 1, math.floor(px) + REACH + 1 do
				local f = fgRow[x]
				local layer, id
				if f and f ~= 0 then
					if fb.selected[f] then layer, id = "fg", f end
				elseif bgRow and bgRow[x] and fb.selected[bgRow[x]] then
					layer, id = "bg", bgRow[x]
				end
				if layer then
					local k = x .. "," .. y
					if canHit(x, y, px, py) and not (fb.blocked[k] and fb.blocked[k] > now) and hitsFor(id) then
						n += 1
						local d = (x + 0.5 - px) ^ 2 + (y + 0.5 - py) ^ 2
						if not bestD or d < bestD then best, bestD = { layer = layer, x = x, y = y, id = id }, d end
					end
				end
			end
		end
	end
	return best, n
end

-- Block ids present in the world (fg + bg) -> count.
local function worldCounts()
	local counts = {}
	local w = fb.world
	if not w then return counts end
	for _, layer in ipairs({ "fg", "bg" }) do
		for _, row in pairs(w[layer]) do
			for _, id in pairs(row) do
				if id ~= 0 then counts[id] = (counts[id] or 0) + 1 end
			end
		end
	end
	return counts
end

-- Auto Collect helpers. The game's drop list ({uid,id,n,x,y,armed,taking,...}): v1159 world.dropList()
-- (= addDrop's 3rd upvalue, behind the dropAdded packet); before, the 1st upvalue of the DropTaken
-- remote's handler (v1159 gave every WorldRemote a random name). Cleared in place on world change.
local function findDrops()
	local w = fb.world or findWorld()
	local ok, list = pcall(function() return w.dropList() end)
	if ok and type(list) == "table" then return list end
	local old = worldRemotes:FindFirstChild("DropTaken")
	for _, c in ipairs(old and getconnections(old.OnClientEvent) or {}) do
		local ok2, l = pcall(function() return debug.getupvalues(c.Function)[1] end)
		if ok2 and type(l) == "table" then return l end
	end
end

-- Player API (Game.lua t154): .state() -> {x, y (feet), vx, vy, grounded, dead, ...},
-- .solidAt(x, y), HW = 0.3, H = 0.95. Matched by those static fields: calling state()
-- during the scan was flaky at script load.
local function findPlayer()
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and rawget(t, "HW") == 0.3 and type(rawget(t, "state")) == "function"
			and type(rawget(t, "solidAt")) == "function" then
			return t
		end
	end
end
-- Client inventory (Shared.Inventory instance): {slots={{id,n}}, capacity} + :count/:add/:remove/:room.
local function findInventory()
	for _, t in ipairs(getgc(true)) do
		-- needs the methods: GetInventory replies are plain {slots, capacity} tables too
		if type(t) == "table" and type(rawget(t, "slots")) == "table" and type(rawget(t, "capacity")) == "number"
			and getmetatable(t) and type(t.count) == "function" and type(t.remove) == "function" then
			return t
		end
	end
end

-- Place a block exactly like the game's build path: SetTile + build act + take it out of the
-- client inventory (SaveInventory sends the whole bag, so it must match), then replay
-- TileChanged locally so it shows (server doesn't echo our own edits).
-- Verified v889: a place 30ms after the last hit+break and a 2nd place 50ms after the 1st were
-- both accepted, so places don't share the hit cooldown. We use the client UI's own 0.15.
local PLACE_GAP = 0.3 -- v1225 refuses places 0.15s apart ("placing too fast"); one farm reject 11-10 with places 0.18s apart
local function placeTile(layer, x, y, id, gap) -- gap: an already drawn human.gap(PLACE_GAP) (Row Farm)
	local wait = (gap or human.gap(fb.placeGapTest or PLACE_GAP)) - (os.clock() - (fb.lastPlace or 0)) -- placeGapTest: live place-gap test only
	if wait > 0 then task.wait(wait) end
	sendTile(layer, x, y, id)
	net.act.send({ kind = 2, x = x + 0.5, y = y + 0.5 }) -- v1159 client: the build act sits on the tile center
	fb.inv:remove(id, 1)
	fb.lastPlace = os.clock()
	fb.pend2[x .. "," .. y] = nil -- the local update below isn't a rejected break
	fb.world.tileChanged(layer, x, y, id)
end
-- Copy the server's bag into the client bag via GetInventory (safe read) + the game's own
-- InventorySync handler. Waits out in-flight pickups first so they aren't counted twice.
local function resyncBag()
	local t0 = os.clock()
	while os.clock() - t0 < 2 do
		local busy = false
		for _, d in ipairs(fb.drops or {}) do
			if d.taking then busy = true break end
		end
		if not busy then break end
		task.wait(0.05)
	end
	local ok, r = pcall(net.call, "GetInventory") -- the game's own load-time read (Game.lua line 31)
	if not (ok and type(r) == "table" and type(r.slots) == "table") then return false end
	-- the game's own InventorySync handler: v1159 a Net.on wrapper on the inventorySync packet (Net
	-- source; the handler is its 4th upvalue); before, a connection on the InventorySync remote
	local fired = false
	for _, h in pairs(net.inventorySync and net.inventorySync.getListeners() or {}) do
		local f = debug.info(h, "s") == debug.info(net.on, "s") and debug.getupvalues(h)[4] -- a Net.on wrapper
		if type(f) == "function" then fired = pcall(f, r.slots, r.capacity) or fired end
	end
	local old = not fired and worldRemotes:FindFirstChild("InventorySync")
	for _, c in ipairs(old and getconnections(old.OnClientEvent) or {}) do
		pcall(c.Fire, c, r.slots, r.capacity)
	end
	return true
end

-- Seed of a block: id + 1 by convention (954 Sugar Cane -> 955 Sugar Cane Seed), checked by name.
local function seedOf(id)
	local s, it = itemDB[id + 1], itemDB[id]
	return s and it and s.kind == "seed" and s.name == it.name .. " Seed" and id + 1 or nil
end

-- getgc scans can miss transiently; cache at load so a toggle doesn't hinge on one scan
fb.inv = findInventory() or fb.inv
fb.player = findPlayer() or fb.player
fb.drops = findDrops() or fb.drops

-- Your gem count, read locally: the HUD's own counter = 1st upvalue of ChatUI's setGems (addGems /
-- setGems keep it current). Never menuApi.gems(): that's a server call (GetGems), and v1131 kicks
-- for too many of those: "Kicked for sending the game too much at once (stats)" (267) - the bot
-- used to ask it every frame while walking to gems, Auto Farm's gems/h every 0.3s.
-- The table is found by getgc (identity 8: at load, or from any of our own threads), then only read.
function fb.gemsNow()
	if not fb.gemsFn then
		for _, t in pairs(getgc(true)) do
			if type(t) == "table" and type(rawget(t, "setGems")) == "function" and type(rawget(t, "addGems")) == "function" then
				fb.gemsFn = t.setGems
				break
			end
		end
	end
	local ok, n = pcall(function() return debug.getupvalues(fb.gemsFn)[1] end)
	return ok and type(n) == "number" and n or nil
end
fb.gemsFn = nil -- a re-run looks again (the HUD may have been rebuilt)
fb.gemsNow()

fb.collected = fb.collected or 0
fb.dropSkip = {} -- uid -> os.clock() until which we leave it alone
fb.farmSeeds = fb.farmSeeds or {} -- seed ids of blocks Auto Farm placed (Auto Drop watches these)

-- Our stashes (Auto Farm's seed pile, Auto Harvest's drop spot): never pull them back in. A stash
-- spreads over sp.n tiles outward (sp.x + dir .. sp.x + n * dir) once a tile is full (dropStack).
-- fb.piles: every tile a stash ever went on (dropStack). 11-13, a tester: the auto spot filled up, a
-- new one was picked, the old pile lost its guard and the bot walked through it, took the 200 back,
-- dropped them on the new spot, walked back through the old one... So old piles stay guarded too.
fb.piles = fb.piles or {}
function fb.notePile(x, y)
	local wn = fb.world and fb.world.name
	for _, p in ipairs(fb.piles) do
		if p.world == wn and p.x == x and p.y == y then return end
	end
	table.insert(fb.piles, { world = wn, x = x, y = y })
	if #fb.piles > 200 then table.remove(fb.piles, 1) end -- ponytail: oldest out, plenty for a session
end
-- Plus any tile holding 100+ items (a drop of 100+, or several adding up; gems aside): a stash,
-- whoever's. 11-14: after a re-run fb.piles is empty, so the 200s by the door read as strays and
-- Auto Harvest kept walking onto them. Tree strays are a few items each, far under 100.
local function inPile(d)
	if (d.n or 0) >= 100 then return true end
	local x, sum = math.floor(d.x), 0
	for _, o in ipairs(fb.drops or {}) do -- ponytail: O(drops) per call, fine for a few hundred drops
		if o.id ~= 112 and math.floor(o.x) == x and math.abs(o.y - d.y) < 1 then
			sum += o.n or 0
			if sum >= 100 then return true end
		end
	end
	for _, p in ipairs(fb.piles) do
		if fb.world and p.world == fb.world.name and math.floor(d.x) == p.x and math.abs(d.y - (p.y + 0.5)) < 1.5 then
			return true
		end
	end
	for _, sp in pairs({ fb.dropSpot, fb.hvSpot, fb.rowSpot }) do
		local i = (math.floor(d.x) - sp.x) * sp.dir
		if fb.world and sp.world == fb.world.name and i >= 1 and i <= (sp.n or 1)
			and math.abs(d.y - (sp.y + 0.5)) < 1.5 then
			return true
		end
	end
	return false
end
-- Someone's items (any id not in ids; gems aside) lying on tile x, y: a pile never goes on top of
-- them (your own block stash near the door, another seed's pile).
function fb.othersAt(x, y, ids)
	for _, d in ipairs(fb.drops or {}) do
		if d.id ~= 112 and math.floor(d.x) == x and math.abs(d.y - (y + 0.5)) < 0.8
			and not (ids and table.find(ids, d.id)) then return true end
	end
	return false
end

-- Hazard flags, read client-side from ItemDB (Game.lua): hurts (lava), deadly (death spikes),
-- bumper / bouncy (pinball), slippery (ice). Older runs could clear them (Anti Lava / Spike /
-- Pinball / Ice, all removed: they change what the server simulates), so every flag is captured
-- once per session and restored on load.
fb.realFlags = fb.realFlags or { hurts = fb.realHurts } -- realHurts: captured by older runs
for _, flag in ipairs({ "hurts", "deadly", "bumper", "bouncy", "slippery" }) do
	if not fb.realFlags[flag] then -- capture once per session, before we ever clear it
		local real = {}
		for id, it in pairs(itemDB) do
			if type(it) == "table" and it[flag] then real[id] = it[flag] end
		end
		fb.realFlags[flag] = real
	end
end
local function restoreHazards() -- every captured flag back to the game's value
	for flag, real in pairs(fb.realFlags) do
		for id, v in pairs(real) do itemDB[id][flag] = v end
	end
end
restoreHazards() -- clean slate on re-run

-- Wingless Double Jump was removed (an air jump without wings is visible to the server). An older
-- run may have flagged a worn item doubleJump = "plain": un-flag it (only items that had none).
for id in pairs(fb.djPatched or {}) do itemDB[id].doubleJump = nil end
fb.djPatched = nil

-- State.
local state = {
	FastBreak = false,
	AutoBreak = false,
	BreakWalk = false,
	AutoCollect = false,
	AutoFarm = false,
	AutoHarvest = false,
	AutoPlant = false,
	FarmFetch = false,
	FarmDrop = false,
	RowFarm = false,
	RowFetch = false,
	RowDrop = false,
	RotRow = false, -- Auto Rotate's farm phase: Row Farm instead of Auto Farm
	PathLeave = false,
	Humanize = true, -- matches human.on
	HumanPauses = false, -- humanizer micro / medium pauses (off = the user's middle way, 11-11)
	PlantBurst = true, -- Auto Plant at the client's pace, resting on "too fast" (the user's choice, 11-11)
	DoorHover = false,
	DoorTags = false,
	UltimateFPS = false,
	BlankScreen = false,
	AutoRotate = false,
	AntiIdle = true, -- Roblox's 20 min idle kick (278): the bots' input doesn't count as activity
}
-- Re-run: the older run's switches all go off at once (its loops and in-flight trips / sweeps
-- check them and end), so two runs never drive the bot together.
if fb.state then for k in pairs(fb.state) do fb.state[k] = false end end
fb.state = state

-- Clean up any previous instance of this GUI.
if getgenv().__growtopiaGui then
	pcall(function() getgenv().__growtopiaGui:Destroy() end)
end

-- Root ScreenGui. Parented to PlayerGui (see CLAUDE.md gotcha #1).
local playerGui = players.LocalPlayer:WaitForChild("PlayerGui")
-- v1208: the game renames GameGui.World and everything in it at runtime, so go by shape: World > full-size
-- Frame holding a UIScale (the camera) > its zero-size Frame with the most children (the tile layer).
local worldFrame, tilesLayer
for _ = 1, 60 do -- built by the game's code, so it can be missing for as long as the modules above
	for _, w in ipairs(playerGui:WaitForChild("GameGui"):GetChildren()) do
		for _, cam in ipairs(w:IsA("Frame") and w:GetChildren() or {}) do
			if cam:IsA("Frame") and cam.Size == UDim2.fromScale(1, 1) and cam:FindFirstChildOfClass("UIScale") then
				for _, t in ipairs(cam:GetChildren()) do
					if t:IsA("Frame") and t.Size == UDim2.new() and (not tilesLayer or #t:GetChildren() > #tilesLayer:GetChildren()) then
						worldFrame, tilesLayer = w, t
					end
				end
			end
		end
	end
	if tilesLayer then break end
	task.wait(1)
end
assert(tilesLayer, "Growblox: the game's world view wasn't found")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "GrowtopiaAF"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 50
screenGui.Parent = playerGui
getgenv().__growtopiaGui = screenGui

-- Rounded-corner helper.
local function corner(inst, r)
	local c = Instance.new("UICorner", inst)
	c.CornerRadius = UDim.new(0, r or 8)
	return c
end

-- ===== Main window: rounded dark shell =====
local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(640, 568) -- 11 nav entries (40 + 4 each) fit the sidebar
main.Position = UDim2.new(0.5, -320, 0.5, -284)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = screenGui
corner(main, 14)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = STROKE
mainStroke.Thickness = 1
mainStroke.Transparency = 0.3

-- ===== Title bar (drag region + window controls) =====
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 52)
titleBar.BackgroundTransparency = 1
titleBar.Parent = main

local logo = Instance.new("ImageLabel")
logo.Size = UDim2.fromOffset(36, 36)
logo.Position = UDim2.fromOffset(16, 8)
logo.BackgroundTransparency = 1
logo.Image = LOGO_ASSET
logo.ScaleType = Enum.ScaleType.Fit
logo.Parent = titleBar

local function controlBtn(char, xOff, cb)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(28, 28)
	b.Position = UDim2.new(1, xOff, 0, 12)
	b.BackgroundTransparency = 1
	b.Font = Enum.Font.GothamMedium
	b.Text = char
	b.TextColor3 = MUTED
	b.TextSize = 16
	b.AutoButtonColor = false
	b.Parent = titleBar
	b.MouseEnter:Connect(function() b.TextColor3 = TEXT end)
	b.MouseLeave:Connect(function() b.TextColor3 = MUTED end)
	if cb then b.MouseButton1Click:Connect(cb) end
	return b
end
-- Floating logo shown when the panel is closed; click it to reopen.
local floatingLogo = Instance.new("ImageButton")
floatingLogo.Name = "FloatingLogo"
floatingLogo.Size = UDim2.fromOffset(56, 56)
floatingLogo.Position = UDim2.fromOffset(24, 24)
floatingLogo.BackgroundColor3 = PANEL
floatingLogo.BorderSizePixel = 0
floatingLogo.Image = LOGO_ASSET
floatingLogo.ScaleType = Enum.ScaleType.Fit
floatingLogo.AutoButtonColor = false
floatingLogo.Visible = false
floatingLogo.Active = true
floatingLogo.Draggable = true
floatingLogo.Parent = screenGui
corner(floatingLogo, 12)
local floatStroke = Instance.new("UIStroke", floatingLogo)
floatStroke.Color = STROKE
floatStroke.Thickness = 1
floatStroke.Transparency = 0.3
local floatPad = Instance.new("UIPadding", floatingLogo)
floatPad.PaddingTop = UDim.new(0, 8); floatPad.PaddingBottom = UDim.new(0, 8)
floatPad.PaddingLeft = UDim.new(0, 8); floatPad.PaddingRight = UDim.new(0, 8)
floatingLogo.MouseEnter:Connect(function() floatingLogo.BackgroundColor3 = PANEL2 end)
floatingLogo.MouseLeave:Connect(function() floatingLogo.BackgroundColor3 = PANEL end)

-- Single source of truth for panel visibility.
local function setShown(shown)
	main.Visible = shown
	floatingLogo.Visible = not shown
end

controlBtn("✕", -36, function() setShown(false) end)
floatingLogo.MouseButton1Click:Connect(function() setShown(true) end)

-- ===== Sidebar =====
local sidebar = Instance.new("Frame")
sidebar.Size = UDim2.new(0, 196, 1, -60)
sidebar.Position = UDim2.fromOffset(8, 52)
sidebar.BackgroundColor3 = SIDEBAR
sidebar.BorderSizePixel = 0
sidebar.Parent = main
corner(sidebar, 12)

local navList = Instance.new("ScrollingFrame") -- 12 entries no longer fit the sidebar
navList.Size = UDim2.new(1, -20, 1, -20)
navList.Position = UDim2.fromOffset(10, 10)
navList.BackgroundTransparency = 1
navList.BorderSizePixel = 0
navList.ScrollBarThickness = 2
navList.ScrollBarImageColor3 = STROKE
navList.CanvasSize = UDim2.new()
navList.AutomaticCanvasSize = Enum.AutomaticSize.Y
navList.Parent = sidebar
local navLayout = Instance.new("UIListLayout", navList)
navLayout.Padding = UDim.new(0, 4)
navLayout.SortOrder = Enum.SortOrder.LayoutOrder

-- ===== Content area (one scrolling page per nav entry) =====
local contentArea = Instance.new("Frame")
contentArea.Size = UDim2.new(1, -220, 1, -64)
contentArea.Position = UDim2.fromOffset(212, 56)
contentArea.BackgroundTransparency = 1
contentArea.Parent = main

-- ===== Page / navigation system =====
local pages = {}
local navButtons = {}
local activePage

local function makePage(name)
	local page = Instance.new("ScrollingFrame")
	page.Name = name
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 3
	page.ScrollBarImageColor3 = STROKE
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.Visible = false
	page.Parent = contentArea
	local l = Instance.new("UIListLayout", page)
	l.Padding = UDim.new(0, 12)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	local p = Instance.new("UIPadding", page)
	p.PaddingRight = UDim.new(0, 8)
	p.PaddingBottom = UDim.new(0, 10)
	pages[name] = page
	return page
end

local function selectPage(name)
	activePage = name
	for pname, pg in pairs(pages) do
		pg.Visible = (pname == name)
	end
	for nname, btn in pairs(navButtons) do
		local on = (nname == name)
		btn.BackgroundColor3 = on and PANEL2 or SIDEBAR
		btn.BackgroundTransparency = on and 0 or 1
		btn.TextColor3 = on and TEXT or MUTED
		btn.Dot.BackgroundTransparency = on and 0 or 1
	end
end

local function makeNav(icon, name, order)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 40)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = PANEL2
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.Parent = navList
	corner(btn, 8)

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.Size = UDim2.fromOffset(5, 5)
	dot.Position = UDim2.fromOffset(6, 18)
	dot.BackgroundColor3 = TEXT
	dot.BackgroundTransparency = 1
	dot.BorderSizePixel = 0
	dot.Parent = btn
	corner(dot, 3)

	local ico = Instance.new("TextLabel")
	ico.Size = UDim2.fromOffset(24, 40)
	ico.Position = UDim2.fromOffset(16, 0)
	ico.BackgroundTransparency = 1
	ico.Font = Enum.Font.GothamMedium
	ico.Text = icon
	ico.TextColor3 = TEXT
	ico.TextSize = 15
	ico.Parent = btn
	btn.TextColor3 = MUTED

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -52, 1, 0)
	lbl.Position = UDim2.fromOffset(48, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamMedium
	lbl.Text = name
	lbl.TextColor3 = TEXT
	lbl.TextSize = 14
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = btn
	btn:GetPropertyChangedSignal("TextColor3"):Connect(function()
		ico.TextColor3 = btn.TextColor3
		lbl.TextColor3 = btn.TextColor3
	end)

	navButtons[name] = btn
	btn.MouseButton1Click:Connect(function() selectPage(name) end)
	btn.MouseEnter:Connect(function()
		if activePage ~= name then btn.BackgroundTransparency = 0.6; btn.BackgroundColor3 = PANEL end
	end)
	btn.MouseLeave:Connect(function()
		if activePage ~= name then btn.BackgroundTransparency = 1 end
	end)
	return btn
end

local function makeSection(page, text, order)
	local h = Instance.new("TextLabel")
	h.Size = UDim2.new(1, 0, 0, 22)
	h.LayoutOrder = order
	h.BackgroundTransparency = 1
	h.Font = Enum.Font.GothamBold
	h.Text = text
	h.TextColor3 = TEXT
	h.TextSize = 15
	h.TextXAlignment = Enum.TextXAlignment.Left
	h.Parent = page
	return h
end

-- Card-style toggle row. Flips state[key], then calls onChange(newValue) if
-- given; onChange may return false to veto (switch snaps back).
fb.toggleSet = {} -- key -> set(on), this run's switches
local function makeToggle(page, titleText, descText, order, key, onChange)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 66)
	row.LayoutOrder = order
	row.BackgroundColor3 = PANEL
	row.BorderSizePixel = 0
	row.Parent = page
	corner(row, 10)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -90, 0, 20)
	title.Position = UDim2.fromOffset(18, 14)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = titleText
	title.TextColor3 = TEXT
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local desc = Instance.new("TextLabel")
	desc.Size = UDim2.new(1, -90, 0, 16)
	desc.Position = UDim2.fromOffset(18, 34)
	desc.BackgroundTransparency = 1
	desc.Font = Enum.Font.Gotham
	desc.Text = descText
	desc.TextColor3 = MUTED
	desc.TextSize = 12
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.Parent = row

	local switch = Instance.new("TextButton")
	switch.Size = UDim2.fromOffset(50, 26)
	switch.Position = UDim2.new(1, -68, 0.5, -13)
	switch.BackgroundColor3 = PANEL2
	switch.Text = ""
	switch.AutoButtonColor = false
	switch.Parent = row
	corner(switch, 13)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(20, 20)
	knob.Position = UDim2.fromOffset(3, 3)
	knob.BackgroundColor3 = MUTED
	knob.BorderSizePixel = 0
	knob.Parent = switch
	corner(knob, 10)

	local function render()
		local on = state[key]
		switch.BackgroundColor3 = on and ACCENT or PANEL2
		knob.BackgroundColor3 = on and Color3.fromRGB(20, 20, 20) or MUTED
		if not knob:IsDescendantOf(game) then return end -- an older run's GUI (destroyed): tween errors
		knob:TweenPosition(
			UDim2.fromOffset(on and 27 or 3, 3),
			Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.15, true
		)
	end

	local function flip()
		state[key] = not state[key]
		if onChange and onChange(state[key]) == false then
			state[key] = not state[key]
		end
		render()
		if fb.saveCfg then pcall(fb.saveCfg) end -- settings + Auto Rotate progress: growblox_auto.json
	end
	switch.MouseButton1Click:Connect(flip)
	-- = clicking it (rejoin). `not` both sides: a key with no default in `state` is nil, and nil ~= false
	-- flipped it ON (11-14: No drop / Dirt wall saved off came back on every autoexec)
	fb.toggleSet[key] = function(on) if not state[key] ~= not on then flip() end end
	render()
	return render -- for code that flips state[key] itself
end

local function makeInfoCard(page, titleText, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 58)
	row.LayoutOrder = order
	row.BackgroundColor3 = PANEL
	row.BorderSizePixel = 0
	row.Parent = page
	corner(row, 10)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(0.6, -18, 1, 0)
	title.Position = UDim2.fromOffset(18, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamMedium
	title.Text = titleText
	title.TextColor3 = MUTED
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local value = Instance.new("TextLabel")
	value.Size = UDim2.new(0.4, -18, 1, 0)
	value.Position = UDim2.new(0.6, 0, 0, 0)
	value.BackgroundTransparency = 1
	value.Font = Enum.Font.GothamBold
	value.Text = "-"
	value.TextColor3 = TEXT
	value.TextSize = 15
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row
	return value
end

-- Full-width action button (light on dark).
local function makeButton(page, labelText, order, callback)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 42)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = ACCENT
	btn.Text = labelText
	btn.Font = Enum.Font.GothamBold
	btn.TextColor3 = Color3.fromRGB(20, 20, 20)
	btn.TextSize = 14
	btn.AutoButtonColor = true
	btn.Parent = page
	corner(btn, 10)
	btn.MouseButton1Click:Connect(function() pcall(callback) end)
	return btn
end

-- Search box card (PANEL, same look as the other cards). Returns the TextBox.
local function makeSearchBox(page, placeholder, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.LayoutOrder = order
	row.BackgroundColor3 = PANEL
	row.BorderSizePixel = 0
	row.Parent = page
	corner(row, 10)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, -36, 1, 0)
	box.Position = UDim2.fromOffset(18, 0)
	box.BackgroundTransparency = 1
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.GothamMedium
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = MUTED
	box.Text = ""
	box.TextColor3 = TEXT
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = row
	return box
end

-- ===== Pages =====
makeNav("⛏", "Break", 1)
makeNav("◎", "Auto Break", 2)
makeNav("✦", "Collect", 3)
makeNav("❖", "Auto Farm", 4)
makeNav("▤", "Row Farm", 5)
makeNav("✿", "Harvest", 6)
makeNav("❦", "Plant", 7)
makeNav("➜", "Path", 8)
makeNav("◆", "Player", 9)
makeNav("▣", "Doors", 10)
makeNav("◐", "Rotate", 11) -- ↻ has no glyph in the nav font
local breakPage = makePage("Break")
local autoPage = makePage("Auto Break")
local collectPage = makePage("Collect")
local farmPage = makePage("Auto Farm")
makePage("Row Farm") -- pages["Row Farm"], filled in the Row Farm section
local harvestPage = makePage("Harvest") -- filled in the Auto Harvest section (needs the path bot)
makePage("Plant") -- pages.Plant, filled in the same section (no new main-chunk local: near Luau's limit)
local pathPage = makePage("Path")
local playerPage = makePage("Player")
local doorsPage = makePage("Doors")
makePage("Rotate") -- pages.Rotate, filled in the Auto Rotate section
makeNav("▼", "Auto Drop", 12)
makeNav("$", "Economy", 13)
makePage("Auto Drop") -- pages["Auto Drop"], filled in the Auto Rotate section (shares its world travel)
makePage("Economy") -- pages.Economy, filled right below

-- Economy page: workspace/economy.json, written by discord-economy/listener.mjs (Discord trade
-- channels). unit_price = items per WL (the game's "200/1"), so the best sell = the MOST items
-- per WL and the best buy = the FEWEST. A fresh post (< 10 min) beats an older one; older = grey.
-- Click a price = copy the link to its Discord message. Re-reads the file every 2 s while open.
-- Search = items whose name contains the text. Graph mode: the picked item's rate over time (click
-- an item name to pick it), sell = white, buy = grey, the last 24 h of posts it has.
do
	local ec = { page = pages.Economy, FILE = "economy.json", STALE = 600, rows = {}, graph = false, WINDOW = 86400 }
	makeSection(ec.page, "Economy · Discord trade channels", 1)
	ec.status = makeInfoCard(ec.page, "Data", 2)
	ec.search = makeSearchBox(ec.page, "Search item (e.g. pepper, sugar cane)", 3)
	ec.modeBtn = makeButton(ec.page, "Mode: List  ·  switch to Graph", 4, function()
		ec.graph = not ec.graph
		ec.refresh()
	end)
	ec.chart = Instance.new("Frame")
	ec.chart.Size = UDim2.new(1, 0, 0, 240)
	ec.chart.BackgroundColor3 = PANEL
	ec.chart.BorderSizePixel = 0
	ec.chart.LayoutOrder = 5
	ec.chart.Visible = false
	ec.chart.Parent = ec.page
	corner(ec.chart, 10)
	ec.chartTitle = Instance.new("TextLabel")
	ec.chartTitle.Size = UDim2.new(1, -36, 0, 30)
	ec.chartTitle.Position = UDim2.fromOffset(18, 6)
	ec.chartTitle.BackgroundTransparency = 1
	ec.chartTitle.Font = Enum.Font.GothamBold
	ec.chartTitle.TextSize = 14
	ec.chartTitle.TextColor3 = TEXT
	ec.chartTitle.TextXAlignment = Enum.TextXAlignment.Left
	ec.chartTitle.TextTruncate = Enum.TextTruncate.AtEnd
	ec.chartTitle.Parent = ec.chart
	ec.plot = Instance.new("Frame") -- points + lines go in here; axis labels sit outside it
	ec.plot.Size = UDim2.new(1, -96, 1, -76)
	ec.plot.Position = UDim2.fromOffset(78, 40)
	ec.plot.BackgroundColor3 = BG
	ec.plot.BorderSizePixel = 0
	ec.plot.ClipsDescendants = true
	ec.plot.Parent = ec.chart
	corner(ec.plot, 6)
	ec.axis = Instance.new("Folder", ec.chart)
	ec.listHead = makeSection(ec.page, "Item   ·   best sell   ·   best buy   (click price = copy link · item = graph)", 6)
	ec.search:GetPropertyChangedSignal("Text"):Connect(function() ec.refresh() end)
	ec.list = Instance.new("Frame")
	ec.list.Size = UDim2.new(1, 0, 0, 0)
	ec.list.AutomaticSize = Enum.AutomaticSize.Y
	ec.list.BackgroundTransparency = 1
	ec.list.LayoutOrder = 7
	ec.list.Parent = ec.page
	ec.layout = Instance.new("UIListLayout", ec.list)
	ec.layout.Padding = UDim.new(0, 6)
	ec.layout.SortOrder = Enum.SortOrder.LayoutOrder

	function ec.num(x) return (string.format("%.2f", x):gsub("%.?0+$", "")) end
	function ec.rate(r) return r >= 1 and ec.num(r) .. "/WL" or ec.num(1 / r) .. " WL each" end
	function ec.label(parent, x, w, align)
		local t = Instance.new("TextButton")
		t.Size = UDim2.new(w, -12, 1, 0)
		t.Position = UDim2.new(x, 12, 0, 0)
		t.BackgroundTransparency = 1
		t.AutoButtonColor = false
		t.Font = Enum.Font.GothamMedium
		t.TextSize = 13
		t.TextColor3 = TEXT
		t.TextXAlignment = align
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Parent = parent
		return t
	end
	function ec.row(item)
		local r = ec.rows[item]
		if r then return r end
		local f = Instance.new("Frame")
		f.Size = UDim2.new(1, 0, 0, 40)
		f.BackgroundColor3 = PANEL
		f.BorderSizePixel = 0
		f.Parent = ec.list
		corner(f, 8)
		r = { frame = f, name = ec.label(f, 0, 0.3, Enum.TextXAlignment.Left),
			sell = ec.label(f, 0.3, 0.35, Enum.TextXAlignment.Left), buy = ec.label(f, 0.65, 0.35, Enum.TextXAlignment.Left) }
		r.name.Text = item
		r.name.MouseButton1Click:Connect(function() -- item name = its graph
			ec.sel, ec.graph = item, true
			ec.refresh()
		end)
		for _, side in ipairs({ "sell", "buy" }) do
			r[side].MouseButton1Click:Connect(function()
				local e = r[side .. "E"]
				local copy = setclipboard or toclipboard
				if e and e.link and copy then
					pcall(copy, e.link)
					r[side].Text = "link copied"
				end
			end)
		end
		ec.rows[item] = r
		return r
	end
	-- e beats cur: fresh over stale, then the better rate, then the newer post
	function ec.better(e, cur, now)
		if not cur then return true end
		local fe, fc = now - e.seen_at < ec.STALE, now - cur.seen_at < ec.STALE
		if fe ~= fc then return fe end
		if e.unit_price ~= cur.unit_price then
			return (e.side == "sell") == (e.unit_price > cur.unit_price)
		end
		return e.seen_at > cur.seen_at
	end
	function ec.render()
		local ok, data = pcall(function() return game:GetService("HttpService"):JSONDecode(readfile(ec.FILE)) end)
		if not ok or type(data) ~= "table" then
			ec.status.Text = "no economy.json · start the listener"
			return
		end
		local now, best, hist, n, newest = os.time(), {}, {}, 0, 0
		for _, e in ipairs(data) do
			if type(e) == "table" and type(e.seen_at) == "number" then
				newest = math.max(newest, e.seen_at)
				if type(e.item) == "string" and not e.deleted and type(e.unit_price) == "number" and e.unit_price > 0
					and (e.side == "sell" or e.side == "buy") then
					n += 1
					best[e.item] = best[e.item] or {}
					if ec.better(e, best[e.item][e.side], now) then best[e.item][e.side] = e end
					hist[e.item] = hist[e.item] or {}
					table.insert(hist[e.item], e)
				end
			end
		end
		local q = ec.search.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
		local items = {}
		for item in pairs(best) do
			if q == "" or item:find(q, 1, true) then items[#items + 1] = item end
		end
		table.sort(items)
		local total = 0
		for _ in pairs(best) do total += 1 end
		ec.status.Text = string.format("%d prices · %s items · newest %ds ago", n,
			q == "" and tostring(total) or #items .. "/" .. total, now - newest)
		for item, r in pairs(ec.rows) do
			if not table.find(items, item) then r.frame:Destroy() ec.rows[item] = nil end
		end
		-- graph mode: the picked item, else the first one the search shows
		if ec.graph and not (ec.sel and best[ec.sel] and table.find(items, ec.sel)) then ec.sel = items[1] end
		ec.chart.Visible = ec.graph
		ec.modeBtn.Text = ec.graph and "Mode: Graph  ·  switch to List" or "Mode: List  ·  switch to Graph"
		if ec.graph then ec.drawChart(ec.sel, ec.sel and hist[ec.sel], now) end
		for i, item in ipairs(items) do
			local r = ec.row(item)
			r.frame.LayoutOrder = i
			for _, side in ipairs({ "sell", "buy" }) do
				local e = best[item][side]
				r[side .. "E"] = e
				if e then
					local age = now - e.seen_at
					r[side].Text = string.format("%s %s · %ds%s", side, ec.rate(e.unit_price), age,
						type(e.world) == "string" and " · " .. e.world or "")
					r[side].TextColor3 = age < ec.STALE and TEXT or MUTED
				else
					r[side].Text, r[side].TextColor3 = "-", MUTED
				end
			end
			local fresh = (best[item].sell and now - best[item].sell.seen_at < ec.STALE)
				or (best[item].buy and now - best[item].buy.seen_at < ec.STALE)
			r.name.TextColor3 = (item == ec.sel and ec.graph or fresh) and TEXT or MUTED
			r.frame.BackgroundColor3 = item == ec.sel and ec.graph and PANEL2 or PANEL
		end
	end
	function ec.refresh() pcall(ec.render) end

	-- Graph: rate (items per WL) over the last 24 h, one dot per post, a line per side.
	-- Redrawn only when the points, the size or the minute change (frames are rebuilt each time).
	function ec.axisText(text, x, y, w, align)
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromOffset(w, 14)
		t.Position = UDim2.fromOffset(x, y)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamMedium
		t.TextSize = 11
		t.TextColor3 = MUTED
		t.TextXAlignment = align
		t.Text = text
		t.Parent = ec.axis
	end
	function ec.drawChart(item, list, now)
		local W, H = ec.plot.AbsoluteSize.X, ec.plot.AbsoluteSize.Y
		local pts, lo, hi = {}, math.huge, -math.huge
		for _, e in ipairs(list or {}) do
			if now - e.seen_at <= ec.WINDOW then pts[#pts + 1] = e end
		end
		table.sort(pts, function(a, b) return a.seen_at < b.seen_at end)
		while #pts > 200 do table.remove(pts, 1) end -- ponytail: last 200 posts, enough dots for 400 px
		local sig = table.concat({ tostring(item), #pts, pts[#pts] and pts[#pts].seen_at or 0, W, H, now // 60 }, "|")
		if sig == ec.sig then return end
		ec.sig = sig
		ec.plot:ClearAllChildren()
		ec.axis:ClearAllChildren()
		if not item then ec.chartTitle.Text = "no item matches the search" return end
		ec.chartTitle.Text = string.format("%s  ·  %d posts in 24 h  ·  white = sell · grey = buy", item, #pts)
		if #pts == 0 or W < 10 then return end
		for _, e in ipairs(pts) do lo, hi = math.min(lo, e.unit_price), math.max(hi, e.unit_price) end
		local pad = math.max((hi - lo) * 0.1, hi * 0.05)
		lo, hi = math.max(0, lo - pad), hi + pad
		local t0 = math.min(pts[1].seen_at, now - 60)
		local function at(e) return (e.seen_at - t0) / (now - t0) * W, (1 - (e.unit_price - lo) / (hi - lo)) * H end
		local last = {}
		for _, e in ipairs(pts) do
			local x, y = at(e)
			local col = e.side == "sell" and TEXT or MUTED
			local p = last[e.side]
			if p then -- a 2 px frame from the previous dot of this side, rotated onto it
				local dx, dy = x - p[1], y - p[2]
				local ln = Instance.new("Frame")
				ln.AnchorPoint = Vector2.new(0.5, 0.5)
				ln.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 2)
				ln.Position = UDim2.fromOffset((x + p[1]) / 2, (y + p[2]) / 2)
				ln.Rotation = math.deg(math.atan2(dy, dx))
				ln.BackgroundColor3 = col
				ln.BackgroundTransparency = 0.4
				ln.BorderSizePixel = 0
				ln.Parent = ec.plot
			end
			local d = Instance.new("Frame")
			d.AnchorPoint = Vector2.new(0.5, 0.5)
			d.Size = UDim2.fromOffset(6, 6)
			d.Position = UDim2.fromOffset(x, y)
			d.BackgroundColor3 = col
			d.BorderSizePixel = 0
			d.Parent = ec.plot
			corner(d, 3)
			last[e.side] = { x, y }
		end
		local px, py = ec.plot.Position.X.Offset, ec.plot.Position.Y.Offset
		ec.axisText(ec.rate(hi), 4, py, px - 10, Enum.TextXAlignment.Right)
		ec.axisText(ec.rate(lo), 4, py + H - 14, px - 10, Enum.TextXAlignment.Right)
		local span = now - t0
		ec.axisText(span >= 3600 and string.format("%.1fh ago", span / 3600) or (span // 60) .. "m ago", px, py + H + 6, 90,
			Enum.TextXAlignment.Left)
		ec.axisText("now", px + W - 60, py + H + 6, 60, Enum.TextXAlignment.Right)
	end
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			if ec.page.Visible then pcall(ec.render) end
			task.wait(2)
		end
	end)
end

-- Break page
makeSection(breakPage, "Breaking", 1)
makeToggle(breakPage, "Fast Break", "One click breaks a block (real hits padded)", 2, "FastBreak", function(on)
	if on then
		fb.world = fb.world or findWorld()
		if not fb.world then return false end -- not in a world yet
	end
	fb.fastOn = on
	setPatched(on)
end)
local statusLabel = makeInfoCard(breakPage, "Status", 3)
local brokenLabel = makeInfoCard(breakPage, "Blocks broken", 4)
local revertLabel = makeInfoCard(breakPage, "Rejected by server", 5)

-- Auto Break page
makeSection(autoPage, "Auto Break", 1)
human.stoppers.brk = function()
	if not fb.autoOn then return end
	state.AutoBreak, fb.autoOn = false, false
	if fb.renderAutoBreak then fb.renderAutoBreak() end
end
fb.renderAutoBreak = makeToggle(autoPage, "Auto Break", "Breaks selected blocks within 4 tiles, nearest first", 2, "AutoBreak", function(on)
	if on then
		fb.world = fb.world or findWorld()
		if not fb.world or not next(fb.selected) then return false end -- need world + selection
		fb.brStatus = nil
	end
	fb.autoOn = on
end)
-- Pathfinder for Auto Break (fb.breakTick, in the Auto Harvest section: needs the path bot).
makeToggle(autoPage, "Walk to blocks", "Nothing in reach: walk to the next one + its drops", 3, "BreakWalk", function(on)
	if on and not fb.hookMobile() then return false end
end)
local autoLabel = makeInfoCard(autoPage, "Target", 4)
makeSection(autoPage, "Pick blocks (in this world)", 5)
local searchBox = makeSearchBox(autoPage, "Search block name...", 6)

local resultGrid = Instance.new("Frame")
resultGrid.Size = UDim2.new(1, 0, 0, 0)
resultGrid.AutomaticSize = Enum.AutomaticSize.Y
resultGrid.LayoutOrder = 7
resultGrid.BackgroundTransparency = 1
resultGrid.Parent = autoPage
local rgl = Instance.new("UIGridLayout", resultGrid)
rgl.CellSize = UDim2.new(0.5, -4, 0, 34)
rgl.CellPadding = UDim2.fromOffset(8, 8)
rgl.SortOrder = Enum.SortOrder.LayoutOrder

-- Rebuild result pills: selected first, then matches by count. Only breakable ids.
local function renderResults()
	for _, c in ipairs(resultGrid:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local q = string.lower(searchBox.Text)
	local counts = worldCounts()
	local list = {}
	for id, n in pairs(counts) do
		local it = itemDB[id]
		if it and hitsFor(id) and (fb.selected[id] or q == "" or string.find(string.lower(it.name or ""), q, 1, true)) then
			table.insert(list, { id = id, n = n })
		end
	end
	table.sort(list, function(a, b)
		local sa, sb = fb.selected[a.id] and 1 or 0, fb.selected[b.id] and 1 or 0
		if sa ~= sb then return sa > sb end
		return a.n > b.n
	end)
	for i = 1, math.min(#list, 12) do
		local e = list[i]
		local on = fb.selected[e.id]
		local p = Instance.new("TextButton")
		p.LayoutOrder = i
		p.BackgroundColor3 = on and ACCENT or PANEL
		p.TextColor3 = on and Color3.fromRGB(20, 20, 20) or TEXT
		p.Text = string.format("%s  ×%d", itemDB[e.id].name, e.n)
		p.TextTruncate = Enum.TextTruncate.AtEnd
		p.Font = Enum.Font.GothamMedium
		p.TextSize = 12
		p.AutoButtonColor = false
		p.Parent = resultGrid
		corner(p, 8)
		p.MouseButton1Click:Connect(function()
			fb.selected[e.id] = not fb.selected[e.id] or nil
			renderResults()
		end)
	end
end
searchBox:GetPropertyChangedSignal("Text"):Connect(renderResults)
renderResults()

-- Collect page
makeSection(collectPage, "Auto Collect", 1)
makeToggle(collectPage, "Auto Collect", "Stand still 1s: walks onto the nearest drop within 8 tiles", 2, "AutoCollect", function(on)
	if on then
		fb.drops = fb.drops or findDrops()
		fb.player = findPlayer() or fb.player
		if not (fb.drops and fb.player) then return false end -- not in a world yet
	end
end)
local collectLabel = makeInfoCard(collectPage, "Picked up", 3)

-- Auto Farm page. Stand still in the middle of a tile with empty space left and/or right:
-- place -> break -> (auto collect) on those tiles, forever.
-- Farmable blocks in the bag, best first. Score = rarity / hits.
-- ponytail: gem formula is server-side; rarity/hits is a guess, the Gems/h card is the truth
local function farmChoices()
	local list = {}
	for _, s in ipairs(fb.inv and fb.inv.slots or {}) do
		local it = itemDB[s.id]
		local h = it and it.farmable and not it.kind and hitsFor(s.id)
		if h and s.n > 0 then
			list[#list + 1] = { id = s.id, n = s.n, score = (it.rarity or 1) / h }
		end
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.n > b.n
	end)
	return list
end

-- Block to place next: the manual pick while you have it, else the best in the bag.
local function farmBlock()
	if fb.farmPick then
		return fb.inv:count(fb.farmPick) > 0 and fb.farmPick or nil
	end
	local best = farmChoices()[1]
	return best and best.id
end

makeSection(farmPage, "Auto Farm", 1)
local renderFarmToggle = makeToggle(farmPage, "Auto Farm", "Place & break beside you, step / hop onto the drops", 2, "AutoFarm", function(on)
	if not on then fb.farmStatus = nil return end
	if not fb.hookMobile() then fb.farmStatus = "controls not found yet · try again" return false end
	if state.AutoHarvest or state.AutoPlant or state.RowFarm then fb.farmStatus = "turn Harvest / Plant / Row Farm off first" return false end
	fb.world = fb.world or findWorld()
	fb.drops = fb.drops or findDrops()
	fb.player = findPlayer() or fb.player
	fb.inv = findInventory() or fb.inv
	if not (fb.world and fb.drops and fb.player and fb.inv) then
		fb.farmStatus = "enter a world first"
		return false
	end
	-- Lock in the tiles left, right and above your head (all ~1 tile away, so drops are in pickup
	-- range) that are empty or already hold the block you farm: that one is broken first (counts as
	-- broken), then refilled like the rest. Skip one your hitbox (0.3 wide each way, 0.95 tall) pokes into.
	-- "3 on top" (FarmTop): the 3 tiles above your head instead (top-left, top, top-right).
	local s = fb.player.state()
	local row, cx = math.floor(s.y - 0.5), math.floor(s.x)
	local head = s.y - 0.95 >= row
	local spots = state.FarmTop and {
		head and { cx - 1, row - 1 },
		head and { cx, row - 1 },
		head and { cx + 1, row - 1 },
	} or {
		s.x - 0.3 >= cx and { cx - 1, row },
		s.x + 0.3 <= cx + 1 and { cx + 1, row },
		head and { cx, row - 1 },
	}
	local want = fb.farmPick or farmBlock()
	local tiles = {}
	for i = 1, 3 do
		local p = spots[i]
		local f = p and fb.world.fg[p[2]] and fb.world.fg[p[2]][p[1]]
		local b = p and fb.world.bg[p[2]] and fb.world.bg[p[2]][p[1]]
		if f == 0 or (want and f == want) then
			-- under: a top-left / top-right tile over open space beside you: drops that fall land there.
			-- head: its pickup jumps from beside the middle column (a wall beside you to hop onto, or
			-- no floor there to stand on), so it needs the tile above your head empty at that moment.
			local diag = p[2] < row and p[1] ~= cx
			local open = diag and not fb.player.solidAt(p[1], row)
			tiles[#tiles + 1] = { x = p[1], y = p[2], mine = want and (f == want or b == want) and want or nil,
				under = open or nil, head = diag and not (open and fb.player.solidAt(p[1], row + 1)) or nil }
		end
	end
	fb.farmMid = nil
	for _, t in ipairs(tiles) do
		if state.FarmTop and t.x == cx then fb.farmMid = t end
	end
	if state.FarmTop and not fb.farmMid then -- the side ones are picked up jumping past it
		fb.farmStatus = "3 on top: the tile above your head must be empty (or your farm block)"
		return false
	end
	if #tiles == 0 then
		fb.farmStatus = "need empty space (or your farm block) " .. (state.FarmTop and "in the 3 tiles above you" or "beside/above you") .. " · stand centered"
		return false
	end
	-- anchor = the tile's center, so your body (0.3 each side) never touches a farm tile; farmStep
	-- walks you there first
	fb.farmTiles, fb.farmAnchor, fb.farmHome = tiles, { x = cx + 0.5, y = s.y }, { x = cx, y = row }
	fb.farmStart, fb.farmBroken, fb.farmGems, fb.farmStatus = os.clock(), 0, 0, nil
	fb.farmGems0 = fb.gemsNow() -- gems/h = your gem count's rise (local HUD value, no server call)
	fb.farmDrain, fb.tripRetryAt, fb.farmRejectRun = false, 0, 0
end)
-- Trips use the path bot, walking + jumping (never teleport).
local needBot = function(on) if on and not fb.hookMobile() then return false end end
makeToggle(farmPage, "Fetch dropped blocks", "Out of blocks: walk to a pile & back", 3, "FarmFetch", needBot)
local renderDropToggle = makeToggle(farmPage, "Auto drop seeds", "200 seeds: walk 5 tiles away, drop on one pile", 4, "FarmDrop", needBot)
local farmStatusLabel = makeInfoCard(farmPage, "Status", 5)
local farmBlockLabel = makeInfoCard(farmPage, "Block", 6)
local farmStatsLabel = makeInfoCard(farmPage, "Broken · per min · gems/h", 7)
makeSection(farmPage, "Block (from your bag)", 8)
local farmGrid = Instance.new("Frame")
farmGrid.Size = UDim2.new(1, 0, 0, 0)
farmGrid.AutomaticSize = Enum.AutomaticSize.Y
farmGrid.LayoutOrder = 9
farmGrid.BackgroundTransparency = 1
farmGrid.Parent = farmPage
local fgl = Instance.new("UIGridLayout", farmGrid)
fgl.CellSize = UDim2.new(0.5, -4, 0, 34)
fgl.CellPadding = UDim2.fromOffset(8, 8)
fgl.SortOrder = Enum.SortOrder.LayoutOrder

makeToggle(farmPage, "3 on top", "Farm top-left, top & top-right of you (not left / right / top)", 10, "FarmTop", function()
	if state.AutoFarm then fb.farmStatus = "turn Auto Farm off first to change the layout" return false end
end)

local function renderFarmPicks()
	for _, c in ipairs(farmGrid:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local opts = { { text = "Auto (best in bag)" } }
	for _, e in ipairs(farmChoices()) do
		opts[#opts + 1] = { id = e.id, text = string.format("%s  ×%d", itemDB[e.id].name, e.n) }
		if #opts >= 12 then break end
	end
	for i, o in ipairs(opts) do
		local on = fb.farmPick == o.id
		local p = Instance.new("TextButton")
		p.LayoutOrder = i
		p.BackgroundColor3 = on and ACCENT or PANEL
		p.TextColor3 = on and Color3.fromRGB(20, 20, 20) or TEXT
		p.Text = o.text
		p.TextTruncate = Enum.TextTruncate.AtEnd
		p.Font = Enum.Font.GothamMedium
		p.TextSize = 12
		p.AutoButtonColor = false
		p.Parent = farmGrid
		corner(p, 8)
		p.MouseButton1Click:Connect(function()
			fb.farmPick = o.id
			renderFarmPicks()
		end)
	end
end


-- Player page
makeSection(playerPage, "Humanizer (all auto modes)", 1)
makeToggle(playerPage, "Humanize timing", "Jittered gaps, key releases, drift, pauses, backoff, session stop · ~25% slower", 2, "Humanize", function(on)
	human.on = on
	human.endAt, human.holdUntil, human.microAt, human.medAt = nil, nil, nil, nil
end)
makeToggle(playerPage, "Short & long pauses", "0.4-3s every 20-60s, 8-45s every 5-15 min · off = ~15% faster, gaps stay jittered", 3, "HumanPauses", function(on)
	human.pauses = on
	human.microAt, human.medAt, human.holdUntil = nil, nil, nil
end)
human.pauses = state.HumanPauses
human.card = makeInfoCard(playerPage, "Humanizer", 4)
makeSection(playerPage, "\"Are you still there?\" checks (you answer them)", 5)
human.fcCard = makeInfoCard(playerPage, "Checks", 6)
-- Ultimate FPS (measured v1111, world DSHR): the game is drawn entirely in GUI (workspace = 8 instances),
-- so the 3D pass renders an empty scene: off = ~50 -> ~72 fps. The Backdrop (sky / hills art behind the
-- tiles, ~110 images) costs ~10 more. Plus the game's own Low Graphics (only what's near you, no shadows).
-- Left alone: chat (its ScrollingFrame culls: no gain measured), TextureKeep (1px off-screen images that
-- keep textures loaded). More fps also matters for the bots: under 30 fps the game runs in slow motion.
fb.ultimateFps = function(on)
	pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(not on and not state.BlankScreen) end)
	local bd -- the backdrop: the world view's other layer with art in it (renamed at runtime since v1208)
	for _, c in ipairs(worldFrame:GetChildren()) do
		if c:IsA("Frame") and not c:FindFirstChildOfClass("UIScale") and #c:GetChildren() > (bd and #bd:GetChildren() or 0) then bd = c end
	end
	if bd then bd.Visible = not on end
	local m = on and fb.findMenuApi and fb.findMenuApi() -- = ticking Options > Low Graphics; left on when this goes off (it's your setting)
	if on and m and m.setSetting and m.settings and (m.settings.lowGfx or 0) < 0.5 then m.setSetting("lowGfx", 1) end
end
fb.ultimateFps(false) -- clean slate on re-run
makeSection(playerPage, "Performance", 7)
makeToggle(playerPage, "Ultimate FPS", "No 3D pass, no backdrop art, game Low Graphics on · ~+50% fps", 8, "UltimateFPS", fb.ultimateFps)
-- Blank screen: nothing drawn but black, an fps counter and this panel. No 3D pass, and every game
-- ScreenGui disabled: Enabled only skips drawing, the game's scripts / physics / packets run on (the
-- script drives worlds through the game's Lua API, not its buttons). TextureKeep stays (1px images
-- that keep textures loaded for when this goes off). The game's "Warning from System" banner (admin
-- message) or a FarmCheck popup turns it off so you see them.
fb.blankOff = fb.blankOff or {} -- ScreenGuis we disabled; in getgenv so a re-run can give them back
fb.blankScreen = function(on)
	if fb.blankConn then fb.blankConn:Disconnect() fb.blankConn = nil end
	if fb.blankGui then fb.blankGui:Destroy() fb.blankGui = nil end
	if not on then
		for g in pairs(fb.blankOff) do pcall(function() g.Enabled = true end) end
		fb.blankOff = {}
		pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(not state.UltimateFPS) end)
		return
	end
	pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(false) end)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = "BlankFps", true, false, screenGui.DisplayOrder - 1
	local bg = Instance.new("Frame")
	bg.Size, bg.BackgroundColor3, bg.BorderSizePixel = UDim2.fromScale(1, 1), Color3.new(0, 0, 0), 0
	bg.Parent = gui
	local fps = Instance.new("TextLabel")
	fps.Size, fps.Position, fps.AnchorPoint = UDim2.fromOffset(400, 70), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
	fps.BackgroundTransparency, fps.Font, fps.TextSize, fps.TextColor3 = 1, Enum.Font.GothamBold, 56, TEXT
	fps.Text = "-- FPS"
	fps.Parent = bg
	local hint = Instance.new("TextLabel")
	hint.Size, hint.Position, hint.AnchorPoint = UDim2.fromOffset(400, 20), UDim2.new(0.5, 0, 0.5, 46), Vector2.new(0.5, 0)
	hint.BackgroundTransparency, hint.Font, hint.TextSize, hint.TextColor3 = 1, Enum.Font.Gotham, 13, MUTED
	hint.Text = "Blank screen · game still running · " .. TOGGLE_KEY.Name .. " = panel"
	hint.Parent = bg
	gui.Parent = playerGui
	fb.blankGui = gui
	local frames, t0 = 0, os.clock()
	fb.blankConn = game:GetService("RunService").RenderStepped:Connect(function()
		frames += 1
		local dt = os.clock() - t0
		if dt < 0.5 then return end
		fps.Text = string.format("%d FPS", math.floor(frames / dt + 0.5))
		frames, t0 = 0, os.clock()
		local menu = playerGui:FindFirstChild("MenuGui")
		local warn = menu and menu:FindFirstChild("Warning")
		if fb.farmCheckOpen or (warn and warn:IsA("GuiObject") and warn.Visible) then
			pcall(fb.toggleSet.BlankScreen, false)
			pcall(function()
				game:GetService("StarterGui"):SetCore("SendNotification", { Title = "Blank screen off", Text = "The game is showing you a message", Duration = 15 })
			end)
			return
		end
		for _, g in ipairs(playerGui:GetChildren()) do -- also ones the game adds / turns back on later
			if g:IsA("ScreenGui") and g.Enabled and g ~= screenGui and g ~= gui and g.Name ~= "TextureKeep" then
				g.Enabled, fb.blankOff[g] = false, true
			end
		end
	end)
end
fb.blankScreen(false) -- clean slate on re-run (gives back what an older run hid)
makeToggle(playerPage, "Blank screen", "Draws only fps + this panel · game keeps running · admin warnings turn it off", 9, "BlankScreen", fb.blankScreen)
-- Anti-AFK: Roblox's own idle disconnect (20 min without real input, error 278). The bots drive
-- the game through its MobileControls, which Roblox doesn't count as input. Player.Idled (fires ~2
-- min into idling, then every 30s) -> one virtual right click: the game reads only the left button
-- and touch, so it does nothing in-game. Never fires while you use mouse / keys yourself.
-- Not the game's "Are you still there?" check: that one stays yours to answer.
if not fb.idleHooked then -- once per session; re-runs flip fb.antiIdle
	fb.idleHooked = true
	players.LocalPlayer.Idled:Connect(function()
		if not fb.antiIdle then return end
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end)
end
fb.antiIdle = state.AntiIdle
makeSection(playerPage, "Session", 10)
makeToggle(playerPage, "Anti-AFK", "Stops Roblox's 20 min idle disconnect (278) · not the game's check", 11, "AntiIdle", function(on)
	fb.antiIdle = on
end)

-- Wing Skin (client-only look, verified v1450). Your own avatar's wings come from the game's
-- wornWings() (your worn table, slot -> id; a worn item with `wingSheet` first) and its rig from
-- v9.applyWorn (same table when called for you; other players pass their own slots). Wings with
-- `wingSheet` are drawn as two animated images from Assets.Player[wingSheet] (frame from wingAir /
-- wingGround, else the default flap: still on the ground, 16 fps in the air) and their back-slot
-- cloth sprite is skipped. So ItemDB stays untouched (patching it swapped everyone wearing the
-- same wings): those two functions get a proxy of your worn table that reads your wings as FAKE,
-- an ItemDB entry (via ItemDB's metatable, not stored) that is the skin, except the keys the
-- jump code reads (doubleJump / slowFall / jumpFx: air jump, glide clamp, jump effect) which stay
-- your own item's. Your real worn table, the physics' wornSpeed / buildRange and every packet are
-- unchanged. Not copied: the 0.4s fast flap after an air jump, the game runs it only for
-- doubleJump == true wings (= the glide clamp too).
do
	local FILE = "growblox_wingskin.txt" -- the pick survives teleports (autoexec re-runs this)
	local FAKE = -1
	local OWN = { doubleJump = true, slowFall = true, jumpFx = true }
	for id, o in pairs(fb.wingOrig or {}) do -- an older run patched ItemDB itself: put it back
		for k in pairs({ wingSheet = 1, wingAir = 1, wingGround = 1, wingDx = 1, wingDy = 1, wingFx = 1 }) do itemDB[id][k] = o[k] end
	end
	fb.wingOrig = nil
	fb.wingFake = setmetatable({}, { __index = function(_, k)
		local it = itemDB[OWN[k] and fb.wingOn or fb.wingSkin]
		return it and it[k]
	end })
	local function unhook()
		local h = fb.wingHook
		fb.wingOn, fb.wingHook = nil, nil
		if not h then return end
		pcall(debug.setupvalue, h.ww, 1, h.worn)
		pcall(debug.setupvalue, h.aw, h.ai, h.worn)
		h.mt.__index = h.orig
	end
	unhook() -- clean slate on re-run
	local function hook()
		if fb.wingHook then return true end
		if os.clock() < (fb.wingRetry or 0) then return end
		local av = fb.findAvatar and fb.findAvatar()
		local worn = av and debug.getupvalues(av.buildRange)[1]
		if type(worn) ~= "table" then return end
		fb.wingRetry = os.clock() + 30 -- two getgc scans: don't repeat them every 2s if not found
		local v9, ww, ai
		for _, t in pairs(getgc(true)) do
			if type(t) == "table" and type(rawget(t, "applyWorn")) == "function" and type(rawget(t, "wingCell")) == "function" then v9 = t break end
		end
		for _, f in pairs(getgc(false)) do
			if type(f) == "function" and islclosure(f) then
				local ok, ups = pcall(debug.getupvalues, f)
				if ok and #ups == 2 and ups[1] == worn and ups[2] == itemDB then
					local okc, c = pcall(debug.getconstants, f)
					if okc and table.find(c, "wingSheet") then ww = f break end
				end
			end
		end
		for i, u in ipairs(v9 and debug.getupvalues(v9.applyWorn) or {}) do
			if u == worn then ai = i end
		end
		local mt = getrawmetatable and getrawmetatable(itemDB) or getmetatable(itemDB)
		if not (ww and ai and type(mt) == "table") then return end
		local function swap(v) if v ~= nil and v == fb.wingOn then return FAKE end return v end
		local proxy = setmetatable({}, {
			__index = function(_, k) return swap(worn[k]) end,
			__newindex = worn,
			__iter = function() return function(_, k) local nk, v = next(worn, k) return nk, swap(v) end end,
			__len = function() return #worn end,
		})
		local orig = mt.__index
		mt.__index = function(t, k)
			if k == FAKE then return fb.wingFake end
			if type(orig) == "function" then return orig(t, k) end
			return orig and orig[k]
		end
		debug.setupvalue(ww, 1, proxy)
		debug.setupvalue(v9.applyWorn, ai, proxy)
		fb.wingHook = { ww = ww, aw = v9.applyWorn, ai = ai, worn = worn, mt = mt, orig = orig }
		return true
	end
	local function apply()
		if not fb.wingSkin then unhook() return end
		if not hook() then return end
		local pick -- same pick as the game's wornWings(): wings with a sheet first, else any doubleJump item
		for _, id in pairs(fb.wingHook.worn) do
			local it = itemDB[id]
			if it and it.doubleJump then
				if it.wingSheet then pick = id break end
				pick = pick or id
			end
		end
		fb.wingOn = pick
	end

	local ok, saved = pcall(readfile, FILE)
	saved = ok and tonumber(saved)
	fb.wingSkin = saved and itemDB[saved] and itemDB[saved].wingSheet and saved or nil

	makeSection(playerPage, "Wing Skin · your screen only · needs wings worn", 12)
	local grid = Instance.new("Frame")
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 13
	grid.BackgroundTransparency = 1
	grid.Parent = playerPage
	local gl = Instance.new("UIGridLayout", grid)
	gl.CellSize = UDim2.new(0.5, -4, 0, 34)
	gl.CellPadding = UDim2.fromOffset(8, 8)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	local opts = {}
	for id, it in pairs(itemDB) do
		if type(it) == "table" and it.wingSheet then opts[#opts + 1] = { id = id, text = it.name } end
	end
	table.sort(opts, function(a, b) return a.text < b.text end)
	table.insert(opts, 1, { text = "Off (your real wings)" })
	local buttons = {}
	local function render()
		for _, b in ipairs(buttons) do
			local on = fb.wingSkin == b.id
			b.p.BackgroundColor3 = on and ACCENT or PANEL
			b.p.TextColor3 = on and Color3.fromRGB(20, 20, 20) or TEXT
		end
	end
	for i, o in ipairs(opts) do
		local p = Instance.new("TextButton")
		p.LayoutOrder = i
		p.Text = o.text
		p.TextTruncate = Enum.TextTruncate.AtEnd
		p.Font = Enum.Font.GothamMedium
		p.TextSize = 12
		p.AutoButtonColor = false
		p.Parent = grid
		corner(p, 8)
		buttons[#buttons + 1] = { p = p, id = o.id }
		p.MouseButton1Click:Connect(function()
			fb.wingSkin, fb.wingRetry = o.id, nil
			pcall(writefile, FILE, tostring(o.id or ""))
			pcall(apply)
			render()
		end)
	end
	render()
	-- Re-check every 2s: wings changed, or the avatar table found late (after a teleport).
	task.spawn(function()
		while task.wait(2) and screenGui.Parent and fb.gen == myGen do
			pcall(apply)
		end
	end)
end

-- Doors page. Door data (id, dest, label, public, locked) is replicated to every
-- visitor, so this works in worlds you don't own. Passwords are NOT sent.
local function describeDest(dest)
	if dest == "" then return "(no destination)" end
	local wname, did = string.match(dest, "^([^:]*):?(.*)$")
	local w = fb.world
	if wname == "" or wname == w.name then
		if did == "" then return "spawn" end
		local t = w.doors.find(did)
		return t and string.format("%s (%d, %d)", did, t.x, t.y) or (did .. " (missing!)")
	end
	return did ~= "" and (wname .. " : " .. did) or wname
end

local function doorAt(x, y)
	local w = fb.world
	local row = w and w.fg[y]
	local it = row and itemDB[row[x]]
	if not (it and it.door) then return nil end
	local d = w.doors.get(x, y) or {}
	return { x = x, y = y, name = it.name, id = d.id or "", dest = d.dest or "", label = d.label or "",
		public = d.public, locked = d.locked }
end

local function scanDoors()
	local list = {}
	local w = fb.world
	if not w then return list end
	for y, row in pairs(w.fg) do
		for x in pairs(row) do
			local d = doorAt(x, y)
			if d then list[#list + 1] = d end
		end
	end
	table.sort(list, function(a, b) return a.y < b.y or (a.y == b.y and a.x < b.x) end)
	return list
end

local function doorLine(d)
	local tags = { string.format("%s @ %d, %d", d.name, d.x, d.y) }
	if d.public then tags[#tags + 1] = "public" end
	if d.locked then tags[#tags + 1] = "password" end
	if d.label ~= "" then tags[#tags + 1] = '"' .. d.label .. '"' end
	return string.format("%s  →  %s", d.id ~= "" and d.id or "(no id)", describeDest(d.dest)), table.concat(tags, " · ")
end

-- On-door tags: parented into the game's scrolling tile layer (World.Camera.Tiles,
-- 64px per tile, under a UIScale) so they pan/zoom with the map for free.
local TILE = 64
local oldTags = tilesLayer:FindFirstChild("DoorTags")
if oldTags then oldTags:Destroy() end
local tagFolder = Instance.new("Folder")
tagFolder.Name = "DoorTags"
tagFolder.Parent = tilesLayer

local function renderTags(list)
	tagFolder:ClearAllChildren()
	if not state.DoorTags then return end
	for _, d in ipairs(list) do
		-- explicit sizes via TextService: AutomaticSize misbehaves inside the game's zero-size Tiles frame
		local lines = {
			{ d.id ~= "" and d.id or "(no id)", Enum.Font.GothamBold, 15, TEXT },
			{ "→ " .. describeDest(d.dest) .. (d.locked and " (pw)" or ""), Enum.Font.GothamMedium, 12, MUTED },
		}
		local w, h = 0, 0
		for _, l in ipairs(lines) do
			l.size = textService:GetTextSize(l[1], l[3], l[2], Vector2.new(1e4, 1e4))
			w = math.max(w, l.size.X)
			h += l.size.Y
		end
		local tag = Instance.new("Frame")
		tag.Name = d.x .. "," .. d.y
		tag.AnchorPoint = Vector2.new(0.5, 0.5)
		tag.Position = UDim2.fromOffset(d.x * TILE + TILE / 2, d.y * TILE + TILE / 2)
		tag.Size = UDim2.fromOffset(w + 14, h + 8)
		tag.BackgroundColor3 = BG
		tag.BackgroundTransparency = 0.25
		tag.BorderSizePixel = 0
		tag.ZIndex = 50
		corner(tag, 6)
		local y = 4
		for _, l in ipairs(lines) do
			local t = Instance.new("TextLabel")
			t.Position = UDim2.fromOffset(0, y)
			t.Size = UDim2.new(1, 0, 0, l.size.Y)
			t.BackgroundTransparency = 1
			t.Text, t.Font, t.TextSize, t.TextColor3 = l[1], l[2], l[3], l[4]
			t.ZIndex = 51
			t.Parent = tag
			y += l.size.Y
		end
		tag.Parent = tagFolder
	end
end

makeSection(doorsPage, "Door Checker", 1)
makeToggle(doorsPage, "Hover Info", "Point at a door to see its ID + destination", 2, "DoorHover")
local renderDoors -- defined below
makeToggle(doorsPage, "Show on Doors", "Draw ID → destination on every door", 2, "DoorTags", function()
	renderDoors()
end)
local doorCount = makeInfoCard(doorsPage, "Doors in world", 3)
local doorList = Instance.new("Frame")
doorList.Size = UDim2.new(1, 0, 0, 0)
doorList.AutomaticSize = Enum.AutomaticSize.Y
doorList.LayoutOrder = 5
doorList.BackgroundTransparency = 1
doorList.Parent = doorsPage
local dll = Instance.new("UIListLayout", doorList)
dll.Padding = UDim.new(0, 8)
dll.SortOrder = Enum.SortOrder.LayoutOrder

renderDoors = function()
	for _, c in ipairs(doorList:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
	local list = scanDoors()
	renderTags(list)
	doorCount.Text = string.format("%d  (%s)", #list, fb.world and fb.world.name or "-")
	for i, d in ipairs(list) do
		local title, sub = doorLine(d)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 54)
		row.LayoutOrder = i
		row.BackgroundColor3 = PANEL
		row.BorderSizePixel = 0
		row.Parent = doorList
		corner(row, 10)
		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -36, 0, 20)
		t.Position = UDim2.fromOffset(18, 9)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.Text = title
		t.TextColor3 = TEXT
		t.TextSize = 14
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Parent = row
		local dsc = Instance.new("TextLabel")
		dsc.Size = UDim2.new(1, -36, 0, 16)
		dsc.Position = UDim2.fromOffset(18, 29)
		dsc.BackgroundTransparency = 1
		dsc.Font = Enum.Font.Gotham
		dsc.Text = sub
		dsc.TextColor3 = MUTED
		dsc.TextSize = 12
		dsc.TextXAlignment = Enum.TextXAlignment.Left
		dsc.TextTruncate = Enum.TextTruncate.AtEnd
		dsc.Parent = row
	end
end
makeButton(doorsPage, "Refresh", 4, renderDoors)
-- door edited / placed / removed by anyone: refresh list + tags (v1159: no DoorChanged by name any
-- more; tileChanged below still catches doors placed / removed)
if worldRemotes:FindFirstChild("DoorChanged") then
	worldRemotes.DoorChanged.OnClientEvent:Connect(function()
		if screenGui.Parent then task.delay(0.1, renderDoors) end
	end)
end
net.tileChanged.listen(function(d)
	local x, y, id = d.x, d.y, d.id
	if not screenGui.Parent then return end
	local it = itemDB[id]
	if (it and it.door) or tagFolder:FindFirstChild(x .. "," .. y) then task.delay(0.1, renderDoors) end
end)
renderDoors()
fb.doorWorld = fb.world and fb.world.name

-- Hover tooltip: mouse pixel -> tile via the game's camera (world.view, in tiles)
-- drawn inside PlayerGui.GameGui.World.
local guiService = game:GetService("GuiService")
local tip = Instance.new("TextLabel")
tip.AutomaticSize = Enum.AutomaticSize.XY
tip.BackgroundColor3 = PANEL
tip.BorderSizePixel = 0
tip.Font = Enum.Font.GothamMedium
tip.TextColor3 = TEXT
tip.TextSize = 13
tip.TextXAlignment = Enum.TextXAlignment.Left
tip.Visible = false
tip.ZIndex = 10
tip.Parent = screenGui
corner(tip, 8)
local tipPad = Instance.new("UIPadding", tip)
tipPad.PaddingTop = UDim.new(0, 6); tipPad.PaddingBottom = UDim.new(0, 6)
tipPad.PaddingLeft = UDim.new(0, 10); tipPad.PaddingRight = UDim.new(0, 10)

local function tileAtMouse()
	local v = fb.world and fb.world.view
	if not v then return nil end
	local m = userInputService:GetMouseLocation()
	local inset = guiService:GetGuiInset()
	local abs = worldFrame.AbsolutePosition + inset
	local scale = worldFrame.AbsoluteSize.X / v[3]
	return math.floor(v[1] + (m.X - abs.X) / scale), math.floor(v[2] + (m.Y - abs.Y) / scale), m - inset
end

game:GetService("RunService").RenderStepped:Connect(function()
	if not (state.DoorHover and screenGui.Parent) then
		tip.Visible = false
		return
	end
	local ok, d, m = pcall(function()
		local x, y, mouse = tileAtMouse()
		return x and doorAt(x, y), mouse
	end)
	if ok and d then
		local title, sub = doorLine(d)
		tip.Text = title .. "\n" .. sub
		tip.Position = UDim2.fromOffset(m.X + 16, m.Y + 16)
		tip.Visible = true
	else
		tip.Visible = false
	end
end)

selectPage("Break")

-- Keybind toggle.
userInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == TOGGLE_KEY then
		setShown(not main.Visible)
	end
end)

-- Auto Break loop: nearest selected tile -> hit until done -> break -> next. With Walk to blocks,
-- fb.breakTick (Auto Harvest section: needs the path bot) starts the next walk once <= 2 blocks
-- are left in reach and never blocks, so hits go on while you walk (the hit cooldown, not the
-- walking, is the limit).
task.spawn(function()
	while screenGui.Parent and fb.gen == myGen do
		if fb.autoOn and human.idle() then
			fb.target, fb.brStatus = nil, human.status
			task.wait(0.25)
			continue
		end
		local t, n = nil, 0
		if fb.autoOn then t, n = pickTarget() end
		if fb.breakTick then -- also stops its walk when Auto Break / Walk is switched off
			local ok, err = pcall(fb.breakTick, n)
			if not ok then fb.brStatus = "error: " .. tostring(err) end
		end
		if t then
			pcall(function()
				fb.target = t
				local grid = fb.world[t.layer]
				local n = hitsFor(t.id)
				for i = 1, n do
					-- stop if toggled off, tile changed under us, or we walked out of reach
					if not fb.autoOn or fb.farmCheckOpen or grid[t.y][t.x] ~= t.id or not (fb.pos and canHit(t.x, t.y, fb.pos.x, fb.pos.y)) then
						return
					end
					hitTile(t.x, t.y, i == n and function() finishBreak(t.layer, t.x, t.y, true) end)
				end
				human.cycle(0.1)
				if human.drift() then fb.hitAt = (fb.hitAt or 0) + human.gap(HIT_GAP) end -- whiff: a swing slot lost
			end)
			fb.target = nil
		else
			task.wait(0.1)
		end
	end
end)

-- Our stash piles (Auto Farm's seed pile, Auto Harvest's drop spot) stay unarmed while those run,
-- so walking through them doesn't pick them back up: the game re-arms a drop (RenderStepped) only
-- while you're NOT touching it, and only takes armed ones. No drop is ever moved: every pickup is
-- the game's own touch pickup, with you standing on the drop.
local pileConn
pileConn = game:GetService("RunService").Heartbeat:Connect(function()
	if fb.gen ~= myGen or not screenGui.Parent then pileConn:Disconnect() return end
	if not ((state.AutoFarm or state.AutoHarvest or state.RowFarm) and fb.drops) then return end
	for _, d in ipairs(fb.drops) do
		if d.armed and d.id ~= 112 and d ~= fb.fetching and inPile(d) then d.armed = false end
	end
end)

-- Auto Farm loop. Server rules (verified live v889, own world, Dirt):
--   * a hit sooner than ~0.3s after placing that tile is dropped -> break rejected
--     (place->hit 0.05s: 4/4 rejected, 0.2s: 2/4, 0.35s: 0/4, 0.6s: 0/4)
--   * TakeDrop fails for a drop inside a solid block -> don't cover a tile's drops
-- So we round-robin the locked tiles: break a tile once its block has settled, and refill
-- empty tiles in the gaps between hits once their drops are picked up. With 3 tiles the
-- settle time hides behind the other tiles' hits.
local SETTLE = 0.35 -- the lowest clean step above (0/4 at 0.35); the humanizer only ever adds to it
local DROP_WAIT = 0.35 -- ponytail: ~ping, drops arrive via DropAdded; raise on high ping

-- Layer + id of our block on this tile (nil if empty). A normal background behind an
-- fg farm tile is ignored.
local function tileState(t)
	local w = fb.world
	local f = w.fg[t.y][t.x]
	local b = w.bg[t.y] and w.bg[t.y][t.x] or 0
	local mineBg = t.mine and itemDB[t.mine].background
	local layer = (f ~= 0 and "fg") or (mineBg and b == t.mine and "bg") or nil
	return layer, layer == "fg" and f or b, b
end

-- A drop in this tile we can still take (or being taken) = pick it up before building over it
-- (it'd be inside the block). Maxed, or given up on (dropSkip), = we can't anyway.
local function dropsIn(x, y)
	local now = os.clock()
	for _, d in ipairs(fb.drops) do
		if not d.pending and math.floor(d.x) == x and math.floor(d.y) == y
			and not (fb.dropSkip[d.uid] and fb.dropSkip[d.uid] > now)
			and (d.taking or d.id == 112 or (d.armed and fb.inv:room(d.id) > 0)) then
			return true
		end
	end
end

-- Walk (game input, like holding a key) until your body x is at tx, braking so you stop on it
-- (Game.lua v973 ground physics: accel 36 toward the input, 48 braking without). jump(t) -> hold
-- jump t seconds in. Ends when done() (or, without done, when there, grounded and still), or
-- after `timeout`. false = the game's controls aren't hooked.
local function stepToX(tx, timeout, done, jump)
	if not fb.hookMobile() then return false end
	local t0 = os.clock()
	local input = function()
		local p = fb.player.state()
		local dx = tx - p.x
		local j = jump and jump(os.clock() - t0) or false
		if math.abs(dx) < 0.04 then return 0, j end
		if p.vx * dx > 0 and p.vx * p.vx / 96 >= math.abs(dx) - 0.02 then return 0, j end -- braking gets there
		return dx > 0 and 1 or -1, j
	end
	fb.botInput = input
	while fb.botInput == input and os.clock() - t0 < timeout do
		local p = fb.player.state()
		if done then
			if done(os.clock() - t0) then break end
		elseif math.abs(tx - p.x) < 0.05 and math.abs(p.vx) < 0.05 and p.grounded then
			break
		end
		task.wait()
	end
	if fb.botInput == input then fb.botInput = nil end
	return true
end

-- Drops on farm tile t we can still take, + (top-left / top-right over open space) any that fell
-- onto the tile under it.
function fb.tileDrops(t)
	return dropsIn(t.x, t.y) or (t.under and dropsIn(t.x, t.y + 1)) or false
end

-- Pick up the drops on farm tile t like a player: the touch pickup needs a drop within 0.6 of your
-- body x and between 1.25 above and 0.3 below your feet. Side tile: step toward it (0.75 over still
-- stands on your own tile; onto its middle if it has a floor). Tile above your head: a short hop.
-- "3 on top", top-left / top-right: a wall beside you = hop up onto it (feet in the farm tile's row);
-- open beside you = step under it (takes what fell there), then a short hop.
-- Parallel (11-14, "it should jump when it sees the drop and put the block right away"): starts the
-- moment the drops are there (tryPlace), hits on the other tiles go on meanwhile, and each tile is
-- let go as soon as its drops are taken: tryPlace refills it once your body (and your last sent
-- move) is out of it + a beat. Other tiles' drops that show up meanwhile are taken in the same go.
-- Drops still there after a try are left alone for 30s.
local function collectTile(first)
	local a, row, mid = fb.farmAnchor, fb.farmHome.y, fb.farmMid
	local function hop(gone) -- a tap jump where you stand: rises ~1.4 tiles
		local x = fb.player.state().x
		stepToX(x, 1.2, function(dt)
			return gone() or (dt > 0.2 and fb.player.state().grounded) -- landed again
		end, function(dt) return dt < 0.08 end)
	end
	-- Walk to x tx and tap jump on the way in (within 0.18: your body is already clear of the next
	-- column, so the jump can't clip a block there), braking onto tx in the air. Ends once the drops
	-- are gone, or landed. 11-14 live sample: the old "walk there, wait for the drops (up to 1.5s),
	-- then hop" stood ~1 s under each tile before jumping.
	local function hopAt(tx, gone)
		local jt
		stepToX(tx, 1.8, function(dt)
			return gone() or (jt ~= nil and dt - jt > 0.2 and fb.player.state().grounded)
		end, function(dt)
			if not jt and math.abs(fb.player.state().x - tx) < 0.18 then jt = dt end
			return jt ~= nil and dt - jt < 0.08
		end)
	end
	-- Walk to x tx (a side tile's drops on the floor: the touch pickup takes them as you get there).
	-- Ends once they're gone, or 0.15s after arriving (the take is in flight; no 1.5s wait).
	local function stepOn(tx, gone)
		local at
		stepToX(tx, 1.5, function()
			local p = fb.player.state()
			if not at and math.abs(p.x - tx) < 0.08 and p.grounded then at = os.clock() end
			return gone() or (at ~= nil and os.clock() - at > 0.15)
		end)
	end
	local function release(o)
		o.collecting = nil
		if not fb.tileDrops(o) then return end
		local now = os.clock()
		for _, d in ipairs(fb.drops) do
			local dx, dy = math.floor(d.x), math.floor(d.y)
			if dx == o.x and (dy == o.y or (o.under and dy == o.y + 1)) and d.uid then fb.dropSkip[d.uid] = now + 30 end
		end
	end
	local t, n = first, 0
	while t and n < 6 and state.AutoFarm and not fb.farmCheckOpen do
		n += 1
		t.collecting = true
		local off = t.x + 0.5 - a.x
		local side = math.abs(off) < 0.5 and 0 or (off > 0 and 1 or -1)
		local tt = t
		local gone = function() return not fb.tileDrops(tt) end
		fb.farmStatus = "picking up"
		if t.head and mid then
			-- jumps beside / onto the middle column: keep the middle empty until you're back down
			if not tileState(mid) then
				mid.collecting = true
				if fb.player.solidAt(t.x, row) then -- a wall beside you: up onto it, then back
					stepToX(a.x + side, 1.5, function(dt)
						return gone() or (dt > 0.25 and fb.player.state().grounded)
					end, function(dt) return dt < 0.15 end)
				else -- no floor beside you: lean over, hop
					hopAt(a.x + side * 0.75, gone)
				end
				stepToX(a.x, 1.5)
				mid.collecting = nil
			else
				tt = nil -- the middle got a block meanwhile: no headroom, next time (not given up on)
			end
		elseif side ~= 0 and t.y < row then -- top-left / top-right over a floor: under it, hop on arrival
			hopAt(a.x + side, gone)
		elseif side ~= 0 then
			local floor = fb.player.solidAt(t.x, t.y + 1)
			stepOn(a.x + side * (floor and 1 or 0.75), gone)
		else -- above your head: hop as you get back under it
			hopAt(a.x, gone)
		end
		if tt then release(t) else t.collecting = nil end
		t = fb.farmReady(fb.player.state().x) -- next: the nearest emptied tile whose drops are there
		if not t then -- back onto the anchor (centered, grounded, still); drops that show up on the way: go
			stepToX(a.x, 2, function()
				local p = fb.player.state()
				t = fb.farmReady(p.x)
				return t ~= nil or (math.abs(a.x - p.x) < 0.05 and math.abs(p.vx) < 0.05 and p.grounded)
			end)
		end
	end
	if t then stepToX(a.x, 2) end -- n ran out: back anyway
end
-- A farm tile to pick up now: empty, drops on it, not being picked up, headroom if it needs it.
-- px: your x = the nearest one first (not always left to right).
function fb.farmReady(px)
	local mid, best, bd = fb.farmMid, nil, nil
	for _, o in ipairs(fb.farmTiles or {}) do
		if not o.collecting and not tileState(o) and fb.tileDrops(o) and not (o.head and mid and tileState(mid)) then
			local d = px and math.abs(o.x + 0.5 - px) or 0
			if not bd or d < bd then best, bd = o, d end
		end
	end
	return best
end
-- Start the pickup thread for tile t (one at a time; it takes the others' drops too).
function fb.farmCollect(t)
	if fb.collectT or t.collecting then return false end
	if t.head and fb.farmMid and tileState(fb.farmMid) then return false end -- waits for the middle to be broken
	fb.collectT, t.collecting = t, true
	task.spawn(function()
		pcall(collectTile, t)
		for _, o in ipairs(fb.farmTiles) do o.collecting = nil end
		fb.collectT = nil
	end)
	return true
end
-- Every frame: drops on an emptied farm tile = jump for them now (11-14: "the moment a seed or block
-- shows up, jump, always"), not when the hit loop next looks (up to a hit gap later).
do
	local conn
	conn = game:GetService("RunService").Heartbeat:Connect(function()
		if fb.gen ~= myGen or not screenGui.Parent then conn:Disconnect() return end
		if not (state.AutoFarm and fb.farmTiles and fb.farmAnchor) or fb.collectT or fb.farmCheckOpen or human.idle() then return end
		local s = fb.player and fb.player.state()
		if not s or s.dead or math.abs(s.x - fb.farmAnchor.x) > 0.4 or math.abs(s.y - fb.farmAnchor.y) > 0.4 then return end
		local t = fb.farmReady(s.x)
		if t then fb.farmCollect(t) end
	end)
end

local function stopFarm(msg)
	state.AutoFarm = false
	renderFarmToggle()
	fb.farmStatus = msg
end
human.stoppers.farm = function(m) if state.AutoFarm then stopFarm(m) end end

-- Refill an empty tile if it's ready. Returns true if it did something.
local function tryPlace(t)
	local layer, _, b = tileState(t)
	if layer then return false end
	if t.placed then
		-- our block vanished without us breaking it = server rejected the place (echoed
		-- the tile back). Never refund it blindly: if the server never had it (client bag
		-- showed a block the server doesn't have), the refund makes it place-reject-refund
		-- forever. Copy the server's bag instead; 0 left = "out of blocks" (-> Fetch).
		t.placed = false
		fb.placeRejects = (fb.placeRejects or 0) + 1
		fb.farmRejectRun = (fb.farmRejectRun or 0) + 1
		if fb.farmRejectRun >= 5 then
			resyncBag()
			stopFarm("place keeps getting rejected · stopped")
			return true
		end
		fb.farmStatus = resyncBag() and "place rejected · bag re-synced" or "place rejected · backing off"
		task.wait(1)
		return true
	end
	if t.collecting then return false end -- its pickup step is on
	if fb.farmDrain then return false end -- emptying the tiles for a trip
	if os.clock() < (t.placeAfter or 0) then return false end
	if fb.tileDrops(t) then -- drops there: go get them now (no waiting out DROP_WAIT)
		-- The step runs on its own thread so the other tiles keep getting hit and refilled meanwhile
		-- (a player punches while stepping; reach is 4, the step under 1.1; the step never enters
		-- another farm tile, and the body check below still runs). Measured 11-10: pickups were 32
		-- steps per 23 blocks and 34% of the time, with no hits or places during them.
		-- Usually the per-frame watcher below has started it already.
		return fb.farmCollect(t)
	end
	-- none yet: they may still be on the way (~ping) before we build over the spot
	if os.clock() - (t.brokeAt or 0) < (t.dropWait or DROP_WAIT) then return false end
	-- the real client never builds into your own body; the server checks it against your last
	-- `move` (fb.pos), which trails a step back by up to a packet. Seen in it = place a beat after
	-- the last time (the move packet is unreliable, the place reliable: no order between them).
	for _, p in ipairs({ fb.player.state(), fb.pos }) do
		if p and p.x + 0.3 > t.x and p.x - 0.3 < t.x + 1 and p.y > t.y and p.y - 0.95 < t.y + 1 then
			t.placeAfter = os.clock() + 0.15
			return false
		end
	end
	local pick = farmBlock()
	if not pick then
		fb.farmStatus = "out of blocks"
		return false
	end
	local bgPick = itemDB[pick].background
	if bgPick and b ~= 0 then
		fb.farmStatus = "background taken · pick an fg block"
		return false
	end
	local pl = bgPick and "bg" or "fg"
	t.mine, t.placed, fb.farmLast = pick, true, pick
	local sd = seedOf(pick)
	if sd then fb.farmSeeds[sd] = true end
	placeTile(pl, t.x, t.y, pick)
	t.placedAt, t.settle = os.clock(), human.gap(SETTLE) -- humanizer: place -> first hit isn't a constant
	if fb.world[pl][t.y][t.x] ~= pick then -- local replay didn't take: stop before we drain the bag
		fb.farmStatus = "place didn't show · stopped"
		state.AutoFarm = false
		renderFarmToggle()
	end
	return true
end

-- Break our settled block on this tile, refilling the other tiles between hits.
local function tryBreak(t)
	local layer, id = tileState(t)
	if not layer then return false end
	if id ~= t.mine then -- not ours (someone built here): leave it
		fb.farmStatus = "tile taken"
		return false
	end
	if os.clock() - (t.placedAt or 0) < (t.settle or SETTLE) then return false end
	fb.farmStatus = "breaking " .. itemDB[id].name
	local grid = fb.world[layer]
	local n, broke = hitsFor(id), false
	for i = 1, n do
		if not state.AutoFarm or fb.farmCheckOpen or grid[t.y][t.x] ~= id then return true end
		for _, o in ipairs(fb.farmTiles) do
			if o ~= t then tryPlace(o) end
		end
		hitTile(t.x, t.y, i == n and function()
			if state.AutoFarm and grid[t.y][t.x] == id then
				finishBreak(layer, t.x, t.y, true)
				broke = true
			end
		end)
	end
	if broke then
		t.placed, t.brokeAt, t.dropWait = false, os.clock(), human.gap(DROP_WAIT) -- break -> refill too
		fb.farmBroken += 1
		fb.farmRejectRun = 0
		human.cycle(0.1)
		if human.drift() then fb.hitAt = (fb.hitAt or 0) + human.gap(HIT_GAP) end -- whiff: a swing slot lost
	end
	return true
end

local farmTrip -- (trip) -> leave, do it, come back; defined after the Path section (needs the bot)

-- Why we need to leave the farm, if we do: { drop = seedId } or { fetch = blockId }.
local function tripNeeded()
	if state.FarmDrop then
		for sd in pairs(fb.farmSeeds) do
			if fb.inv:count(sd) >= 200 then return { drop = sd } end
		end
	end
	local want = fb.farmPick or fb.farmLast
	if state.FarmFetch and want and not farmBlock() then return { fetch = want } end
end

local function farmStep()
	if not state.AutoFarm then
		task.wait(0.2)
		return
	end
	if human.idle() then fb.farmStatus = human.status task.wait(0.25) return end
	local s = fb.player.state()
	if not fb.collectT then -- off the anchor on purpose while a pickup step runs
		if math.abs(s.x - fb.farmAnchor.x) > 0.4 or math.abs(s.y - fb.farmAnchor.y) > 0.4 then
			fb.farmStatus = "you moved · go back or re-toggle"
			task.wait(0.2)
			return
		end
		if math.abs(s.x - fb.farmAnchor.x) > 0.06 then stepToX(fb.farmAnchor.x, 1.5) return end -- center first
	end
	-- Trip due: stop refilling and leave once our blocks are broken (they'd box you in).
	local trip = tripNeeded()
	fb.farmDrain = trip ~= nil
	if trip and not fb.collectT and os.clock() >= fb.tripRetryAt then
		local busy = false
		for _, t in ipairs(fb.farmTiles) do
			local layer, id = tileState(t)
			if layer and id == t.mine then busy = true end
		end
		if not busy then
			farmTrip(trip)
			return
		end
	end
	local did = false
	for _, t in ipairs(fb.farmTiles) do
		if not state.AutoFarm then return end
		did = tryBreak(t) or tryPlace(t) or did
	end
	if not did then task.wait(0.03) end
end
task.spawn(function()
	while screenGui.Parent and fb.gen == myGen do
		local ok, err = pcall(farmStep)
		if not ok then
			fb.farmStatus = "error: " .. tostring(err)
			task.wait(0.5)
		end
	end
end)

-- ===== Path: walk to a drop with the game's own physics =====
-- The game reads MobileControls.dir() (-1/0/1) and .jumping() every physics frame and adds
-- them to the keyboard (Game.lua ~11906), so overriding those two is the same as pressing
-- keys: no position spoofing, the server just sees normal walking/jumping.
-- Routes: A* over standable tiles where every edge is a move simulated with a copy of the
-- game's physics step (Game.lua ~11930-12050, verified v893), so jumps are exactly as high
-- and as long as the real ones. Hazards are read from ItemDB live, so the Anti toggles apply.
local function findMobile()
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and type(rawget(t, "dir")) == "function" and type(rawget(t, "jumping")) == "function"
			and type(rawget(t, "busy")) == "function" then
			return t
		end
	end
end

-- Wrap once per session; the wrappers read fb.botInput live so re-runs never stack them.
-- getgc can miss the table at load, so features retry via fb.hookMobile() when switched on.
-- Player effects the server sets as attributes holding a server time (v1348 ghosts: Slimed, Mind
-- Control; Muddy is older). Game: Mind flips left/right after adding this input; Muddy / Slimed
-- halve walk speed and cut the jump to ×0.7 / ×0.6.
fb.effect = function(attr)
	return (players.LocalPlayer:GetAttribute(attr) or 0) > workspace:GetServerTimeNow()
end
fb.hookMobile = function()
	if fb.mcHooked then return true end
	local mc = findMobile()
	if not mc then return false end
	fb.mcHooked = true
	local origDir, origJump = mc.dir, mc.jumping
	local botJump = false
	mc.dir = function() -- called first each physics frame, so it computes both inputs
		local f = fb.botInput
		if f then
			local ok, d, j = pcall(f)
			botJump = ok and j or false
			d = ok and d or 0
			return fb.effect("MindUntil") and -d or d -- the game flips it back
		end
		botJump = false
		return origDir()
	end
	mc.jumping = function()
		return botJump or origJump()
	end
	return true
end
fb.hookMobile()

local JUMP_V, BOUNCE_V = -19.8997487421324, -28.854635676091977
local SIM = { solid = {}, jump = 1, ban = {} } -- per-plan caches; ban = jumps that failed for real
-- A jump the bot really tried and missed (sim said yes, the game said no): 2 misses from the same
-- tile = the planner leaves that move out there for 10 min, so it can't retry it forever.
function SIM.banKey(fx, fy, m) return string.format("%s|%d|%d|%s", tostring(fb.world and fb.world.name), fx, fy, tostring(m)) end
function SIM.banned(fx, fy, m)
	local b = next(SIM.ban) and SIM.ban[SIM.banKey(fx, fy, m)]
	return b and b.n >= 2 and os.clock() - b.at < 600
end
function SIM.missed(step)
	if step.m.walk then return end
	local k = SIM.banKey(step.fx, step.fy, step.m)
	local b = SIM.ban[k]
	if not b or os.clock() - b.at > 600 then b = { n = 0 } SIM.ban[k] = b end
	b.n, b.at = b.n + 1, os.clock()
end

local function tileItem(x, y)
	local row = fb.world.fg[y]
	return row and itemDB[row[x]]
end
local function solid(x, y) -- the game's own solidAt (doors, gates, area access), cached per plan
	local k = y * 100000 + x
	local v = SIM.solid[k]
	if v == nil then
		if fb.player.solidAt then
			v = fb.player.solidAt(x, y) and true or false
		else -- ponytail: ItemDB fallback ignores doors/gates/area access
			local it = (x < 0 or x >= fb.world.w or y >= fb.world.h) or tileItem(x, y)
			v = it == true or (it and it.solid) or false
		end
		SIM.solid[k] = v
	end
	return v
end
local function boxHits(x, y) -- player box: 0.3 each side, 0.95 tall, y = feet
	for ty = math.floor(y - 0.95), math.floor(y - 0.0001) do
		for tx = math.floor(x - 0.3), math.floor(x + 0.2999) do
			if solid(tx, ty) then return true end
		end
	end
	return false
end
local function landsOnPlatform(x, py, y)
	local ty = math.floor(y)
	if ty + 0.001 < py then return false end
	for tx = math.floor(x - 0.3), math.floor(x + 0.2999) do
		local it = tileItem(tx, ty)
		if it and it.platform then return true end
	end
	return false
end
local function underFeet(x, y, flag)
	local ty = math.floor(y + 0.02)
	for tx = math.floor(x - 0.29), math.floor(x + 0.29) do
		local it = tileItem(tx, ty)
		if it and it[flag] then return true end
	end
	return false
end
-- Laser Grid (laserAt, Game.lua ~10538): your first touch arms it; it fires after
-- (#laserWarm + 1) * laserStep s (1.25s for id 5666) for laserOn s (2s), re-arms 4.5s after
-- the trigger. Not solid. So crossing it fast is legit: allow a move to touch each laser
-- tile for up to warm-up minus a margin, but never end a move inside one.
local function laserWarm(it) return (#it.laserWarm + 1) * it.laserStep end

-- false = touched something deadly. A hair wider than the game's checks: stay clear.
-- Records laser contact in s.lasers[key] = { x, y, first touch time } and s.inLaser.
local function touchesHazard(s)
	if SIM.noHaz then return false end -- debug: "is it the hazards that block the route?"
	s.inLaser = false
	for ty = math.floor(s.y - 0.97), math.floor(s.y + 0.02) do
		for tx = math.floor(s.x - 0.32), math.floor(s.x + 0.32) do
			local it = tileItem(tx, ty)
			if it then
				if it.laser and it.laserWarm then
					local k = ty * 100000 + tx
					local c = s.lasers[k]
					if not c then
						s.lasers[k] = { x = tx, y = ty, t = s.t }
					elseif s.t - c.t > laserWarm(it) - 0.25 then
						return true -- still in it when it fires
					end
					s.inLaser = true
				elseif it.deadly or it.hurts or it.bumper or it.laser then
					return true
				end
			end
		end
	end
	return false
end

-- One physics frame, mirrored line by line from the game's step. false = touched a hazard.
local function simStep(s, dir, jump, dt)
	local target = dir * 7.2 * SIM.speed
	local same = not (dir == 0 or not (s.vx * dir >= 0))
	local a = same and (s.g and 36 or 22) or (s.g and 48 or 17)
	if s.g and underFeet(s.x, s.y, "slippery") then a *= same and 0.3 or 0.06 end
	if s.vx < target then s.vx = math.min(target, s.vx + a * dt) else s.vx = math.max(target, s.vx - a * dt) end
	s.t += dt
	if s.g then s.jg, s.aj = s.t, false end
	if jump and not s.pj then s.jp = s.t end
	if s.t - s.jg <= 0.08 and s.vy >= 0 and s.t - s.jp <= 0.1 then
		s.vy, s.jp, s.jg, s.rising = JUMP_V * SIM.jump, -1, -1, true
	elseif jump and not s.pj and not s.aj and SIM.wings then -- wings: one mid-air jump until you land
		s.vy, s.jp, s.aj, s.rising = JUMP_V, -1, true, true -- v1348: mud / slime don't touch this one
	end
	s.pj = jump
	if s.vy >= 0 then s.rising = false end
	s.vy = math.min(s.vy + ((s.rising and not jump) and 143 or 55) * SIM.grav * dt, 24)
	if jump and s.vy > 2.5 and SIM.slowClamp then s.vy = 2.5 end -- doubleJump == true wings / slowFall items
	s.g = false
	local n = math.max(1, math.ceil(math.max(math.abs(s.vx), math.abs(s.vy)) * dt / 0.3))
	local h = dt / n
	for _ = 1, n do
		if s.vx ~= 0 then
			s.x += s.vx * h
			if boxHits(s.x, s.y) and not s.g then -- auto step-up, max 0.3
				for k = 1, 6 do
					if not boxHits(s.x, s.y - k * 0.05) then
						s.y -= k * 0.05
						break
					end
				end
			end
			if boxHits(s.x, s.y) then
				s.x = s.vx > 0 and math.floor(s.x + 0.3) - 0.301 or math.floor(s.x - 0.3) + 1.301
				s.vx = 0
			end
		end
		local py = s.y
		s.y += s.vy * h
		if boxHits(s.x, s.y) then
			if s.vy > 0 then
				s.y, s.g, s.vy = math.floor(s.y) - 0.001, true, 0
				if underFeet(s.x, s.y, "bouncy") then s.vy, s.g = BOUNCE_V, false end
			else -- head bump: vy is NOT reset, so you hover under the ceiling until gravity wins
				s.y = math.floor(s.y - 0.95) + 1.951
			end
		elseif s.vy > 0 and landsOnPlatform(s.x, py, s.y) then
			s.y, s.g, s.vy = math.floor(s.y) - 0.001, true, 0
		end
		if touchesHazard(s) then return false end
	end
	if not s.g and s.vy >= 0 and (boxHits(s.x, s.y + 0.01) or landsOnPlatform(s.x, s.y, s.y + 0.01)) then
		s.g, s.vy = true, 0
	end
	return true
end

local function standable(cx, ry)
	if solid(cx, ry) then return false end
	local below = tileItem(cx, ry + 1)
	return solid(cx, ry + 1) or (below and below.platform) or false
end
-- Tile you're standing in: body column + row (feet y = ground - 0.001).
local function nodeOf(x, y)
	local ry = math.floor(y - 0.01) -- feet are ground-0.001 after landing, exactly ground after goTo
	for _, cx in ipairs({ math.floor(x), math.floor(x - 0.3), math.floor(x + 0.3) }) do
		if standable(cx, ry) then return cx, ry end
	end
end

-- Moves tried from every tile. walk: to a column's center (tx). jump: hold to the apex
-- (`hold`) or tap (~1.4 tile hop); sideways input `d` starts after `td` seconds, so
-- "jump up a 1-wide shaft, then slide onto the ledge" is a td > 0 jump.
-- dj = double jump (wings): full jump, second press at the apex (~0.36s), only tried when
-- you wear something with doubleJump.
local MOVES = { { walk = -1 }, { walk = 1 }, { d = 0, td = 0, hold = true }, { d = 0, td = 0, dj = true } }
for _, d in ipairs({ -1, 1 }) do
	for _, td in ipairs({ 0, 0.2, 0.35 }) do
		MOVES[#MOVES + 1] = { d = d, td = td, hold = true }
	end
	MOVES[#MOVES + 1] = { d = d, td = 0, hold = false }
	MOVES[#MOVES + 1] = { d = d, td = 0, dj = true }
	MOVES[#MOVES + 1] = { d = d, td = 0.36, dj = true }
	-- drop: creep off the edge (<= 1.5 t/s), steer back once airborne = land on the ledge right under
	-- the one you left. walk / jumps leave the edge at up to 7.2 t/s, which needs ~1.5 tiles of air
	-- (accel 17) to turn around: on stacked rows they fell past the next row to the bottom.
	MOVES[#MOVES + 1] = { drop = d, v = 1.5 }
end

-- Inputs for move m, t seconds in, from tile (cx, ry). Same function drives the sim and the bot.
local function moveInput(m, t, x, vx, vy, grounded, cx, y, ry)
	if m.drop then
		if not grounded then return -m.drop, false end
		if y > ry + 1.5 then return 0, false end -- landed lower: stop
		return (vx * m.drop < m.v) and m.drop or 0, false
	end
	if m.walk then
		local dx = (m.tx or cx + m.walk) + 0.5 - x
		local brake = vx * vx / 96 + 0.06 -- stopping distance at decel 48
		return (dx * m.walk > brake) and m.walk or 0, false
	end
	if grounded and t > 0.1 then return 0, false end -- landed: let go and stop
	local jump
	if m.dj then -- hold, let go just before the apex, press again at it (rising edge = air jump)
		jump = t < 0.35 or (t >= 0.38 and (t < 0.42 or vy < 0))
	else
		jump = t < 0.05 or (m.hold and vy < 0) or (not m.hold and t < 0.03)
	end
	return t >= m.td and m.d or 0, jump
end

local function moveDone(t, grounded, vx)
	return t > 0.06 and grounded and math.abs(vx) < 0.3
end

-- The game's touch pickup (Game.lua updateDrops): a drop at (dx, dy) is taken when |dx - x| < 0.6
-- and feet - 1.25 < dy < feet + 0.3 (x = body center, feet = y). Nothing else picks drops up now,
-- so every drop route has to bring you there. Small margins for the sim's rounding.
local function touches(x, feet, dx, dy)
	return math.abs(dx - x) < 0.55 and dy > feet - 1.2 and dy < feet + 0.25
end

-- Returns landing tile + time, and `grab` = your body passed over the target (SIM.gx/gy)
-- mid-move, so the drop gets picked up in the air by the touch pickup.
local function simMove(cx, ry, m, dt)
	if m.dj and not SIM.wings then return nil end
	dt = dt or 1 / 60
	local s = { x = cx + 0.5, y = ry + 0.999, vx = 0, vy = 0, g = true, t = 0, jg = 0, jp = -1, pj = false,
		rising = false, lasers = {}, inLaser = false }
	local t, grab = 0, false
	for _ = 1, math.ceil(3 / dt) do -- 3s cap
		local d, j = moveInput(m, t, s.x, s.vx, s.vy, s.g, cx, s.y, ry)
		if not simStep(s, d, j, dt) then return nil end
		t += dt
		-- no edge within reach: walk covers flat ground, don't sim a 3s creep from every node
		if m.drop and s.g and s.y < ry + 1.5 and math.abs(s.x - cx - 0.5) > 1.3 then return nil end
		if not grab and SIM.gx and touches(s.x, s.y, SIM.gx, SIM.gy) then
			grab = true
		end
		if moveDone(t, s.g, s.vx) then
			if s.inLaser then return nil end -- never stop inside a laser
			local nx, ny = nodeOf(s.x, s.y)
			return nx, ny, t, grab, next(s.lasers) and s.lasers or nil
		end
	end
end

-- A* from (sx, sy) to any tile where standing (centered) touches the drop at (gx, gy).
-- Returns steps { m, fx, fy, tx, ty } with straight walks merged, or nil + reason.
-- ponytail: linear open-list scan + 2500-node cap; binary heap if big worlds need it
-- Worn item with doubleJump (wings) = one air jump; doubleJump == true wings or a slowFall
-- item also clamp your fall to 2.5 while jump is held (Game.lua physics step).
local function wingsInfo()
	local ok, worn = pcall(function() return debug.getupvalues(fb.avatar.buildRange)[1] end)
	local wings
	for _, id in pairs(ok and type(worn) == "table" and worn or {}) do
		local it = itemDB[id]
		if it and it.doubleJump then wings = it end
	end
	local slow = fb.avatar and fb.avatar.slowFall and fb.avatar.slowFall()
	return wings ~= nil, (wings and wings.doubleJump == true) or slow or false
end

local function planPath(sx, sy, gx, gy, opts)
	SIM.solid = {}
	SIM.noHaz = opts and opts.noHazards or false
	local mud, slime = fb.effect("MuddyUntil"), fb.effect("SlimedUntil")
	SIM.speed = (fb.avatar and fb.avatar.wornSpeed and fb.avatar.wornSpeed() or 1) * (fb.world.speedScale or 1)
		* (mud and 0.5 or 1) * (slime and 0.5 or 1)
	SIM.jump = (mud and 0.7 or 1) * (slime and 0.6 or 1)
	SIM.grav = fb.world.gravityScale or 1
	SIM.wings, SIM.slowClamp = wingsInfo()
	local exact = opts and opts.exact -- goal = the tile (gx, gy) itself, no mid-air grabs
	-- goal(x, y): goal = any node it accepts, nearest by route (no heuristic, no mid-air grabs).
	-- Auto Break: "a block is in reach from here" - through walls, so blocks you can't walk to count.
	local goalFn = opts and opts.goal
	local grabs = not exact and not goalFn and not (opts and opts.stand) -- stand: goal = standing on it only
	SIM.gx, SIM.gy = grabs and gx or nil, grabs and gy or nil
	local function key(x, y) return y * 100000 + x end
	local function isGoal(x, y)
		if goalFn then return goalFn(x, y) end
		if exact then return x == math.floor(gx) and y == math.floor(gy) end
		return touches(x + 0.5, y + 1, gx, gy)
	end
	local g, came, open = {}, {}, {}
	local function route(k, last) -- steps to node k (+ an optional final move), straight walks merged
		local steps = {}
		while came[k] do
			table.insert(steps, 1, came[k].step)
			k = came[k].from
		end
		steps[#steps + 1] = last
		local merged = {}
		for _, st in ipairs(steps) do
			local prev = merged[#merged]
			if prev and prev.m.walk and st.m.walk == prev.m.walk and st.fy == prev.ty and st.ty == prev.ty then
				prev.tx = st.tx
				prev.m = { walk = st.m.walk, tx = st.tx }
				for k, v in pairs(st.lasers or {}) do
					prev.lasers = prev.lasers or {}
					prev.lasers[k] = v
				end
			else
				merged[#merged + 1] = { m = st.m, fx = st.fx, fy = st.fy, tx = st.tx, ty = st.ty, lasers = st.lasers, grab = st.grab }
			end
		end
		return merged
	end
	local sk = key(sx, sy)
	g[sk], open[sk] = 0, { x = sx, y = sy }
	local expanded = 0
	while next(open) do
		local bk, bn, bf
		for k, n in pairs(open) do
			local f = g[k] + (goalFn and 0 or math.sqrt((n.x - gx) ^ 2 + (n.y - gy) ^ 2) / 7.2)
			if not bf or f < bf then bk, bn, bf = k, n, f end
		end
		open[bk] = nil
		if isGoal(bn.x, bn.y) then return route(bk) end
		expanded += 1
		if expanded > 2500 then return nil, "too far / no route" end
		if expanded % 20 == 0 then task.wait() end -- keep the client smooth while planning
		for _, m in ipairs(MOVES) do
			if SIM.banned(bn.x, bn.y, m) then continue end
			local nx, ny, t, grab, lasers = simMove(bn.x, bn.y, m)
			if nx and grab then -- this jump passes through the drop: done (pickup happens mid-air)
				return route(bk, { m = m, fx = bn.x, fy = bn.y, tx = nx, ty = ny, lasers = lasers, grab = true })
			end
			if nx and (nx ~= bn.x or ny ~= bn.y) then
				local nk = key(nx, ny)
				-- flat walks get merged into one run, so cost them at running speed; jumps pay
				-- their sim time + a penalty so we only hop when walking can't get there
				local flatWalk = m.walk and ny == bn.y
				local ng = g[bk] + (flatWalk and 1 / 7.2 or t + 0.3)
				-- the game steps physics by the frame (up to 1/30 s), the sim by 1/60: an upward jump
				-- that lands elsewhere at 30-40 FPS is a coin flip in game (1-wide shafts, wing double
				-- jumps) -> costs 5 s extra, so any steady route wins and this one is the last resort
				if ny < bn.y and not m.walk then
					for _, dt in ipairs({ 1 / 30, 1 / 40 }) do
						local x2, y2 = simMove(bn.x, bn.y, m, dt)
						if x2 ~= nx or y2 ~= ny then ng += 5 break end
					end
				end
				if not g[nk] or ng < g[nk] - 1e-6 then
					g[nk] = ng
					came[nk] = { from = bk, step = { m = m, fx = bn.x, fy = bn.y, tx = nx, ty = ny, lasers = lasers } }
					open[nk] = { x = nx, y = ny }
				end
			end
		end
	end
	return nil, "no route"
end

fb.planPath = planPath -- debug: plan a route without walking it
-- Worn items / speed / slowFall + the game's onDrop (wornSpeed + buildRange live here). A scan can
-- miss it (v1210, after a teleport: nil at load, there minutes later), so callers look again while it's nil.
function fb.findAvatar()
	if not fb.avatar then
		if setthreadidentity then pcall(setthreadidentity, 8) end
		for _, t in pairs(getgc(true)) do
			if type(t) == "table" and type(rawget(t, "wornSpeed")) == "function" and type(rawget(t, "buildRange")) == "function" then
				fb.avatar = t
				break
			end
		end
	end
	return fb.avatar
end
fb.findAvatar()

-- Route dots on the map (tile layer pans/zooms with the world).
local pathDots = tilesLayer:FindFirstChild("PathDots") or Instance.new("Folder")
pathDots.Name = "PathDots"
pathDots.Parent = tilesLayer
local function drawPath(steps)
	pathDots:ClearAllChildren()
	for i, st in ipairs(steps or {}) do
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(12, 12)
		dot.Position = UDim2.fromOffset((st.tx + 0.5) * TILE, (st.ty + 0.5) * TILE)
		dot.BackgroundColor3 = i == #steps and ACCENT or MUTED
		dot.BorderSizePixel = 0
		dot.ZIndex = 60
		corner(dot, 6)
		dot.Parent = pathDots
	end
end

-- Executor: runs inside the game's physics frame (via the dir() wrapper).
local bot -- { drop, steps, i, phase = "plan"|"center"|"move", t0, replans }
local MOVE_KEYS = { Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Space,
	Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.W }
local function botStop(msg)
	bot = nil
	if fb.gen == myGen then -- an older run's stop must not end the newer run's walk
		fb.botInput, fb.pathStatus = nil, msg
	end
	pathDots:ClearAllChildren()
end

-- Leave like the menu's Exit button: WorldMenu.openPicker() = leave() (LeaveWorld + reset
-- other players) and opens the world picker, so the UI stays consistent.
-- Found at load: the bot runs inside the game's own physics thread (identity 2), where
-- getgc doesn't see the WorldMenu table.
local function findWorldMenu()
	for _, t in pairs(getgc(true)) do
		if type(t) == "table" and type(rawget(t, "openPicker")) == "function" and type(rawget(t, "enterFailed")) == "function" then
			return t
		end
	end
end
fb.worldMenu = findWorldMenu() or fb.worldMenu
local function leaveWorld()
	if not fb.worldMenu and setthreadidentity then
		setthreadidentity(8)
		fb.worldMenu = findWorldMenu()
	end
	if fb.worldMenu then
		fb.worldMenu.openPicker()
	else
		net.call("LeaveWorld") -- fallback: leaves, but the picker won't open
	end
end

-- Plan from where you stand. No route yet = "wait" (stay armed, don't move) instead of
-- stopping; botFrame re-plans as soon as the area changes. `waiting` re-plans don't count
-- towards the "lost" limit, only re-plans after a move went wrong do.
local function replan(waiting)
	local b = bot
	if not waiting then
		b.replans += 1
		if b.replans > 6 then return botStop("lost the route · stopped") end
	end
	b.phase = "plan"
	if not waiting then fb.pathStatus = "planning…" end
	task.spawn(function()
		local s = fb.player.state()
		local t0 = os.clock()
		while not s.grounded and os.clock() - t0 < 2 do -- wait to land
			task.wait()
			s = fb.player.state()
		end
		if bot ~= b then return end
		SIM.solid = {} -- the world may have changed since the last plan
		local cx, ry = nodeOf(s.x, s.y)
		local steps, why
		if cx then
			steps, why = planPath(cx, ry, b.drop.x, b.drop.y, { exact = b.drop.exact, goal = b.drop.goal, stand = b.stand })
		else
			why = "not on solid ground"
		end
		if bot ~= b then return end -- stopped meanwhile
		if not steps then
			b.phase, b.waitAt = "wait", os.clock()
			fb.pathStatus = "waiting · " .. why .. " (open a way)"
			pathDots:ClearAllChildren()
			return
		end
		b.steps, b.i, b.phase, b.t0, b.tpCol = steps, 1, "center", b.gt or 0, nil
		fb.pathStatus = string.format("walking · %d moves", #steps)
		drawPath(steps)
	end)
end

-- Cheap fingerprint of the tiles between you and the target (+ where you stand), so a
-- waiting bot can notice a broken/placed block within 0.25s. Your own breaks are not echoed
-- by the server (no TileChanged for you), so we look at the local grid instead.
local function areaKey(b, s)
	local fg = fb.world.fg
	local px, py = math.floor(s.x), math.floor(s.y)
	local gx, gy = math.floor(b.drop.x), math.floor(b.drop.y)
	local h = 0
	for y = math.min(py, gy) - 12, math.max(py, gy) + 12 do
		local row = fg[y]
		if row then
			for x = math.min(px, gx) - 12, math.max(px, gx) + 12 do
				h = (h * 31 + (row[x] or 0)) % 2147483647
			end
		end
	end
	return string.format("%d:%d:%d:%s", h, px, py, tostring(s.grounded))
end

local function botFrame()
	local b = bot
	local s = fb.player.state()
	local now = os.clock()
	-- b.gt = game clock. The game steps physics by min(frame dt, 1/30), so under 30 FPS it runs
	-- slower than real time; move timing (jump hold, sideways delay, timeouts) must follow it the way
	-- the sim does, or jumps let go too early and routes fail at low FPS. b.t0 is on this clock.
	b.gt = (b.gt or 0) + math.min(now - (b.last or now), 1 / 30)
	b.last = now
	if s.dead then
		botStop("stopped · died")
		return 0, false
	end
	-- `taking` is only set while OUR client's TakeDrop is in flight (touch pickup or Auto
	-- Collect), so seen-taking + gone = we got it; gone without it = someone else did. A take
	-- can finish between two physics frames, so a bag / gem count rise counts too.
	if b.drop.taking then b.sawTaking = true end
	if not b.sawTaking and b.have0 and b.have() > b.have0 then b.sawTaking = true end
	local gone = not table.find(fb.drops, b.drop)
	if not b.drop.tile and (gone or (b.sawTaking and b.drop.id ~= 112 and fb.inv:room(b.drop.id) <= 0)) then -- got it / got what fits
		if b.sawTaking and state.PathLeave and not b.trip then
			botStop("got it · leaving world")
			task.delay(human.react(), leaveWorld)
		else
			botStop(b.sawTaking and "done · got it" or "done · drop is gone")
		end
		return 0, false
	end
	if b.phase == "plan" then return 0, false end
	if b.phase == "wait" then -- armed, not moving: your keys work as usual
		if now - (b.checkAt or 0) >= 0.25 then
			b.checkAt = now
			local key = areaKey(b, s)
			if key ~= b.waitKey or now - b.waitAt > 5 then -- something changed (or 5s fallback: doors/switches)
				b.waitKey = key
				replan(true)
			end
		end
		return 0, false
	end
	-- the bot is driving from here on: your movement keys take over and stop it (not while you
	-- type in chat / a text box: those keys are letters then)
	for _, k in ipairs(userInputService:GetFocusedTextBox() == nil and MOVE_KEYS or {}) do
		if userInputService:IsKeyDown(k) then
			botStop("stopped · you took over")
			return 0, false
		end
	end
	local step = b.steps[b.i]
	if not step then
		if b.drop.tile then
			botStop("arrived")
		elseif b.gt - b.t0 > 3 then
			botStop("arrived · drop not taken")
		end
		return 0, false -- standing at the goal: Auto Collect / touch pickup takes it
	end
	if b.phase == "center" then -- sims start centered and still; get there first
		local dx = step.fx + 0.5 - s.x
		if s.grounded and (math.abs(dx) > 1.2 or math.floor(s.y - 0.01) ~= step.fy) then
			replan(true) -- you moved while it was planning/waiting: plan from here instead
			return 0, false
		end
		if s.grounded and math.abs(dx) < 0.1 and math.abs(s.vx) < 0.3 then
			-- a laser this move crosses is mid-cycle (armed by an earlier touch): wait it out
			local la = fb.world.lasersAt
			for _, p in pairs(step.lasers or {}) do
				local trig = la and la[p.y * fb.world.w + p.x]
				local it = tileItem(p.x, p.y)
				if trig and it and it.laserWarm and now - trig < laserWarm(it) + it.laserOn + 0.15 then
					fb.pathStatus = "waiting for laser"
					return 0, false
				end
			end
			b.phase, b.t0 = "move", b.gt
		else
			if b.gt - b.t0 > 2 then replan() return 0, false end
			local brake = s.vx * s.vx / 96 + 0.05
			return (math.abs(dx) > brake) and (dx > 0 and 1 or -1) or 0, false
		end
	end
	local t = b.gt - b.t0
	if moveDone(t, s.grounded, s.vx) then
		local cx, ry = nodeOf(s.x, s.y)
		if cx == step.tx and ry == step.ty then
			b.i += 1
			b.phase, b.t0 = "center", b.gt
			fb.pathStatus = string.format("walking · %d/%d", b.i - 1, #b.steps)
		else
			SIM.missed(step)
			replan()
		end
		return 0, false
	end
	if t > 3 then SIM.missed(step) replan() return 0, false end
	return moveInput(step.m, t, s.x, s.vx, s.vy, s.grounded, step.fx, s.y, step.fy)
end

-- mode: nil = Path page click; "break" / "farm" / "harvest" / "plant" / "collect" = Auto Break /
-- Farm / Harvest / Plant / Collect trips. Every walk is walk + jump with the game's own input
-- (no teleport anywhere). Trips never auto-leave the world.
local function goToDrop(d, mode)
	if fb.gen ~= myGen then return end -- an older run (re-run since) never takes the controls back
	fb.world = fb.world or findWorld()
	fb.player = fb.player or findPlayer()
	fb.drops = fb.drops or findDrops()
	fb.findAvatar()
	if not (fb.hookMobile() and fb.world and fb.player and fb.drops) then
		fb.pathStatus = "not ready · enter a world"
		return
	end
	-- stand: Auto Harvest leftovers lie on the floor, so walk onto them instead of grabbing them
	-- mid-jump (a grazing grab can fall between two frames at low FPS: lands past it, comes back)
	bot = { drop = d, replans = -1, phase = "plan", t0 = 0, trip = mode ~= nil, stand = mode == "harvest" and not d.tile }
	if not d.tile and fb.inv then -- how much of it we hold now: a rise = we picked it up
		bot.have = d.id == 112 and function() return fb.gemsNow() or 0 end -- per frame: local only, never GetGems
			or function() return fb.inv:count(d.id) end
		local ok, n = pcall(bot.have)
		bot.have0 = ok and type(n) == "number" and n or nil
	end
	fb.botInput = botFrame
	replan()
end
fb.goTo = goToDrop -- debug: fb.goTo({ x = 71.5, y = 33.5, tile = true }) walks to a tile

-- Server pull-back (MoveTo) while the bot runs = stop at once, never push on.
net.moveTo.listen(function() -- ByteNet since v973; the old MoveTo remote no longer fires
	if bot and screenGui.Parent then
		fb.pullbacks = (fb.pullbacks or 0) + 1
		botStop("stopped · server pulled you back")
	end
end)

-- ===== Auto Farm trips: fetch dropped blocks / drop full seed stacks, then come back =====
-- Run the path bot to `target` and wait until it stops (or state[key] goes off). Gives up when
-- it has had no route for 4s or the trip takes over 45s. Defaults = Auto Farm trip.
local function runBot(target, mode, key, stop) -- stop() -> true: end the trip now
	key = key or "AutoFarm"
	goToDrop(target, mode or "farm")
	local t0 = os.clock()
	while bot and state[key] do
		if (bot.phase == "wait" and os.clock() - bot.waitAt > 4) or os.clock() - t0 > 45 then
			botStop("no route")
			break
		end
		if stop and stop() then
			botStop("stopped")
			break
		end
		if fb.farmCheckOpen then
			botStop("paused · answer the \"Are you still there?\" popup")
			break
		end
		task.wait(0.1)
	end
	if bot then botStop("stopped") end -- switched off mid-trip
end

-- Auto Collect: once you've stood still for 1s, walk (path bot) onto the nearest drop within 8
-- tiles you can take; the game's own touch pickup does the rest. Not while another auto mode or a
-- Path walk drives the bot, during humanizer pauses, or while "Are you still there?" is up.
task.spawn(function()
	local still = os.clock()
	while screenGui.Parent and fb.gen == myGen do
		task.wait(0.25)
		pcall(function()
			if not (state.AutoCollect and fb.player and fb.drops and fb.inv) then still = os.clock() return end
			local s = fb.player.state()
			if bot or s.dead or not s.grounded or math.abs(s.vx) > 0.05 then still = os.clock() return end
			if state.AutoFarm or state.AutoHarvest or state.AutoPlant or state.RowFarm or fb.autoOn or human.idle() then return end
			if os.clock() - still < 1 then return end
			local now, fg = os.clock(), fb.world and fb.world.fg
			local best, bd
			for _, d in ipairs(fb.drops) do
				local row = fg and fg[math.floor(d.y)]
				local inside = row and itemDB[row[math.floor(d.x)]]
				if (d.armed or d.id == 112) and d.uid and not (d.pending or d.display or d.taking or d.shut)
					and not (inside and inside.solid) and not inPile(d)
					and not (fb.dropSkip[d.uid] and fb.dropSkip[d.uid] > now) and human.seen(d, now)
					and (d.id == 112 or fb.inv:room(d.id) > 0) then
					local dd = (d.x - s.x) ^ 2 + (d.y - s.y) ^ 2
					if dd <= 64 and (not bd or dd < bd) then best, bd = d, dd end
				end
			end
			if not best then return end
			runBot(best, "collect", "AutoCollect")
			if table.find(fb.drops, best) then
				fb.dropSkip[best.uid] = os.clock() + 30 -- couldn't get it: leave it a while
			else
				fb.collected += 1
			end
			still = os.clock()
		end)
	end
end)

-- Are we standing on tile (x, y)? Then center on it by walking: a walk stops a hair off center,
-- and the farm tiles / drop direction need an exact x. Bang-bang on the game's ground physics
-- (Game.lua v973: accel 36 toward the input, 48 braking with none): press toward the center until
-- braking from here would just reach it, then let go. No goTo.
local function snapTo(x, y)
	local s = fb.player.state()
	SIM.solid = {}
	local cx, ry = nodeOf(s.x, s.y)
	if cx ~= x or ry ~= y then return false end
	stepToX(x + 0.5, 2)
	return true
end

local function goHome()
	local h = fb.farmHome
	fb.farmStatus = "going back"
	runBot({ x = h.x + 0.5, y = h.y + 0.5, tile = true, exact = true })
	if not (state.AutoFarm and snapTo(h.x, h.y)) then return false end
	local s = fb.player.state()
	fb.farmAnchor = { x = s.x, y = s.y }
	return true
end

-- Nearest pile of `id` we could take (not inside a block, not skipped).
local function nearestPile(id)
	local s = fb.player.state()
	local now, fg = os.clock(), fb.world.fg
	local best, bd
	for _, d in ipairs(fb.drops) do
		local row = fg[math.floor(d.y)]
		local inside = row and itemDB[row[math.floor(d.x)]]
		if d.id == id and d.uid and not (d.pending or d.display or d.taking or d.shut)
			and not (inside and inside.solid) and not (fb.dropSkip[d.uid] and fb.dropSkip[d.uid] > now) then
			local dist = (d.x - s.x) ^ 2 + (d.y - s.y) ^ 2
			if not bd or dist < bd then best, bd = d, dist end
		end
	end
	return best
end

-- A stash = a tile you stand on + the side the pile goes (dir). The game drops at
-- x + facing × 0.75 in your body row, so the pile lands on tile (x + dir, y).
-- Fits = standable + game's dropOk (no solid / entrance tile where the pile lands). Trees are
-- fine (full farms have no other tile): the pile guard keeps pile drops unarmed while Auto Harvest /
-- Auto Farm runs, so walking through the pile never takes it back.
local function spotFits(x, y, dir)
	local it = tileItem(x + dir, y)
	-- display / combiner: the game's onDrop puts the stack INTO it (display) or refuses (shut combiner)
	return standable(x, y) and not solid(x + dir, y) and not (it and (it.solid or it.entrance or it.display or it.combiner))
end
-- Closest reachable stash at least minDx columns left/right of tile h; the pile goes outward.
-- skip(x, y): pile tiles to leave out (Auto Rotate's full storage tiles).
local function findSpot(h, minDx, skip)
	SIM.solid = {}
	local cands = {}
	for dy = -4, 4 do
		for dx = -10, 10 do
			local dir = dx > 0 and 1 or -1
			if math.abs(dx) >= minDx and spotFits(h.x + dx, h.y + dy, dir) and not fb.othersAt(h.x + dx + dir, h.y + dy)
				and not (skip and skip(h.x + dx + dir, h.y + dy)) then
				cands[#cands + 1] = { x = h.x + dx, y = h.y + dy, dir = dir, score = math.abs(dx) - minDx + math.abs(dy) * 1.5 }
			end
		end
	end
	table.sort(cands, function(a, b) return a.score < b.score end)
	for i = 1, math.min(#cands, 6) do -- closest ones that the bot can actually reach
		local c = cands[i]
		if planPath(h.x, h.y, c.x + 0.5, c.y + 0.5, { exact = true }) then
			c.world = fb.world.name
			return c
		end
	end
end

-- Auto Farm's seed stash: 5+ tiles from the farm (off the way back), kept per world so every
-- 200 goes on the same pile.
local function dropSpot()
	SIM.solid = {}
	local sp = fb.dropSpot
	if sp and sp.world == fb.world.name and spotFits(sp.x, sp.y, sp.dir) then return sp end
	fb.dropSpot = findSpot(fb.farmHome, 5)
	return fb.dropSpot
end

-- Walk to stash sp, face the pile side, drop the whole stack of each id via the game's own
-- drop (fb.avatar.onDrop: dropOk check, bag remove, Net.drop, local drop).
-- v1111: a tile only holds so much; the server refuses more ("There's too much stuff here.").
-- The game's local drop is `pending` until the server confirms it (dropArrived removes it within
-- a ping); refused = it's still there 1.3s later (the game expires it at 1.5s), the stack is
-- still yours server-side, so the bag is read back and the stash grows one tile outward: stand
-- on the full pile tile, drop on the next (sp.n = pile tiles, kept for later trips + inPile).
-- Returns error or nil, + how many items were dropped.
-- mix: ids allowed to share a pile tile (default ids), e.g. Auto Harvest's block + seed.
local function dropStack(sp, ids, mode, key, mix)
	local found0 = os.clock()
	while not fb.findAvatar() and state[key or "AutoFarm"] and os.clock() - found0 < 8 do task.wait(0.5) end
	if not (fb.avatar and fb.avatar.onDrop) then return "drop function not found", 0 end
	local total = 0
	for _ = 1, 6 do
		local x = sp.x + sp.dir * ((sp.n or 1) - 1) -- stand here, the pile goes on x + dir
		if fb.othersAt(x + sp.dir, sp.y, mix or ids) then -- never mix: someone's items lie there
			return (sp.n or 1) > 1 and "drop spot full · set a new one" or "other items lie on the drop spot · set a new one", total
		end
		runBot({ x = x + 0.5, y = sp.y + 0.5, tile = true, exact = true }, mode, key)
		if not (state[key or "AutoFarm"] and snapTo(x, sp.y)) then return "couldn't reach the drop spot", total end
		-- facing = last non-zero walk input: press toward the pile for exactly one physics frame
		local function faceIt()
			local face = function() fb.botInput = nil return sp.dir, false end
			fb.botInput = face
			local t0 = os.clock()
			while fb.botInput == face and os.clock() - t0 < 1 do task.wait() end
			if fb.botInput == face then fb.botInput = nil end
		end
		faceIt()
		local full, refused = false, nil
		for _, id in ipairs(ids) do
			local n = fb.inv:count(id)
			if n > 0 then
				-- refused locally (bag unchanged): "Slow down!", a punch turned you (0.2s), or the tile
				-- in front won't take drops -> face again and retry twice, then try the next tile out
				for try = 1, 3 do
					if try > 1 then faceIt() end
					task.wait(try == 1 and 0.35 or 0.6) -- the game's "Slow down!" gap between drops
					fb.avatar.onDrop(id, n)
					if fb.inv:count(id) < n then break end
				end
				if fb.inv:count(id) >= n then refused = itemDB[id].name break end
				local p = fb.drops[#fb.drops]
				if p and p.pending and p.id == id then
					while table.find(fb.drops, p) and os.clock() - p.pending < 1.3 do task.wait(0.05) end
					if table.find(fb.drops, p) then
						full = true
						if not resyncBag() then fb.inv:add(id, n) end -- read failed: the server still has it
						break
					end
				end
				total += n
				fb.notePile(x + sp.dir, sp.y)
			end
		end
		if not (full or refused) then return nil, total end
		if fb.rlog then fb.rlog("drop refused", string.format("%s @ %d,%d in %s", tostring(refused or "full"), x + sp.dir, sp.y, fb.world.name)) end
		if not spotFits(x + sp.dir, sp.y, sp.dir) then
			return refused and ("the game won't drop " .. refused .. " here · set a new drop spot") or "drop spot full · set a new one", total
		end
		sp.n = (sp.n or 1) + 1
	end
	return "drop spot full · set a new one", total
end

local function dropSeeds(sd)
	local name = itemDB[sd].name
	local sp = dropSpot()
	if not sp then return "no spot 5+ tiles away to drop " .. name end
	fb.farmStatus = string.format("dropping %s @ %d,%d", name, sp.x + sp.dir, sp.y)
	local err, n = dropStack(sp, { sd })
	fb.seedsDropped = (fb.seedsDropped or 0) + n
	return err
end

farmTrip = function(trip)
	local pulls = fb.pullbacks or 0
	local err
	if trip.fetch then
		local name = itemDB[trip.fetch].name
		local pile = nearestPile(trip.fetch)
		if not pile then
			fb.farmStatus = "out of " .. name .. " · none dropped here"
			fb.tripRetryAt = os.clock() + 5
			return
		end
		fb.farmStatus = string.format("fetching %s ×%d", name, pile.n)
		fb.fetching, pile.armed = pile, true -- may be a stash pile: let this one be picked up
		runBot(pile, "collect")
		fb.fetching = nil
		if fb.inv:count(trip.fetch) == 0 then fb.dropSkip[pile.uid] = os.clock() + 30 end -- try another pile next
	else
		err = dropSeeds(trip.drop)
		if err then
			state.FarmDrop = false
			renderDropToggle()
		end
	end
	if not state.AutoFarm then return end
	local home = (fb.pullbacks or 0) == pulls and goHome()
	if (fb.pullbacks or 0) > pulls then return stopFarm("server pulled you back · stopped") end
	if not home then return stopFarm("couldn't get back to the farm · stopped") end
	fb.farmStatus = err and (err .. " · auto drop off") or nil
end

-- ===== Row Farm: walk out placing a row (a wall behind you), walk back breaking it =====
-- Start = the tile you stand on; the row runs along your body row toward the side with more room
-- (tie: right), up to rw.LEN blocks, on flat floor. It ends early at a wall / gap / door / hazard /
-- tile you can't edit / taken background (bg block). You need its LEN + 1 tiles: you end the walk
-- out one past the last block.
-- Nothing waits idle (11-11: the first version stopped on every tile and was ~2-3x slower than
-- Auto Farm). One per-frame walk input (rw.input -> rw.tx) + a scheduler loop:
--   Out: walk on without stopping; the tile you left gets its block as soon as neither your body
--   nor your last `move` (fb.pos) pokes into it and the place gap has passed. ~PLACE_GAP a block.
--   Out of blocks = the lap ends there.
--   Back: hits at the hit gap while you walk: the block behind the front one is hit (2 tiles off,
--   in punch reach) while the front one's break holds (DROP_WAIT), then you walk into it = the
--   game's own touch pickup takes its drops. ~hits × HIT_GAP a block.
-- Trips (Fetch a pile / Auto drop a full seed stack) only between laps, from the start tile with
-- the row empty (the wall would box you in). Seed pile: 5+ tiles past either end of the row (the
-- start side first), never on it (a block on a drop = nobody can take it).
-- Off the row (you moved, pulled back), toggled off, world closed: stops at once, blocks stay.
-- Toggled on with leftovers of the block in your row touching you: those get broken first.
-- do-block + `rw` fields: the main chunk is close to Luau's 200-locals limit.
do
	local rw = { LEN = 20, n = 0, page = pages["Row Farm"], HAZ = { "hurts", "deadly", "bumper", "bouncy", "slippery" } }
	fb.rowSeeds = fb.rowSeeds or {} -- seed ids of blocks Row Farm placed (its Auto drop watches these)

	-- Block to place next: the manual pick while you have it, else the best in the bag.
	function rw.block()
		if fb.rowPick then return fb.inv:count(fb.rowPick) > 0 and fb.rowPick or nil end
		local best = farmChoices()[1]
		return best and best.id
	end
	-- This run still owns the switch (a re-toggle starts a new run: rw.token).
	function rw.on() return state.RowFarm and rw.cur == rw.token and fb.gen == myGen end
	function rw.stop(msg)
		if fb.gen ~= myGen then return end
		state.RowFarm = false
		rw.render()
		fb.rowMsg = msg
	end
	human.stoppers.row = function(m) if state.RowFarm then rw.stop(m) end end
	pcall(net.on, "WorldClosed", function()
		if fb.gen == myGen and state.RowFarm then rw.stop("world closed · stopped") end
	end)

	-- Id on tile (x, row) in a layer, 0 = empty.
	function rw.tile(layer, x)
		local r = fb.world[layer][rw.ty]
		return r and r[x] or 0
	end
	-- Solid / platform floor under tile x, nothing in it that hurts or throws you.
	function rw.floorOk(x)
		local below = tileItem(x, rw.ty + 1)
		if not (solid(x, rw.ty + 1) or (below and below.platform)) then return false end
		for _, f in ipairs(rw.HAZ) do
			if below and below[f] then return false end
		end
		return true
	end
	function rw.walkable(x) return rw.tile("fg", x) == 0 and not solid(x, rw.ty) and rw.floorOk(x) end
	-- Blocks fit toward d: block tiles sx .. sx + d(n-1), you end the walk out on sx + d·n.
	function rw.measure(d)
		SIM.solid = {}
		local b = rw.block()
		local bgPick, areas = b and itemDB[b].background, fb.world.areas
		local n = 0
		for i = 1, rw.LEN do
			local x = rw.sx + d * (i - 1)
			if not (rw.walkable(x) and rw.walkable(x + d)) or (bgPick and rw.tile("bg", x) ~= 0)
				or (areas and areas.canEdit and not areas.canEdit(x, rw.ty))
				or inPile({ x = x + 0.5, y = rw.ty + 0.5 }) then -- never build over a stash (Harvest's / Auto Farm's pile)
				break
			end
			n = i
		end
		return n
	end
	-- Auto Rotate's spot search: the longest row that fits from tile (x, y), either way. Uses the
	-- current pick (Rotate sets fb.rowPick first); never while Row Farm runs (rw.sx / rw.ty are its).
	function fb.rowFit(x, y)
		if state.RowFarm then return 0 end
		rw.sx, rw.ty = x, y
		return math.max(rw.measure(1), rw.measure(-1))
	end
	-- Your body, or the server's last `move` of it, pokes into tile x (the server checks a place
	-- against fb.pos, which trails a step behind).
	function rw.inTile(x)
		for _, p in ipairs({ fb.player.state(), fb.pos }) do
			if p and p.x + 0.3 > x and p.x - 0.3 < x + 1 and p.y > rw.ty and p.y - 0.95 < rw.ty + 1 then return true end
		end
		return false
	end
	-- Tile x in punch reach from your body and from the server's last `move` of it.
	function rw.reach(x)
		local s = fb.player.state()
		return canHit(x, rw.ty, s.x, s.y) and (not fb.pos or canHit(x, rw.ty, fb.pos.x, fb.pos.y))
	end
	-- Walk input, every physics frame (the game's own MobileControls keys): toward rw.tx, braking so
	-- you stop on it (Game.lua ground physics, as stepToX). Run over or a movement key down (not while
	-- typing) = let go of the keys at once.
	rw.input = function()
		for _, k in ipairs(rw.on() and userInputService:GetFocusedTextBox() == nil and MOVE_KEYS or {}) do
			if userInputService:IsKeyDown(k) then
				rw.stop("you took over · stopped")
				break
			end
		end
		if not rw.on() then
			if fb.botInput == rw.input then fb.botInput = nil end
			return 0, false
		end
		local p = fb.player.state()
		local dx = rw.tx - p.x
		if math.abs(dx) < 0.04 then return 0, false end
		if p.vx * dx > 0 and p.vx * p.vx / 96 >= math.abs(dx) - 0.02 then return 0, false end -- braking gets there
		return dx > 0 and 1 or -1, false
	end
	function rw.arrived()
		local p = fb.player.state()
		return math.abs(rw.tx - p.x) < 0.05 and math.abs(p.vx) < 0.05 and p.grounded
	end
	-- Every scheduler step: still on, same world, humanizer pause / "Are you still there?" = hold
	-- (keys let go), still on the row. false = stop.
	function rw.tick()
		if not rw.on() then return false end
		if fb.world.fg ~= rw.fg0 then rw.stop("left the world · stopped") return false end
		if human.idle() then
			if fb.botInput == rw.input then fb.botInput = nil end
			repeat
				fb.rowStatus = human.status
				task.wait(0.25)
			until not (rw.on() and human.idle())
			if not rw.on() then return false end
		end
		fb.botInput = rw.input
		local s = fb.player.state()
		if s.dead or math.abs(s.y - rw.fy) > 0.4 or math.abs(s.x - rw.tx) > 2.2 then
			rw.stop("you moved off the row · stopped")
			return false
		end
		return true
	end
	-- Walk onto rw.tx and stop there (up to t s).
	function rw.settle(t)
		local t0 = os.clock()
		while not rw.arrived() and os.clock() - t0 < t do
			if not rw.tick() then return false end
			task.wait()
		end
		return rw.on()
	end
	-- The (humanized) place gap since the last place has passed. placeTile gets the same gap.
	function rw.placeReady()
		rw.pgap = rw.pgap or human.gap(fb.placeGapTest or PLACE_GAP)
		return os.clock() - (fb.lastPlace or 0) >= rw.pgap
	end

	-- Walk out without stopping: the next tile is the walk target; the tile you left gets its block
	-- as soon as your body and the server's view of it are off it and the place gap has passed (you
	-- only slow down when the gap hasn't). Out of blocks / tile taken = the row ends there.
	function rw.out()
		local placed = {}
		for i = 1, rw.n do
			local pick = rw.block()
			if not pick then break end -- out of blocks: this lap ends here
			local x = rw.sx + rw.d * (i - 1) -- the tile you stand on: it gets the block once you're off it
			local layer = itemDB[pick].background and "bg" or "fg"
			if layer == "bg" and rw.tile("bg", x) ~= 0 then break end -- Auto picked a bg block: background taken
			rw.tx = x + rw.d + 0.5
			fb.rowStatus = string.format("placing %d/%d", i, rw.n)
			repeat
				if not rw.tick() then return nil end
				local go = not rw.inTile(x) and rw.placeReady()
				if not go then task.wait() end
			until go
			if rw.tile("fg", x) ~= 0 then break end -- something got there meanwhile
			placeTile(layer, x, rw.ty, pick, rw.pgap)
			rw.pgap = nil
			fb.rowLast = pick
			local sd = seedOf(pick)
			if sd then fb.rowSeeds[sd] = true end
			if rw.tile(layer, x) ~= pick then rw.stop("place didn't show · stopped") return nil end
			placed[#placed + 1] = { x = x, id = pick, layer = layer, at = os.clock(), settle = human.gap(SETTLE), hits = 0, rej = 0 }
		end
		return placed
	end

	-- Walk back, pipelined like Auto Farm: hits go on at the hit gap while you walk. Once the front
	-- block's break is sent, the one behind it gets hit (2 tiles off: still in punch reach) while the
	-- break holds for DROP_WAIT (a refused break comes back as the block within a ping, and its drops
	-- land), then you walk into it: the touch pickup takes the drops as you pass. A block gone without
	-- a break = the server refused the place: copy its bag, never refund (see tryPlace).
	-- Ends standing on the first placed tile. Also clears leftovers (rw.cleanup).
	function rw.back(placed)
		local c = #placed -- the front block: next one to see gone
		if c == 0 then return true end
		rw.tx = placed[c].x + rw.d + 0.5
		while true do
			if not rw.tick() then return false end
			local now, p = os.clock(), placed[c]
			if p then
				local cur = rw.tile(p.layer, p.x)
				if cur == p.id then
					if p.brokeAt then -- the break was refused: the block is back
						p.brokeAt, p.hits, p.rej = nil, 0, p.rej + 1
						if p.rej >= 3 then rw.stop("break keeps getting rejected · stopped") return false end
					end
				elseif cur ~= 0 or rw.tile("fg", p.x) ~= 0 then
					rw.stop("row tile taken · stopped")
					return false
				elseif not p.brokeAt or now - p.brokeAt >= p.confirm then
					if p.brokeAt then
						fb.rowBroken += 1
						rw.rejRun = 0
						human.cycle(0.1)
						if human.drift() then fb.hitAt = (fb.hitAt or 0) + human.gap(HIT_GAP) end -- whiff: a swing slot lost
					else
						fb.placeRejects = (fb.placeRejects or 0) + 1
						rw.rejRun += 1
						local synced = resyncBag()
						if rw.rejRun >= 5 then rw.stop("place keeps getting rejected · stopped") return false end
						fb.rowStatus = synced and "place rejected · bag re-synced" or "place rejected"
					end
					rw.tx = p.x + 0.5 -- walk in: its drops get picked up
					c -= 1
					continue
				end
			end
			-- next to hit: the front block, or the one behind it while the front one's break holds
			local h
			for j = c, math.max(c - 1, 1), -1 do
				if not placed[j].brokeAt then
					h = placed[j]
					break
				end
			end
			if h and rw.tile(h.layer, h.x) == h.id and now >= h.at + h.settle and rw.reach(h.x) and human.hitReady() then
				h.hits += 1
				fb.rowStatus = string.format("breaking · %d left", c)
				hitTile(h.x, rw.ty, h.hits >= (hitsFor(h.id) or 1) and function()
					if rw.on() and rw.tile(h.layer, h.x) == h.id then
						finishBreak(h.layer, h.x, rw.ty, true)
						h.brokeAt, h.confirm = os.clock(), human.gap(DROP_WAIT)
					end
				end)
			elseif c < 1 and rw.arrived() then
				return true
			else
				task.wait()
			end
		end
	end

	-- Leftovers of a stopped run (the last block, else the pick) in your row, touching you: break
	-- along them (the longer side) like a walk back, then the row starts where that ends.
	function rw.cleanup()
		local id = fb.rowLast or rw.block()
		if not id then return true end
		local layer = itemDB[id].background and "bg" or "fg"
		SIM.solid = {}
		local cx, D, n = rw.sx, 1, 0
		for _, dir in ipairs({ 1, -1 }) do
			local k = 0
			while k < rw.LEN and rw.tile(layer, cx + dir * (k + 1)) == id and rw.floorOk(cx + dir * (k + 1)) do k += 1 end
			if k > n then D, n = dir, k end
		end
		if n == 0 then return true end
		local placed = {}
		for k = 1, n do -- placed[n] = the one touching you, broken first
			placed[k] = { x = cx + D * (n - k + 1), id = id, layer = layer, at = 0, settle = 0, hits = 0, rej = 0 }
		end
		rw.d = -D
		if not rw.back(placed) then return false end
		rw.sx = cx + D * n
		return true
	end

	-- Seed pile: 5+ tiles past either end of the row (start side first), reachable, kept per world.
	function rw.spot()
		SIM.solid = {}
		local lo, hi = math.min(rw.sx, rw.sx + rw.d * rw.LEN), math.max(rw.sx, rw.sx + rw.d * rw.LEN)
		local off = function(x) return x <= lo - 5 or x >= hi + 5 end
		local sp = fb.rowSpot
		if sp and sp.world == fb.world.name and off(sp.x) and spotFits(sp.x, sp.y, sp.dir) then return sp end
		local cands = {}
		for dy = -4, 4 do
			for x = lo - 12, hi + 12 do
				local dir = x < lo and -1 or 1 -- the pile goes outward, away from the row
				if off(x) and spotFits(x, rw.ty + dy, dir) then
					local near = (x - rw.sx) * rw.d < 0
					local dist = near and math.abs(x - rw.sx) or math.abs(x - (rw.sx + rw.d * rw.LEN)) + 100
					cands[#cands + 1] = { x = x, y = rw.ty + dy, dir = dir, score = dist + math.abs(dy) * 1.5 }
				end
			end
		end
		table.sort(cands, function(a, b) return a.score < b.score end)
		for i = 1, math.min(#cands, 6) do
			local c = cands[i]
			if planPath(rw.sx, rw.ty, c.x + 0.5, c.y + 0.5, { exact = true }) then
				c.world = fb.world.name
				fb.rowSpot = c
				return c
			end
		end
	end

	-- Between laps, on the start tile with the row empty: drop full seed stacks, fetch blocks,
	-- come back. true = go on, false = stopped, nil = nothing to fetch yet (waited).
	function rw.trip()
		local pulls, went, note, full = fb.pullbacks or 0, false, nil, {}
		if state.RowDrop then
			for sd in pairs(fb.rowSeeds) do
				if fb.inv:count(sd) >= 200 then full[#full + 1] = sd end
			end
		end
		if #full > 0 then
			local sp, err, n = rw.spot(), nil, 0
			if sp then
				fb.rowStatus = string.format("dropping %s @ %d,%d", itemDB[full[1]].name, sp.x + sp.dir, sp.y)
				err, n = dropStack(sp, full, "farm", "RowFarm")
				fb.seedsDropped = (fb.seedsDropped or 0) + n
				went = true
			else
				err = "no spot 5+ tiles off the row"
			end
			if err and rw.on() then
				state.RowDrop = false
				rw.renderDrop()
				note = err .. " · auto drop off"
			end
		end
		if not rw.on() then return false end
		if not rw.block() then
			local want = fb.rowPick or fb.rowLast
			if not want then rw.stop("no farmable block in your bag") return false end
			local name = itemDB[want].name
			if not state.RowFetch then rw.stop("out of " .. name .. " · stopped") return false end
			local pile = nearestPile(want)
			if pile then
				fb.rowStatus = string.format("fetching %s ×%d", name, pile.n or 0)
				fb.fetching, pile.armed = pile, true -- may be a stash pile: let this one be picked up
				runBot(pile, "collect", "RowFarm")
				fb.fetching = nil
				if fb.inv:count(want) == 0 then fb.dropSkip[pile.uid] = os.clock() + 30 end -- try another pile next
				went = true
			elseif not went then
				fb.rowStatus = "out of " .. name .. " · none dropped here"
				task.wait(5)
				return nil
			end
		end
		if not rw.on() then return false end
		if went then
			if (fb.pullbacks or 0) == pulls then
				fb.rowStatus = "going back"
				runBot({ x = rw.sx + 0.5, y = rw.ty + 0.5, tile = true, exact = true }, "farm", "RowFarm")
			end
			if not rw.on() then return false end
			if (fb.pullbacks or 0) > pulls then rw.stop("server pulled you back · stopped") return false end
			if not snapTo(rw.sx, rw.ty) then rw.stop("couldn't get back to the row · stopped") return false end
			rw.fy = fb.player.state().y
		end
		fb.rowStatus = note
		return true
	end

	function rw.run()
		local s = fb.player.state()
		if s.dead or not s.grounded then return rw.stop("stand on the floor first") end
		rw.sx, rw.ty, rw.fy, rw.fg0, rw.rejRun, rw.n, rw.d = math.floor(s.x), math.floor(s.y - 0.5), s.y, fb.world.fg, 0, 0, 1
		rw.tx = rw.sx + 0.5
		if not (rw.settle(2) and rw.cleanup()) then return end
		local r, l = rw.measure(1), rw.measure(-1)
		rw.d = l > r and -1 or 1
		if math.max(r, l) < 3 then return rw.stop("need 3+ free tiles left or right (flat floor)") end
		while rw.on() do
			local go = rw.trip()
			if go == false then return end
			if go and rw.block() then
				rw.n = rw.measure(rw.d)
				if rw.n < 3 then return rw.stop("row blocked (under 3 free tiles) · stopped") end
				local placed = rw.out()
				if not (placed and rw.back(placed)) then return end
				if #placed > 0 then fb.rowLaps += 1 end
			end
		end
	end
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			if state.RowFarm and rw.cur ~= rw.token then
				rw.cur = rw.token
				local ok, err = pcall(rw.run)
				if rw.on() then rw.stop(ok and "stopped" or "error: " .. tostring(err)) end
				if not bot and fb.gen == myGen then fb.botInput = nil end -- an error mid-step never leaves a key held
			end
			task.wait(0.2)
		end
	end)

	-- Row Farm page
	makeSection(rw.page, "Row Farm", 1)
	rw.render = makeToggle(rw.page, "Row Farm", "Place 20 walking out, break them walking back", 2, "RowFarm", function(on)
		fb.rowMsg = nil
		if not on then fb.rowStatus = nil return end
		if not fb.hookMobile() then fb.rowMsg = "controls not found yet · try again" return false end
		if state.AutoFarm or state.AutoHarvest or state.AutoPlant then fb.rowMsg = "turn Auto Farm / Harvest / Plant off first" return false end
		fb.world = fb.world or findWorld()
		fb.drops = fb.drops or findDrops()
		fb.player = findPlayer() or fb.player
		fb.inv = findInventory() or fb.inv
		if not (fb.world and fb.drops and fb.player and fb.inv) then fb.rowMsg = "enter a world first" return false end
		rw.token = {}
		fb.rowStart, fb.rowBroken, fb.rowLaps, fb.rowGems = os.clock(), 0, 0, 0
		fb.rowGems0 = fb.gemsNow() -- gems/h = your gem count's rise (local HUD value, no server call)
		fb.rowStatus = "starting"
	end)
	makeToggle(rw.page, "Fetch dropped blocks", "Out of blocks: walk to a pile & back", 3, "RowFetch", needBot)
	rw.renderDrop = makeToggle(rw.page, "Auto drop seeds", "200 seeds: walk 5+ tiles off the row, drop there", 4, "RowDrop", needBot)
	rw.statusL = makeInfoCard(rw.page, "Status", 5)
	rw.blockL = makeInfoCard(rw.page, "Block", 6)
	rw.rowL = makeInfoCard(rw.page, "Row · laps", 7)
	rw.statsL = makeInfoCard(rw.page, "Broken · gems/h", 8)
	makeSection(rw.page, "Block (from your bag)", 9)
	rw.grid = Instance.new("Frame")
	rw.grid.Size = UDim2.new(1, 0, 0, 0)
	rw.grid.AutomaticSize = Enum.AutomaticSize.Y
	rw.grid.LayoutOrder = 10
	rw.grid.BackgroundTransparency = 1
	rw.grid.Parent = rw.page
	rw.gl = Instance.new("UIGridLayout", rw.grid)
	rw.gl.CellSize = UDim2.new(0.5, -4, 0, 34)
	rw.gl.CellPadding = UDim2.fromOffset(8, 8)
	rw.gl.SortOrder = Enum.SortOrder.LayoutOrder
	function rw.renderPicks()
		for _, c in ipairs(rw.grid:GetChildren()) do
			if c:IsA("TextButton") then c:Destroy() end
		end
		local opts = { { text = "Auto (best in bag)" } }
		for _, e in ipairs(farmChoices()) do
			opts[#opts + 1] = { id = e.id, text = string.format("%s  ×%d", itemDB[e.id].name, e.n) }
			if #opts >= 12 then break end
		end
		for i, o in ipairs(opts) do
			local on = fb.rowPick == o.id
			local p = Instance.new("TextButton")
			p.LayoutOrder = i
			p.BackgroundColor3 = on and ACCENT or PANEL
			p.TextColor3 = on and Color3.fromRGB(20, 20, 20) or TEXT
			p.Text = o.text
			p.TextTruncate = Enum.TextTruncate.AtEnd
			p.Font = Enum.Font.GothamMedium
			p.TextSize = 12
			p.AutoButtonColor = false
			p.Parent = rw.grid
			corner(p, 8)
			p.MouseButton1Click:Connect(function()
				fb.rowPick = o.id
				rw.renderPicks()
			end)
		end
	end

	-- Live readouts (own loop: the main updater's labels are main-chunk locals).
	task.spawn(function()
		local last = 0
		while screenGui.Parent and fb.gen == myGen do
			pcall(function()
				rw.statusL.Text = state.RowFarm and (fb.rowStatus or "running") or fb.rowMsg or "OFF"
				local nb = fb.inv and rw.block()
				rw.blockL.Text = nb and string.format("%s ×%d", itemDB[nb].name, fb.inv:count(nb)) or "none in bag"
				rw.rowL.Text = state.RowFarm and rw.n > 0 and string.format("%d tiles · %d laps", rw.n, fb.rowLaps) or "-"
				local hrs = state.RowFarm and (os.clock() - fb.rowStart) / 3600
				if hrs and fb.rowGems0 then
					local g = fb.gemsNow() -- local HUD value: this runs every 0.3s
					if g then fb.rowGems = math.max(0, g - fb.rowGems0) end
				end
				rw.statsL.Text = hrs and string.format("%d · %d", fb.rowBroken, math.floor(fb.rowGems / math.max(hrs, 1 / 360))) or "-"
				if os.clock() - last > 3 then
					last = os.clock()
					rw.renderPicks()
				end
			end)
			task.wait(0.3)
		end
	end)
end

-- ===== Auto Harvest: walk to ripe rows, sweep them; at 200 respawn -> drop -> continue =====
-- Game rules (decompile v973, Game.lua hit()):
--   * tree data lives in the 2nd upvalue of the game's setTree (connected to TreeChanged):
--     trees[y * w + x] = { p = planted (server time), f = fruit }; ripe when
--     GetServerTimeNow() >= p + ItemDB[seedId].grow
--   * punching a ripe tree = setTile("fg", x, y, 0) (Net.tile, no hit packets) + the punch act;
--     the client allows it within punchRange (2.5, box check from body center)
--   * menu Respawn = die() -> 2s dying -> respawn() at the spawn door / checkpoint
--   * the game sends `move` 15x/s only while you have velocity, else 1x/s (Others.lua). Rows and
--     the trips between them are walked (path bot): no teleport anywhere.
--   * planting = Game.lua plantSeed: setTile("fg", x, y, seedId) (Net.tile) + bag remove + the
--     "plant" action (act kind 3); canPlace for a seed = empty fg, solid or platform tile below,
--     areas.canEdit, builderOk(x, y, true), within buildRange (2.5 box). Client rate 0.15s.
-- do-block: the main chunk is close to Luau's 200-locals limit. Auto Plant lives in `pl` fields
-- for the same reason.
do
	local DROP_AT = 200 -- a full stack
	local SCAN = 8 -- a sweep goes on while a target is this many columns ahead in the row
	local hv = { cut = {}, cutAt = {}, rejAt = {}, rejLog = {}, miss = {} } -- Auto Harvest bits; cut = seed ids cut this run
	fb.hvPick = fb.hvPick or {} -- seed ids of the trees to harvest; empty = all
	local pl = { GAP = 0.3, BASE = 0.3, FAST = 0.135, FILE = "growtopia_treespots.json", page = pages.Plant } -- Auto Plant

	-- Trees = the game's setTree's 2nd upvalue (trees[y * w + x] = {p, f}). v1159: setTree sits behind
	-- the treeChanged packet's listener (one of its upvalues, found by name); before, it was the
	-- TreeChanged remote's handler itself.
	local function findTrees() -- re-read every step: a world change may swap the table
		local ok, t = pcall(function()
			for _, h in pairs(net.treeChanged.getListeners()) do
				for _, f in ipairs(debug.getupvalues(h)) do
					if type(f) == "function" and debug.info(f, "n") == "setTree" then return debug.getupvalues(f)[2] end
				end
			end
		end)
		if ok and type(t) == "table" then return t end
		local old = worldRemotes:FindFirstChild("TreeChanged")
		for _, c in ipairs(old and getconnections(old.OnClientEvent) or {}) do
			local ok2, t2 = pcall(function() return debug.getupvalues(c.Function)[2] end)
			if ok2 and type(t2) == "table" then return t2 end
		end
	end

	-- Tree spots per world (tile keys y * w + x), remembered from the live trees table so Auto
	-- Plant can replant a harvested farm, and saved to the executor workspace so a rejoin keeps them.
	if not fb.treeSpots then
		fb.treeSpots = {}
		pcall(function()
			for wn, arr in pairs(game:GetService("HttpService"):JSONDecode(readfile(pl.FILE))) do
				local set = {}
				for _, k in ipairs(arr) do set[k] = true end
				fb.treeSpots[wn] = set
			end
		end)
	end
	function pl.spots(w)
		local set = fb.treeSpots[w.name]
		if not set then
			set = {}
			fb.treeSpots[w.name] = set
		end
		return set
	end
	function pl.note(w, trees)
		local set = pl.spots(w)
		for k in pairs(trees) do
			if not set[k] then set[k], pl.dirty = true, true end
		end
	end
	function pl.save()
		if not pl.dirty then return end
		pl.dirty = false
		local out = {}
		for wn, set in pairs(fb.treeSpots) do
			local arr = {}
			for k in pairs(set) do arr[#arr + 1] = k end
			out[wn] = arr
		end
		pcall(writefile, pl.FILE, game:GetService("HttpService"):JSONEncode(out))
	end
	-- The menu API table (respawn / enter / leave / list ...), via getgc at identity 8. A scan can
	-- miss (seen on an autoexec load: nil while the table was there), so callers look again while
	-- it's nil. Found = also wrap leave() once: your own Exit goes through it (fb.leftAt, Rejoin).
	function fb.findMenuApi()
		if not fb.menuApi then
			if setthreadidentity then pcall(setthreadidentity, 8) end
			for _, t in pairs(getgc(true)) do
				if type(t) == "table" and type(rawget(t, "respawn")) == "function" and type(rawget(t, "enter")) == "function"
					and type(rawget(t, "list")) == "function" then
					fb.menuApi = t
					break
				end
			end
		end
		local m = fb.menuApi
		if m and not fb.leaveHooked then
			fb.leaveHooked = true
			local leave = m.leave
			m.leave = function(...)
				fb.leftAt = os.clock()
				return leave(...)
			end
		end
		return m
	end
	fb.findMenuApi()

	-- Seed id if (x, y) is a ripe tree we may harvest now, else nil.
	local function ripeAt(w, trees, x, y)
		local t = trees[y * w.w + x]
		local id = t and w.fg[y] and w.fg[y][x]
		local it = id and itemDB[id]
		if not (it and it.kind == "seed" and (not next(fb.hvPick) or fb.hvPick[id])
			and workspace:GetServerTimeNow() >= t.p + (it.grow or 0)) then return nil end
		local k, now = x .. "," .. y, os.clock()
		if (fb.blocked[k] and fb.blocked[k] > now) or (fb.hvSkip[k] and fb.hvSkip[k] > now) or not w.areas.canEdit(x, y) then
			return nil
		end
		return id
	end
	-- Floor a sweep may walk onto: standable, nothing harmful in that column (the Anti toggles
	-- clear these flags, so they count as safe then).
	local function walkable(x, ry)
		if not standable(x, ry) then return false end
		for y = ry - 1, ry + 1 do
			local it = tileItem(x, y)
			if it and (it.deadly or it.hurts or it.bumper or it.laser) then return false end
		end
		return true
	end
	-- Columns until the nearest wanted tile going `dir` along walkable floor in row ry (max SCAN).
	local function ahead(want, cx, ry, dir)
		for i = 1, SCAN do
			local x = cx + dir * i
			if not walkable(x, ry) then return nil end
			if want(x) then return i end
		end
	end
	-- End of the run of wanted tiles through x in row ry (gaps up to SCAN, like a sweep), on the
	-- side nearer to px. Starting a sweep there covers the run end to end in one pass, instead of
	-- starting mid-row and leaving the far end for a trip back.
	local function rowEnd(want, x, ry, px)
		local ends = {}
		for _, dir in ipairs({ -1, 1 }) do
			local e = x
			while true do
				local i = ahead(want, e, ry, dir)
				if not i then break end
				e += dir * i
			end
			ends[#ends + 1] = e
		end
		local first = math.abs(ends[1] - px) <= math.abs(ends[2] - px)
		return first and ends[1] or ends[2]
	end
	-- No route to tile x of row ry: its whole run (same walkable floor) sits out 30 s in `skip`
	-- (fb.hvSkip / fb.plSkip), else bottom-up picks the next tile of it, 4 s of no route each.
	function hv.skipRun(want, x, ry, skip)
		local till = os.clock() + 30
		skip[x .. "," .. ry] = till
		for _, dir in ipairs({ -1, 1 }) do
			local e = x
			while true do
				local i = ahead(want, e, ry, dir)
				if not i then break end
				e += dir * i
				skip[e .. "," .. ry] = till -- want(e) is nil now: ahead goes on past it
			end
		end
	end

	-- 11-11: cuts at HIT_GAP (0.19 + jitter) got ~40% rejected in PIOT (runs like 71-76,14 refused
	-- back to back). By hand the same world took 54/54 at 0.220-0.232 (held punch). So harvest's
	-- floor is the hand's: 0.22, the jitter only adds.
	local HV_GAP = 0.22
	local function harvestTree(x, y, id)
		human.hitWait()
		hv.cut[id] = true -- with "All trees", this type stays a target after its last tree is cut
		fb.pend2[x .. "," .. y] = os.clock() -- server echoes the tree back if it rejects
		hv.cutAt[x .. "," .. y] = os.clock()
		sendTile("fg", x, y, 0)
		local ax, ay = aim(x, y)
		net.act.send({ kind = 1, x = ax, y = ay })
		human.hitDone(HV_GAP)
		fb.world.tileChanged("fg", x, y, 0) -- local: clears the seed + tree, like the game's hit()
		fb.hvCount += 1
	end

	-- What Auto Harvest is after: the picked trees' seeds + blocks (none picked = every tree type in
	-- this world + any cut this run), known from the start, so a bag already at 200 counts too.
	-- Only these (and gems) get collected; their blocks hitting 200 send it to drop.
	function hv.sync()
		local ids, blocks = {}, {}
		for _, set in ipairs(next(fb.hvPick) and { fb.hvPick } or { hv.by or {}, hv.cut }) do
			for sd in pairs(set) do
				ids[sd] = true
				if itemDB[sd - 1] and seedOf(sd - 1) == sd then ids[sd - 1], blocks[sd - 1] = true, true end
			end
		end
		fb.hvIds, fb.hvBlocks = ids, blocks
	end

	-- The block is what harvesting is for: once a target block reaches a full stack, stop and go
	-- drop (a full seed stack alone only stops seed pickups). Returns the full stacks to drop, block
	-- first, or nil. Seeds without a matching block id fall back to "any target item is full".
	fb.hvBlocks = fb.hvBlocks or {}
	function hv.full()
		local trigger = next(fb.hvBlocks) and fb.hvBlocks or fb.hvIds
		local hit
		for id in pairs(trigger) do
			if fb.inv:count(id) >= DROP_AT then hit = true break end
		end
		if not hit then return nil end
		local ids = {}
		for _, set in ipairs({ fb.hvBlocks, fb.hvIds }) do
			for id in pairs(set) do
				if fb.inv:count(id) >= DROP_AT and not table.find(ids, id) then ids[#ids + 1] = id end
			end
		end
		return ids
	end

	-- A drop Auto Harvest may walk to: a target item (or gems) the touch pickup can take now, not
	-- in a stash, not given up on, and with room in the bag.
	function hv.dropOk(w, d, now)
		local row = w.fg[math.floor(d.y)]
		local inside = row and itemDB[row[math.floor(d.x)]]
		return (fb.hvIds[d.id] or d.id == 112) and d.uid and (d.armed or d.id == 112)
			and not (d.pending or d.display or d.taking) and not (inside and inside.solid) and not inPile(d)
			and not (fb.dropSkip[d.uid] and fb.dropSkip[d.uid] > now) and (d.id == 112 or fb.inv:room(d.id) > 0)
	end

	-- The nearest dropped target block to (x, y) within maxD tiles: picked up before more trees are
	-- cut. Only drops of <= 100 (never a stash pile); no block for the seed = its seeds. With ry + dir
	-- (mid-sweep): not one lying ahead in the sweep's row, the walk takes those.
	-- 11-11: it used to look world-wide and also end sweeps, so the bot cut a few trees, walked off to a
	-- stray block, came back...: 49% of a 53 s run "walking to Sugar Cane", 26% sweeping. By hand the
	-- user cut a whole row at ~0.23 s/tree and only took what the walk passed over (54 trees / 14 s).
	-- Now only near ones go first; the rest is step 2's leftover pass once nearby trees are done.
	function hv.blockDrop(w, x, y, ry, dir, maxD)
		local now, best, bd = os.clock(), nil, nil
		local blocks = next(fb.hvBlocks) and fb.hvBlocks or fb.hvIds
		for _, d in ipairs(fb.drops) do
			if blocks[d.id] and d.n <= 100 and hv.dropOk(w, d, now)
				and not (ry and math.floor(d.y) == ry and (d.x - x) * dir > -0.6) then
				local dd = (d.x - x) ^ 2 + (d.y - y) ^ 2
				if (not maxD or dd <= maxD * maxD) and (not bd or dd < bd) then best, bd = d, dd end
			end
		end
		return best
	end

	local function stopHarvest(msg)
		state.AutoHarvest = false
		if hv.render then hv.render() end
		fb.hvStatus = msg
	end
	human.stoppers.harvest = function(m) if state.AutoHarvest then stopHarvest(m) end end

	-- A cut the server rejects comes back as a tileChanged echo of the tree (fb.blocked then holds
	-- it 10s, and it used to be retried every 10s forever: walk to it, rejected, walk back to the
	-- drops...). Same tree rejected twice = the server won't take it: leave it 5 min. 3 rejects in
	-- a minute = something is off: stop, since every reject is one more mark on the server's side.
	-- Own listener + fb.onEcho (re-set each run), so it doesn't depend on the session's older hooks.
	if not fb.hooked4 then
		fb.hooked4 = true
		net.tileChanged.listen(function(d) if fb.onEcho then pcall(fb.onEcho, d) end end)
	end
	fb.onEcho = function(d)
		local k, now = d.x .. "," .. d.y, os.clock()
		if d.id == 0 or not hv.cutAt[k] or now - hv.cutAt[k] > 3 then return end
		hv.cutAt[k] = nil
		if hv.rejAt[k] and now - hv.rejAt[k] < 120 then fb.hvSkip[k] = now + 300 end
		hv.rejAt[k] = now
		table.insert(hv.rejLog, now)
		while now - hv.rejLog[1] > 60 do table.remove(hv.rejLog, 1) end
		if #hv.rejLog >= 3 and state.AutoHarvest then
			hv.rejLog = {}
			-- the trees it just refused: 5 min off (fb.blocked, so a restart doesn't go straight back to them)
			for rk, t in pairs(hv.rejAt) do
				if now - t < 60 then fb.blocked[rk] = now + 300 end
			end
			stopHarvest("server rejected 3 cuts in 1 min · stopped")
		end
	end

	local function respawnNow()
		local m = fb.findMenuApi()
		if not (m and m.respawn) then return false end
		m.respawn()
		local t0 = os.clock()
		task.wait(2.3) -- dying lasts 2s, then the game's respawn() puts you at the door
		while fb.player.state().dead and os.clock() - t0 < 6 do task.wait(0.1) end
		task.wait(0.5) -- land
		return not fb.player.state().dead
	end

	-- Where menu Respawn puts you (Game.lua respawn()): your checkpoint while its tile still is one,
	-- else the world's spawn door. Tile x, y (feet at y + 1), or nil if unknown.
	local function respawnTile(w)
		local k = w.checkpoint
		local row = k and w.w > 0 and w.fg[k // w.w]
		local it = row and itemDB[row[k % w.w]]
		if it and it.checkpoint then return k % w.w, k // w.w end
		if w.spawn then return w.spawn.X, w.spawn.Y end
	end

	-- Full stacks (>= 200) of anything we harvested: respawn, walk to the stash, drop them.
	-- The drop spot nearer to you than where Respawn puts you = just walk there, no respawn (and
	-- respawn after all only if there's no way there on foot).
	local function harvestTrip(ids)
		local name = itemDB[ids[1]] and itemDB[ids[1]].name or "?"
		task.wait(human.react()) -- humanizer: noticing the full stack takes a moment
		local w, s, sp = fb.world, fb.player.state(), fb.hvSpot
		-- everything Auto Harvest drops may share a pile tile (a block-only trip onto block + seed piles
		-- used to read the seeds as someone else's: new spot, the old pile left behind)
		local own = table.clone(ids)
		for _, set in ipairs({ fb.hvIds, fb.hvBlocks }) do
			for id in pairs(set) do
				if not table.find(own, id) then own[#own + 1] = id end
			end
		end
		-- auto spot that can't take the drop: pick another one next trip (3 in a row = stop)
		local function dropErr(sp, err)
			if not err or not state.AutoHarvest then fb.hvDropFails = 0 return end
			if sp.auto and err ~= "couldn't reach the drop spot" then
				fb.hvDropFails = (fb.hvDropFails or 0) + 1
				if fb.hvDropFails < 3 then fb.hvSpot = nil return end
			end
			stopHarvest(err .. " · stopped")
		end
		local rx, ry = respawnTile(w)
		SIM.solid = {}
		if rx and sp and sp.world == w.name and spotFits(sp.x, sp.y, sp.dir) and not fb.othersAt(sp.x + sp.dir * (sp.n or 1), sp.y, own)
			and (s.x - sp.x - 0.5) ^ 2 + (s.y - sp.y - 1) ^ 2 < (s.x - rx - 0.5) ^ 2 + (s.y - ry - 1) ^ 2 then
			fb.hvStatus = string.format("%s ×%d · walking to drop @ %d,%d", name, DROP_AT, sp.x + sp.dir, sp.y)
			local pulls = fb.pullbacks or 0
			local err, n = dropStack(sp, ids, "harvest", "AutoHarvest", own)
			fb.hvDropped += n
			if (fb.pullbacks or 0) > pulls then return stopHarvest("server pulled you back · stopped") end
			if err ~= "couldn't reach the drop spot" or not state.AutoHarvest then return dropErr(sp, err) end
		end
		fb.hvStatus = string.format("%s ×%d · respawning", name, DROP_AT)
		if not respawnNow() then return stopHarvest("respawn failed · stopped") end
		local sp = fb.hvSpot
		SIM.solid = {}
		if not (sp and sp.world == fb.world.name and spotFits(sp.x, sp.y, sp.dir)
			and not fb.othersAt(sp.x + sp.dir * (sp.n or 1), sp.y, own)) then
			if sp and not sp.auto then return stopHarvest("drop spot blocked · set it again") end
			local s = fb.player.state()
			local cx, ry = nodeOf(s.x, s.y)
			sp = cx and findSpot({ x = cx, y = ry }, 2) -- auto: 2+ tiles from the spawn door
			if not sp then return stopHarvest("no drop spot near spawn · set one") end
			sp.auto, fb.hvSpot = true, sp
		end
		fb.hvStatus = string.format("dropping @ %d,%d", sp.x + sp.dir, sp.y)
		local pulls = fb.pullbacks or 0
		local err, n = dropStack(sp, ids, "harvest", "AutoHarvest", own)
		fb.hvDropped += n
		if (fb.pullbacks or 0) > pulls then return stopHarvest("server pulled you back · stopped") end
		dropErr(sp, err)
	end

	-- Sweep row ry: walk (game input, like holding a key) and act on the wanted tile 2 columns
	-- ahead first, then 1 ahead, yours, 1 and 2 behind (all within the 2.5 reach); stop walking
	-- while your column, the next or the 2 behind are still wanted, so nothing is left behind.
	-- Harvest: trees are cut ~2 columns early, so their drops have landed when you walk over them
	-- (touch pickup; Auto Collect / the leftover pass get stragglers). Ends when nothing is wanted
	-- within SCAN columns ahead, the floor ends, or state[key] goes off.
	-- want(x) -> value or nil; act(x, value); ready() -> may act now; skip(x): give a tile up;
	-- done(dir, state) (optional) -> end the sweep now.
	local function sweepRow(ry, key, want, act, ready, skip, done)
		if fb.gen ~= myGen then return end -- re-run since: the newer run drives
		local cx = math.floor(fb.player.state().x)
		local r, l = ahead(want, cx, ry, 1), ahead(want, cx, ry, -1)
		local dir = (r and (not l or r <= l)) and 1 or -1 -- nearer side first (rowEnd: the only side)
		-- humanizer drift, once per driftEvery sweeps: 1 late start, 2 a whiffed swing (its slot is
		-- lost, the tile is acted on in the next one), 3 walk ~1 tile past the end, then step back
		local drift = human.drift() and human.int(1, 3)
		local walk, lastDid, busyAt = 0, os.clock(), nil
		local startAt = drift == 1 and os.clock() + human.range(HUMAN.lateStart) or 0
		-- the walk key is held for walkHold, then sometimes let go for `release` (its own clock,
		-- not tied to the swing clock below)
		local holdEnd, freeUntil, swingAt = os.clock() + human.range(HUMAN.walkHold), 0, 0
		local input = function() return walk, false end
		fb.botInput = input
		while state[key] and fb.botInput == input do
			local s = fb.player.state()
			if s.dead or math.floor(s.y - 0.01) ~= ry then break end -- died / knocked off the row
			if done and done(dir, s) then break end
			if fb.farmCheckOpen then break end -- "Are you still there?": stop right here
			cx = math.floor(s.x)
			local nextOk = walkable(cx + dir, ry)
			if ready() and os.clock() >= swingAt then
				-- only within reach of where the SERVER has you (your last move packet): walking at
				-- full speed it lags up to ~0.5 tile, so a cut 2 tiles ahead from the live position
				-- can be out of its reach -> rejected (the tree comes back, and each reject counts)
				local p = fb.pos or s
				for _, dx in ipairs({ nextOk and 2 * dir or dir, dir, 0, -dir, -2 * dir }) do
					local v = want(cx + dx)
					if v and canHit(cx + dx, ry, p.x, p.y) then
						if drift == 2 then -- whiff: no packet, this swing slot is just gone
							drift, swingAt = nil, os.clock() + human.gap(HIT_GAP)
						else
							act(cx + dx, v)
						end
						lastDid = os.clock()
						break
					end
				end
			end
			local near = { 0, dir, -dir, -2 * dir }
			local busy = false
			for _, dx in ipairs(near) do
				if want(cx + dx) then busy = true break end
			end
			-- stuck 2s on a wanted tile (counted from when it came near, not from the last act: a
			-- long walk to a lone tree used to give it up on arrival) = acting doesn't clear it
			busyAt = busy and (busyAt or os.clock()) or nil
			if busy and os.clock() - math.max(lastDid, busyAt) > 2 then -- give them up
				for _, dx in ipairs(near) do
					if want(cx + dx) then skip(cx + dx) end
				end
				break
			end
			if not busy and not (nextOk and ahead(want, cx, ry, dir)) then break end
			local now = os.clock()
			if walk ~= 0 and now >= holdEnd then
				holdEnd = now + human.range(HUMAN.walkHold)
				if human.chance(HUMAN.releaseP) then freeUntil = now + human.range(HUMAN.release) end
			end
			walk = (busy or not nextOk or now < freeUntil or now < startAt) and 0 or dir
			task.wait()
		end
		local s = fb.player.state()
		if drift == 3 and state[key] and fb.botInput == input and not s.dead
			and walkable(math.floor(s.x) + dir, ry) and walkable(math.floor(s.x) + 2 * dir, ry) then
			local t = human.range(HUMAN.overshoot) -- one extra tile, then a one-tile correction back
			walk = dir
			task.wait(t)
			walk = -dir
			task.wait(t)
		end
		walk = 0
		if fb.botInput == input then fb.botInput = nil end
	end

	local function harvestStep()
		if not state.AutoHarvest then task.wait(0.2) return end
		local idle0 = fb.hvIdleFrom -- Auto Rotate: since when there's been nothing to do (see below)
		fb.hvIdleFrom = nil
		if human.idle() then fb.hvStatus = human.status task.wait(0.25) return end
		local w, trees = fb.world, findTrees()
		if not (w and trees) then fb.hvStatus = "enter a world" task.wait(1) return end
		hv.sync()
		local full = hv.full()
		if full and state.NoDrop then -- under level 10: can't drop. Auto Rotate farms the blocks (rot.harvest)
			fb.hvStatus = "bag full · can't drop (No drop mode)"
			task.wait(0.5)
			return
		end
		if full then return harvestTrip(full) end
		local s = fb.player.state()
		if s.dead then task.wait(0.5) return end
		-- everything is "nearest to where you stand" (also right after a drop trip)
		local refX, refY = s.x, s.y
		local now = os.clock()
		-- 0. a dropped target block within 4 tiles (a drop of <= 100, so never a stash pile) is picked
		-- up before more trees are cut (step 2 walks to it); farther ones wait for the leftover pass
		local pri = hv.blockDrop(w, refX, refY, nil, nil, 4)
		-- Bottom-up (11-12, a tester: the same way every round, from the bottom up): the row to work
		-- is the lowest one with a ripe tree you can stand at; in it, the tree nearest you (step 2).
		SIM.solid = {}
		local low, lowY, lowD
		for k in pairs(trees) do
			local x, y = k % w.w, k // w.w
			if (not lowY or y >= lowY) and ripeAt(w, trees, x, y) and standable(x, y) then
				local d = math.abs(x + 0.5 - refX)
				if not lowY or y > lowY or d < lowD then low, lowY, lowD = x, y, d end
			end
		end
		-- 1. ripe trees in this row near you, none lower: sweep it, then let the last drops land + get picked up
		local cx, ry = nodeOf(s.x, s.y)
		local want = function(x) return ripeAt(w, trees, x, ry) end
		if cx and not pri and not (lowY and lowY > ry) and (want(cx) or ahead(want, cx, ry, 1) or ahead(want, cx, ry, -1)) then
			if hv.waited then hv.waited = nil task.wait(human.react()) end -- a tree ripened while idle
			fb.hvStatus = "sweeping row " .. ry
			sweepRow(ry, "AutoHarvest", want, function(x, id) harvestTree(x, ry, id) end,
				human.hitReady,
				function(x) fb.hvSkip[x .. "," .. ry] = os.clock() + 30 end,
				-- stop cutting only for a full block stack (go drop it): stray drops wait (see hv.blockDrop)
				function() return hv.full() ~= nil end)
			human.cycle(1)
			if hv.full() then return end -- straight to the drop trip
			task.wait(0.4) -- let the last drops land; leftovers get a walk trip (step 2)
			return
		end
		-- 2. walk (path bot, walk + jump) to the lowest row's ripe tree, or a leftover drop of a
		-- harvested item / gems that a sweep left behind in your row (the others once every tree is
		-- cut). A dropped block (step 0) goes first, always.
		local best, bd, drop = pri, nil, nil
		if not best then
			if low then
				best = { x = low + 0.5, y = lowY + 0.5, tile = true, exact = true }
				bd = (best.x - refX) ^ 2 + (best.y - refY) ^ 2
			end
			for _, d in ipairs(fb.drops) do
				if hv.dropOk(w, d, now) and (not low or (ry and math.floor(d.y) == ry)) then
					-- drops first: a sweep's leftovers (passed mid-air, or a walking take the server
					-- refused) get picked before the next row, even 3x farther than its tree
					local dd = ((d.x - refX) ^ 2 + (d.y - refY) ^ 2) / 9
					if not bd or dd < bd then best, bd = d, dd end
				end
			end
		end
		if not best then
			hv.waited = true
			fb.hvIdleFrom = idle0 or os.clock()
			fb.hvStatus = "waiting for trees to grow"
			task.wait(1)
			return
		end
		drop = not best.tile and best
		if not drop then -- the end of that row's ripe run nearer to you, then one sweep
			local ty = math.floor(best.y)
			best.x = rowEnd(function(x) return ripeAt(w, trees, x, ty) end, math.floor(best.x), ty, refX) + 0.5
		end
		fb.hvStatus = drop and string.format("walking to %s ×%d", itemDB[drop.id] and itemDB[drop.id].name or "?", drop.n)
			or string.format("walking to tree @ %d,%d", math.floor(best.x), math.floor(best.y))
		local pulls = fb.pullbacks or 0
		if hv.waited then hv.waited = nil task.wait(human.react()) end -- a tree ripened while idle
		-- straight to that row's end: the rows you pass on the way wait their turn (bottom-up)
		runBot(best, "harvest", "AutoHarvest", function() return hv.full() ~= nil end)
		if hv.full() then return end -- filled up on the way: drop trip next step
		if not state.AutoHarvest then return end
		-- server pull-back = it didn't accept a move; strikes add up to a kick, so stop
		if (fb.pullbacks or 0) > pulls then return stopHarvest("server pulled you back · stopped") end
		if fb.farmCheckOpen then return end -- "Are you still there?" cut the trip short: not a failed target
		if drop then
			if table.find(fb.drops, drop) then -- still there = couldn't get it: leave it for a while
				-- missed twice = it can't be got from here (no route / server refuses): 5 min, so a
				-- dropped block that goes first can't pull you back and forth to it
				hv.miss[drop.uid] = (hv.miss[drop.uid] or 0) + 1
				fb.dropSkip[drop.uid] = os.clock() + (hv.miss[drop.uid] >= 2 and 300 or 30)
			end
			return
		end
		SIM.solid = {}
		local s2 = fb.player.state()
		local nx, ny = nodeOf(s2.x, s2.y)
		local tx, ty = math.floor(best.x), math.floor(best.y)
		if not (nx and ny == ty and math.abs(nx - tx) <= 1) then -- no route: the next row up first
			hv.skipRun(function(x) return ripeAt(w, trees, x, ty) end, tx, ty, fb.hvSkip)
		end
	end
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			local ok, err = pcall(harvestStep)
			if not ok then
				fb.hvStatus = "error: " .. tostring(err)
				task.wait(0.5)
			end
		end
	end)

	-- Pill grids (Harvest tree pick, Plant mode / seed pick)
	function pl.grid(order, parent)
		local g = Instance.new("Frame")
		g.Size = UDim2.new(1, 0, 0, 0)
		g.AutomaticSize = Enum.AutomaticSize.Y
		g.LayoutOrder = order
		g.BackgroundTransparency = 1
		g.Parent = parent or pl.page
		local l = Instance.new("UIGridLayout", g)
		l.CellSize = UDim2.new(0.5, -4, 0, 34)
		l.CellPadding = UDim2.fromOffset(8, 8)
		l.SortOrder = Enum.SortOrder.LayoutOrder
		return g
	end
	function pl.pill(parent, order, text, on, onClick)
		local p = Instance.new("TextButton")
		p.LayoutOrder = order
		p.BackgroundColor3 = on and ACCENT or PANEL
		p.TextColor3 = on and Color3.fromRGB(20, 20, 20) or TEXT
		p.Text = text
		p.TextTruncate = Enum.TextTruncate.AtEnd
		p.Font = Enum.Font.GothamMedium
		p.TextSize = 12
		p.AutoButtonColor = false
		p.Parent = parent
		corner(p, 8)
		p.MouseButton1Down:Connect(onClick) -- not Click: the Rotate page's grid is rebuilt every 2s, a Click needs the same button at release
	end
	function pl.clear(g)
		for _, c in ipairs(g:GetChildren()) do
			if c:IsA("TextButton") then c:Destroy() end
		end
	end

	-- Harvest page
	makeSection(harvestPage, "Auto Harvest", 1)
	hv.render = makeToggle(harvestPage, "Auto Harvest", "Walk to ripe rows, sweep & collect", 2, "AutoHarvest", function(on)
		if not on then
			fb.hvStatus = nil
			if bot then botStop("stopped") end
			fb.botInput = nil -- ends a sweep
			return
		end
		if state.AutoFarm or state.AutoPlant or state.RowFarm then fb.hvStatus = "turn Auto Farm / Plant / Row Farm off first" return false end
		fb.world = findWorld() or fb.world
		fb.drops = findDrops() or fb.drops
		fb.player = findPlayer() or fb.player
		fb.inv = findInventory() or fb.inv
		if not (fb.hookMobile() and fb.world and fb.drops and fb.player and fb.inv and findTrees()) then
			fb.hvStatus = "enter a world first"
			return false
		end
		fb.hvCount, fb.hvDropped, fb.hvRevBase, fb.hvSkip, fb.hvStatus = 0, 0, fb.reverts, {}, nil
		hv.cut = {}
		hv.sync()
	end)
	hv.status = makeInfoCard(harvestPage, "Status", 3)
	hv.stats = makeInfoCard(harvestPage, "Harvested · rejected · dropped", 4)
	hv.trees = makeInfoCard(harvestPage, "Ripe trees", 5)
	makeSection(harvestPage, "Drop spot (at 200)", 6)
	hv.spot = makeInfoCard(harvestPage, "Spot", 7)
	local spotBtn
	spotBtn = makeButton(harvestPage, "Set spot here (pile goes the way you face)", 8, function()
		local function say(msg) -- on the button itself: the Status card is scrolled off here
			spotBtn.Text = msg
			task.delay(2, function() spotBtn.Text = "Set spot here (pile goes the way you face)" end)
		end
		local s = fb.player.state()
		SIM.solid = {}
		local cx, ry = nodeOf(s.x, s.y)
		local dir = (s.facing or 1) >= 0 and 1 or -1
		if not cx then return say("stand on solid ground first") end
		if not spotFits(cx, ry, dir) then return say("can't drop there (wall / door in front)") end
		fb.hvSpot = { world = fb.world.name, x = cx, y = ry, dir = dir }
		say(string.format("spot set · %d,%d", cx, ry))
	end)
	makeButton(harvestPage, "Auto spot (near spawn)", 9, function() fb.hvSpot = nil end)
	makeSection(harvestPage, "Trees to harvest (ripe / planted) · their blocks drop at 200", 10)
	hv.treeGrid = pl.grid(11, harvestPage)
	-- Tree types in this world, most planted first; picked ones always show. None picked = all.
	function hv.renderTrees()
		pl.clear(hv.treeGrid)
		local by, list = hv.by or {}, {}
		for id, e in pairs(by) do list[#list + 1] = { id = id, ripe = e.ripe, total = e.total } end
		for id in pairs(fb.hvPick) do
			if not by[id] then list[#list + 1] = { id = id, ripe = 0, total = 0 } end
		end
		table.sort(list, function(a, b) return a.total > b.total end)
		pl.pill(hv.treeGrid, 0, "All trees", not next(fb.hvPick), function()
			table.clear(fb.hvPick)
			hv.renderTrees()
		end)
		for i = 1, math.min(#list, 11) do
			local e = list[i]
			local name = itemDB[e.id] and (itemDB[e.id].name:gsub(" Seed$", "")) or tostring(e.id)
			pl.pill(hv.treeGrid, i, string.format("%s · %d/%d", name, e.ripe, e.total), fb.hvPick[e.id], function()
				fb.hvPick[e.id] = not fb.hvPick[e.id] or nil
				hv.renderTrees()
			end)
		end
	end

	task.spawn(function()
		local tick = 0
		while screenGui.Parent do
			tick += 1
			pcall(function()
				hv.status.Text = fb.hvStatus or (state.AutoHarvest and "running" or "OFF")
				hv.stats.Text = state.AutoHarvest
					and string.format("%d · %d · %d", fb.hvCount, fb.reverts - fb.hvRevBase, fb.hvDropped) or "-"
				local sp = fb.hvSpot
				hv.spot.Text = not sp and "auto · near spawn"
					or string.format("%s%d,%d → pile %s", sp.auto and "auto · " or "", sp.x, sp.y, sp.dir > 0 and "right" or "left")
				local w, trees = fb.world, findTrees()
				if w and trees then
					local st, ripe, total, by = workspace:GetServerTimeNow(), 0, 0, {}
					local all = not next(fb.hvPick)
					for k, t in pairs(trees) do
						local id = w.fg[k // w.w] and w.fg[k // w.w][k % w.w]
						local it = itemDB[id]
						if it and it.kind == "seed" then
							local e = by[id] or { ripe = 0, total = 0 }
							by[id] = e
							local r = st >= t.p + (it.grow or 0)
							e.total += 1
							if r then e.ripe += 1 end
							if all or fb.hvPick[id] then -- the card counts what Auto Harvest will cut
								total += 1
								if r then ripe += 1 end
							end
						end
					end
					hv.trees.Text = string.format("%d / %d", ripe, total)
					hv.by = by
					if tick % 6 == 1 then hv.renderTrees() end -- every 3s
					pl.note(w, trees) -- remember where trees are, for Auto Plant's "Tree spots"
				end
			end)
			task.wait(0.5)
		end
	end)

	-- ===== Auto Plant =====
	-- Seed spot ok right now (the picked seed's canPlace, minus reach)? Never on our drop spots:
	-- they must stay seed-free (spotFits).
	function pl.spotOk(w, x, y)
		if x < 0 or y < 0 or x >= w.w or y >= w.h then return false end
		local row = w.fg[y]
		if not (row and row[x] == 0) then return false end
		local below = tileItem(x, y + 1)
		if not (solid(x, y + 1) or (below and below.platform)) then return false end
		for _, sp in pairs({ fb.dropSpot, fb.hvSpot, fb.rowSpot }) do
			if sp.world == w.name and y == sp.y and (x == sp.x or x == sp.x + sp.dir) then return false end
		end
		if not w.areas.canEdit(x, y) or (w.builderOk and not w.builderOk(x, y, true)) then return false end
		local it = itemDB[fb.plantPick]
		return not (it and w.needsWay and w.needsWay(it) and w.wayBlocked(x, y))
	end
	-- A spot we'd plant now: mode ("Tree spots" = only where trees were), seeds in the bag, not
	-- skipped after a reject / failed route.
	function pl.want(w, x, y)
		if not (fb.plantPick and fb.inv:count(fb.plantPick) > 0) then return nil end
		if fb.plantMode ~= "all" and not pl.spots(w)[y * w.w + x] then return nil end
		local k = x .. "," .. y
		if fb.plSkip[k] and fb.plSkip[k] > os.clock() then return nil end
		return pl.spotOk(w, x, y) or nil
	end
	-- Every spot of the current mode that's plantable, as {x, y} via f(x, y).
	function pl.each(w, f)
		if fb.plantMode == "all" then
			for y = 0, w.h - 1 do
				local row = w.fg[y]
				for x = 0, w.w - 1 do
					if row and row[x] == 0 then f(x, y) end
				end
			end
		else
			for k in pairs(pl.spots(w)) do f(k % w.w, k // w.w) end
		end
	end

	-- Burst mode (Plant page "Burst like a player", state.PlantBurst): the client's own pace (setTile:
	-- actAt + 0.135), and when the server objects - a refused plant or its "too fast" notice, whichever
	-- comes first - stand still 3.5-5s, then go on at full pace again (pl.rest). Off = steady pace (GAP,
	-- learned from the notices). Measured 11-11 by hand: clicks 0.145s apart (median); the server took ~3
	-- quick plants, refused everything after until a 3.7s pause, then took 11, refused again: ~3.3
	-- plants/s net, as steady 0.3s gives. Refused spots are tried again after the rest; 3 refusals = the spot.
	function pl.gap() return state.PlantBurst and pl.FAST or pl.GAP end
	function pl.rest(now)
		if now < (pl.calmUntil or 0) then return end -- plants already on their way are refused too
		local len = human.on and human.range({ 3.5, 5 }) or 4
		pl.calmUntil, fb.plantAt = now + len, now + len
		pl.rests = (pl.rests or 0) + 1
	end
	-- Plant like the game's plantSeed: tile packet + local tile + bag remove, then the plant act.
	-- ponytail: steady 0.3s is a guess. v1225's server refuses plants at 0.15s ("You're placing too fast,
	-- wait a moment.") and its limit isn't visible to us; pl.rejected widens the gap if it still objects.
	function pl.plant(x, y)
		local id = fb.plantPick
		local wait = math.max(fb.plantAt or 0, (fb.lastPlace or 0) + pl.gap()) - os.clock()
		if wait > 0 then task.wait(wait) end
		if fb.inv:count(id) < 1 or fb.world.fg[y][x] ~= 0 then return end
		fb.plPend[x .. "," .. y] = os.clock()
		sendTile("fg", x, y, id)
		net.act.send({ kind = 3, x = x + 0.5, y = y + 0.5 }) -- v1159 client: the plant act sits on the tile center
		fb.inv:remove(id, 1)
		fb.lastPlace = os.clock()
		fb.plantAt = fb.lastPlace + human.gap(pl.gap())
		fb.world.tileChanged("fg", x, y, id) -- local, like plantSeed's setTile (no packet)
		fb.plCount += 1
		pl.last = { x = x, y = y, world = fb.world.name } -- where to resume after a seed fetch
		pl.clean = (pl.clean or 0) + 1
		if pl.clean >= 40 and pl.GAP > pl.BASE then -- 40 plants with no refusal: one step back toward BASE
			pl.GAP, pl.clean = math.max(pl.BASE, pl.GAP / 1.5), 0
		end
	end
	-- The tile echo gives no reason; the server's chat notice does (v1225: "You're placing too fast, wait
	-- a moment.", a WorldNotice, listener below). Too fast = stand still 4s, then plant slower (40 clean
	-- plants step it back, see pl.plant); the refused spot is tried again after the pause. No notice =
	-- the spot: one more try, then left alone this run. Until a notice has been seen this session (the
	-- route is unconfirmed), the old guess stays too: a different spot refused within 10s of the last =
	-- too fast. 11-10 a run sat at 0.45s for good after 2 early refusals of unknown cause.
	-- Refused even at 1 per second = speed isn't the problem: pl.step stops.
	function pl.slow(now, sure) -- sure = the server said "too fast": the gap never steps back below 1.25× this one
		if now < (pl.calmUntil or 0) then return end -- once per burst: plants already on their way
		if sure then pl.BASE = math.min(1, math.max(pl.BASE, pl.GAP * 1.25)) end
		pl.refused = pl.GAP >= 1
		pl.calmUntil, fb.plantAt = now + 4, now + 4
		pl.GAP, pl.clean = math.min(pl.GAP * 1.5, 1), 0
	end
	function pl.rejected(k)
		local now, last = os.clock(), pl.lastRej
		pl.lastRej, pl.clean = { k = k, t = now }, 0
		if state.PlantBurst then
			fb.plBurstRej = (fb.plBurstRej or 0) + 1 -- expected here: kept out of the humanizer's backoff
			pl.rest(now)
			fb.plBadN = fb.plBadN or {}
			local n = (fb.plBadN[k] or 0) + 1
			fb.plBadN[k] = n
			fb.plSkip[k] = n >= 3 and math.huge or pl.calmUntil
			return
		end
		if fb.tooFastAt and now - fb.tooFastAt < 1.5 then -- the notice came first: speed, not the spot
			pl.slow(now, true)
			fb.plSkip[k] = pl.calmUntil
			return
		end
		local twice = fb.plBad[k]
		fb.plBad[k] = true
		if not fb.noticeSeen and not twice and last and last.k ~= k and now - last.t < 10 then pl.slow(now) end
		fb.plSkip[k] = twice and math.huge or math.max(now + 2, pl.calmUntil or 0) -- first time: one more try
	end
	pcall(function() -- an extra listener next to the game's own (Net.on adds, it never replaces)
		net.on("WorldNotice", function(text)
			if fb.gen ~= myGen or type(text) ~= "string" or not text:lower():find("too fast") then return end
			local now = os.clock()
			fb.tooFastAt, fb.noticeSeen, fb.tooFastN = now, true, (fb.tooFastN or 0) + 1
			if not (state.AutoPlant and now - (fb.lastPlace or 0) < 2) then return end
			if state.PlantBurst then return pl.rest(now) end
			if pl.lastRej and now - pl.lastRej.t < 1.5 then fb.plBad[pl.lastRej.k] = nil end -- echo came first
			pl.slow(now, true)
		end)
	end)
	-- Rejected plant: the server echoes the tile back empty (successful edits aren't echoed to you).
	net.tileChanged.listen(function(d)
		if fb.gen ~= myGen or d.id ~= 0 or d.layer == 2 or not fb.plPend then return end
		local k = d.x .. "," .. d.y
		local t = fb.plPend[k]
		if t and os.clock() - t < 3 then
			fb.plPend[k] = nil
			fb.plRejects += 1
			pl.rejected(k)
		end
	end)

	function pl.stop(msg)
		state.AutoPlant = false
		if pl.render then pl.render() end
		fb.plStatus = msg
	end
	human.stoppers.plant = function(m) if state.AutoPlant then pl.stop(m) end end

	function pl.step()
		if not state.AutoPlant then task.wait(0.2) return end
		if human.idle() then fb.plStatus = human.status task.wait(0.25) return end
		local w, id = fb.world, fb.plantPick
		if not w then fb.plStatus = "enter a world" task.wait(1) return end
		local name = itemDB[id].name
		if pl.refused then
			resyncBag() -- the bag is client-side after rejects
			return pl.stop("plants still refused at 1 per second · bag re-synced · stopped")
		end
		if os.clock() < (pl.calmUntil or 0) then
			fb.plStatus = state.PlantBurst and string.format("server: too fast · resting %.1fs (burst)", pl.calmUntil - os.clock())
				or string.format("server: placing too fast · waiting · then %.2fs per plant", pl.GAP)
			task.wait(0.25)
			return
		end
		local s = fb.player.state()
		if s.dead then task.wait(0.5) return end
		local pulls = fb.pullbacks or 0
		SIM.solid = {}
		-- 1. out of seeds: walk to the nearest dropped pile of them, onto its tile when it's on
		-- the floor (your own stash pile sits off your path and Auto Collect skips stashes)
		if fb.inv:count(id) < 1 then
			if os.clock() - (pl.syncAt or 0) > 10 then -- the client bag can drift: ask the server first
				pl.syncAt = os.clock()
				resyncBag()
				if fb.inv:count(id) > 0 then return end
			end
			local d = nearestPile(id)
			if not d then
				for _, o in ipairs(fb.drops) do
					if o.id == id and o.uid and not o.pending then -- piles exist, just skipped for now
						fb.plStatus = "out of " .. name .. " · dropped piles retry soon"
						task.wait(2)
						return
					end
				end
				return pl.stop("out of " .. name .. " · none dropped here")
			end
			fb.plStatus = string.format("fetching %s ×%d", name, d.n)
			pl.resume = pl.resume or pl.last -- come back here afterwards, not to the spots near the pile
			-- your own drops stay unarmed (no touch pickup) until you step off them while they're in
			-- view, and Auto Harvest keeps its stash unarmed on purpose: arm it (client-side gate only)
			d.armed, fb.fetching = true, d
			local tx, ty = math.floor(d.x), math.floor(d.y)
			runBot(standable(tx, ty) and { x = tx + 0.5, y = ty + 0.5, tile = true, exact = true } or d, "collect", "AutoPlant")
			local t0 = os.clock()
			while state.AutoPlant and table.find(fb.drops, d) and (d.taking or os.clock() - t0 < 0.5) and os.clock() - t0 < 3 do
				task.wait(0.05)
			end
			fb.fetching = nil
			if (fb.pullbacks or 0) > pulls then return pl.stop("server pulled you back · stopped") end
			if fb.inv:count(id) < 1 and table.find(fb.drops, d) then fb.dropSkip[d.uid] = os.clock() + 30 end
			return
		end
		-- back from a seed fetch: resume where planting stopped (step 3), skip the rows by the pile
		local r = pl.resume
		if r and r.world ~= w.name then r, pl.resume = nil, nil end
		-- Bottom-up, like Auto Harvest: the row to plant is the lowest one with a spot; in it, the spot
		-- nearest you - or, resuming, nearest to where planting stopped
		local refX = r and r.x + 0.5 or s.x
		local best, bd
		pl.each(w, function(x, y)
			if (not best or y >= best.y) and pl.want(w, x, y) then
				local dd = math.abs(x + 0.5 - refX)
				if not best or y > best.y or dd < bd then best, bd = { x = x, y = y }, dd end
			end
		end)
		-- 2. spots in this row near you, none lower: plant along it
		local cx, ry = nodeOf(s.x, s.y)
		local want = function(x) return pl.want(w, x, ry) end
		if cx and not r and not (best and best.y > ry) and (want(cx) or ahead(want, cx, ry, 1) or ahead(want, cx, ry, -1)) then
			fb.plStatus = "planting row " .. ry
			local ready = function() return os.clock() >= math.max(fb.plantAt or 0, (fb.lastPlace or 0) + pl.gap()) end
			sweepRow(ry, "AutoPlant", want, function(x) pl.plant(x, ry) end, ready,
				-- give a spot up only if it could have been planted: waiting out a pause isn't "stuck"
				function(x) if ready() then fb.plSkip[x .. "," .. ry] = os.clock() + 30 end end)
			return human.cycle(1)
		end
		-- 3. go to that spot (path bot, walk + jump only)
		if not best then
			pl.resume = nil
			return pl.stop("done · nothing left to plant")
		end
		-- the end of that row's run of spots nearer to the reference, then one sweep covers it
		-- end to end (resuming: the run picks up next to the last planted tile)
		best.x = rowEnd(function(x) return pl.want(w, x, best.y) end, best.x, best.y, refX)
		fb.plStatus = string.format(r and "resuming at %d,%d" or "going to %d,%d", best.x, best.y)
		runBot({ x = best.x + 0.5, y = best.y + 0.5, tile = true, exact = true }, "plant", "AutoPlant")
		if not state.AutoPlant then return end
		if (fb.pullbacks or 0) > pulls then return pl.stop("server pulled you back · stopped") end
		SIM.solid = {}
		local s2 = fb.player.state()
		local nx, ny = nodeOf(s2.x, s2.y)
		if nx and ny == best.y and math.abs(nx - best.x) <= 2 then
			pl.resume = nil -- back on track: plant on from here
		elseif not fb.farmCheckOpen then -- no route ("Are you still there?" cutting the walk isn't): the next row up first
			hv.skipRun(function(x) return pl.want(w, x, best.y) end, best.x, best.y, fb.plSkip)
		end
	end
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			local ok, err = pcall(pl.step)
			if not ok then
				fb.plStatus = "error: " .. tostring(err)
				task.wait(0.5)
			end
		end
	end)

	-- Plant page
	makeSection(pl.page, "Auto Plant", 1)
	pl.render = makeToggle(pl.page, "Auto Plant", "Plant the picked seed along rows · fetches dropped seeds", 2, "AutoPlant", function(on)
		if not on then
			fb.plStatus = nil
			if bot then botStop("stopped") end
			fb.botInput = nil -- ends a sweep
			return
		end
		if state.AutoFarm or state.AutoHarvest or state.RowFarm then fb.plStatus = "turn Auto Farm / Harvest / Row Farm off first" return false end
		if not fb.plantPick then fb.plStatus = "pick a seed below" return false end
		fb.world = findWorld() or fb.world
		fb.drops = findDrops() or fb.drops
		fb.player = findPlayer() or fb.player
		fb.inv = findInventory() or fb.inv
		if not (fb.hookMobile() and fb.world and fb.drops and fb.player and fb.inv) then
			fb.plStatus = "enter a world first"
			return false
		end
		if fb.plantMode ~= "all" and not next(pl.spots(fb.world)) then
			fb.plStatus = "no tree spots known in this world · pick Everywhere"
			return false
		end
		fb.plCount, fb.plRejects, fb.plSkip, fb.plPend, fb.plBad, fb.plStatus = 0, 0, {}, {}, {}, nil
		fb.plBadN, fb.plBurstRej, pl.rests = {}, 0, 0
		pl.resume, pl.refused = nil, nil -- a fresh start plants from wherever you are
	end)
	makeToggle(pl.page, "Burst like a player", "Client pace (0.14s); on \"too fast\" rest 3.5-5s, go on · off = steady 0.3s", 3, "PlantBurst")
	pl.status = makeInfoCard(pl.page, "Status", 4)
	pl.stats = makeInfoCard(pl.page, "Planted · rejected", 5)
	pl.left = makeInfoCard(pl.page, "Spots to plant", 6)
	makeSection(pl.page, "Where", 7)
	pl.modeGrid = pl.grid(8)
	makeButton(pl.page, "Forget tree spots (this world)", 9, function()
		if not fb.world then return end
		fb.treeSpots[fb.world.name], pl.dirty = {}, true
		pl.save()
		pl.renderMode()
	end)
	makeSection(pl.page, "Seed (bag · dropped in world)", 10)
	pl.seedGrid = pl.grid(11)

	function pl.renderMode()
		pl.clear(pl.modeGrid)
		local n = 0
		for _ in pairs(fb.world and pl.spots(fb.world) or {}) do n += 1 end
		pl.pill(pl.modeGrid, 1, string.format("Tree spots (%d)", n), fb.plantMode ~= "all", function()
			fb.plantMode = "trees"
			pl.renderMode()
		end)
		pl.pill(pl.modeGrid, 2, "Everywhere", fb.plantMode == "all", function()
			fb.plantMode = "all"
			pl.renderMode()
		end)
	end
	-- Seeds in the bag + seeds lying in the world, most in bag first; the pick always shows.
	function pl.renderSeeds()
		pl.clear(pl.seedGrid)
		local byId, list = {}, {}
		local function add(id, bag, dropped)
			local e = byId[id]
			if not e then
				e = { id = id, bag = 0, dropped = 0 }
				byId[id], list[#list + 1] = e, e
			end
			e.bag += bag
			e.dropped += dropped
		end
		if fb.plantPick then add(fb.plantPick, 0, 0) end
		for _, sl in ipairs(fb.inv and fb.inv.slots or {}) do
			local it = itemDB[sl.id]
			if it and it.kind == "seed" and sl.n > 0 then add(sl.id, sl.n, 0) end
		end
		for _, d in ipairs(fb.drops or {}) do
			local it = d.uid and not d.pending and itemDB[d.id]
			if it and it.kind == "seed" then add(d.id, 0, d.n) end
		end
		table.sort(list, function(a, b)
			if a.bag ~= b.bag then return a.bag > b.bag end
			return a.dropped > b.dropped
		end)
		for i = 1, math.min(#list, 12) do
			local e = list[i]
			local name = (itemDB[e.id].name:gsub(" Seed$", ""))
			pl.pill(pl.seedGrid, i, string.format("%s ×%d%s", name, e.bag, e.dropped > 0 and (" · " .. e.dropped .. " dropped") or ""),
				fb.plantPick == e.id, function()
					fb.plantPick = e.id
					pl.renderSeeds()
				end)
		end
	end

	task.spawn(function()
		local tick = 0
		while screenGui.Parent do
			pcall(function()
				pl.status.Text = fb.plStatus or (state.AutoPlant and "running" or "OFF")
				pl.stats.Text = state.AutoPlant and string.format("%d · %d", fb.plCount, fb.plRejects) or "-"
				if tick % 4 == 0 and fb.world and fb.inv then -- every 2s: spots left
					local n = 0
					pl.each(fb.world, function(x, y)
						if pl.spotOk(fb.world, x, y) then n += 1 end
					end)
					pl.left.Text = tostring(n)
				end
				if tick % 6 == 0 then -- every 3s: lists (bag / drops / world change)
					fb.world = fb.world or findWorld()
					pl.renderMode()
					pl.renderSeeds()
				end
				if tick % 10 == 0 then pl.save() end
			end)
			tick += 1
			task.wait(0.5)
		end
	end)

	-- ===== Auto Break pathfinder ("Walk to blocks") =====
	-- fb.breakTick(n) runs every Auto Break loop step (n = blocks hittable now) and never blocks
	-- for long: it starts a walk once <= 2 are left in reach, so hits go on while you walk, and it
	-- watches that walk. A walk = one route search (path bot, walk + jump)
	-- to the nearest spot BY ROUTE where a block you can't hit from here becomes hittable (canHit,
	-- through walls: farms keep blocks in closed layers you only walk past), or where you stand on
	-- a drop the breaking left (gems, the block, its seed). Blocks / drops you can't get near are
	-- simply never goals.
	function fb.breakTick(n)
		local mine = bot ~= nil and bot == fb.brBot
		if not (fb.autoOn and state.BreakWalk) then
			if mine then botStop("stopped") end
			return
		end
		if state.AutoFarm or state.AutoHarvest or state.AutoPlant or state.RowFarm then -- they drive the bot
			fb.brStatus = "walk paused · another auto mode is on"
			return
		end
		local now = os.clock()
		if mine then -- our walk is running: watch it
			if (fb.pullbacks or 0) > fb.brPulls then -- a move not accepted: strikes add up
				botStop("stopped · server pulled you back")
				state.AutoBreak, fb.autoOn = false, false
				if fb.renderAutoBreak then fb.renderAutoBreak() end
				fb.brStatus = "server pulled you back · stopped"
			elseif bot.phase == "wait" and now - (bot.waitAt or now) > 3 then
				botStop("no route")
				fb.brNext = now + 2
			end
			return
		end
		-- a Path page walk is running / enough left in reach / cooling down after "none reachable"
		if bot or n > 2 or now < (fb.brNext or 0) then return end
		-- getgc misses tables now and then (the load-time scan too): look again until found
		fb.world = fb.world or findWorld()
		fb.player = fb.player or findPlayer()
		fb.drops = fb.drops or findDrops()
		fb.inv = fb.inv or findInventory()
		local w = fb.world
		if not (w and fb.player and fb.drops and fb.inv) then
			fb.brStatus = "game tables not found yet · retrying"
			fb.brNext = now + 1
			return
		end
		local s = fb.player.state()
		if s.dead then return end
		SIM.solid = {}
		local sx, sy = nodeOf(s.x, s.y)
		if not sx then
			fb.brStatus = "not on solid ground"
			fb.brNext = now + 0.5
			return
		end
		local W, nb = w.w, 0
		local elig = {} -- y * W + x -> true: blocks pickTarget would hit (same rules), not hittable from here
		for _, layer in ipairs({ "fg", "bg" }) do -- bg only behind an empty fg, like pickTarget
			for y, row in pairs(w[layer]) do
				for x, id in pairs(row) do
					if id ~= 0 and fb.selected[id] and (layer == "fg" or w.fg[y][x] == 0) and hitsFor(id)
						and not canHit(x, y, s.x, s.y) then
						local k = x .. "," .. y
						if not (fb.blocked[k] and fb.blocked[k] > now) and w.areas.canEdit(x, y) then
							elig[y * W + x], nb = true, nb + 1
						end
					end
				end
			end
		end
		local drops = {} -- drops of what we break (+ gems) the game would let us take
		for _, d in ipairs(fb.drops) do
			local want = fb.selected[d.id] or d.id == 112 or (fb.selected[d.id - 1] and seedOf(d.id - 1) == d.id)
			if want and d.uid and (d.armed or d.id == 112) and not (d.pending or d.display or d.taking) and not inPile(d)
				and not (fb.dropSkip[d.uid] and fb.dropSkip[d.uid] > now) and (d.id == 112 or fb.inv:room(d.id) > 0) then
				local row = w.fg[math.floor(d.y)]
				local inside = row and itemDB[row[math.floor(d.x)]]
				if not (inside and inside.solid) then drops[#drops + 1] = d end
			end
		end
		if nb == 0 and #drops == 0 then
			if n == 0 then fb.brStatus = "nothing selected left · waiting" end
			fb.brNext = now + 1
			return
		end
		local goal = function(x, y) -- standing on node (x, y): feet at (x + 0.5, y + 1)
			if x == sx and y == sy then return false end
			local fx, fy = x + 0.5, y + 1
			for by = y - REACH, y + REACH + 1 do
				for bx = x - REACH, x + REACH do
					if elig[by * W + bx] and canHit(bx, by, fx, fy) then return true end
				end
			end
			for _, d in ipairs(drops) do -- standing here touches it (the game's pickup)
				if touches(fx, fy, d.x, d.y) then return true end
			end
			return false
		end
		if not planPath(sx, sy, s.x, s.y, { goal = goal }) then -- check first: a dead-end walk would idle
			if n == 0 then fb.brStatus = string.format("%d blocks, %d drops left · none reachable", nb, #drops) end
			fb.brNext = now + 2
			return
		end
		fb.brPulls = fb.pullbacks or 0
		fb.brStatus = string.format("walking · %d blocks, %d drops left", nb, #drops)
		goToDrop({ x = s.x, y = s.y, tile = true, goal = goal }, "break")
		fb.brBot = bot
	end
	-- for Auto Rotate (its own do-block further down: the main chunk is near Luau's locals limit)
	fb.hv, fb.pl, hv.findTrees, hv.respawnTile = hv, pl, findTrees, respawnTile
end

-- Path page
makeSection(pathPage, "Walk to a drop", 1)
local pathLabel = makeInfoCard(pathPage, "Status", 2)
makeButton(pathPage, "Stop", 3, function() if bot then botStop("stopped") end end)
makeToggle(pathPage, "Auto leave after get", "Exit the world once you pick the drop up", 4, "PathLeave")
makeSection(pathPage, "Drops nearby (click to go)", 7)
local dropGrid = Instance.new("Frame")
dropGrid.Size = UDim2.new(1, 0, 0, 0)
dropGrid.AutomaticSize = Enum.AutomaticSize.Y
dropGrid.LayoutOrder = 8
dropGrid.BackgroundTransparency = 1
dropGrid.Parent = pathPage
local dgl = Instance.new("UIGridLayout", dropGrid)
dgl.CellSize = UDim2.new(0.5, -4, 0, 34)
dgl.CellPadding = UDim2.fromOffset(8, 8)
dgl.SortOrder = Enum.SortOrder.LayoutOrder

local function renderDropPicks()
	for _, c in ipairs(dropGrid:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local ok, s = pcall(function() return fb.player.state() end)
	if not (ok and s and fb.drops) then return end
	local list = {}
	for _, d in ipairs(fb.drops) do
		local dist = math.sqrt((d.x - s.x) ^ 2 + (d.y - s.y + 0.5) ^ 2)
		if d.uid and not d.pending and dist < 40 then list[#list + 1] = { d = d, dist = dist } end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	for i = 1, math.min(#list, 12) do
		local e = list[i]
		local on = bot and bot.drop == e.d
		local p = Instance.new("TextButton")
		p.LayoutOrder = i
		p.BackgroundColor3 = on and ACCENT or PANEL
		p.TextColor3 = on and Color3.fromRGB(20, 20, 20) or TEXT
		p.Text = string.format("%s ×%d · %dt", itemDB[e.d.id] and itemDB[e.d.id].name or "?", e.d.n, math.floor(e.dist + 0.5))
		p.TextTruncate = Enum.TextTruncate.AtEnd
		p.Font = Enum.Font.GothamMedium
		p.TextSize = 12
		p.AutoButtonColor = false
		p.Parent = dropGrid
		corner(p, 8)
		p.MouseButton1Click:Connect(function()
			goToDrop(e.d)
			renderDropPicks()
		end)
	end
end

-- Rejoin (v1111): the server can close the world on you: note WorldClosed(reason). The game puts the
-- reason in chat, zooms out 0.45s and opens the world picker (which leaves). The auto modes that
-- were on: switch them off, wait for the picker, enter the same world like its Enter World button
-- (WorldMenu.enter), switch them back on (Auto Farm walks back to its tile first). Not when it's
-- yours to look at: an "Are you still there?" open or a reason about farming / bots, a kick / ban,
-- you left yourself. At most 3 rejoins in 10 min.
do
	local rj = {
		MODES = { "AutoBreak", "AutoCollect", "AutoFarm", "AutoHarvest", "AutoPlant" },
		STATUS = { AutoBreak = "brStatus", AutoFarm = "farmStatus", AutoHarvest = "hvStatus", AutoPlant = "plStatus" },
	}
	fb.rejoins = fb.rejoins or {}
	function rj.say(on, msg)
		for _, k in ipairs(on) do
			if rj.STATUS[k] then fb[rj.STATUS[k]] = msg end
		end
		pcall(function()
			game:GetService("StarterGui"):SetCore("SendNotification", { Title = "World closed", Text = msg, Duration = 15 })
		end)
	end
	-- your own Exit (and Auto leave after get) goes through menuApi.leave first: fb.findMenuApi
	-- wraps it to remember when
	fb.findMenuApi()
	-- Why not to go back in (nil = go): also used by Auto Rotate (fb.rjNo).
	function rj.no(why)
		local low, now = why:lower(), os.clock()
		while fb.rejoins[1] and now - fb.rejoins[1] > 600 do table.remove(fb.rejoins, 1) end
		return now - (fb.leftAt or -1e9) < 5 and "you left"
			or (fb.farmCheckOpen or low:find("farm") or low:find("still there") or low:find("%f[%a]bots?%f[%A]"))
				and "farming check · yours to answer"
			or (low:find("kick") or low:find("%f[%a]ban")) and "kicked / banned"
			or #fb.rejoins >= 3 and "closed 3 times in 10 min"
			or not (fb.worldMenu and fb.worldMenu.enter) and "world menu not found"
			or nil
	end
	fb.rjNo = rj.no
	function rj.run(name, why, on)
		if setthreadidentity then pcall(setthreadidentity, 8) end -- getgc below; listeners run at identity 2
		for _, k in ipairs(on) do fb.toggleSet[k](false) end
		local no, now = rj.no(why), os.clock()
		local tag = why ~= "" and " (" .. why .. ")" or ""
		if no then return rj.say(on, "world closed" .. tag .. " · not rejoining: " .. no) end
		table.insert(fb.rejoins, now)
		rj.say(on, "world closed" .. tag .. " · rejoining " .. name)
		task.wait(human.range({ 3, 6 })) -- the picker opens after the zoom and leaves: entering before that gets undone
		if fb.gen ~= myGen or fb.farmCheckOpen then return end
		local fg0 = fb.world.fg
		fb.worldMenu.enter(name) -- = typing the name + Enter World; the game's applyWorld swaps in a new fg grid
		local t0 = os.clock()
		while fb.world.fg == fg0 and os.clock() - t0 < 15 do task.wait(0.25) end
		if fb.world.fg == fg0 or fb.world.name ~= name then
			return rj.say(on, "couldn't get back into " .. name .. " · modes left off")
		end
		task.wait(human.range({ 2, 4 })) -- land at the door, let drops / trees arrive
		if fb.gen ~= myGen then return end
		fb.world, fb.drops = findWorld() or fb.world, findDrops() or fb.drops
		fb.player, fb.inv = findPlayer() or fb.player, findInventory() or fb.inv
		local failed = {}
		for _, k in ipairs(on) do
			local ok, h = true, fb.farmHome
			if k == "AutoFarm" then -- its toggle locks the tiles around where you stand: walk back to the farm tile first
				fb.farmStatus = "rejoined · going back"
				state.Rejoining = true
				if h then runBot({ x = h.x + 0.5, y = h.y + 0.5, tile = true, exact = true }, "farm", "Rejoining") end
				state.Rejoining = nil
				ok = h ~= nil and snapTo(h.x, h.y)
			end
			if ok then fb.toggleSet[k](true) end
			if not state[k] then failed[#failed + 1] = k end
		end
		if #failed > 0 then rj.say(failed, "rejoined " .. name .. " · couldn't restart " .. table.concat(failed, ", ")) end
	end
	pcall(net.on, "WorldClosed", function(why)
		if fb.gen ~= myGen then return end
		if (state.AutoRotate or state.AutoDrop) and fb.rotClosed then task.spawn(fb.rotClosed, tostring(why or "")) return end
		local name, on = fb.world and fb.world.name, {}
		for _, k in ipairs(rj.MODES) do
			if state[k] then on[#on + 1] = k end
		end
		if #on > 0 and name and name ~= "" then task.spawn(rj.run, name, tostring(why or ""), on) end
	end, function() return fb.world and fb.world.name or "" end)
end

-- ===== Auto Rotate (Rotate page): every farm world in turn, forever =====
-- Per world: Auto Harvest until nothing ripe is left -> Auto Farm the tree's block until none is in
-- the bag or dropped (from a floor tile near the door with 2-3 free tiles beside / above, found by
-- the script) -> Auto Plant the tree spots -> every leftover seed (bag + dropped piles) to the
-- storage world, 200 a trip, dropped 2+ tiles from its door (a full tile = the pile grows outward)
-- -> next world. One tree type per world, read from the world (the most planted seed).
-- Ready = ALL of a world's trees ripe (planted + grow, server time). The next ready world in list
-- order goes first; none ready = wait in a random world from the game's Active Worlds list.
-- v1111 EnterWorld: a world on this server loads in place (this script keeps running); one on
-- another server = the server teleports you ("Entering X...") and this script ends with the old
-- server. So settings + progress go to growblox_auto.json (executor workspace) on every change, and
-- autoexec/growblox_autoload.lua runs the script again on arrival: Auto Rotate goes on from the
-- saved phase if it was on in the last 15 min.
-- Holds while "Are you still there?" is up (you answer it). A mode that stops on an error stops the
-- rotation; server rejects = a 1-2 min cool-down (see rot.ended); a humanizer session end = a 1-2
-- min rest, then it goes on.
do
	-- one settings file per account: 2 clients on one PC share the workspace folder
	local rot = { FILE = "growblox_auto_" .. players.LocalPlayer.Name .. ".json", FRESH = 900, page = pages.Rotate, bad = {}, loading = true,
		COOL = { { 60, 120 }, { 180, 300 }, { 300, 480 } }, -- s of cool-down after the 1st / 2nd / 3rd reject stop in 30 min
		SETTINGS = { "FastBreak", "BreakWalk", "FarmFetch", "FarmDrop", "RowFetch", "RowDrop", "RotRow", "PathLeave", "Humanize", "HumanPauses", "PlantBurst", "DoorHover", "DoorTags", "UltimateFPS", "BlankScreen", "AntiIdle", "DropWall", "NoDrop", "Guard", "FarmTop" },
		MODES = { "AutoBreak", "AutoCollect", "AutoFarm", "AutoHarvest", "AutoPlant", "RowFarm" } } -- RowFarm: only switched off (Rotate drives the bot)
	local cfg = (function()
		local ok, c = pcall(function() return game:GetService("HttpService"):JSONDecode(readfile(rot.FILE)) end)
		if not ok then -- first run on this account: start from the old shared file
			ok, c = pcall(function() return game:GetService("HttpService"):JSONDecode(readfile("growblox_auto.json")) end)
		end
		return ok and type(c) == "table" and c or {}
	end)()
	cfg.worlds, cfg.storage, cfg.per = cfg.worlds or {}, cfg.storage or "", cfg.per or {}
	cfg.settings, cfg.run = cfg.settings or {}, cfg.run or {} -- run: on, at, world, phase, last, more
	cfg.drop = cfg.drop or {} -- Auto Drop: on, at, supply, storage, items {id}, more
	cfg.drop.supply, cfg.drop.storage, cfg.drop.items = cfg.drop.supply or "", cfg.drop.storage or "", cfg.drop.items or {}

	function rot.save()
		for _, k in ipairs(rot.SETTINGS) do cfg.settings[k] = state[k] end
		-- loading: the settings restore below clicks switches (each one saves) before the resume
		-- check; keep the file's `on` and `at` until that's done (a stale run must stay stale)
		if not rot.loading then
			cfg.run.on, cfg.run.at = state.AutoRotate or nil, os.time()
			cfg.drop.on, cfg.drop.at = state.AutoDrop or nil, os.time()
		end
		rot.savedAt = os.clock()
		pcall(function() writefile(rot.FILE, game:GetService("HttpService"):JSONEncode(cfg)) end)
	end
	fb.saveCfg = rot.save
	function rot.per(name) -- per world: seed, ready (server time), farm {x, y}, spot (storage drop)
		cfg.per[name] = cfg.per[name] or {}
		return cfg.per[name]
	end
	function rot.fmt(s)
		local m = math.max(0, math.ceil(s / 60))
		return m >= 60 and string.format("%dh%02dm", m // 60, m % 60) or m .. "m"
	end
	-- Auto Rotate and Auto Drop share this engine (world travel, piles, storage drops, resume, world
	-- closed); one of the two runs at a time. key = the one on (runBot / dropStack stop when it goes off).
	function rot.on() return state.AutoRotate or state.AutoDrop end
	function rot.key() return state.AutoDrop and "AutoDrop" or "AutoRotate" end
	function rot.say(msg, notify)
		rot.msg = msg
		if notify and fb.gen == myGen then
			pcall(function()
				game:GetService("StarterGui"):SetCore("SendNotification", { Title = rot.title or "Auto Rotate", Text = msg, Duration = 15 })
			end)
		end
	end
	function rot.set(phase, world)
		if world and world ~= cfg.run.statW then -- a world's round starts: time + gems for the webhook (rot.report)
			cfg.run.statW, cfg.run.t0, cfg.run.g0, cfg.run.left = world, os.time(), fb.gemsNow(), nil
		end
		cfg.run.phase, cfg.run.world, cfg.run.pin = phase, world or cfg.run.world, nil
		rot.ran, rot.moved, rot.doneAt, rot.spotFails, rot.bad, rot.retries, rot.hvLeft = nil, 0, nil, 0, {}, 0, nil
		rot.save()
		rot.log("phase", tostring(phase) .. " " .. tostring(cfg.run.world))
	end
	function rot.modesOff()
		for _, k in ipairs(rot.MODES) do
			if state[k] then fb.toggleSet[k](false) end
		end
		if bot then botStop("stopped") end
		if fb.gen == myGen then fb.botInput = nil end
	end
	function rot.stop(msg)
		if fb.gen ~= myGen then return end -- an older run (re-run since) stays quiet
		rot.log("stop", msg)
		rot.modesOff()
		local what = state.AutoDrop and "auto drop off" or "rotation off"
		if state.AutoRotate then fb.toggleSet.AutoRotate(false) end
		if state.AutoDrop then fb.toggleSet.AutoDrop(false) end
		rot.say(msg .. " · " .. what, true)
	end
	-- A mode it started went off by itself: humanizer session end = rest, then start it again;
	-- server rejects = cool down, see below; anything else (error, pulled back, you switched it off) = stop.
	function rot.ended(name, msg)
		if os.clock() < (rot.restUntil or 0) then rot.ran = nil return end
		msg = tostring(msg or "stopped")
		if fb.pathStatus == "stopped · you took over" then -- a movement key during a walk = you drive now
			return rot.stop(name .. ": " .. msg .. " (you pressed a move key)")
		end
		-- a walk that found no way there: start the phase again, twice per phase
		if (msg:find("couldn't reach") or msg:find("couldn't get back")) and rot.retries < 2 then
			rot.retries, rot.ran = rot.retries + 1, nil
			rot.say(name .. ": " .. msg .. " · trying again")
			return
		end
		-- server rejects (Harvest: 3 cuts in 1 min, Farm: 3 places): one spot / a lag spike shouldn't
		-- end the whole rotation. Cool down (longer each time, rot.COOL), then the same phase goes on
		-- (the refused trees sit out 5 min); never skipped ahead: farming before the harvest is done
		-- leaves the trees standing. 4 in 30 min = not a spike: stop, every reject is a mark server-side.
		if msg:find("server rejected") or msg:find("server refused") then
			local now = os.clock()
			rot.rejStops = rot.rejStops or {}
			while rot.rejStops[1] and now - rot.rejStops[1] > 1800 do table.remove(rot.rejStops, 1) end
			table.insert(rot.rejStops, now)
			local n = #rot.rejStops
			if rot.COOL[n] then
				rot.log("rejects", name .. ": " .. msg .. " (" .. n .. "/3)")
				rot.restUntil, rot.restWhy, rot.ran = now + human.range(rot.COOL[n]), "server rejects " .. n .. "/3", nil
				return
			end
		end
		rot.stop(name .. ": " .. msg)
	end
	function rot.live() -- still on, and no world close being handled
		return rot.on() and os.clock() >= (rot.holdUntil or 0)
	end
	function rot.inWorld() -- the picker (MenuGui.WorldPicker) is up between worlds
		local mg = playerGui:FindFirstChild("MenuGui")
		local wp = mg and mg:FindFirstChild("WorldPicker")
		return fb.world ~= nil and (fb.world.name or "") ~= "" and not (wp and wp.Visible)
	end
	function rot.refind()
		fb.world, fb.drops = findWorld() or fb.world, findDrops() or fb.drops
		fb.player, fb.inv = findPlayer() or fb.player, findInventory() or fb.inv
	end

	-- Timeline of world changes / closes / stops (growblox_rotate_log.json, last 300): a teleport's
	-- length = "loaded" time minus "teleport" time.
	rot.LOG = "growblox_rotate_log_" .. players.LocalPlayer.Name .. ".json"
	fb.rotLog = fb.rotLog or (function()
		local ok, l = pcall(function() return game:GetService("HttpService"):JSONDecode(readfile(rot.LOG)) end)
		return ok and type(l) == "table" and l or {}
	end)()
	function rot.log(ev, detail)
		if fb.gen ~= myGen then return end
		table.insert(fb.rotLog, { t = os.time(), ev = ev, d = tostring(detail or "") })
		while #fb.rotLog > 300 do table.remove(fb.rotLog, 1) end
		pcall(function() writefile(rot.LOG, game:GetService("HttpService"):JSONEncode(fb.rotLog)) end)
	end
	fb.rlog = rot.log -- dropStack (defined above rot) logs through this
	-- Watch the game's own enter path, once per session (the menu looks both fields up on every
	-- call): menuApi.enter's answer (ok, message, teleport) and WorldMenu.enterFailed (a teleport
	-- that couldn't start: "That world is full..." / "Couldn't reach that world...").
	function rot.hookEnter()
		local m, wm = fb.findMenuApi(), fb.worldMenu
		if m and not fb.enterHooked then
			fb.enterHooked = true
			local enter = m.enter
			m.enter = function(...)
				local r = table.pack(enter(...))
				fb.enterRes = { ok = r[1], msg = r[2], teleport = r[3] }
				return table.unpack(r, 1, r.n)
			end
		end
		if wm and not fb.failHooked then
			fb.failHooked = true
			local failed = wm.enterFailed
			wm.enterFailed = function(msg, ...)
				fb.enterFail = tostring(msg or "")
				return failed(msg, ...)
			end
		end
	end
	-- Leave like the menu's Exit (WorldMenu.openPicker), enter like typing the name + Enter World.
	-- Same server: the world loads in place right away (applyWorld swaps in a new fg grid). Another
	-- server: the game says "Entering X..." and teleports you; that ends this script and the
	-- autoexec loader starts it over there. A teleport that fails (or never comes, 2 min) = the
	-- game's own enterFailed, which also frees the picker for the next try.
	function rot.go(name)
		rot.modesOff()
		rot.save()
		rot.say("going to " .. name)
		task.wait(human.range({ 2, 4 }))
		if not rot.on() or fb.farmCheckOpen or (state.AutoRotate and cfg.run.force and name ~= cfg.run.world) then return end
		rot.hookEnter()
		local from = rot.inWorld() and fb.world.name or "picker"
		if from ~= "picker" then
			fb.worldMenu.openPicker()
			task.wait(human.range({ 2, 4 }))
			if state.AutoRotate and cfg.run.force and name ~= cfg.run.world then return end -- you clicked another world: this trip's off
		end
		local fg0, t0 = fb.world.fg, os.clock()
		fb.enterRes, fb.enterFail = nil, nil
		fb.worldMenu.enter(name)
		local r = fb.enterRes
		if not r then -- the picker was still busy (an earlier "Entering..."): free it, try again
			fb.worldMenu.enterFailed("")
		elseif r.teleport then
			rot.say("teleporting to " .. name .. " (it's on another server)")
			rot.log("teleport", from .. " -> " .. name)
			rot.save()
			while not fb.enterFail and os.clock() - t0 < 120 do task.wait(0.5) end
			if not fb.enterFail then fb.worldMenu.enterFailed("Couldn't reach that world, try again.") end
		end
		if fb.world.fg == fg0 or fb.world.name ~= name then
			local why = fb.enterFail ~= "" and fb.enterFail or r and r.msg or "the picker was busy"
			rot.log("enter failed", name .. ": " .. tostring(why))
			rot.fails = (rot.fails or 0) + 1
			if rot.fails >= 3 then return rot.stop("couldn't enter " .. name .. ": " .. tostring(why)) end
			rot.say("couldn't enter " .. name .. " (" .. tostring(why) .. ") · trying again")
			task.wait(human.range({ 10, 20 }) * rot.fails)
			return
		end
		rot.log("entered", string.format("%s -> %s (same server, %.1fs)", from, name, os.clock() - t0))
		rot.fails = 0
		task.wait(human.range({ 1, 2 })) -- at the door
		rot.refind()
	end
	function rot.randomWorld() -- one of the game's Active Worlds (the picker's list), none of yours
		local ok, l = pcall(function() return fb.findMenuApi().list() end)
		local pool = {}
		for _, n in ipairs(ok and type(l) == "table" and type(l.active) == "table" and l.active or {}) do
			if type(n) == "string" and n ~= cfg.storage and not table.find(cfg.worlds, n) then pool[#pool + 1] = n end
		end
		return #pool > 0 and pool[human.int(1, #pool)] or "START"
	end

	-- The seed planted most in world w + when every tree of it is ripe (server time).
	function rot.scan(w)
		local n, last, ripe, best = {}, {}, {}, nil
		local st = workspace:GetServerTimeNow()
		for k, t in pairs(fb.hv.findTrees() or {}) do
			local row = w.fg[k // w.w]
			local id = row and row[k % w.w]
			local it = id and itemDB[id]
			if it and it.kind == "seed" and type(t) == "table" and t.p then
				n[id], last[id] = (n[id] or 0) + 1, math.max(last[id] or 0, t.p + (it.grow or 0))
				if st >= t.p + (it.grow or 0) then ripe[id] = (ripe[id] or 0) + 1 end
				if not best or n[id] > n[best] then best = id end
			end
		end
		return best, best and last[best] or 0, best and ripe[best] or 0 -- seed, all ripe at, ripe now
	end
	-- No trees here: the seed with the most dropped in this world, its blocks counted too (Auto Farm
	-- turns those into it), if at least `min` lie here (a few strays from breaking blocks don't make
	-- it a farm of that).
	function rot.droppedSeed(min)
		local n, best = {}, nil
		for _, d in ipairs(fb.drops) do
			local it = d.uid and not d.pending and itemDB[d.id]
			local seed = it and (it.kind == "seed" and d.id or seedOf(d.id))
			if seed then
				n[seed] = (n[seed] or 0) + d.n
				if not best or n[seed] > n[best] then best = seed end
			end
		end
		return best and n[best] >= min and best or nil
	end
	-- Where to work next: here if it's a ready farm world, else the first ready one after the last
	-- finished (list order). None: nil + when the first one gets ready.
	function rot.pick(here)
		local list, now, soon = cfg.worlds, workspace:GetServerTimeNow(), nil
		local function ready(name) return (rot.per(name).ready or 0) <= now end
		if here and table.find(list, here) and ready(here) then return here end
		local start = table.find(list, cfg.run.last or "") or 0
		for i = 1, #list do
			local name = list[(start + i - 1) % #list + 1]
			if ready(name) then return name end
			soon = math.min(soon or math.huge, rot.per(name).ready)
		end
		return nil, soon
	end

	-- A floor tile near the spawn door to farm from: 2-3 of left / right / above free (empty or the
	-- farm block, editable, no drop or stash on it). Tree spots are fine (empty while farming, the
	-- farm ends before planting) but count against it. Nearest the door, reachable on foot.
	function rot.farmSpot(w, block)
		local P, spots = rot.per(w.name), fb.pl.spots(w)
		SIM.solid = {}
		local function free(x, y)
			local row = w.fg[y]
			local id = row and row[x]
			return (id == 0 or id == block) and w.areas.canEdit(x, y) and not dropsIn(x, y)
				and not inPile({ x = x + 0.5, y = y + 0.5 })
		end
		local function score(x, y)
			if rot.bad[x .. "," .. y] or not standable(x, y) then return nil end
			if state.FarmTop and not free(x, y - 1) then return nil end -- "3 on top" needs the middle (Auto Farm)
			local n, trees = 0, 0
			local around = state.FarmTop and { { x - 1, y - 1 }, { x, y - 1 }, { x + 1, y - 1 } } -- "3 on top"
				or { { x - 1, y }, { x + 1, y }, { x, y - 1 } }
			for _, p in ipairs(around) do
				if free(p[1], p[2]) then
					n += 1
					if spots[p[2] * w.w + p[1]] then trees += 1 end
				end
			end
			return n >= 2 and (3 - n) * 6 + trees * 3 or nil
		end
		local h = P.farm
		if h and h.manual then return standable(h.x, h.y) and h or nil end -- yours (Rotate page): as is
		if h and score(h.x, h.y) then return h end
		local rx, ry = fb.hv.respawnTile(w)
		local s = fb.player.state()
		local sx, sy = nodeOf(s.x, s.y)
		if not (rx and sx) then return nil end
		local cands = {}
		for dy = -6, 6 do
			for dx = -12, 12 do
				local sc = (dx ~= 0 or dy ~= 0) and score(rx + dx, ry + dy)
				if sc then cands[#cands + 1] = { x = rx + dx, y = ry + dy, score = sc + math.abs(dx) + math.abs(dy) * 1.5 } end
			end
		end
		table.sort(cands, function(a, b) return a.score < b.score end)
		for i = 1, math.min(#cands, 8) do
			local c = cands[i]
			if planPath(sx, sy, c.x + 0.5, c.y + 0.5, { exact = true }) then
				P.farm = { x = c.x, y = c.y }
				return P.farm
			end
		end
	end

	-- Walk onto pile d (like Auto Plant's seed fetch: your own piles stay unarmed until then).
	function rot.fetch(d)
		rot.say(string.format("picking up %s ×%d", itemDB[d.id] and itemDB[d.id].name or "?", d.n))
		local n0 = fb.inv:count(d.id)
		d.armed, fb.fetching = true, d
		local tx, ty = math.floor(d.x), math.floor(d.y)
		runBot(standable(tx, ty) and { x = tx + 0.5, y = ty + 0.5, tile = true, exact = true } or d, "collect", rot.key())
		local t0 = os.clock()
		while rot.on() and table.find(fb.drops, d) and (d.taking or os.clock() - t0 < 0.5) and os.clock() - t0 < 3 do
			task.wait(0.05)
		end
		fb.fetching = nil
		if fb.inv:count(d.id) == n0 and table.find(fb.drops, d) then fb.dropSkip[d.uid] = os.clock() + 30 end
	end
	function rot.anyPile(id) -- any drop of id here, skipped or not
		for _, d in ipairs(fb.drops) do
			if d.id == id and d.uid and not d.pending then return true end
		end
		return false
	end
	-- Drop every `seed` you carry in the storage world, 2+ tiles from its door (dropStack: the pile
	-- grows outward when a tile is full; a full spot = its pile tiles go in P.fulls and the next
	-- spot is the closest one whose pile tile isn't full, e.g. the row above / the other side).
	-- A full tile with no drop left on it (you cleared it) is free again.
	-- S / key: Auto Drop's storage world / toggle (default Auto Rotate's). One pile spot per item
	-- (P.spots[id]): piles never mix (fb.othersAt).
	function rot.dropAll(seed, S, key)
		S, key = S or cfg.storage, key or "AutoRotate"
		local P = rot.per(S)
		P.full, P.fulls, P.spot, P.spots = nil, P.fulls or {}, nil, P.spots or {} -- full / spot: older formats
		for k in pairs(P.fulls) do
			local x, y = k:match("^(-?%d+),(-?%d+)$")
			x, y = tonumber(x), tonumber(y)
			local kept = false
			for _, d in ipairs(fb.drops) do
				if math.floor(d.x) == x and math.abs(d.y - (y + 0.5)) < 1.5 then kept = true break end
			end
			if not kept then P.fulls[k] = nil end
		end
		local sk = tostring(seed) -- string key: JSONEncode won't take a sparse number-keyed table
		local sp = P.spots[sk]
		SIM.solid = {}
		if not (sp and spotFits(sp.x + sp.dir * ((sp.n or 1) - 1), sp.y, sp.dir)) then
			local rx, ry = fb.hv.respawnTile(fb.world)
			sp = rx and findSpot({ x = rx, y = ry }, 2, function(x, y) return P.fulls[x .. "," .. y] end)
			if not sp then return rot.stop("storage full near the door in " .. S .. " · clear some piles") end
			P.spots[sk] = sp
		end
		rot.say(string.format("dropping %s ×%d @ %d,%d", itemDB[seed].name, fb.inv:count(seed), sp.x + sp.dir, sp.y))
		local err = dropStack(sp, { seed }, "collect", key)
		if err == "drop spot full · set a new one" then
			for i = 1, sp.n or 1 do P.fulls[(sp.x + sp.dir * i) .. "," .. sp.y] = true end
			P.spots[sk] = nil
		elseif err and rot.live() then
			P.spots[sk], rot.dropFails = nil, (rot.dropFails or 0) + 1
			if rot.dropFails >= 3 then return rot.stop("storage: " .. err) end
		elseif not err then
			rot.dropFails = 0
		end
		rot.save()
	end
	-- Discord webhook when a world's round ends: how long it took, seeds that didn't fit (bag + dropped
	-- here at the last plant's end), gems gained (the HUD's gem count, local: never GetGems).
	-- Sent with the executor's request() (Delta / Opiumware: `request`), in the background.
	function rot.report(F)
		local url = cfg.webhook or ""
		if not url:match("^https://discord%.com/api/webhooks/") and not url:match("^https://discordapp%.com/api/webhooks/") then return end
		local req = (syn and syn.request) or (http and http.request) or http_request or request
		if not req then return end
		local P, R = rot.per(F), cfg.run
		local secs = R.t0 and os.time() - R.t0
		local g1 = fb.gemsNow()
		local seed = P.seed and itemDB[P.seed] and itemDB[P.seed].name or "?"
		local ready = P.ready and P.ready - workspace:GetServerTimeNow()
		local fields = {
			{ name = "Time", value = secs and string.format("%dh %02dm (done %s)", secs // 3600, secs % 3600 // 60, os.date("%H:%M")) or "?", inline = true },
			{ name = "Seeds not planted (full)", value = R.left and string.format("~%d %s", R.left, seed) or "?", inline = true },
			{ name = "Gems", value = (g1 and R.g0) and string.format("+%d", math.max(0, g1 - R.g0)) or "?", inline = true },
			{ name = "Next ripe", value = ready and ready > 0 and rot.fmt(ready) or "-", inline = true },
		}
		local body = game:GetService("HttpService"):JSONEncode({ embeds = { {
			title = "Done · " .. F, description = seed .. " · " .. players.LocalPlayer.Name, color = 0x57F287, fields = fields,
		} } })
		task.spawn(pcall, req, { Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
	end
	function rot.finish(F)
		pcall(rot.report, F)
		cfg.run.statW = nil -- the next round here starts a new count
		cfg.run.last, cfg.run.more = F, nil
		rot.set("wait")
		rot.say("done with " .. F)
	end
	-- A world clicked in the list: drop whatever's running, go there, start the rotation from it.
	-- Trees that aren't ripe yet don't send it on to another world (cfg.run.force, read by rot.harvest).
	function rot.force(name)
		if fb.gen ~= myGen then return end
		if not state.AutoRotate then
			fb.toggleSet.AutoRotate(true)
			if not state.AutoRotate then return end -- its toggle said why (rot.msg)
		end
		rot.holdUntil, rot.restUntil, rot.fails = os.clock() + 2, nil, 0 -- a step mid-walk sees "not live" (rot.live)
		rot.modesOff()
		rot.per(name).ready, cfg.run.more, cfg.run.force = nil, nil, true
		rot.set("harvest", name)
		rot.say("going to " .. name .. " · starting from there")
	end

	-- A phase button (Rotate page): drop whatever's running and do that phase in this farm world (Auto
	-- Rotate goes on if it was off). Harvest: unripe trees don't send it away (force). Farm: ripe trees
	-- don't send it back to harvest (pin, until the next phase change).
	function rot.phaseTo(phase)
		if fb.gen ~= myGen then return end
		local here = fb.world and fb.world.name
		local name = state.AutoRotate and cfg.run.world or here
		if not (name and table.find(cfg.worlds, name)) then return rot.say("go to one of your farm worlds first") end
		if not state.AutoRotate then
			fb.toggleSet.AutoRotate(true)
			if not state.AutoRotate then return end -- its toggle said why (rot.msg)
		end
		rot.holdUntil, rot.restUntil, rot.fails = os.clock() + 2, nil, 0
		rot.modesOff()
		rot.per(name).ready, cfg.run.more = nil, nil
		rot.set(phase, name)
		if phase == "harvest" then cfg.run.force = true end
		if phase == "farm" then cfg.run.pin = "farm" end
		rot.say(phase .. " · " .. name .. " (you picked it)")
	end

	-- ===== phases: one bounded step per call =====
	function rot.harvest(w)
		if state.AutoHarvest then
			rot.say("harvest · " .. (fb.hvStatus or "running"))
			if state.NoDrop and fb.hv.full() then -- 200 blocks: break them into seeds, plant, come back
				fb.toggleSet.AutoHarvest(false)
				rot.log("no drop", "bag full in " .. w.name .. " · farm, plant, then harvest again")
				return rot.set("farm")
			end
			-- idle = nothing it may cut or pick up now. Done only when no ripe tree is left, or the
			-- ripe ones left (skipped: refused / no route) haven't gone down in 6 min: a skip lasts
			-- 30 s - 5 min, so ending on the first idle moment used to leave them standing.
			local _, _, left = rot.scan(w)
			if left ~= rot.hvLeft then rot.hvLeft, rot.hvLeftAt = left, os.clock() end
			if fb.hvIdleFrom and os.clock() - fb.hvIdleFrom > 5 and (left == 0 or os.clock() - rot.hvLeftAt > 360) then
				fb.toggleSet.AutoHarvest(false)
				rot.per(w.name).hvLeft = left -- given up on these: rot.farm doesn't send it back for them
				return rot.set("farm")
			end
			return task.wait(0.5)
		end
		if rot.ran then return rot.ended("Auto Harvest", fb.hvStatus) end
		local P = rot.per(w.name)
		local seed, ready = rot.scan(w)
		local forced = cfg.run.force or cfg.run.cycle -- cycle: No drop mode coming back mid-world
		cfg.run.force, cfg.run.cycle = nil, nil
		if not seed then -- no trees: farm the blocks dropped here (rot.farm: straight to planting if there are none)
			P.seed = rot.droppedSeed(20) or P.seed
			if not P.seed then
				P.ready = workspace:GetServerTimeNow() + 1800
				rot.say("no trees, dropped seeds or blocks in " .. w.name .. " · looking again in 30m", true)
				return rot.set("wait")
			end
			return rot.set("farm")
		end
		P.seed = seed
		if ready > workspace:GetServerTimeNow() + 30 and not forced then -- not all ripe yet: another world first
			P.ready = ready
			return rot.set("wait")
		end
		fb.hvPick, P.plantFull = { [P.seed] = true }, nil -- harvesting frees tree spots
		fb.toggleSet.AutoHarvest(true)
		if not state.AutoHarvest then return rot.stop("Auto Harvest won't start: " .. tostring(fb.hvStatus)) end
		rot.ran = true
	end
	-- Every block broken. No drop mode with ripe trees left: harvest the next 200 straight away
	-- (planting waits for 200 seeds, or the world's end); else plant.
	function rot.farmDone(w)
		local P = rot.per(w.name)
		local _, _, left = rot.scan(w)
		if state.NoDrop and left > (P.hvLeft or 0) then
			cfg.run.cycle = true -- new, unripe trees don't send it to another world (rot.harvest)
			rot.say("blocks done · harvesting the next 200")
			return rot.set("harvest")
		end
		return rot.set("plant")
	end
	function rot.farm(w)
		local P = rot.per(w.name)
		local block = P.block or (P.seed and seedOf(P.seed - 1) == P.seed and P.seed - 1) or nil -- P.block: picked on the Rotate page
		-- harvest first: a farm phase resumed from the file (an older run's, or one that skipped ahead)
		-- while ripe trees still stand goes back to harvest. hvLeft = the ones harvest gave up on.
		local _, _, left = rot.scan(w)
		-- No drop mode moves between harvest / farm / plant itself (rot.noDropNext)
		if not state.NoDrop and left > (P.hvLeft or 0) and cfg.run.pin ~= "farm" then -- pin: you picked Farm (rot.phaseTo)
			P.hvLeft = nil
			if state.AutoFarm then fb.toggleSet.AutoFarm(false) end
			if state.RowFarm then fb.toggleSet.RowFarm(false) end
			rot.say(left .. " ripe trees still here · harvesting first")
			return rot.set("harvest")
		end
		-- No drop: 200 seeds = plant them now (more would only pile up), unless the world had no free
		-- spot left at the last plant (P.plantFull)
		local seedsFull = state.NoDrop and P.seed and fb.inv:count(P.seed) >= 200 and not P.plantFull
		if seedsFull and (state.AutoFarm or state.RowFarm or not rot.ran) then
			if state.AutoFarm then fb.toggleSet.AutoFarm(false) end
			if state.RowFarm then fb.toggleSet.RowFarm(false) end
			rot.say("200 seeds · planting them first")
			return rot.set("plant")
		end
		if state.RotRow then return rot.rowFarm(w, P, block) end
		if state.RowFarm then -- switched to Auto Farm mid-phase: start over with it
			fb.toggleSet.RowFarm(false)
			rot.ran = nil
		end
		if state.AutoFarm then
			rot.say("farm · " .. (fb.farmStatus or "running"))
			if (fb.farmStatus or ""):find("^you moved") then -- knocked off the tile: walk back, start again
				fb.toggleSet.AutoFarm(false)
				rot.ran, rot.moved = nil, rot.moved + 1
				if rot.moved > 3 then rot.stop("Auto Farm: moved off the farm tile 3 times") end
				return
			end
			local busy = farmBlock() ~= nil or nearestPile(block) ~= nil
			for _, t in ipairs(fb.farmTiles or {}) do
				local layer, id = tileState(t)
				if layer and id == t.mine then busy = true end
			end
			if busy then
				rot.doneAt = nil
			elseif not rot.doneAt then
				rot.doneAt = os.clock()
			elseif os.clock() - rot.doneAt > 6 then -- every block farmed (bag + dropped)
				fb.toggleSet.AutoFarm(false)
				return rot.farmDone(w)
			end
			return task.wait(0.5)
		end
		if rot.ran then return rot.ended("Auto Farm", fb.farmStatus) end
		if not block or (fb.inv:count(block) == 0 and not nearestPile(block)) then return rot.farmDone(w) end
		local h = rot.farmSpot(w, block)
		if not h then
			local m = P.farm and P.farm.manual
				and string.format("your farm spot %d,%d in %s isn't a floor tile now · set it again", P.farm.x, P.farm.y, w.name)
			return rot.stop(m or ("no free spot to farm near the door in " .. w.name .. " · set one on the Rotate page"))
		end
		rot.say(string.format("walking to %s farm spot %d,%d", h.manual and "your" or "auto", h.x, h.y))
		runBot({ x = h.x + 0.5, y = h.y + 0.5, tile = true, exact = true }, "farm", "AutoRotate")
		if not rot.live() then return end
		fb.farmPick = block
		local there = snapTo(h.x, h.y)
		if there then
			fb.toggleSet.FarmFetch(true)
			fb.toggleSet.FarmDrop(not state.NoDrop)
			fb.toggleSet.AutoFarm(true)
		end
		local why = tostring(fb.pathStatus or "no route")
		if not there and why:find("^paused") then return end -- "Are you still there?" cut the walk: walk again, not a fail
		if not state.AutoFarm and h.manual then -- yours: never swapped for an auto one
			if there then -- its toggle refused it: nothing free beside / above
				return rot.stop(string.format("Auto Farm won't start at your spot %d,%d in %s: %s", h.x, h.y, w.name, tostring(fb.farmStatus)))
			end
			rot.spotFails += 1
			rot.log("walk fail", string.format("farm spot %d,%d in %s (%d/3): %s", h.x, h.y, w.name, rot.spotFails, why))
			if rot.spotFails >= 3 then -- 3 in a row: skip farming here this round, keep rotating (a stop idled 9 h on 11-09)
				local m = string.format("couldn't walk to your farm spot %d,%d in %s (%s) · farm skipped this round", h.x, h.y, w.name, why)
				rot.log("skip", m)
				rot.say(m, true)
				return rot.set("plant")
			end
			return
		end
		if not state.AutoFarm then -- no route, or its toggle refused the spot: another one
			rot.bad[h.x .. "," .. h.y], P.farm, rot.spotFails = true, nil, rot.spotFails + 1
			if rot.spotFails >= 3 then
				local m = "couldn't start Auto Farm in " .. w.name .. ": " .. tostring(fb.farmStatus) .. " · farm skipped this round"
				rot.log("skip", m)
				rot.say(m, true)
				return rot.set("plant")
			end
			return
		end
		rot.ran, rot.spotFails = true, 0 -- fails count in a row: a phase runs for hours
	end
	-- Row Farm spot: the start tile of the longest flat row (3+ blocks, up to Row Farm's 20) near
	-- the spawn door, reachable on foot; the farm spot you set (Rotate page) is used as is.
	function rot.rowSpot(w)
		local P = rot.per(w.name)
		local h = P.farm
		SIM.solid = {}
		if h and h.manual then return standable(h.x, h.y) and h or nil end -- yours: as is
		h = P.row
		if h and not rot.bad[h.x .. "," .. h.y] and fb.rowFit(h.x, h.y) >= 3 then return h end
		local rx, ry = fb.hv.respawnTile(w)
		local s = fb.player.state()
		local sx, sy = nodeOf(s.x, s.y)
		if not (rx and sx) then return nil end
		local cands = {}
		for dy = -6, 6 do
			for dx = -12, 12 do
				local x, y = rx + dx, ry + dy
				local n = not rot.bad[x .. "," .. y] and standable(x, y) and fb.rowFit(x, y) or 0
				if n >= 3 then cands[#cands + 1] = { x = x, y = y, score = (20 - n) * 3 + math.abs(dx) + math.abs(dy) * 1.5 } end
			end
		end
		table.sort(cands, function(a, b) return a.score < b.score end)
		for i = 1, math.min(#cands, 8) do
			local c = cands[i]
			if planPath(sx, sy, c.x + 0.5, c.y + 0.5, { exact = true }) then
				P.row = { x = c.x, y = c.y }
				return P.row
			end
		end
	end
	-- Farm phase with Row Farm (Rotate page "Farm with Row Farm"): walk to the row spot, Row Farm with
	-- Fetch + Auto drop on; done when it has run dry (bag empty, row empty, no pile left) for 6s.
	function rot.rowFarm(w, P, block)
		if state.AutoFarm then -- switched to Row Farm mid-phase: start over with it
			fb.toggleSet.AutoFarm(false)
			rot.ran = nil
		end
		if state.RowFarm then
			rot.say("row farm · " .. (fb.rowStatus or "running"))
			if (fb.rowStatus or ""):find("none dropped here") then
				rot.doneAt = rot.doneAt or os.clock()
				if os.clock() - rot.doneAt > 6 then -- every block farmed (bag + row + dropped)
					fb.toggleSet.RowFarm(false)
					return rot.farmDone(w)
				end
			else
				rot.doneAt = nil
			end
			return task.wait(0.5)
		end
		local msg = fb.rowMsg or ""
		if rot.ran then
			rot.ran = nil
			if msg:find("^you moved") then -- knocked off the row: walk back, start again
				rot.moved += 1
				if rot.moved > 3 then rot.stop("Row Farm: moved off the row 3 times") end
				return
			end
			-- an auto spot that turned out too short: another one (3 tries, then skip farming here)
			if (msg:find("^need 3") or msg:find("^row blocked")) and not (P.farm and P.farm.manual) and P.row then
				rot.bad[P.row.x .. "," .. P.row.y], P.row, rot.spotFails = true, nil, rot.spotFails + 1
				if rot.spotFails >= 3 then
					rot.log("skip", "no row to farm in " .. w.name .. " · farm skipped this round")
					return rot.set("plant")
				end
				return
			end
			rot.ran = true
			return rot.ended("Row Farm", fb.rowMsg)
		end
		if not block or (fb.inv:count(block) == 0 and not nearestPile(block)) then return rot.farmDone(w) end
		fb.rowPick = block -- before the spot search: a bg block needs empty background
		local h = rot.rowSpot(w)
		if not h then
			local m = P.farm and P.farm.manual
				and string.format("your farm spot %d,%d in %s isn't a floor tile now · set it again", P.farm.x, P.farm.y, w.name)
			return rot.stop(m or ("no flat row of 3+ free tiles near the door in " .. w.name .. " · set a farm spot on the Rotate page"))
		end
		rot.say(string.format("walking to %s row spot %d,%d", h.manual and "your" or "auto", h.x, h.y))
		runBot({ x = h.x + 0.5, y = h.y + 0.5, tile = true, exact = true }, "farm", "AutoRotate")
		if not rot.live() then return end
		if snapTo(h.x, h.y) then
			fb.toggleSet.RowFetch(true)
			fb.toggleSet.RowDrop(not state.NoDrop)
			fb.toggleSet.RowFarm(true)
		end
		if not state.RowFarm then -- no route, or its toggle refused
			rot.spotFails += 1
			if not h.manual then rot.bad[h.x .. "," .. h.y], P.row = true, nil end
			if rot.spotFails >= 3 then
				local m = string.format("couldn't start Row Farm in %s: %s · farm skipped this round", w.name, tostring(fb.rowMsg or "no route"))
				rot.log("skip", m)
				rot.say(m, true)
				return rot.set("plant")
			end
			return
		end
		rot.ran, rot.spotFails = true, 0
	end
	function rot.plant(w)
		if state.AutoPlant then
			rot.say("plant · " .. (fb.plStatus or "running"))
			return task.wait(0.5)
		end
		local P = rot.per(w.name)
		if rot.ran then
			local m = fb.plStatus or ""
			if not (m:find("^done") or m:find("^out of")) then return rot.ended("Auto Plant", m) end
			local _, ready = rot.scan(w) -- back when the last one is ripe
			P.ready = ready > 0 and ready or workspace:GetServerTimeNow() + 1800
			local left = fb.inv:count(P.seed) -- seeds that didn't fit: bag + dropped here (webhook)
			for _, d in ipairs(fb.drops) do
				if d.id == P.seed and d.uid and not d.pending then left += d.n end
			end
			cfg.run.left = left
			if state.NoDrop then
				P.plantFull = m:find("^done") and fb.inv:count(P.seed) > 0 or nil -- seeds left = no free spot
				return rot.noDropNext(w)
			end
			cfg.run.more = true -- leftover seeds may lie anywhere here: look first
			return rot.set("store")
		end
		if not P.seed then
			if state.NoDrop then return rot.finish(w.name) end
			cfg.run.more = true
			return rot.set("store")
		end
		-- every free spot: "only where trees were" left rows that never had one empty and carried
		-- their seeds off to storage. Storage is for seeds left over once the world is full.
		fb.plantPick, fb.plantMode = P.seed, "all"
		fb.toggleSet.AutoPlant(true)
		if not state.AutoPlant then return rot.stop("Auto Plant won't start: " .. tostring(fb.plStatus)) end
		rot.ran = true
	end
	-- No drop mode, after a plant: blocks left (bag / dropped) = farm them; ripe trees left = harvest
	-- the next 200 (cfg.run.cycle: new, unripe trees don't send it away); else this world is done.
	-- Seeds left in the bag stay there (no storage trip without dropping).
	function rot.noDropNext(w)
		local P = rot.per(w.name)
		local block = P.block or (P.seed and seedOf(P.seed - 1) == P.seed and P.seed - 1) or nil -- P.block: picked on the Rotate page
		if block and (fb.inv:count(block) > 0 or nearestPile(block)) then return rot.set("farm") end
		local _, _, left = rot.scan(w)
		if left > (P.hvLeft or 0) then
			cfg.run.cycle = true
			return rot.set("harvest")
		end
		rot.finish(w.name)
	end
	-- Leftover seeds -> storage: in the farm world pick its piles up (bag holds 200 of one item),
	-- carry them over, drop, come back while piles are left. No storage world set = they stay.
	function rot.store(here)
		local F, S = cfg.run.world, cfg.storage
		if state.NoDrop then return rot.finish(F) end -- can't drop: no storage trips
		local seed = rot.per(F).seed
		if not seed or S == "" or S == F then
			if S == "" or S == F then rot.say("no storage world set · leftover seeds stay in " .. F) end
			return rot.finish(F)
		end
		local n = fb.inv:count(seed)
		if here == F and cfg.run.more then
			local pile = fb.inv:room(seed) > 0 and nearestPile(seed)
			if pile then return rot.fetch(pile) end
			cfg.run.more = rot.anyPile(seed) -- bag full with piles left: come back for them
			if n == 0 then return rot.finish(F) end
			return rot.go(S)
		end
		if here == S and n > 0 then return rot.dropAll(seed) end
		if n > 0 then return rot.go(S) end
		if cfg.run.more then return rot.go(F) end
		rot.finish(F)
	end

	function rot.step()
		if not rot.on() then task.wait(0.5) return end
		if os.clock() - (rot.savedAt or 0) > 60 then rot.save() end -- keeps "on" fresh for a resume
		if os.clock() < (rot.holdUntil or 0) then task.wait(0.25) return end
		if os.clock() < (rot.restUntil or 0) then
			rot.say("rest · back in " .. rot.fmt(rot.restUntil - os.clock()) .. " (" .. (rot.restWhy or "humanizer") .. ")")
			task.wait(1)
			return
		end
		if human.idle() then rot.say(human.status) task.wait(0.25) return end
		if state.AutoDrop then
			if not (fb.world and fb.player and fb.inv and fb.drops) then rot.refind() task.wait(1) return end
			return rot.D.step()
		end
		if #cfg.worlds == 0 then return rot.stop("no farm worlds set") end
		if not (fb.world and fb.player and fb.inv and fb.drops) then rot.refind() task.wait(1) return end
		local run = cfg.run
		local here = rot.inWorld() and fb.world.name or nil
		if not run.phase or run.phase == "wait" then
			local name, soon = rot.pick(here)
			if name then return rot.set("harvest", name) end
			if run.phase ~= "wait" then rot.set("wait") end
			if not here or here == cfg.storage or table.find(cfg.worlds, here) then return rot.go(rot.randomWorld()) end
			rot.say(string.format("waiting in %s · next ripe in %s", here, rot.fmt((soon or 0) - workspace:GetServerTimeNow())))
			task.wait(5)
			return
		end
		if run.phase == "store" then return rot.store(here) end
		if here ~= run.world then return rot.go(run.world) end
		rot[run.phase](fb.world)
	end
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			local ok, err = pcall(rot.step)
			if not ok then
				rot.say("error: " .. tostring(err))
				task.wait(1)
			end
		end
	end)
	-- humanizer session over: every mode is switched off; rest, then the same phase goes on
	human.stoppers.rotate = function()
		if rot.on() then rot.restUntil, rot.restWhy, rot.ran = os.clock() + human.range(HUMAN.rest), nil, nil end
	end
	-- WorldClosed while rotating (from the rejoin listener): same rules as Rejoin, then the loop
	-- goes back in (once the game's picker is up). A random world closing = just another one.
	fb.rotClosed = function(why)
		if setthreadidentity then pcall(setthreadidentity, 8) end
		rot.holdUntil = os.clock() + 4 -- the game opens the picker (and leaves) ~0.5s after this
		rot.log("world closed", (fb.world and fb.world.name or "?") .. ": " .. why)
		rot.modesOff()
		rot.ran = nil
		if cfg.run.phase == "wait" and not state.AutoDrop then return end
		local no, tag = fb.rjNo and fb.rjNo(why), why ~= "" and " (" .. why .. ")" or ""
		if no and no ~= "you left" then return rot.stop("world closed" .. tag .. " · " .. no) end
		table.insert(fb.rejoins, os.clock())
		rot.say("world closed" .. tag .. " · going back in", true)
	end

	-- Rotate page
	makeSection(rot.page, "Auto Rotate", 1)
	makeToggle(rot.page, "Auto Rotate", "Harvest → farm → plant → leftover seeds to storage → next world", 2, "AutoRotate", function(on)
		if not on then
			rot.modesOff()
			rot.say("OFF")
			return
		end
		if #cfg.worlds == 0 then rot.say("type your farm worlds below first") return false end
		if state.AutoDrop then fb.toggleSet.AutoDrop(false) end -- one of the two at a time
		rot.title = "Auto Rotate"
		rot.refind()
		fb.worldMenu = fb.worldMenu or findWorldMenu()
		local miss = not fb.hookMobile() and "controls" or not (fb.worldMenu and fb.worldMenu.enter) and "world menu"
			or not fb.findMenuApi() and "menu API" or not fb.hv and "harvest module" or nil
		if miss then rot.say("game " .. miss .. " not found yet · try again") return false end
		if not (fb.world and fb.player and fb.inv and fb.drops) then rot.say("enter any world first") return false end
		rot.modesOff()
		if cfg.run.world and not table.find(cfg.worlds, cfg.run.world) then cfg.run.phase, cfg.run.world = nil, nil end
		rot.ran, rot.fails, rot.restUntil, rot.holdUntil = nil, 0, nil, nil
		rot.moved, rot.spotFails, rot.bad, rot.retries, rot.rejStops = 0, 0, {}, 0, nil -- you turned it on: reject strikes start over
		rot.say("starting")
	end)
	rot.status = makeInfoCard(rot.page, "Status", 3)
	rot.next = makeInfoCard(rot.page, "Next ripe", 4)
	makeSection(rot.page, "Phase (this world · click to switch)", 5)
	rot.phaseGrid = fb.pl.grid(6, rot.page)
	rot.phaseGrid:FindFirstChildOfClass("UIGridLayout").CellSize = UDim2.new(1 / 3, -6, 0, 34)
	makeSection(rot.page, "Farm worlds, in order (one tree type each)", 7)
	rot.worldsBox = makeSearchBox(rot.page, "e.g. WPD, SHAKEGT, DSHR", 8)
	makeSection(rot.page, "Storage world (leftover seeds)", 9)
	rot.storeBox = makeSearchBox(rot.page, "e.g. MYSTORAGE", 10)
	makeSection(rot.page, "Worlds (click one = go there, start from it)", 11)
	rot.grid = fb.pl.grid(12, rot.page)
	-- Farm spot per world: stand where Auto Farm should stand (left / right / above get the blocks),
	-- press Set. None set = the script picks one near the door.
	makeSection(rot.page, "Farm spot (per world · stand on it, press Set)", 13)
	rot.spotCard = makeInfoCard(rot.page, "This world", 14)
	rot.spotBtn = makeButton(rot.page, "Set farm spot here", 15, function()
		local function say(msg)
			rot.spotBtn.Text = msg
			task.delay(2.5, function() rot.spotBtn.Text = "Set farm spot here" end)
		end
		local w, s = fb.world, fb.player and fb.player.state()
		if not (w and s and rot.inWorld()) then return say("enter the farm world first") end
		SIM.solid = {}
		local cx, ry = nodeOf(s.x, s.y)
		if not cx then return say("stand on solid ground first") end
		local free = 0
		for _, p in ipairs({ { cx - 1, ry }, { cx + 1, ry }, { cx, ry - 1 } }) do
			if w.fg[p[2]] and w.fg[p[2]][p[1]] == 0 then free += 1 end
		end
		rot.per(w.name).farm = { x = cx, y = ry, manual = true }
		rot.save()
		say(string.format("set · %s %d,%d · %d of 3 beside/above empty now", w.name, cx, ry, free))
	end)
	makeButton(rot.page, "Clear it (pick automatically)", 16, function()
		local P = fb.world and cfg.per[fb.world.name]
		if P then
			P.farm, P.row = nil, nil
			rot.save()
		end
	end)
	makeSection(rot.page, "Farm phase", 17)
	makeToggle(rot.page, "Farm with Row Farm", "Off = Auto Farm (3 tiles beside you) · on = Row Farm (20-tile row)", 18, "RotRow")
	makeToggle(rot.page, "No drop (under level 10)", "200 blocks → break into seeds → plant → harvest again · no drops, no storage", 19, "NoDrop")
	makeSection(rot.page, "Farm block (this world · Auto = the trees' block)", 20)
	rot.blockGrid = fb.pl.grid(21, rot.page)
	function rot.names(s) -- world names the way the picker takes them: A-Z 0-9, max 24
		local out = {}
		for n in s:upper():gmatch("[A-Z0-9]+") do
			n = n:sub(1, 24)
			if not table.find(out, n) then out[#out + 1] = n end
		end
		return out
	end
	rot.worldsBox.Text = table.concat(cfg.worlds, ", ")
	rot.worldsBox.FocusLost:Connect(function()
		cfg.worlds = rot.names(rot.worldsBox.Text)
		rot.worldsBox.Text = table.concat(cfg.worlds, ", ")
		rot.save()
	end)
	rot.storeBox.Text = cfg.storage
	rot.storeBox.FocusLost:Connect(function()
		cfg.storage = rot.names(rot.storeBox.Text)[1] or ""
		rot.storeBox.Text = cfg.storage
		rot.save()
	end)
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			pcall(function()
				rot.status.Text = rot.msg or "OFF"
				local now, soon = workspace:GetServerTimeNow(), nil
				fb.pl.clear(rot.grid)
				for i, name in ipairs(cfg.worlds) do
					local r = rot.per(name).ready
					if r and r > now then soon = math.min(soon or r, r) end
					local cur = state.AutoRotate and cfg.run.world == name and cfg.run.phase ~= nil and cfg.run.phase ~= "wait"
					local what = cur and cfg.run.phase or (not r and "?") or (r <= now and "ripe") or rot.fmt(r - now)
					fb.pl.pill(rot.grid, i, name .. " · " .. what, cur, function() rot.force(name) end)
				end
				rot.next.Text = soon and rot.fmt(soon - now) or "-"
				fb.pl.clear(rot.phaseGrid)
				for i, ph in ipairs({ "harvest", "farm", "plant" }) do
					local cur = state.AutoRotate and cfg.run.phase == ph
					fb.pl.pill(rot.phaseGrid, i, ({ "Auto Harvest", "Auto Farm", "Auto Plant" })[i], cur, function() rot.phaseTo(ph) end)
				end
				local w = fb.world
				-- farm block pick for this world: Auto + blocks with a seed that are in the bag / dropped here
				fb.pl.clear(rot.blockGrid)
				local P = w and w.name ~= "" and table.find(cfg.worlds, w.name) and rot.per(w.name)
				if P then
					local n, ids = {}, {}
					for _, sl in ipairs(fb.inv and fb.inv.slots or {}) do n[sl.id] = (n[sl.id] or 0) + sl.n end
					for _, d in ipairs(fb.drops or {}) do
						if d.uid and not (d.pending or d.display) then n[d.id] = (n[d.id] or 0) + d.n end
					end
					if P.block then n[P.block] = n[P.block] or 0 end
					for id in pairs(n) do
						local it = itemDB[id]
						if it and it.kind ~= "seed" and seedOf(id) then ids[#ids + 1] = id end
					end
					table.sort(ids, function(a, b) return itemDB[a].name < itemDB[b].name end)
					local function pick(id) -- farming here right now: start it over with that block
						P.block = id
						if state.AutoRotate and cfg.run.phase == "farm" and cfg.run.world == w.name then
							rot.holdUntil, rot.ran = os.clock() + 2, nil
							rot.modesOff()
						end
						rot.save()
					end
					fb.pl.pill(rot.blockGrid, 0, "Auto", not P.block, function() pick(nil) end)
					for i = 1, math.min(#ids, 19) do
						local id = ids[i]
						fb.pl.pill(rot.blockGrid, i, string.format("%s · %d", itemDB[id].name, n[id]), P.block == id, function() pick(id) end)
					end
				end
				local f = w and cfg.per[w.name] and cfg.per[w.name].farm
				rot.spotCard.Text = not (w and w.name ~= "") and "-"
					or f and string.format("%s %d,%d (%s)", w.name, f.x, f.y, f.manual and "set" or "auto")
					or w.name .. " · auto"
			end)
			task.wait(2)
		end
	end)

	-- ===== Auto Drop (Auto Drop page): chosen items from a supply world to a storage world =====
	-- Supply: walk onto the piles of the picked items until the bag takes no more (200 each).
	-- Storage: into its display boxes first (one already holding that item, then empty ones; never
	-- one with other items in it), a box that refuses = full -> the next one; no box left = floor
	-- piles 2+ tiles from the door (rot.dropAll: a full tile -> the next tile out, then a new spot).
	-- Then back to supply while piles are left there; none left = done, Auto Drop goes off.
	rot.D = { page = pages["Auto Drop"], skip = {} } -- skip: "x,y:id" -> os.clock() until (box refused / no way)
	function rot.D.carry()
		local n = 0
		for _, id in ipairs(cfg.drop.items) do n += fb.inv:count(id) end
		return n
	end
	function rot.D.amount(w, x, y, id) -- how many of id box x, y holds (entries {id, n, at})
		local n = 0
		for _, c in pairs(w.displays and w.displays.get(x, y) or {}) do
			if type(c) == "table" and c[1] == id then n += tonumber(c[2]) or 1 end
		end
		return n
	end
	-- Display boxes here that may take id, best first: holding id already, then empty, nearest.
	function rot.D.boxes(w, id)
		local s, now, out = fb.player.state(), os.clock(), {}
		for y, row in pairs(w.fg) do
			for x, tid in pairs(row) do
				local it = tid ~= 0 and itemDB[tid]
				if it and it.display and not it.displayOne and (rot.D.skip[x .. "," .. y .. ":" .. id] or 0) < now
					and w.areas.canEdit(x, y) then
					local mine, other = false, false
					for _, c in pairs(w.displays and w.displays.get(x, y) or {}) do
						if type(c) == "table" and c[1] == id then mine = true else other = true end
					end
					if mine or not other then
						out[#out + 1] = { x = x, y = y, rank = (mine and 0 or 1000) + math.abs(x + 0.5 - s.x) + math.abs(y + 1 - s.y) * 1.5 }
					end
				end
			end
		end
		table.sort(out, function(a, b) return a.rank < b.rank end)
		return out
	end
	-- Stand beside box b, face it, drop the whole stack: the game's onDrop sees the box in front
	-- (displayHere) and puts it in (displayPut -> DisplayItem); refused = the stack comes back.
	-- nil = in, else why not.
	function rot.D.toBox(w, b, id)
		SIM.solid = {}
		local s = fb.player.state()
		local sx, sy = nodeOf(s.x, s.y)
		local near = s.x < b.x + 0.5 and 1 or -1 -- dir = stand tile -> box; your side first
		local dir
		for _, d in ipairs({ near, -near }) do
			if sx and standable(b.x - d, b.y) and planPath(sx, sy, b.x - d + 0.5, b.y + 0.5, { exact = true }) then dir = d break end
		end
		if not dir then return "no way to it" end
		runBot({ x = b.x - dir + 0.5, y = b.y + 0.5, tile = true, exact = true }, "collect", "AutoDrop")
		if not (state.AutoDrop and snapTo(b.x - dir, b.y)) then return "couldn't reach it" end
		if not rot.D.face(w, dir, b.x, b.y, true) then return "couldn't line up with it" end -- never on the floor instead
		local n, had = fb.inv:count(id), rot.D.amount(w, b.x, b.y, id)
		task.wait(0.35) -- the game's "Slow down!" gap
		fb.avatar.onDrop(id, n)
		if fb.inv:count(id) >= n then return "refused" end
		local t0 = os.clock()
		while os.clock() - t0 < 4 and fb.inv:count(id) < n and rot.D.amount(w, b.x, b.y, id) <= had do task.wait(0.1) end
		return fb.inv:count(id) >= n and "full" or nil
	end
	-- Face dir with a one-frame walk press (facing = last walk input) until the game's drop point
	-- (x + facing × 0.7..0.8, body row) is on tile tx (box: and the game sees display box tx, ty).
	function rot.D.face(w, dir, tx, ty, box)
		for _ = 1, 3 do
			local face = function() fb.botInput = nil return dir, false end
			fb.botInput = face
			local t0 = os.clock()
			while fb.botInput == face and os.clock() - t0 < 1 do task.wait() end
			if fb.botInput == face then fb.botInput = nil end
			task.wait(0.1)
			local st = fb.player.state()
			local ok = (st.facing or 0) * dir > 0 and math.floor(st.x + dir * 0.7) == tx and math.floor(st.x + dir * 0.8) == tx
			if box then
				local bx, by = w.displayHere and w.displayHere(st.x + dir * 0.75)
				ok = ok and bx == tx and by == ty
			end
			if ok then return true end
		end
		return false
	end

	-- Dirt wall (toggle): one stack per tile, sealed with Dirt (id 2) on the same tile. 20 wide,
	-- 3 high, zig-zag: layer 1 left -> right on the floor (stand right of the tile, face left),
	-- layer 2 right -> left on top of it (stand left, face right), layer 3 left -> right again.
	-- An upper layer's last tile is filled from past the wall's end, so that spot gets a plain Dirt
	-- support (placed from the first tile of the layer below: 2 per wall). Site = 22 × 4 empty tiles
	-- on solid floor near the storage door, the door kept clear; full (60 tiles) = a new site.
	rot.D.DIRT = 2
	function rot.D.slot(wl, i) -- slot i (0..59) -> tile tx, ty to fill, stand x, face dir
		local L, k = i // 20, i % 20
		if L % 2 == 0 then return wl.x + k, wl.y - L, wl.x + k + 1, -1 end
		return wl.x + 19 - k, wl.y - L, wl.x + 18 - k, 1
	end
	function rot.D.support(wl, L) -- ground for layer L's last stand tile (L = 1, 2; 0-based)
		if L == 1 then return wl.x - 1, wl.y end
		if L == 2 then return wl.x + 20, wl.y - 1 end
	end
	function rot.D.site(w)
		SIM.solid = {}
		local rx, ry = fb.hv.respawnTile(w)
		local s = fb.player.state()
		local sx, sy = nodeOf(s.x, s.y)
		if not (rx and sx) then return nil end
		local taken = {}
		for _, d in ipairs(fb.drops) do taken[math.floor(d.x) .. "," .. math.floor(d.y)] = true end
		local function empty(x, y)
			local row = w.fg[y]
			return row and row[x] == 0 and not taken[x .. "," .. y] and w.areas.canEdit(x, y)
				and not (w.builderOk and not w.builderOk(x, y, true))
		end
		local cands = {}
		for y0 = ry - 8, ry + 8 do
			task.wait()
			for x0 = rx - 40, rx + 20 do
				-- door clear: 2+ tiles around the 22 × 4 box
				if not (rx >= x0 - 3 and rx <= x0 + 22 and ry >= y0 - 5 and ry <= y0 + 1) then
					local ok = true
					for x = x0 - 1, x0 + 20 do
						for y = y0 - 3, y0 do
							if not empty(x, y) then ok = false break end
						end
						if not ok or (x > x0 and not solid(x, y0 + 1)) then ok = false break end
					end
					if ok then cands[#cands + 1] = { x = x0, y = y0, score = math.abs(x0 + 10 - rx) + math.abs(y0 - ry) * 3 } end
				end
			end
		end
		table.sort(cands, function(a, b) return a.score < b.score end)
		for i = 1, math.min(#cands, 8) do
			local c = cands[i]
			if planPath(sx, sy, c.x + 1.5, c.y + 0.5, { exact = true }) then
				return { world = w.name, x = c.x, y = c.y, i = 0 }
			end
		end
	end
	-- Fill the next wall tile with the whole stack of id. nil = done, else why not (for the log).
	function rot.D.wallSlot(id)
		local w, P, D = fb.world, rot.per(cfg.drop.storage), rot.D
		local wl = P.wall
		while wl and wl.i < 60 do -- sealed already (placed, not saved): next
			local tx, ty = D.slot(wl, wl.i)
			if w.fg[ty] and w.fg[ty][tx] == D.DIRT then wl.i += 1 else break end
		end
		if wl then
			local tx, ty, sx = D.slot(wl, math.min(wl.i, 59))
			SIM.solid = {}
			if wl.world ~= w.name or wl.i >= 60 or not (w.fg[ty] and w.fg[ty][tx] == 0 and standable(sx, ty)) then wl = nil end
		end
		if not wl then
			rot.say("looking for room for a dirt wall")
			wl = D.site(w)
			if not wl then return rot.stop("no room near the door in " .. w.name .. " for a dirt wall (22 × 4 empty on solid floor)") end
			P.wall, D.wallFails = wl, 0
			rot.log("dirt wall", string.format("new wall @ %d,%d in %s", wl.x, wl.y, w.name))
		end
		local tx, ty, sx, dir = D.slot(wl, wl.i)
		local ux, uy = (wl.i % 20 == 0) and D.support(wl, wl.i // 20 + 1)
		ux = ux and w.fg[uy] and w.fg[uy][ux] == 0 and ux or nil
		if fb.inv:count(D.DIRT) < (ux and 2 or 1) then return rot.stop("out of Dirt · put Dirt in your bag") end
		local name = itemDB[id] and itemDB[id].name or "?"
		rot.say(string.format("dirt wall %d/60 · %s ×%d @ %d,%d", wl.i + 1, name, fb.inv:count(id), tx, ty))
		local function fail(why)
			D.wallFails = (D.wallFails or 0) + 1
			rot.log("dirt wall", string.format("%s @ %d,%d: %s", name, tx, ty, why))
			if D.wallFails >= 3 then P.wall, D.wallFails = nil, 0 end -- this site doesn't work: a new one
			return why
		end
		runBot({ x = sx + 0.5, y = ty + 0.5, tile = true, exact = true }, "collect", "AutoDrop")
		if not state.AutoDrop then return end
		if not snapTo(sx, ty) then return fail("couldn't reach " .. sx .. "," .. ty) end
		if ux then placeTile("fg", ux, uy, D.DIRT) end -- the next layer's end support, in reach from here
		if not D.face(w, dir, tx, ty) then return fail("couldn't face the tile") end
		local n = fb.inv:count(id)
		task.wait(0.35) -- the game's "Slow down!" gap
		fb.avatar.onDrop(id, n)
		if fb.inv:count(id) >= n then return fail("the game won't drop " .. name .. " there") end
		local p = fb.drops[#fb.drops]
		if p and p.pending and p.id == id then -- the server takes it = the pending local drop goes
			while table.find(fb.drops, p) and os.clock() - p.pending < 1.3 do task.wait(0.05) end
			if table.find(fb.drops, p) then
				if not resyncBag() then fb.inv:add(id, n) end
				return fail("the server refused the drop")
			end
		end
		placeTile("fg", tx, ty, D.DIRT)
		task.wait(1) -- a refused place comes back as the old tile
		if not (w.fg[ty] and w.fg[ty][tx] == D.DIRT) then
			return rot.stop(string.format("Dirt didn't stay on %d,%d (%s is lying there unsealed)", tx, ty, name))
		end
		wl.i, D.wallFails = wl.i + 1, 0
		if wl.i >= 60 then
			rot.log("dirt wall", string.format("wall @ %d,%d full", wl.x, wl.y))
			P.wall = nil
		end
		rot.save()
	end

	function rot.D.store()
		local w = fb.world
		for _, id in ipairs(cfg.drop.items) do
			if fb.inv:count(id) > 0 then
				local name = itemDB[id] and itemDB[id].name or "?"
				for _, b in ipairs(rot.D.boxes(w, id)) do
					rot.say(string.format("display box @ %d,%d · %s ×%d", b.x, b.y, name, fb.inv:count(id)))
					local err = rot.D.toBox(w, b, id)
					if not state.AutoDrop then return end
					if not err then
						rot.log("display", string.format("%s in box @ %d,%d", name, b.x, b.y))
						return
					end
					rot.D.skip[b.x .. "," .. b.y .. ":" .. id] = os.clock() + 600
					rot.log("display skipped", string.format("%s @ %d,%d: %s", name, b.x, b.y, err))
				end
				if state.DropWall then return rot.D.wallSlot(id) end
				return rot.dropAll(id, cfg.drop.storage, "AutoDrop")
			end
		end
	end
	function rot.D.step()
		local C = cfg.drop
		local here = rot.inWorld() and fb.world.name or nil
		if #C.items == 0 then return rot.stop("pick the items to move first") end
		if C.supply == "" or C.storage == "" or C.supply == C.storage then return rot.stop("set a supply and a storage world (two different ones)") end
		local carry = rot.D.carry()
		if here == C.storage then
			if carry > 0 then return rot.D.store() end
			if C.more == false then return rot.stop("done · nothing left to move in " .. C.supply) end
			return rot.go(C.supply)
		end
		if here == C.supply then
			local left, room = false, false
			for _, id in ipairs(C.items) do
				local pile = fb.inv:room(id) > 0 and nearestPile(id)
				if pile then return rot.fetch(pile) end
				left = left or rot.anyPile(id)
				room = room or fb.inv:room(id) > 0
			end
			C.more = left
			rot.save()
			if carry > 0 then return rot.go(C.storage) end
			if not left then return rot.stop("done · nothing left to move in " .. C.supply) end
			return rot.stop(room and "piles left that can't be picked up" or "bag full · make room for the items")
		end
		return rot.go(carry > 0 and C.storage or C.supply)
	end

	makeSection(rot.D.page, "Auto Drop", 1)
	makeToggle(rot.D.page, "Auto Drop", "Supply world piles → storage world (display boxes first, then the floor)", 2, "AutoDrop", function(on)
		if not on then
			rot.modesOff()
			rot.say("OFF")
			return
		end
		local C = cfg.drop
		if #C.items == 0 then rot.say("pick the items to move below first") return false end
		if C.supply == "" or C.storage == "" or C.supply == C.storage then rot.say("set a supply and a storage world (two different ones)") return false end
		rot.refind()
		fb.worldMenu = fb.worldMenu or findWorldMenu()
		local miss = not fb.hookMobile() and "controls" or not (fb.worldMenu and fb.worldMenu.enter) and "world menu"
			or not fb.findMenuApi() and "menu API" or not fb.findAvatar() and "drop function" or nil
		if miss then rot.say("game " .. miss .. " not found yet · try again") return false end
		if not (fb.world and fb.player and fb.inv and fb.drops) then rot.say("enter any world first") return false end
		if state.AutoRotate then fb.toggleSet.AutoRotate(false) end -- one of the two at a time
		rot.modesOff()
		rot.title, rot.fails, rot.restUntil, rot.holdUntil, rot.dropFails, C.more = "Auto Drop", 0, nil, nil, 0, nil
		rot.say("starting")
	end)
	rot.D.status = makeInfoCard(rot.D.page, "Status", 3)
	makeSection(rot.D.page, "Supply world (the piles to move)", 4)
	rot.D.supplyBox = makeSearchBox(rot.D.page, "e.g. MYFARM", 5)
	makeSection(rot.D.page, "Storage world (display boxes / floor)", 6)
	rot.D.storeBox = makeSearchBox(rot.D.page, "e.g. MYSTORAGE", 7)
	makeSection(rot.D.page, "Items to move (click to pick · in bag / lying here)", 8)
	rot.D.search = makeSearchBox(rot.D.page, "search an item", 9)
	rot.D.grid = fb.pl.grid(10, rot.D.page)
	for _, p in ipairs({ { rot.D.supplyBox, "supply" }, { rot.D.storeBox, "storage" } }) do
		local box, k = p[1], p[2]
		box.Text = cfg.drop[k]
		box.FocusLost:Connect(function()
			cfg.drop[k] = rot.names(box.Text)[1] or ""
			box.Text = cfg.drop[k]
			rot.save()
		end)
	end
	-- Picks: what you picked, what's in your bag, what lies in this world (gems, tools and
	-- untradeables can't be dropped). Picked first, then by name.
	function rot.D.render()
		local C, bag, here, ids, seen = cfg.drop, {}, {}, {}, {}
		for _, sl in ipairs(fb.inv and fb.inv.slots or {}) do bag[sl.id] = (bag[sl.id] or 0) + sl.n end
		for _, d in ipairs(fb.drops or {}) do
			if d.uid and not (d.pending or d.display) then here[d.id] = (here[d.id] or 0) + d.n end
		end
		local q = rot.D.search.Text:lower()
		for _, src in ipairs({ C.items, bag, here }) do
			for k, v in pairs(src) do
				local id = src == C.items and v or k
				local it = itemDB[id]
				if not seen[id] and it and id ~= 112 and it.kind ~= "tool" and not it.untradeable
					and (q == "" or it.name:lower():find(q, 1, true)) then
					seen[id], ids[#ids + 1] = true, id
				end
			end
		end
		table.sort(ids, function(a, b)
			local pa, pb = table.find(C.items, a) ~= nil, table.find(C.items, b) ~= nil
			if pa ~= pb then return pa end
			return itemDB[a].name < itemDB[b].name
		end)
		fb.pl.clear(rot.D.grid)
		for i = 1, math.min(#ids, 30) do
			local id = ids[i]
			local on = table.find(C.items, id) ~= nil
			fb.pl.pill(rot.D.grid, i, string.format("%s · %d / %d", itemDB[id].name, bag[id] or 0, here[id] or 0), on, function()
				local k = table.find(C.items, id)
				if k then table.remove(C.items, k) else C.items[#C.items + 1] = id end
				rot.save()
				rot.D.render()
			end)
		end
	end
	makeSection(rot.D.page, "Storage layout (when no display box takes it)", 11)
	makeToggle(rot.D.page, "Dirt wall", "Each stack on its own tile, sealed with Dirt · 20 wide, 3 high, near the door", 12, "DropWall")
	rot.D.search:GetPropertyChangedSignal("Text"):Connect(function() pcall(rot.D.render) end)
	task.spawn(function()
		while screenGui.Parent and fb.gen == myGen do
			pcall(function()
				rot.D.status.Text = state.AutoDrop and rot.msg or "OFF"
				if rot.D.page.Visible then rot.D.render() end
			end)
			task.wait(2)
		end
	end)

	-- ===== Stranger guard (Rotate page): someone not on your whitelist in one of your FARM worlds (the
	-- Rotate list; anywhere else it does nothing) -> every auto
	-- mode off, 20 s of nothing (no input), then leave like the Exit button. Whitelist = Roblox
	-- usernames, in-game names or user ids (case doesn't matter); you're always on it.
	-- Who's in your world: the game's `entered` packet (S->C {id, userId, name, ...}, checked live 11-14:
	-- the game listens on it, and it also lists who's already there when you come in), and at load /
	-- switch-on the game's own player records (getgc tables with userId + rigs, checked live 11-14:
	-- one per player in your world, + a userId 0 one).
	-- ponytail: a record of someone who just left can linger until GC; who.Parent filters ones gone from the server.
	rot.G = { list = {} }
	cfg.whitelist = cfg.whitelist or ""
	function rot.G.parse()
		rot.G.list = {}
		for n in cfg.whitelist:lower():gmatch("[%w_]+") do rot.G.list[n] = true end
	end
	rot.G.parse()
	function rot.G.ok(uid, name)
		if not uid or uid == 0 or uid == players.LocalPlayer.UserId then return true end
		local p, L = players:GetPlayerByUserId(uid), rot.G.list
		return L[tostring(uid)] or (name and L[tostring(name):lower()]) or (p and (L[p.Name:lower()] or L[p.DisplayName:lower()])) or false
	end
	function rot.G.hit(uid, name)
		if fb.gen ~= myGen or not state.Guard or rot.G.ok(uid, name) then return end
		-- only in your farm worlds (the Rotate list): anywhere else a stranger changes nothing
		local here = fb.world and fb.world.name
		if not (here and table.find(cfg.worlds, here)) or (rot.inWorld and not rot.inWorld()) then return end
		if fb.modAt and os.clock() - fb.modAt < 60 then return end -- already on it
		fb.modAt = os.clock()
		if setthreadidentity then pcall(setthreadidentity, 8) end -- the packet listener runs at the game's identity 2
		for _, k in ipairs({ "AutoRotate", "AutoDrop", "AutoHarvest", "AutoFarm", "RowFarm", "AutoPlant", "AutoBreak", "AutoCollect", "FastBreak" }) do
			if state[k] and fb.toggleSet[k] then pcall(fb.toggleSet[k], false) end
		end
		if bot then botStop("stopped") end
		fb.botInput = nil
		local p = players:GetPlayerByUserId(uid)
		local who = p and p.Name or tostring(name or uid)
		rot.log("guard", who .. " in " .. (fb.world and fb.world.name or "?") .. " · all off, leaving in 20s")
		rot.say("not whitelisted: " .. who .. " · all off, leaving in 20s", true)
		task.delay(20, function()
			if fb.gen ~= myGen then return end
			fb.leftAt = os.clock() -- Rejoin / Auto Rotate read it as "you left": they don't go back in
			pcall(leaveWorld)
			fb.modAt = nil
		end)
	end
	function rot.G.scan() -- everyone in your world now (the game's player records)
		if setthreadidentity then pcall(setthreadidentity, 8) end
		for _, t in pairs(getgc(true)) do
			if type(t) == "table" and type(rawget(t, "userId")) == "number" and rawget(t, "rigs") ~= nil then
				local who = rawget(t, "who")
				if typeof(who) == "Instance" and who.Parent then rot.G.hit(who.UserId, who.Name) end
			end
		end
	end
	fb.modAt = nil -- a re-run inside an older run's 20 s: that one's leave won't fire (gen check)
	pcall(function()
		net.entered.listen(function(d)
			if type(d) == "table" then rot.G.hit(tonumber(d.userId), d.name) end
		end)
	end)
	makeSection(rot.page, "Stranger guard", 22)
	makeToggle(rot.page, "Leave on stranger", "Farm worlds only: someone not on the whitelist → all off, 20s idle, leave", 23, "Guard", function(on)
		if on then task.defer(rot.G.scan) end
	end)
	rot.G.box = makeSearchBox(rot.page, "Whitelist: usernames, e.g. Shake, nastes72", 24)
	rot.G.box.Text = cfg.whitelist
	rot.G.box.FocusLost:Connect(function()
		cfg.whitelist = rot.G.box.Text
		rot.G.parse()
		rot.save()
	end)
	makeSection(rot.page, "Discord webhook (a world's round done)", 25)
	rot.hookBox = makeSearchBox(rot.page, "https://discord.com/api/webhooks/...", 26)
	rot.hookBox.Text = cfg.webhook or ""
	rot.hookBox.FocusLost:Connect(function()
		cfg.webhook = rot.hookBox.Text:gsub("%s", "")
		rot.hookBox.Text = cfg.webhook
		rot.save()
	end)
	makeButton(rot.page, "Send a test (this world's numbers so far)", 27, function()
		local F = cfg.run.world or (fb.world and fb.world.name) or "?"
		if not (cfg.webhook or ""):match("^https://discord") then return rot.say("paste a Discord webhook URL first") end
		rot.report(F)
		rot.say("webhook test sent · " .. F)
	end)

	-- Settings from the last run (= clicking each switch), then Auto Rotate again if it was on in
	-- the last 15 min (a teleport to another world's server, a re-run). Right after a teleport the
	-- game's tables can take a moment to show up: up to 10 tries, 3s apart.
	local resume = cfg.run.on and os.time() - (cfg.run.at or 0) < rot.FRESH
	rot.rkey = resume and "AutoRotate" or "AutoDrop" -- the one that was on (Auto Drop: same 15 min rule)
	resume = resume or (cfg.drop.on and os.time() - (cfg.drop.at or 0) < rot.FRESH)
	-- Kicked (267, or Roblox's own 268): this run is over, and it must not come back by itself if
	-- you rejoin inside the FRESH window.
	pcall(function()
		guiService.ErrorMessageChanged:Connect(function()
			if fb.gen ~= myGen or not (rot.on() or cfg.run.on or cfg.drop.on) then return end
			if setthreadidentity then pcall(setthreadidentity, 8) end -- GetErrorCode is Roblox-only
			local code = guiService:GetErrorCode()
			if code ~= Enum.ConnectionError.DisconnectLuaKick and code ~= Enum.ConnectionError.DisconnectOnRemoteSysStats then return end
			resume, rot.loading = false, nil -- rot.save keeps the file's `on` while loading
			rot.stop("kicked (" .. code.Value .. ") · won't resume")
			rot.save()
		end)
	end)
	local saved = table.clone(cfg.settings)
	for _, k in ipairs(rot.SETTINGS) do
		if type(saved[k]) == "boolean" and state[k] ~= saved[k] and fb.toggleSet[k] then pcall(fb.toggleSet[k], saved[k]) end
	end
	task.spawn(function()
		for i = 1, resume and 10 or 0 do
			task.wait(i == 1 and 1 or 3)
			if fb.gen ~= myGen or state[rot.rkey] or not resume or fb.modAt then break end -- modAt: a stranger here (Stranger guard)
			fb.toggleSet[rot.rkey](true)
			if state[rot.rkey] then break end -- running: a stop from here on is the run's own, not "not ready yet"
		end
		rot.loading = nil
		if not resume or fb.gen ~= myGen then return end
		local here = fb.world and fb.world.name or "?"
		if state.AutoDrop then
			rot.log("loaded", "resumed auto drop in " .. here)
			rot.say("resumed · auto drop", true)
		elseif state.AutoRotate then
			rot.log("loaded", string.format("resumed %s %s in %s", tostring(cfg.run.phase), tostring(cfg.run.world), here))
			rot.say("resumed · " .. tostring(cfg.run.phase or "picking a world") .. " " .. tostring(cfg.run.world or ""), true)
		else
			rot.log("loaded", "couldn't resume in " .. here .. ": " .. tostring(rot.msg))
			rot.say("couldn't resume: " .. tostring(rot.msg), true)
			rot.save()
		end
	end)
end

-- Live updater.
task.spawn(function()
	local lastRefresh = 0
	while screenGui.Parent do
		pcall(function()
			statusLabel.Text = fb.fastOn and "ON" or (fb.world and "OFF" or "OFF · enter a world")
			-- the game's punch reach (2.5 + worn `reach`) for canHit; changes when you wear something
			fb.punchRange = fb.avatar and fb.avatar.punchRange and fb.avatar.punchRange() or fb.punchRange
			brokenLabel.Text = tostring(fb.broken)
			revertLabel.Text = tostring(fb.reverts)
			local t = fb.target
			autoLabel.Text = not fb.autoOn and "OFF"
				or (t and string.format("%s @ %d,%d", itemDB[t.id].name, t.x, t.y))
				or (state.BreakWalk and fb.brStatus) or "none in reach"
			collectLabel.Text = tostring(fb.collected)
			pathLabel.Text = fb.pathStatus or "idle"
			human.card.Text = human.text()
			human.fcCard.Text = human.fcText()
			farmStatusLabel.Text = fb.farmStatus or (state.AutoFarm and "running" or "OFF")
			local nb = fb.inv and farmBlock()
			farmBlockLabel.Text = nb and string.format("%s ×%d", itemDB[nb].name, fb.inv:count(nb)) or "none in bag"
			local hrs = state.AutoFarm and (os.clock() - fb.farmStart) / 3600
			if hrs and fb.farmGems0 then
				local g = fb.gemsNow() -- local HUD value: this runs every 0.3s
				if g then fb.farmGems = math.max(0, g - fb.farmGems0) end
			end
			farmStatsLabel.Text = hrs and string.format("%d · %.1f/min · %d", fb.farmBroken, fb.farmBroken / math.max(hrs * 60, 1 / 6),
				math.floor(fb.farmGems / math.max(hrs, 1 / 360))) or "-"
			if os.clock() - lastRefresh > 3 then -- world changes: refresh counts
				lastRefresh = os.clock()
				fb.world = fb.world or findWorld()
				-- run before the world loaded = these getgc scans missed at load: retry
				fb.player = fb.player or findPlayer()
				fb.drops = fb.drops or findDrops()
				fb.inv = fb.inv or findInventory()
				fb.findAvatar()
				if fb.world and fb.world.name ~= fb.doorWorld then -- entered another world
					fb.doorWorld = fb.world.name
					renderDoors()
				end
				renderResults()
				renderFarmPicks()
				renderDropPicks()
				if state.UltimateFPS then fb.ultimateFps(true) end -- a world change can rebuild the backdrop
			end
		end)
		task.wait(0.3)
	end
	-- GUI destroyed: never leave anything on (unless a newer run owns it).
	if fb.gen == myGen then
		if state.UltimateFPS then fb.ultimateFps(false) end
		if state.BlankScreen then fb.blankScreen(false) end
		fb.antiIdle = false -- script closed: Roblox's idle rules apply again
		fb.fastOn, fb.autoOn = false, false
		fb.botInput = nil
		setPatched(false)
		restoreHazards()
		tagFolder:Destroy()
	end
end)
