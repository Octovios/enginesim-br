-- engine/scaling_growth.lua  (EngineSim BR)
-- What PLAYING one more blind does to the jokers you own, and what SKIPPING it does -- priced in the same dollar
-- currency the skip advisor already uses for tags and the shop.
--
-- The question it answers (the player's own words): "if I have a joker that grows the more I play, it may be better
-- to play even when the blind pays nothing". Green Joker gains +1 Mult per hand, Runner +15 Chips per Straight,
-- Wee Joker +8 Chips per scored 2, Lucky Cat xMult per Lucky trigger, Ceremonial Dagger / Madness / Marble Joker
-- fire when a blind is SELECTED (a skipped blind never is), and Throwback grows only when you SKIP. Decaying jokers
-- (Ice Cream, Popcorn, Ramen, Turtle Bean, Gros Michel's coin flip) lose value by playing.
--
-- Method (measured, not tiered): copy the board, apply one blind's worth of growth to the copies' live counters --
-- the same ability fields engine/joker_effects reads (MULT -> ability.mult, CHIPS -> ability.extra.chips,
-- XMULT -> ability.x_mult) -- and measure the mean best-play score of the grown board against the current one on the
-- SAME sampled deals (common random numbers, so the difference is not sampling noise). The gain, as a fraction of a
-- boss hand, converts to dollars with engine/value_units like every other permanent board improvement.
-- PURE. Deterministic for a given state.

local Rng = require("util.rng")
local Cards = require("util.cards")
local I18N = require("util.i18n")
local JokerValue = require("engine.joker_value")
local Mechanics = require("engine.mechanics")
local VU = require("engine.value_units")
local RC = require("engine.run_context")

local SG = {}

SG.SAMPLES = 10          -- deals per measurement (paired across the two boards)
SG.MAX_DESTROY_PROBES = 4  -- Madness: average the loss over at most this many possible victims

local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

local function copy_joker(j)
  local o = copy(j)
  o.ability = copy(j.ability or {})
  if type(o.ability.extra) == "table" then o.ability.extra = copy(o.ability.extra) end
  return o
end

local function eternal(j)
  local ab = j.ability
  return type(ab) == "table" and (ab.eternal or (type(ab.extra) == "table" and ab.extra.eternal)) or false
end

-- Bump a joker copy's live counter where joker_effects reads it. `base` = the value the reader assumes when absent.
local function bump(j, kind, delta, base)
  local ab = j.ability
  if kind == "mult" then
    ab.mult = math.max(0, (tonumber(ab.mult) or base or 0) + delta)
  elseif kind == "chips" then
    if type(ab.extra) ~= "table" then ab.extra = {} end
    ab.extra.chips = math.max(0, (tonumber(ab.extra.chips) or base or 0) + delta)
  elseif kind == "xmult" then
    local cur = tonumber(ab.x_mult) or base or 1
    ab.x_mult = math.max(1, cur + delta)
  end
end

-- Share of the run's plays that were (or contained) `hands`, when enough plays are known; else `fallback`.
local function play_share(gs, hands, fallback)
  local plays = gs.run and gs.run.hand_type_plays
  if type(plays) ~= "table" then return fallback end
  local total, hit = 0, 0
  for h, n in pairs(plays) do
    total = total + (n or 0)
    if hands[h] then hit = hit + (n or 0) end
  end
  if total < 6 then return fallback end
  return hit / total
end

local function owns(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key and not j.debuffed then return true end end
  return false
end

-- The play pattern of one blind: hands you will play, discards you will use, and how often each growth trigger
-- fires, from the deck's composition and the run's play history.
function SG.environment(gs, avg_score)
  local b = gs.blind or {}
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local btype = b.blind_type or "Small"
  local base_hands = (b.base_hands and b.base_hands > 0) and b.base_hands or 4
  local base_discards = b.base_discards or 3
  local target = RC.requirement(gs, ante, btype == "Boss" and "Boss" or btype)
  local hands = base_hands
  if avg_score and avg_score > 0 then
    hands = math.max(1, math.min(base_hands, math.ceil(target / avg_score)))
  end
  -- about one discard per hand after the first (a player feeding Green Joker discards even less: see its rule)
  local discards = math.min(base_discards, math.max(0, hands - 1))
  local p = RC.deck_profile(gs)
  local n = math.max(1, p.n)
  local face_share = owns(gs, "j_pareidolia") and 1 or (p.faces / n)
  local enh_n = 0
  for _, k in pairs(p.enh) do enh_n = enh_n + k end
  local four_fingers = owns(gs, "j_four_fingers") or owns(gs, "j_shortcut")
  return {
    hands = hands, discards = discards, target = target, avg = avg_score,
    p_noface = (1 - face_share) ^ 2,
    p_straight = play_share(gs, { Straight = true, ["Straight Flush"] = true }, four_fingers and 0.3 or 0.12),
    p_twopair = play_share(gs, { ["Two Pair"] = true, ["Full House"] = true, ["Flush House"] = true }, 0.2),
    p_four = 0.4,
    twos_scored = 4 * (p.twos / n),
    lucky_scored = 4 * ((p.enh.m_lucky or 0) / n),
    glass_scored = 4 * ((p.enh.m_glass or 0) / n),
    enh_scored = 4 * (enh_n / n),
    oops = owns(gs, "j_oops") and 2 or 1,
    profile = p,
  }
end

-- Growth of each joker for ONE blind played: key -> function(env, j, gs) -> kind, delta, base
SG.ON_PLAY = {
  j_green_joker  = function(e) return "mult", e.hands - 0.5 * e.discards, 0 end,   -- you discard sparingly with it
  j_ride_the_bus = function(e) return "mult", e.hands * e.p_noface, 0 end,
  j_runner       = function(e) return "chips", 15 * e.hands * e.p_straight, 0 end,
  j_square       = function(e) return "chips", 4 * e.hands * e.p_four, 0 end,
  j_wee          = function(e) return "chips", 8 * e.hands * e.twos_scored, 0 end,
  j_trousers     = function(e) return "mult", 2 * e.hands * e.p_twopair, 0 end,
  j_castle       = function(e) return "chips", 3 * e.discards * 5 * 0.25, 0 end,
  j_lucky_cat    = function(e) return "xmult", 0.25 * e.hands * e.lucky_scored * math.min(1, 0.2 * e.oops), 1 end,
  j_vampire      = function(e) return "xmult", 0.1 * e.hands * e.enh_scored, 1 end,
  j_glass        = function(e) return "xmult", 0.75 * e.hands * e.glass_scored * math.min(1, 0.25 * e.oops), 1 end,
  j_yorick       = function(e) return "xmult", e.discards * 5 / 23, 1 end,
  -- decayers: playing costs them value
  j_ice_cream    = function(e) return "chips", -5 * e.hands, 100 end,
  j_popcorn      = function() return "mult", -4, 20 end,
  j_ramen        = function(e) return "xmult", -0.01 * e.discards * 4, 2 end,
}
-- Fired when the blind is SELECTED (Small/Big): a skipped blind never triggers them.
SG.ON_SELECT = { j_madness = true, j_ceremonial = true, j_marble = true, j_certificate = true }

local GROWTH_TEXT = {
  mult = { en = "%+.0f Mult", pt = "%+.0f Mult" },
  chips = { en = "%+.0f Chips", pt = "%+.0f Fichas" },
  xmult = { en = "%+.2f xMult", pt = "%+.2f xMult" },
}
local function growth_text(kind, delta)
  local t = GROWTH_TEXT[kind]
  if not t then return "" end
  return string.format(I18N.lang == "pt_BR" and t.pt or t.en, delta)
end

local function with_jokers(gs, jokers, run)
  local o = copy(gs)
  o.jokers = jokers
  if run then o.run = run end
  return o
end

-- Mean best-play score of `gs` on `samples` deals drawn from a stream seeded by `seed`.
local function avg(gs, seed, samples)
  return JokerValue.avg_score(gs, { rng = Rng.stream(seed), samples = samples or SG.SAMPLES })
end

local function seed_of(gs)
  local d = #(gs.deck or {}) * 40503 + #(gs.jokers or {}) * 7919 + math.floor((gs.meta and gs.meta.ante) or 1) * 104729
  return Rng.seed(d + 1337)
end

-- play_vs_skip(gs) -> {
--   play_dollars, skip_dollars,                       -- what one more blind PLAYED / SKIPPED is worth to the board
--   play_items = { { name, text, dollars } ... },     -- per-joker breakdown (for the advice text)
--   skip_items = { ... }, hands = n, measured = bool }
-- Never raises for a missing deck: returns zeros (measured = false).
function SG.play_vs_skip(gs, opts)
  opts = opts or {}
  local out = { play_dollars = 0, skip_dollars = 0, play_items = {}, skip_items = {}, hands = 0, measured = false }
  local jokers = gs.jokers or {}
  if #jokers == 0 then return out end
  local seed = opts.seed or seed_of(gs)
  local samples = opts.samples or SG.SAMPLES
  local base = avg(gs, seed, samples)
  if not base or base <= 0 then return out end
  out.measured = true
  local need = Mechanics.boss_per_hand_need(gs)
  local e = SG.environment(gs, base)
  out.hands = e.hands
  local btype = (gs.blind and gs.blind.blind_type) or "Small"

  -- dollars of a grown copy of the board vs the current one (same deals)
  local function dollars_of(gs2)
    local a2 = avg(gs2, seed, samples)
    if not a2 then return 0 end
    return VU.frac_to_dollars(gs, (a2 - base) / need), a2
  end

  -- ---- PLAY: every rule at once (they compound), then each alone for the breakdown ----
  local grown, any = {}, false
  local singles = {}
  for i, j in ipairs(jokers) do
    local rule = (not j.debuffed) and SG.ON_PLAY[j.key]
    if rule then
      local kind, delta, b = rule(e, j, gs)
      if kind and delta and math.abs(delta) > 1e-6 then
        local c = copy_joker(j)
        bump(c, kind, delta, b)
        grown[i] = c
        any = true
        singles[#singles + 1] = { i = i, j = j, c = c, kind = kind, delta = delta }
      end
    end
  end
  local board = {}
  for i, j in ipairs(jokers) do board[i] = grown[i] or j end

  local run2 = nil
  -- Supernova grows with every play of the hand (its Mult = the run's play count of that hand)
  if owns(gs, "j_supernova") and gs.run then
    run2 = copy(gs.run)
    local plays = copy(gs.run.hand_type_plays or {})
    local top, topn = nil, -1
    for h, k in pairs(plays) do if (k or 0) > topn or ((k or 0) == topn and tostring(h) < tostring(top)) then top, topn = h, k end end
    if top then
      plays[top] = (plays[top] or 0) + e.hands
      run2.hand_type_plays = plays
      any = true
      singles[#singles + 1] = { supernova = true, hand = top }
    end
  end
  -- Turtle Bean: -1 hand size every round
  if owns(gs, "j_turtle_bean") and gs.run and (gs.run.hand_size or 8) > 5 then
    run2 = run2 or copy(gs.run)
    run2.hand_size = (gs.run.hand_size or 8) - 1
    any = true
    singles[#singles + 1] = { bean = true }
  end
  -- Blind-select triggers (Small / Big only: the boss is never skippable, so it is not part of this choice)
  local selects = btype ~= "Boss"
  if selects then
    for i, j in ipairs(jokers) do
      if not j.debuffed and j.key == "j_madness" then
        local c = copy_joker(board[i]); bump(c, "xmult", 0.5, 1); board[i] = c; any = true
        singles[#singles + 1] = { i = i, j = j, c = c, kind = "xmult", delta = 0.5, madness = true }
      end
    end
  end

  if any then
    local total = dollars_of(with_jokers(gs, board, run2))
    out.play_dollars = total
    -- per-item breakdown (each alone), for the reason text; Madness's victim is priced below
    for _, s in ipairs(singles) do
      local item
      if s.supernova then
        local r = copy(gs.run); local p = copy(gs.run.hand_type_plays or {})
        p[s.hand] = (p[s.hand] or 0) + e.hands; r.hand_type_plays = p
        item = { name = "Supernova", key = "j_supernova", text = growth_text("mult", e.hands),
          dollars = dollars_of(with_jokers(gs, jokers, r)) }
      elseif s.bean then
        local r = copy(gs.run); r.hand_size = (gs.run.hand_size or 8) - 1
        item = { name = "Turtle Bean", key = "j_turtle_bean", text = I18N.pick("-1 hand size", "-1 tamanho de mão"),
          dollars = dollars_of(with_jokers(gs, jokers, r)) }
      else
        local b2 = {}
        for i, j in ipairs(jokers) do b2[i] = j end
        b2[s.i] = s.c
        item = { name = s.j.name or s.j.key, key = s.j.key, text = growth_text(s.kind, s.delta),
          dollars = dollars_of(with_jokers(gs, b2)) }
      end
      out.play_items[#out.play_items + 1] = item
    end
  end

  -- Madness destroys a random other (non-Eternal) joker when the blind is selected: expected loss over victims
  if selects and owns(gs, "j_madness") then
    local victims = {}
    for i, j in ipairs(jokers) do
      if j.key ~= "j_madness" and not eternal(j) then victims[#victims + 1] = i end
    end
    if #victims > 0 then
      local loss, k = 0, 0
      for _, vi in ipairs(victims) do
        if k >= SG.MAX_DESTROY_PROBES then break end
        local b2 = {}
        for i, j in ipairs(jokers) do if i ~= vi then b2[#b2 + 1] = j end end
        loss = loss + dollars_of(with_jokers(gs, b2))
        k = k + 1
      end
      local exp_loss = loss / k
      out.play_dollars = out.play_dollars + exp_loss
      out.play_items[#out.play_items + 1] = { name = "Madness", key = "j_madness",
        text = I18N.pick("destroys a random joker", "destrói um coringa aleatório"), dollars = exp_loss }
    end
  end

  -- Gros Michel: 1 in 6 (Oops!: 2 in 6) to be destroyed at the end of each round played
  for i, j in ipairs(jokers) do
    if j.key == "j_gros_michel" and not j.debuffed then
      local b2 = {}
      for k2, jj in ipairs(jokers) do if k2 ~= i then b2[#b2 + 1] = jj end end
      local p = math.min(1, (1 / 6) * e.oops)
      local d = dollars_of(with_jokers(gs, b2)) * p
      out.play_dollars = out.play_dollars + d
      out.play_items[#out.play_items + 1] = { name = j.name or "Gros Michel", key = j.key,
        text = I18N.pick("1 in 6 to be destroyed", "1 em 6 de ser destruído"), dollars = d }
    end
  end

  -- ---- SKIP: Throwback gains x0.25 per skipped blind ----
  for i, j in ipairs(jokers) do
    if j.key == "j_throwback" and not j.debuffed then
      local b2 = {}
      for k2, jj in ipairs(jokers) do b2[k2] = jj end
      local c = copy_joker(j); bump(c, "xmult", 0.25, 1); b2[i] = c
      local d = dollars_of(with_jokers(gs, b2))
      out.skip_dollars = out.skip_dollars + d
      out.skip_items[#out.skip_items + 1] = { name = j.name or "Throwback", key = j.key, text = growth_text("xmult", 0.25), dollars = d }
    end
  end

  -- deterministic order for the text: biggest effect first
  local function by_size(a, b)
    if math.abs(a.dollars) ~= math.abs(b.dollars) then return math.abs(a.dollars) > math.abs(b.dollars) end
    return tostring(a.key) < tostring(b.key)
  end
  table.sort(out.play_items, by_size)
  table.sort(out.skip_items, by_size)
  return out
end

-- Jokers on the board whose growth THIS module cannot price but that the player should hear about (they grow in the
-- shop, which a skipped blind also skips): keys -> short reason key for util/i18n_msgs.
SG.SHOP_GROWERS = {
  j_flash = "grows_reroll", j_red_card = "grows_pack_skip", j_campfire = "grows_sell",
  j_constellation = "grows_planet", j_fortune_teller = "grows_tarot", j_hologram = "grows_card_add",
}

return SG
