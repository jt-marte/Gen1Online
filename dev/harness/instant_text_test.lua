-- Instant text (other/instant_text.lua) on the engine's own text printers,
-- with no ROM: the Gen 1 / Crystal TextBox, Gen 1 battle text, Crystal's
-- Typer and FireRed's Message.  The ROM's charmap is swapped for a stand-in
-- font (one code per character): the typewriters only count codes.  Each
-- printer is timed vanilla first, then with the module installed.
--   cd ../gen1recomp && luajit ../Gen1Online/dev/harness/instant_text_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]dev[/\\]harness[/\\]") or "."
love = require("tests.love_stub")

local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
end

-- the stand-in font, before anything requires the real one
local function spans(s)
  local out = {}
  for i = 1, #s do out[i] = { from = i, to = i } end
  return out
end
package.loaded["src.render.Font"] = setmetatable({
  split = spans,
  encode = function(s) local out = {} for i = 1, #s do out[i] = s:byte(i) end return out end,
  -- every glyph a vanilla 8px cell
  spansFitting = function(list, budget) return math.min(#list, math.floor(budget / 8)) end,
}, { __index = function() return function() return 0 end end })

local Instant = assert(loadfile(here .. "/other/instant_text.lua"))()
local TextBox = require("src.render.TextBox")
local Typer = require("src.ui.gen2.Typer")
local okB, BattleState = pcall(require, "src.battle.BattleState")
local okM, Message = pcall(require, "src.ui.game3.message")
if not okB then print("(Gen 1 battle text not loadable here: " .. tostring(BattleState) .. ")") end
if not okM then print("(FireRed's Message not loadable here: " .. tostring(Message) .. ")") end

-- a game with a slow text speed, a stack and a pad the test presses
local pressed = {}
local stack = { states = {} }
function stack:push(s) self.states[#self.states + 1] = s end
function stack:pop() return table.remove(self.states) end
function stack:top() return self.states[#self.states] end
local game = {
  save = { options = { textSpeed = 5 } },        -- SLOW: 5 frames a letter
  input = { wasPressed = function(_, k) return pressed[k] == true end, isDown = function() return false end },
  stack = stack, data = { text = {} },
}
-- one update; with `press`, A is down for it
local function update(box, press)
  pressed.a = press or nil
  box:update(1 / 60)
  pressed.a = nil
end
-- updates until cond(box), at most `limit`; how many it took (limit + 1: never)
local function framesUntil(box, cond, limit)
  for n = 1, limit do
    update(box)
    if cond(box) then return n end
  end
  return limit + 1
end
local function waitingOrDone(box) return box.waiting or box.done end
local function shownText(box) return table.concat(box:visibleText() or {}, "/") end
local TEXT = "HELLO THERE\nHOW ARE YOU\fSECOND" .. TextBox.PAUSE .. " PAGE\nLINE TWO\fTHE END"

-- ---- vanilla: the typewriter the module replaces ---------------------------------------
local vanillaPage = framesUntil(TextBox.new(game, TEXT), waitingOrDone, 400)
check(vanillaPage > 60, "vanilla TextBox: the first page types out over " .. vanillaPage .. " frames")
local typer0 = Typer.new(game)
typer0:start({ "HELLO THERE", "HOW ARE YOU" })
check(not typer0:tick(), "vanilla Typer: one tick is not the whole page")
local vanillaBattle
if okB then
  local b = setmetatable({ game = game, queue = { { text = "WILD PIDGEY\nappeared!" } } }, { __index = BattleState })
  vanillaBattle = 0
  repeat
    b:updateQueue()
    vanillaBattle = vanillaBattle + 1
  until (b.lineIndex == 2 and #b.shown[#b.shown] == #b.codes) or vanillaBattle > 400
  check(vanillaBattle > 30, "vanilla Gen 1 battle text: two lines over " .. vanillaBattle .. " updates")
end
local function messagePage(total)
  Message.open, Message._waiting, Message._choice = true, false, nil
  Message._pages, Message._page = { "HELLO THERE" }, 1
  Message._revealed, Message._total, Message._delay, Message._speedIdx = 0, total, 0, 0
end
if okM then
  messagePage(11)
  Message.tick()
  check(Message._revealed == 1 and not Message._waiting, "vanilla Message: one tick shows one letter")
  Message.close()
end

-- ---- installed -------------------------------------------------------------------------
local patched = Instant.install({ TextBox = TextBox, BattleState = okB and BattleState or nil,
                                  Typer = Typer, Message = okM and Message or nil })
check(#patched == 2 + (okB and 1 or 0) + (okM and 1 or 0), "installed: " .. table.concat(patched, ", "))

local done = false
local box = TextBox.new(game, TEXT, function() done = true end)
stack:push(box)
local n = framesUntil(box, waitingOrDone, 400)
check(n <= 3 and shownText(box) == "HELLO THERE/HOW ARE YOU",
  ("TextBox: the first page is up whole after %d update(s): %s"):format(n, shownText(box)))
for _ = 1, 3 do update(box) end
check(box.waiting and box.pageIndex == 1, "and waits for A")
update(box, true)
n = framesUntil(box, waitingOrDone, 400)
check(n <= 3 and box.pageIndex == 2 and shownText(box) == "SECOND PAGE/LINE TWO",
  ("A: the next page, mid-text pause and empty-box wait skipped, after %d update(s): %s"):format(n, shownText(box)))
for _ = 1, 3 do update(box) end
update(box, true)
n = framesUntil(box, waitingOrDone, 400)
check(n <= 2 and box.done and shownText(box) == "THE END", ("the last page after %d update(s)"):format(n))
for _ = 1, 3 do update(box) end
check(not done and stack:top() == box, "the box stays until A")
update(box, true)
check(done and stack:top() == nil, "A closes it")

local typer = Typer.new(game)
typer:start({ "HELLO THERE", "HOW ARE YOU" })
check(typer:tick() and table.concat(typer:lines(), "/") == "HELLO THERE/HOW ARE YOU",
  "Typer: the whole page on the first tick")

if okB then
  local b = setmetatable({ game = game, queue = { { text = "WILD PIDGEY\nappeared!" } } }, { __index = BattleState })
  local calls = 0
  repeat
    b:updateQueue()
    calls = calls + 1
  until (b.lineIndex == 2 and #b.shown[#b.shown] == #b.codes) or calls > 400
  check(calls <= 3, ("Gen 1 battle text: both lines after %d update(s) (vanilla %d)"):format(calls, vanillaBattle))
end

if okM then
  messagePage(11)
  Message.tick()
  check(Message._revealed == 11 and Message._waiting, "Message: the whole page on the first tick, waiting for A")
  Message.close()
end

-- ---- once ------------------------------------------------------------------------------
local update0, delay0 = TextBox.update, Typer.delay
local again = Instant.install({ TextBox = TextBox, Typer = Typer, BattleState = okB and BattleState or nil,
                                Message = okM and Message or nil })
check(#again == 0 and TextBox.update == update0 and Typer.delay == delay0, "installing twice changes nothing")
check(#Instant.install({}) == 0 and #Instant.install(nil) == 0, "and nothing to patch is fine")

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
