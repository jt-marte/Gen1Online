-- PVP battles and link trades on FireRed and LeafGreen, played by the game's
-- own link code over the mod's server.
--
-- Accepting a challenge (main.lua) starts the same thing on both machines:
-- a Game3Link (src/link/Game3Link.lua) attached through Link.open on a
-- transport that rides the server's battle rooms (send_battle_msg /
-- poll_battle_msgs, on the async HTTP engine, so the game never blocks on
-- it).  The challenger is seat 0, the master.  Once both games' hellos
-- agree, a battle is the Union Room battle (LB.startUnionRoomBattle: the
-- party is healed for it and put back after, like the cartridge) at the
-- party's real levels, and a trade is the Trade Center's trade screen
-- (LT.startMenu), its trade scene and its save.  Both machines commit a
-- trade when the two digests match, the cable's rule (loopbackCommit).
--
-- env = { G3, send(payload, callback), post(payload, timeout), raw() }
return function(env)
  local G3 = env.G3
  local UI = G3.UI
  local L = {}

  local function now()
    return (love and love.timer and love.timer.getTime) and love.timer.getTime() or os.time()
  end
  local function req(name)
    local ok, m = pcall(require, name)
    return ok and m or nil
  end

  -- -------------------------------------------------------- transport

  local Transport = {}
  Transport.__index = Transport
  L.POLL = 0.1

  function Transport.new(opts)
    return setmetatable({
      paired = true, closed = false, error = nil,
      myId = tostring(opts.myId), theirId = tostring(opts.theirId), roomId = opts.roomId,
      mySeat = opts.seat, inbox = {}, lastPoll = -math.huge, polling = false,
      sendFn = opts.send,
    }, Transport)
  end
  function Transport:seat() return self.mySeat end
  function Transport:seats() return 2 end
  function Transport:send(msg)
    if self.closed then return false end
    self.sendFn({ action = "send_battle_msg", roomId = self.roomId, targetId = self.theirId, msg = msg },
      function() end)
    return true
  end
  function Transport:update()
    if self.closed or self.polling or now() - self.lastPoll < L.POLL then return end
    self.lastPoll, self.polling = now(), true
    self.sendFn({ action = "poll_battle_msgs", roomId = self.roomId, myId = self.myId }, function(res)
      self.polling = false
      for _, m in ipairs((res and res.msgs) or {}) do
        if type(m) == "table" then self.inbox[#self.inbox + 1] = m end
      end
    end)
  end
  function Transport:poll()
    local out = self.inbox
    self.inbox = {}
    return out
  end
  function Transport:close() self.closed = true end
  L.Transport = Transport

  -- ---------------------------------------------------- waiting screen

  -- "Waiting for X..." while the two games shake hands; B gives up
  local Wait = {}
  Wait.__index = Wait
  Wait.g3Native = true
  function Wait.new(game, text, onCancel)
    return setmetatable({ game = game, text = text, onCancel = onCancel, clock = 0 }, Wait)
  end
  function Wait:update()
    self.clock = self.clock + 1
    local input = self.game.input
    if input and input:wasPressed("b") and self.onCancel then self.onCancel() end
  end
  function Wait:draw()
    local Chrome = require("src.ui.game3.chrome")
    local FrlgFont = require("src.ui.game3.frlg_font")
    Chrome.dialogueFrame()
    local Lft, Top, W = Chrome.dialogueWindow()
    local dots = string.rep(".", math.floor(self.clock / 20) % 4)
    FrlgFont.draw(self.text .. dots .. "\nB: CANCEL", Lft * 8, Top * 8 + 1,
      { maxWidth = W * 8, colors = FrlgFont.COLOR.NORMAL })
  end

  -- ------------------------------------------------------------ links

  L.active = nil
  L.HANDSHAKE = 40          -- seconds for the other game to answer

  local function closeLink(a)
    local Link = req("src.core.game3.link")
    if Link and Link.link then pcall(Link.closeLink, "gen1online") end
    if a and a.transport then a.transport:close() end
    local LT = req("src.core.game3.link.trade")
    if LT then LT.loopbackCommit = false end
    local LB = req("src.core.game3.link.battle")
    if LB and LB.setVirtual then LB.setVirtual(nil) end
  end

  local function popWait(a)
    local stack = a.game.stack
    for i = #stack.states, 1, -1 do
      if stack.states[i] == a.wait then
        table.remove(stack.states, i)
        if #stack.states == 0 then stack:clear() end
        break
      end
    end
    a.wait = nil
  end

  -- the link ended: put everything away, then tell main.lua
  local function finish(a, result, why)
    if L.active ~= a then return end
    L.active = nil
    L.last = a
    if a.wait then popWait(a) end
    closeLink(a)
    local LT = req("src.core.game3.link.trade")
    if LT and LT.state == "exit" then LT.state = "off" end
    pcall(env.post, { action = "clear_battle_room", roomId = a.roomId }, 0.5)
    if a.onDone then a.onDone(result, why) end
  end

  -- kind = "battle" | "trade"; opts = { game, myId, theirId, roomId,
  -- isHost, peerName, onDone(result, why) }; result is "win" | "lose" |
  -- "draw" for a battle, "done" for a trade, nil when it never started
  function L.start(kind, opts)
    if L.active then return false, "busy" end
    local Link, Game3Link = req("src.core.game3.link"), req("src.link.Game3Link")
    if not (Link and Game3Link) then return false, "no_link" end
    local transport = Transport.new({ myId = opts.myId, theirId = opts.theirId, roomId = opts.roomId,
      seat = opts.isHost and 0 or 1, send = env.send })
    local a = {
      kind = kind, game = opts.game, transport = transport, roomId = opts.roomId,
      onDone = opts.onDone, started = false, t0 = now(), peerName = opts.peerName,
    }
    L.active = a
    local ok, err = pcall(Link.open, {
      transport = transport, seat = transport.mySeat, seats = 2,
      linkType = kind == "battle" and Game3Link.LINKTYPE.SINGLE_BATTLE or Game3Link.LINKTYPE.TRADE,
      timeout = L.HANDSHAKE, game = env.raw(),
    })
    if not ok then
      finish(a, nil, tostring(err))
      return false, err
    end
    a.wait = Wait.new(a.game, string.format("WAITING FOR %s", tostring(opts.peerName or "TRAINER"):upper()),
      function() finish(a, nil, "cancelled") end)
    a.game.stack:push(a.wait)
    return true
  end

  local function begin(a)
    a.started = true
    if a.wait then popWait(a) end
    if a.kind == "battle" then
      local LB = req("src.core.game3.link.battle")
      -- the cartridge's link battles use the party as it is (no level 50)
      LB.setVirtual({ unpack = { strict = true } })
      local ok, why = LB.startUnionRoomBattle(function(word)
        finish(a, word or "draw")
      end)
      if not ok then finish(a, nil, why or "battle") end
    else
      local LT = req("src.core.game3.link.trade")
      LT.loopbackCommit = true
      -- no onDone: after a trade the screen comes back for the next one, as
      -- in the Trade Center; both players cancelling ends the link
      a.tradesBefore = LT.completed or 0
      local ok, why = LT.startMenu({})
      if not ok then finish(a, nil, why or "trade") end
    end
  end

  -- every frame, from core.update
  function L.tick()
    local a = L.active
    if not a then return end
    local Link = req("src.core.game3.link")
    local lk = Link and Link.link
    if not a.started then
      if lk and lk.isReady and lk:isReady() then
        begin(a)
      elseif not lk or (lk.isOpen and not lk:isOpen()) or now() - a.t0 > L.HANDSHAKE then
        finish(a, nil, "no_answer")
      end
      return
    end
    if a.kind == "battle" then
      local LB = req("src.core.game3.link.battle")
      if LB and LB.state == "setup" then LB.pumpUnionSetup() end
    elseif a.kind == "trade" then
      local LT = req("src.core.game3.link.trade")
      local Menu = req("src.ui.game3.link_trade_menu")
      -- each trade done over this link uses one of the hardcore trade
      -- limit's (main.lua's GtsUI.tradeUsed, through G3.onLinkTrade)
      a.counted = a.counted or (a.tradesBefore or 0)
      while LT and (LT.completed or 0) > a.counted do
        a.counted = a.counted + 1
        if G3.onLinkTrade then pcall(G3.onLinkTrade) end
      end
      -- both cancelled (the trade screen has faded out), or the link dropped
      local left = LT and LT.state == "exit" and not (Menu and Menu.isOpen())
      local dropped = LT and LT.state == "off"
      if left or dropped then
        a.trades = (LT.completed or 0) - (a.tradesBefore or 0)
        finish(a, "done", dropped and "dropped" or nil)
      end
    end
  end

  function L.busy() return L.active ~= nil end

  return L
end
