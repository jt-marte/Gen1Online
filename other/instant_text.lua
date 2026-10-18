-- Instant text: every text box shows its whole page at once instead of
-- typing it out letter by letter, on every game the mod runs on, offline
-- too (the one change the mod makes to the offline game; the user asked for
-- it).  A still turns each page and closes the box, and YES/NO questions,
-- the sound effects inside a text and the waits for them stay as they are.
--
--   requireLocal("other/instant_text.lua").install{ TextBox =, BattleState =,
--                                                  Typer =, Message = }
--
-- Each one is an engine module, any may be missing (a game hands over its
-- own printers only), and installing twice changes nothing.  Returns the
-- names of the printers it patched this time.
local M = {}

local MARK = "_g1oInstantText"

local function once(t, patch)
  if type(t) ~= "table" or rawget(t, MARK) then return false end
  if patch(t) == false then return false end
  rawset(t, MARK, true)
  return true
end

-- src/render/TextBox.lua (Gen 1 and Crystal field text).  The typewriter
-- prints while charTimer has frames banked and stops at the end of each
-- line, so a bottomless timer prints a line per update.  A mid-text pause
-- (TextCommand_PAUSE) and the box's own waits after A (holdFrames: the page
-- clear and the line scroll) are skipped; a pause's sound still plays, and
-- is waited for.
local function textBox(TextBox)
  local orig = TextBox.update
  if type(orig) ~= "function" then return false end
  TextBox.update = function(self, ...)
    if not self.done and not self.waiting then
      self.charTimer = math.huge
      if (self.pauseFrames or 0) > 0 then self.pauseFrames = 0 end
    end
    if (self.holdFrames or 0) > 0 then self.holdFrames = 0 end
    return orig(self, ...)
  end
end

-- src/battle/BattleState.lua (Gen 1 battle text): the same typewriter in the
-- message queue, whose loop also stops at the end of the line.
local function battleState(BattleState)
  local orig = BattleState.updateQueue
  if type(orig) ~= "function" then return false end
  BattleState.updateQueue = function(self, ...)
    self.charTimer = math.huge
    return orig(self, ...)
  end
end

-- src/ui/gen2/Typer.lua (Crystal's battle text and screens): no delay is its
-- own instant mode (the whole page on the first tick).
local function typer(Typer)
  if type(Typer.delay) ~= "function" then return false end
  Typer.delay = function() return 0 end
end

-- src/ui/game3/message.lua (FireRed/LeafGreen field and battle text): a page
-- still typing is revealed whole, as the first A press would do.
local function message(Message)
  local orig = Message.tick
  if type(orig) ~= "function" or type(Message.skipReveal) ~= "function" then return false end
  Message.tick = function(...)
    if Message.open and not Message._waiting
        and not (Message.isRsFieldAutoScroll and Message.isRsFieldAutoScroll()) then
      Message.skipReveal()
    end
    return orig(...)
  end
end

function M.install(m)
  m = m or {}
  local patched = {}
  if once(m.TextBox, textBox) then patched[#patched + 1] = "TextBox" end
  if once(m.BattleState, battleState) then patched[#patched + 1] = "BattleState" end
  if once(m.Typer, typer) then patched[#patched + 1] = "Typer" end
  if once(m.Message, message) then patched[#patched + 1] = "Message" end
  return patched
end

return M
