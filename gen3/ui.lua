-- The mod's screens on FireRed and LeafGreen.
--
-- Every screen in main.lua is written against Gen 1's UI: game.stack (a
-- StateStack of state objects), TextBox.new, Menu.new and Font.draw on a
-- 160x144 screen.  FireRed has none of those: its modal UI is
-- src/ui/game3/stack.lua (a stack of module layers that get handleInput /
-- update / draw), its text is FrlgFont on a 240x160 screen, and the Gen 1
-- font sheets don't exist on a FireRed install.  So this file gives the mod:
--
--   UI.Stack      a StateStack for the mod's own states.  While it holds
--                 anything, one layer ("gen1online") sits on FireRed's stack:
--                 the field and the START menu stop taking input, and that
--                 layer updates and draws the mod's states.
--   UI.TextBox    the FireRed dialogue box (TextBox.new(game, text, onDone)).
--   UI.Menu       a FireRed list window (Menu.new(game, items, opts)).
--   UI.Font       Font.draw / drawBox / width for the mod's full-screen
--                 screens, which keep their 160x144 layout: they draw inside
--                 a 1.5 x 1.11 scale, and text and frames undo that scale, so
--                 they come out in FireRed's own font and window frame.
--   UI.wrapText   wrapText, measured in FireRed's font and dialogue width.
--   UI.nameEntry  FireRed's naming screen.
--
-- Everything is created by the callers in main.lua exactly as on Gen 1.
return function(env)
  local Stack3 = require("src.ui.game3.stack")
  local Chrome = require("src.ui.game3.chrome")
  local FrlgFont = require("src.ui.game3.frlg_font")
  local Window = require("src.ui.game3.window")

  local UI = {}
  local SX, SY = 240 / 160, 160 / 144       -- a Gen 1 pixel on FireRed's screen
  local LAYER = "gen1online"
  local TextBox, Menu = {}, {}     -- filled in below; Host.draw tells them apart

  local function se(id)
    pcall(function()
      local Audio = require("src.core.game3.audio")
      Audio.playSe(require("src.core.game3.se_ids").resolve(id))
    end)
  end
  UI.se = se

  local function battleActive()
    local okB, B = pcall(require, "src.core.game3.battle")
    if not okB then B = nil end
    return B and B.isActive and B.isActive() or false
  end

  -- FireRed's font has no glyph for a few characters the screens use: the
  -- braces and "_" go, "#" becomes FireRed's own No. and "*" (a party's
  -- leader) a ◎
  local GLYPHS = { ["#"] = "№", ["*"] = "◎" }
  local function clean(text)
    return (tostring(text or ""):gsub("[{}]", ""):gsub("_", " "):gsub("[#*]", GLYPHS))
  end
  UI.clean = clean

  -- ---------------------------------------------------------------- stack

  -- frames, counted from main.lua's core.update before the game's own update
  UI.frame = 0
  function UI.nextFrame() UI.frame = UI.frame + 1 end

  local Stack = { states = {} }
  UI.Stack = Stack
  local Host = { isMenu = true }

  function Stack:top() return self.states[#self.states] end
  -- a screen opened mid-battle (an MMO level-up, a chat line) waits for the
  -- battle to end: a layer on FireRed's stack would stall the battle's end
  Stack.pending = {}
  function Stack:push(state)
    if battleActive() then
      self.pending[#self.pending + 1] = state
      return state
    end
    self.states[#self.states + 1] = state
    -- the press that opened it (an A on the field, which FireRed handles
    -- before its menus in the same frame) must not also reach it
    if type(state) == "table" then state._g3Frame = UI.frame end
    -- (re)raise the host layer: a FireRed screen opened in between (a trade
    -- scene, an evolution) has finished by the time the mod pushes again
    Stack3.push(LAYER, Host, { hideBelow = true })
    return state
  end
  function Stack:pop()
    local state = table.remove(self.states)
    if #self.states == 0 then Stack3.pop(LAYER) end
    return state
  end
  function Stack:clear()
    self.states = {}
    self.pending = {}
    Stack3.pop(LAYER)
  end
  function Stack:size() return #self.states + #self.pending end
  -- the host layer is gone when the engine cleared its stack (back to the
  -- title, a session swap): put it back while the mod still has screens
  function Stack:ensureLayer()
    if #self.pending > 0 and not battleActive() then
      local waiting = self.pending
      self.pending = {}
      for _, state in ipairs(waiting) do self:push(state) end
      return
    end
    if #self.states > 0 and not Stack3.has(LAYER) then
      Stack3.push(LAYER, Host, { hideBelow = true })
    end
  end

  -- FireRed's stack calls the top layer's update and handleInput every field
  -- frame.  update runs the mod's top state (its own input reads included);
  -- handleInput only has to exist, so the press goes nowhere else.
  function Host.update(dt)
    if battleActive() then return end
    local top = Stack:top()
    if top and top._g3Frame == UI.frame then return end
    if top and top.update then top:update(dt or 1 / 60) end
  end
  function Host.handleInput() end
  function Host.draw()
    if battleActive() then return end
    -- From the top down: text boxes and the topmost menu, over the nearest
    -- full screen (a lower menu would only peek out from under this one).
    local states, drawn, menuSeen = Stack.states, {}, false
    for i = #states, 1, -1 do
      local s = states[i]
      if getmetatable(s) == TextBox then
        if not menuSeen then table.insert(drawn, 1, s) end
      elseif getmetatable(s) == Menu then
        if not menuSeen then table.insert(drawn, 1, s) end
        menuSeen = true
      else
        table.insert(drawn, 1, s)
        break
      end
    end
    for _, s in ipairs(drawn) do
      if s.draw then
        local G = love.graphics
        G.push("all")
        if not s.g3Native then G.scale(SX, SY) end
        local ok, err = pcall(s.draw, s)
        G.pop()
        if not ok then print("[Gen1Online+] screen draw failed: " .. tostring(err)) end
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end
  UI.Host = Host

  -- ----------------------------------------------------- full-screen font

  -- Font for screens laid out on Gen 1's 160x144 grid, drawn by Host.draw
  -- inside scale(SX, SY).  Text and frames are drawn back at 1:1 on whole
  -- FireRed pixels.
  local Font = {}
  UI.Font = Font
  local function native(fn)
    local G = love.graphics
    G.push()
    G.scale(1 / SX, 1 / SY)
    local ok, err = pcall(fn)
    G.pop()
    if not ok then error(err, 0) end
  end
  function Font.draw(text, x, y)
    native(function()
      FrlgFont.draw(clean(text), math.floor(x * SX + 0.5), math.floor(y * SY + 0.5),
        { maxWidth = 240, colors = FrlgFont.COLOR.NORMAL })
    end)
  end
  -- a Gen 1 box of tiles (tx, ty, tw, th), border included, as a FireRed
  -- frame around the same area
  function Font.drawBox(tx, ty, tw, th)
    native(function()
      local x0, y0 = tx * 8 * SX, ty * 8 * SY
      local x1, y1 = (tx + tw) * 8 * SX, (ty + th) * 8 * SY
      local L, T = math.floor(x0 / 8 + 0.5) + 1, math.floor(y0 / 8 + 0.5) + 1
      local W = math.max(1, math.floor(x1 / 8 + 0.5) - 1 - L)
      local H = math.max(1, math.floor(y1 / 8 + 0.5) - 1 - T)
      Chrome.stdFrame(L, T, W, H)
    end)
  end
  -- width in Gen 1 pixels, so the screens' centring math still works
  function Font.width(text)
    return FrlgFont.measure(clean(text)) / SX
  end
  function Font.split(text)
    local out = {}
    for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
  end

  -- --------------------------------------------------------- word wrap

  local function dialogueSize()
    local _, _, W = Chrome.dialogueWindow()
    return (W or 26) * 8 - 4
  end

  -- wrapText(str, maxLen): pages of two lines, separated by \f.  maxLen is
  -- Gen 1 characters (8 px each); unset it is the dialogue box's width.
  function UI.wrapText(str, maxLen)
    if not str or #tostring(str) == 0 then return "" end
    local width = maxLen and math.floor(maxLen * 8 * SX) or dialogueSize()
    local lines = {}
    for paragraph in clean(str):gmatch("[^\r\n\f]+") do
      local wrapped = FrlgFont.wrap(paragraph, width)
      for line in (wrapped .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then lines[#lines + 1] = line end
      end
    end
    local pages = {}
    for i = 1, #lines, 2 do
      pages[#pages + 1] = lines[i + 1] and (lines[i] .. "\n" .. lines[i + 1]) or lines[i]
    end
    return table.concat(pages, "\f")
  end

  -- ------------------------------------------------------------ text box

  TextBox.__index = TextBox
  TextBox.g3Native = true
  TextBox.isTextBox = true
  UI.TextBox = TextBox

  local function pagesOf(text)
    local pages = {}
    for page in (tostring(text or "") .. "\f"):gmatch("(.-)\f") do
      if page ~= "" then pages[#pages + 1] = clean(page) end
    end
    if #pages == 0 then pages[1] = "" end
    return pages
  end

  function TextBox.new(game, text, onDone, opts)
    local self = setmetatable({}, TextBox)
    self.game = game
    -- callers hand over raw strings too ("A\nB\nC"): wrapping again is
    -- harmless on text wrapText already made
    self.pages = pagesOf(UI.wrapText(text))
    self.text = text
    self.onDone = onDone
    self.opts = opts or {}
    self.page = 1
    self.shown = 0
    self.clock = 0
    return self
  end

  function TextBox:chars()
    return FrlgFont.countChars and FrlgFont.countChars(self.pages[self.page]) or #self.pages[self.page]
  end

  function TextBox:update(dt)
    local input = self.game and self.game.input
    self.clock = self.clock + 1
    local total = self:chars()
    if self.shown < total then
      self.shown = math.min(total, self.shown + 2)
      if input and (input:wasPressed("a") or input:wasPressed("b")) then self.shown = total end
      return
    end
    if not (input and (input:wasPressed("a") or input:wasPressed("b"))) then return end
    if self.page < #self.pages then
      self.page = self.page + 1
      self.shown = 0
      return
    end
    if self.game.stack:top() == self then self.game.stack:pop() end
    if self.onDone then self.onDone() end
  end

  function TextBox:draw()
    Chrome.dialogueFrame()
    local L, T, W = Chrome.dialogueWindow()
    local x, y = L * 8, T * 8 + 1
    local _, endX, endY = FrlgFont.draw(self.pages[self.page], x, y, {
      maxWidth = W * 8, colors = FrlgFont.COLOR.NORMAL, limitChars = self.shown,
    })
    if self.shown >= self:chars() and math.floor(self.clock / 16) % 2 == 0 then
      local ax = math.min((endX or x) + 3, x + W * 8 - 8)
      local ay = (endY or y) + 4
      love.graphics.setColor(0.9, 0.25, 0.2, 1)
      love.graphics.polygon("fill", ax, ay, ax + 6, ay, ax + 3, ay + 4)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end

  -- ---------------------------------------------------------------- menu

  Menu.__index = Menu
  Menu.g3Native = true
  Menu.isMenu = true
  UI.Menu = Menu
  local ROW = 16
  local MAX_ROWS = 8

  function Menu.new(game, items, opts)
    local self = setmetatable({}, Menu)
    opts = opts or {}
    self.game = game
    self.items = items or {}
    self.index = 1
    self.scroll = 0
    self.maxVisible = math.min(opts.maxVisible or MAX_ROWS, MAX_ROWS)
    self.cancelable = opts.cancelable ~= false
    self.startCloses = opts.startCloses or false
    self.keepOnCancel = opts.keepOnCancel or false
    self.onCancel = opts.onCancel
    self.title = opts.title
    -- Gen 1 boxes start at tile tx; a box that spans the screen there
    -- (tx 0 or 1) is a list down the left, anything further right keeps
    -- to the right
    self.right = (opts.tx or 0) >= 8
    return self
  end

  function Menu:visible() return math.min(self.maxVisible, #self.items) end

  function Menu:clampScroll()
    local vis = self:visible()
    if self.index - self.scroll > vis then self.scroll = self.index - vis end
    if self.index - self.scroll < 1 then self.scroll = self.index - 1 end
  end

  function Menu:update(dt)
    local input = self.game.input
    if #self.items == 0 then
      if input:wasPressed("b") or input:wasPressed("a") then self.game.stack:pop() end
      return
    end
    if input:wasPressed("up") then
      self.index = self.index > 1 and self.index - 1 or #self.items
      se("SE_SELECT")
    elseif input:wasPressed("down") then
      self.index = self.index < #self.items and self.index + 1 or 1
      se("SE_SELECT")
    elseif input:wasPressed("a") then
      se("SE_SELECT")
      local item = self.items[self.index]
      if not item.keepOpen and self.game.stack:top() == self then self.game.stack:pop() end
      if item.onSelect then item.onSelect() end
    elseif self.cancelable and (input:wasPressed("b")
        or (self.startCloses and input:wasPressed("start"))) then
      if input:wasPressed("b") then se("SE_SELECT") end
      if not self.keepOnCancel and self.game.stack:top() == self then self.game.stack:pop() end
      if self.onCancel then self.onCancel() end
    end
    self:clampScroll()
  end

  function Menu:geometry()
    local widest = 40
    for _, it in ipairs(self.items) do
      local w = FrlgFont.measure(clean(it.label))
      if w > widest then widest = w end
    end
    local wTiles = math.min(28, math.ceil((widest + Window.CURSOR_WIDTH + 4) / 8))
    local hTiles = self:visible() * 2
    local L = self.right and (29 - wTiles) or 1
    return L, 1, wTiles, hTiles
  end

  function Menu:draw()
    local L, T, W, H = self:geometry()
    Chrome.stdFrame(L, T, W, H)
    local x, y = L * 8, T * 8
    for row = 1, self:visible() do
      local item = self.items[self.scroll + row]
      if not item then break end
      FrlgFont.draw(clean(item.label), x + Window.CURSOR_WIDTH, y + (row - 1) * ROW + 1,
        { maxWidth = W * 8 - Window.CURSOR_WIDTH, colors = FrlgFont.COLOR.NORMAL })
    end
    Window.cursorPx(x, y + (self.index - self.scroll - 1) * ROW + 1)
    love.graphics.setColor(0.4, 0.4, 0.45, 1)
    local cx = x + W * 8 - 6
    if self.scroll > 0 then
      love.graphics.polygon("fill", cx - 3, y + 1, cx + 3, y + 1, cx, y - 3)
    end
    if self.scroll + self:visible() < #self.items then
      local by = y + H * 8 - 2
      love.graphics.polygon("fill", cx - 3, by, cx + 3, by, cx, by + 4)
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- -------------------------------------------------------- name entry

  -- FireRed's naming screen: opts { prompt, maxLength, initial, digits,
  -- onDone(name), onCancel }.  It has upper and lower case, and digits on
  -- the OTHERS page; an empty name counts as cancelling.
  function UI.nameEntry(game, opts)
    local ok, Naming = pcall(require, "src.ui.game3.naming")
    if not (ok and Naming and Naming.open) then
      if opts.onCancel then opts.onCancel() end
      return
    end
    local session = env.session and env.session()
    Naming.open({
      title = opts.prompt,
      maxLen = opts.maxLength,
      initialText = opts.initial or "",
      template = "PLAYER",
      gender = session and session.gender or 0,
      session = session,
      onDone = function(name)
        name = type(name) == "string" and name or ""
        Stack:ensureLayer()
        if name:match("^%s*$") then
          if opts.onCancel then opts.onCancel() end
          if opts.onDone and not opts.onCancel then opts.onDone("") end
          return
        end
        if opts.onDone then opts.onDone(opts.upper and name:upper() or name) end
      end,
    })
  end

  return UI
end
