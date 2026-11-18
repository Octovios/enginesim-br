-- engine/ordering.lua
-- Order optimisation for a chosen play. Two things you can physically reorder
-- in Balatro change the score:
--   1. JOKER order -- effects apply left->right, so a +mult joker LEFT of an
--      xmult joker is added before the multiply (good), but RIGHT of it is wasted
--      after (bad). Reordering can be a big swing.
--   2. CARD order  -- scored cards resolve left->right too, so additive card
--      effects (+chips/+mult enhancements) want to land before multiplicative
--      ones (Glass x2), and first-card retriggers (Hanging Chad) want the
--      highest-value card first.
--
-- We search permutations of the CHOSEN play's jokers and cards and report the
-- best order found vs the current one. The comparator prefers a higher score,
-- and at EQUAL score prefers a higher guaranteed floor (score_min) -- i.e. the
-- safer order for survival -- so we never suggest a riskier order for no gain.
-- PURE: consumes a GameState + played cards, no G access.

local HandEval = require("engine.hand_eval")

local O = {}

O.JOKER_CAP = 7   -- skip joker search past this many (7! = 5040 is the ceiling)
O.CARD_CAP  = 5   -- a played hand is at most 5 cards anyway

local function copy(t) local o = {} for i = 1, #t do o[i] = t[i] end return o end

local function with_jokers(gs, list)
  local p = {} for k, v in pairs(gs) do p[k] = v end
  p.jokers = list
  return p
end

local function same_order(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- SCORE objective: higher score, then (at equal score) a higher guaranteed floor
-- -- the safer order for the same expected value.
local function better_score(a, b)
  if a.score ~= b.score then return a.score > b.score end
  return (a.score_min or 0) > (b.score_min or 0)
end

-- MONEY objective (used once the clear is already guaranteed, so extra score is
-- overkill): keep the clear first, then maximise in-blind $ (retrigger-aware),
-- then prefer the safer floor. This is the "retrigger econ vs more overkill"
-- call -- when survival is locked we order for money, e.g. a Hanging Chad
-- first-card retrigger landing on a Gold-seal card.
local function better_money(a, b, remaining)
  local ak = (a.score_min or 0) >= remaining
  local bk = (b.score_min or 0) >= remaining
  if ak ~= bk then return ak end
  local am, bm = a.money or 0, b.money or 0
  if math.abs(am - bm) > 1e-9 then return am > bm end
  return (a.score_min or 0) > (b.score_min or 0)
end

-- visit every permutation of `list` (Heap-style recursive swap).
local function permute(list, visit)
  local n = #list
  local a = copy(list)
  local function rec(k)
    if k > n then visit(a); HandEval.yield_tick(); return end
    for i = k, n do
      a[k], a[i] = a[i], a[k]
      rec(k + 1)
      a[k], a[i] = a[i], a[k]
    end
  end
  rec(1)
end

-- Best order for a fixed `played`, searching joker order then card order.
-- opts.objective: "score" (default) maximises score; "money" maximises in-blind
-- $ while keeping the clear (pass opts.remaining). Returns a table describing
-- the current vs best order (see fields below).
function O.optimize(gs, played, opts)
  opts = opts or {}
  local objective = opts.objective or "score"
  local remaining = opts.remaining or 0
  local function better(a, b)
    if objective == "money" then return better_money(a, b, remaining) end
    return better_score(a, b)
  end

  local jokers = gs.jokers or {}
  local cur = HandEval.score(gs, played)
  local result = {
    objective = objective,
    current_score = cur.score, best_score = cur.score,
    current_min = cur.score_min or cur.score, best_min = cur.score_min or cur.score,
    current_money = cur.money or 0, best_money = cur.money or 0,
    joker_order = copy(jokers), card_order = copy(played),
    joker_changed = false, card_changed = false,
  }

  -- 1. joker order (cards held in their current order)
  local best_jokers, best_ev = jokers, cur
  if #jokers >= 2 and #jokers <= O.JOKER_CAP then
    permute(jokers, function(perm)
      local ev = HandEval.score(with_jokers(gs, perm), played)
      if better(ev, best_ev) then best_ev = ev; best_jokers = copy(perm) end
    end)
  end
  -- (EngineSim BR) A guaranteed clear orders for money, and the money search almost never moves a joker -- so the row
  -- kept a +Mult joker to the RIGHT of an xMult one forever ("it never puts the multipliers last"). The order is
  -- free to fix and pays on every later hand: when the money order leaves the jokers alone, take the best SCORE
  -- order that costs no money and no guaranteed floor.
  result.joker_score_gain = 0
  if objective == "money" and not same_order(best_jokers, jokers) and (best_ev.money or 0) >= (cur.money or 0) - 1e-9
     and (best_ev.score or 0) > (cur.score or 0) then
    -- the money search moved the jokers (a safer floor is its tie-break) and that order also scores more
    result.joker_score_gain = best_ev.score - cur.score
  elseif objective == "money" and same_order(best_jokers, jokers) and #jokers >= 2 and #jokers <= O.JOKER_CAP then
    local sj, sev = jokers, cur
    permute(jokers, function(perm)
      local ev = HandEval.score(with_jokers(gs, perm), played)
      if (ev.money or 0) >= (cur.money or 0) - 1e-9 and (ev.score_min or 0) >= (cur.score_min or 0)
         and better_score(ev, sev) then sev = ev; sj = copy(perm) end
    end)
    if not same_order(sj, jokers) and sev.score > cur.score then
      best_jokers, best_ev = sj, sev
      result.joker_score_gain = sev.score - cur.score
    end
  end
  result.joker_order = best_jokers
  result.joker_changed = not same_order(best_jokers, jokers)

  -- 2. card order (using the best joker order)
  local gbest = with_jokers(gs, best_jokers)
  local best_cards, best_cev = played, HandEval.score(gbest, played)
  if #played >= 2 and #played <= O.CARD_CAP then
    permute(played, function(perm)
      local ev = HandEval.score(gbest, perm)
      if better(ev, best_cev) then best_cev = ev; best_cards = copy(perm) end
    end)
  end
  result.card_order = best_cards
  result.card_changed = not same_order(best_cards, played)

  result.best_score = best_cev.score
  result.best_min = best_cev.score_min or best_cev.score
  result.best_money = best_cev.money or 0
  result.gain = result.best_score - result.current_score
  result.min_gain = result.best_min - result.current_min
  result.money_gain = result.best_money - result.current_money
  -- a reorder is worth suggesting only if it strictly improves the objective
  result.improves = result.joker_changed or result.card_changed
  return result
end

-- ---- (EngineSim BR) the STANDING joker order --------------------------------------------------------------------
-- Joker order matters on every hand, but the per-play search above only fixes it for the hand being played. The
-- standing order is the arrangement that scores best over several TYPICAL plays of this deck (the best play of
-- `samples` sampled hands, found under the current order): +Chips / +Mult before xMult, a copier where it copies
-- the best joker, Baseball Card's Uncommons... -- whatever the scoring engine says, not a fixed rule. Suggested at
-- blind select and in the shop (main.lua), applied by the self-player. Ceremonial Dagger boards are left to
-- engine/dagger.lua (its neighbour is eaten). <= STANDING_FULL jokers: every permutation; more: insertion moves
-- from the current order until nothing improves.
O.STANDING_SAMPLES = 6
O.STANDING_FULL = 6
O.STANDING_MIN_GAIN = 0.01   -- suggest only a gain of at least 1% (no churn over noise-free but tiny swings)

local function seeded(seed)
  local st = seed % 2147483646 + 1
  return function() st = (st * 16807) % 2147483647; return st / 2147483647 end
end

function O.standing_order(gs, opts)
  opts = opts or {}
  local jokers = gs and gs.jokers or {}
  local n = #jokers
  if n < 2 then return nil end
  for _, j in ipairs(jokers) do if j.key == "j_ceremonial" then return nil end end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or nil
  if not deck or #deck < 5 then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  -- deterministic sample hands (seeded by the deck and board, so the advice never flickers)
  local seed = #deck * 7919 + n * 104729
  for _, j in ipairs(jokers) do seed = seed + #(tostring(j.key)) * 31 end
  local rng = opts.rng or seeded(seed)
  local plays = {}
  local samples = opts.samples or O.STANDING_SAMPLES
  for _ = 1, samples do
    local a = copy(deck)
    for i = #a, 2, -1 do
      local j = math.floor(rng() * i) + 1
      if j > i then j = i end
      a[i], a[j] = a[j], a[i]
    end
    local hand = {}
    for i = 1, hs do hand[i] = a[i] end
    local g = with_jokers(gs, jokers)
    g.hand = hand
    local ev, sel = HandEval.best_play(g, hand)
    if ev and sel and #sel > 0 then plays[#plays + 1] = { hand = hand, sel = sel } end
  end
  if #plays == 0 then return nil end
  local function total(list)
    local g = with_jokers(gs, list)
    local t = 0
    for _, p in ipairs(plays) do
      g.hand = p.hand
      local ev = HandEval.score(g, p.sel)
      t = t + (ev.score or 0)
    end
    return t
  end
  local cur_t = total(jokers)
  local best, best_t = jokers, cur_t
  if n <= O.STANDING_FULL then
    permute(jokers, function(perm)
      local t = total(perm)
      if t > best_t + 1e-9 then best, best_t = copy(perm), t end
    end)
  else
    local order = copy(jokers)
    local improved, passes = true, 0
    while improved and passes < 4 do
      improved, passes = false, passes + 1
      for i = 1, n do
        for k = 1, n do
          if k ~= i then
            local cand = copy(order)
            local x = table.remove(cand, i)
            table.insert(cand, k, x)
            local t = total(cand)
            HandEval.yield_tick()
            if t > best_t + 1e-9 then best, best_t, order, improved = cand, t, cand, true end
          end
        end
      end
    end
  end
  if same_order(best, jokers) or cur_t <= 0 then return nil end
  local gain = (best_t - cur_t) / cur_t
  if gain < (opts.min_gain or O.STANDING_MIN_GAIN) then return nil end
  return { order = best, gain = gain, current_total = cur_t, best_total = best_t }
end

return O
