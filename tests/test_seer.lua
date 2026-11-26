-- tests/test_seer.lua  (EngineSim BR)
-- Seer mode: the engine uses the REAL draw order (the end of gs.remaining is the next card, as the game draws) and
-- the REAL next values of the luck streams; the live peek restores the game's state; the self-check catches a
-- draw that does not match.

local GS = require("model.game_state")
local Seer = require("engine.seer")
local HandEval = require("engine.hand_eval")
local DV = require("engine.discard_value")
local Sim = require("engine.simulation")
local Extract = require("core.state_extraction")

local function card(id, rank, suit, extra)
  local c = GS.card{ id = id, rank_id = rank, suit = suit }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

return function(t)
  -- ---- the known order ------------------------------------------------------------------------------------------
  do
    local a, b, c = card(1, 2, "Spades"), card(2, 3, "Spades"), card(3, 4, "Spades")
    local pile = { a, b, c }                 -- the game draws c first (the end of the array)
    t.ok(not Seer.is_known(pile), "seer: a pile is unknown until marked")
    Seer.mark(pile)
    local o = Seer.order(pile, function() return 0.5 end, function() error("must not shuffle a known pile") end)
    t.ok(Seer.is_known(o) and o ~= pile, "seer: a known pile is copied, still known")
    t.eq(o[1], a, "seer: ... in the same order")
    local nd = Seer.next_draws(pile, 2)
    t.eq(nd[1], c, "seer: the next draw is the last card")
    t.eq(nd[2], b, "seer: then the one before it")
    t.eq(Seer.samples(pile, 80), 1, "seer: one sample is exact")
    t.eq(Seer.samples({ a }, 80), 80, "seer: unknown piles keep their samples")
  end

  -- ---- a discard is valued on the cards the game WILL deal --------------------------------------------------------
  do
    -- hand: four Hearts + junk; the deck's next card (its last) is the fifth Heart, then junk
    local hand = { card(1, 14, "Hearts"), card(2, 12, "Hearts"), card(3, 9, "Hearts"), card(4, 6, "Hearts"),
                   card(5, 2, "Clubs") }
    local remaining = {}
    for i = 1, 20 do remaining[#remaining + 1] = card(100 + i, 3 + (i % 5), "Spades") end
    remaining[#remaining + 1] = card(200, 13, "Hearts")          -- drawn first
    local function st(known)
      local rem = {}
      for i, c in ipairs(remaining) do rem[i] = c end
      if known then Seer.mark(rem) end
      return GS.new{ hand = hand, remaining = rem, run = { hand_levels = {}, hand_size = 5 },
        blind = { target_chips = 1000, chips_scored = 0, hands_left = 3, discards_left = 2 } }
    end
    local exact = DV.measured(st(true), { hand[5] }, { samples = 10 })
    local flush = HandEval.best_play(st(true), { hand[1], hand[2], hand[3], hand[4], remaining[#remaining] })
    t.eq(exact, flush.score, "seer: discarding the junk is valued as the Flush the game will deal")
    local blind_avg = DV.measured(st(false), { hand[5] }, { samples = 10 })
    t.ok(blind_avg < exact, "seer: without the order the same discard averages far lower")
    -- the survival rollout: one exact rollout, 0 or 1
    local p = Sim.survive_current(st(true), 80)
    t.ok(p == 0 or p == 1, "seer: the clear probability is exact (0 or 1)")
  end

  -- ---- chance effects from the real next rolls --------------------------------------------------------------------
  do
    local lucky1 = card(1, 14, "Spades", { enhancement = "m_lucky" })
    local lucky2 = card(2, 14, "Hearts", { enhancement = "m_lucky" })
    local base = GS.new{ run = { hand_levels = {} } }
    local avg = HandEval.score(base, { lucky1, lucky2 })
    -- (GS.new keeps only the fields it knows; main.lua sets seer_rolls on the snapshot afterwards, as here)
    local function with_rolls(g, r) g.seer_rolls = r; return g end
    local seer = with_rolls(GS.new{ run = { hand_levels = {} } }, { normal = 1, lucky_mult = { 0.1, 0.9 } })
    local ev = HandEval.score(seer, { lucky1, lucky2 })
    -- Pair of Aces: 10 + 11 + 11 = 32 chips; mult 2 + 20 (first Lucky hits) + 0 (second misses) = 22
    t.eq(ev.score, 32 * 22, "seer: the first Lucky card hits, the second misses")
    t.ok(not ev.approx, "seer: an exact outcome is not an estimate")
    t.ok(avg.approx and avg.score ~= ev.score, "seer: without it the score is the average")
    local both = with_rolls(GS.new{ run = { hand_levels = {} } }, { normal = 1, lucky_mult = { 0.9, 0.9 } })
    t.eq(HandEval.score(both, { lucky1, lucky2 }).score, 32 * 2, "seer: both miss")
    -- Oops! All 6s doubles the odds (normal = 2): 0.3 < 2/5 hits
    local oops = with_rolls(GS.new{ run = { hand_levels = {} } }, { normal = 2, lucky_mult = { 0.3, 0.3 } })
    t.eq(HandEval.score(oops, { lucky1, lucky2 }).score, 32 * 42, "seer: Oops! doubles the chance")
    -- Misprint: its next value
    local mp = with_rolls(GS.new{ run = { hand_levels = {} }, jokers = { GS.joker{ key = "j_misprint" } } },
      { normal = 1, misprint = { 17 } })
    t.eq(HandEval.score(mp, { card(9, 14, "Clubs") }).score, (5 + 11) * (1 + 17), "seer: Misprint adds its real next roll")
    local lines = Seer.outcomes(seer, "lucky_mult", 5, 2)
    t.ok(lines[1] == true and lines[2] == false, "seer: outcomes list hit / miss")
  end

  -- ---- the live peek restores the game's streams ------------------------------------------------------------------
  do
    local saved = { G = rawget(_G, "G"), pr = rawget(_G, "pseudorandom"), gnb = rawget(_G, "get_new_boss") }
    local ok, err = pcall(function()
      local calls = 0
      _G.G = { GAME = { pseudorandom = { lucky_mult = 0.25 }, probabilities = { normal = 1 },
        round_resets = { ante = 2 }, bosses_used = { bl_hook = 1, bl_wall = 0 } }, P_BLINDS = { bl_wall = { name = "The Wall" } } }
      -- a stand-in with the real shape: each call advances the stream and returns a value
      _G.pseudorandom = function(key, min, max)
        calls = calls + 1
        local pr = G.GAME.pseudorandom
        pr[key] = ((pr[key] or 0.5) * 1.7 + 0.13) % 1
        if min and max then return min + math.floor(pr[key] * (max - min + 1)) end
        return pr[key]
      end
      local r = Extract.peek_rolls({ { key = "lucky_mult", n = 3 }, { key = "misprint", n = 2, min = 0, max = 23 } })
      t.eq(#r.lucky_mult, 3, "peek: three values read")
      t.eq(G.GAME.pseudorandom.lucky_mult, 0.25, "peek: the stream is put back")
      t.eq(G.GAME.pseudorandom.misprint, nil, "peek: an unused stream stays unused")
      t.ok(r.misprint[1] >= 0 and r.misprint[1] <= 23 and math.floor(r.misprint[1]) == r.misprint[1], "peek: Misprint values are integers 0..23")
      -- what the game will produce next is exactly what was peeked
      local live = _G.pseudorandom("lucky_mult")
      t.eq(live, r.lucky_mult[1], "peek: the game's next value is the first peeked one")
      -- the next boss: get_new_boss's side effects are undone
      _G.get_new_boss = function()
        G.GAME.pseudorandom.boss = 0.77
        G.GAME.bosses_used.bl_wall = G.GAME.bosses_used.bl_wall + 1
        return (G.GAME.round_resets.ante == 3) and "bl_wall" or "bl_hook"
      end
      local nb = Extract.peek_next_boss()
      t.eq(nb and nb.key, "bl_wall", "peek: the boss is chosen as for the next ante")
      t.eq(nb and nb.ante, 3, "peek: ... ante 3")
      t.eq(G.GAME.round_resets.ante, 2, "peek: the ante is put back")
      t.eq(G.GAME.bosses_used.bl_wall, 0, "peek: the bosses-used count is put back")
      t.eq(G.GAME.pseudorandom.boss, nil, "peek: the boss stream is put back")
    end)
    t.ok(ok, "seer peek suite ran: " .. tostring(err))
    _G.G, _G.pseudorandom, _G.get_new_boss = saved.G, saved.pr, saved.gnb
  end
end
