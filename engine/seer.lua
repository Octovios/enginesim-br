-- engine/seer.lua  (EngineSim BR) -- the "seer mode" (modo vidente)
--
-- Balatro is deterministic: every random outcome comes from the run's seed. Two parts of that future are
-- already in the live state and the engine can read them without guessing:
--
--   1. THE DRAW ORDER. At the start of a round the game shuffles the deck once (CardArea:shuffle with a seed
--      derived from the run seed and the ante) and then always draws from the END of G.deck.cards
--      (CardArea:remove_card takes the last card of a 'deck' area). So gs.remaining -- read from G.deck.cards
--      in array order by core/state_extraction -- IS the future: its last card is the next card you draw.
--      The engine normally treats those cards as an unknown random pile and averages over shuffles
--      (Monte-Carlo). Marked "known", every sampler that would shuffle it keeps its real order instead, and a
--      single sample is exact.
--
--   2. THE LUCK STREAMS. Each chance check reads its own named stream (pseudorandom('lucky_mult'),
--      pseudorandom('misprint'), ...): a Lucky card's +20 Mult is decided by the next value of the
--      'lucky_mult' stream, whoever triggers it. core/state_extraction peeks the next values of those streams
--      (with the game's own function, restoring the state afterwards) into gs.seer_rolls; the scorer then uses
--      the real outcome in order instead of the average.
--
-- PURE: plain tables in, plain tables out. Nothing here reads the game; main.lua switches the mode on.

local Seer = {}

-- piles whose order is the REAL draw order (weak keys: a pile dies with its state)
local KNOWN = setmetatable({}, { __mode = "k" })

function Seer.mark(list)
  if type(list) == "table" then KNOWN[list] = true end
  return list
end

function Seer.is_known(list)
  return type(list) == "table" and KNOWN[list] == true
end

local function copy(t)
  local o = {}
  for i = 1, #t do o[i] = t[i] end
  return o
end

-- What a sampler gets instead of a random shuffle: for a known pile, a copy in the same (real) order, still
-- known -- the samplers draw with table.remove() from the end, exactly like the game. Unknown piles go to the
-- sampler's own shuffle.
function Seer.order(pile, rng, shuffled)
  if Seer.is_known(pile) then return Seer.mark(copy(pile)) end
  return shuffled(pile, rng)
end

-- The next `n` draws of an ordered pile (the end of the array first). For samplers that read draws from the
-- START of their shuffled list (DiscardValue.measured).
function Seer.next_draws(list, n)
  local out = {}
  local len = #list
  for i = 1, math.min(n, len) do out[i] = list[len - i + 1] end
  return out
end

-- With a known order every sample is the same deal: one is exact.
function Seer.samples(pile, n)
  if Seer.is_known(pile) then return 1 end
  return n
end

-- ---- luck streams ------------------------------------------------------------------------------------------------
-- gs.seer_rolls = { normal = <G.GAME.probabilities.normal>, [stream key] = { v1, v2, ... } }  (core/state_extraction)
-- The scorer asks for the k-th value of a kind during ONE score evaluation (each candidate play starts from the same
-- stream position, as the real play will). Kinds -> stream keys:
Seer.KIND_KEY = {
  lucky = "lucky_mult", lucky_oops = "lucky_mult",
  lucky_money = "lucky_money",
  misprint = "misprint",
  bloodstone = "bloodstone",
  business = "business",
}

-- A roller for one score evaluation: roll(kind) -> the next predicted value of that kind's stream, or nil when the
-- prediction ran out (the caller then falls back to the average).
function Seer.roller(gs)
  local rolls = gs and gs.seer_rolls
  if type(rolls) ~= "table" then return nil end
  local used = {}
  return function(kind)
    local key = Seer.KIND_KEY[kind]
    local list = key and rolls[key]
    if type(list) ~= "table" then return nil end
    local i = (used[key] or 0) + 1
    used[key] = i
    return list[i]
  end
end

-- The probability numerator in force (Oops! All 6s doubles it): G.GAME.probabilities.normal.
function Seer.normal(gs)
  local r = gs and gs.seer_rolls
  return (type(r) == "table" and tonumber(r.normal)) or 1
end

-- ---- using a prediction ONCE ------------------------------------------------------------------------------------
-- A prediction must not feed its own valuation. Judgement is worth the joker it will create; if that joker is 8 Ball,
-- 8 Ball is worth the random Tarots it makes, and the average Tarot includes Judgement -- which, with the prediction,
-- is worth 8 Ball again... (live 2026-11-28: "stack overflow" in the shop after taking Hallucination). So the joker a
-- card creates is measured on an INNER view of the state, without the predictions: there Judgement falls back to the
-- average joker and the loop ends after one level. Two flags ride on the view (they survive the engine's shallow copies):
--   seer_inner      -- no created-joker prediction here (engine/consumable_value CV.seer_joker_frac)
--   seer_pack_inner -- no known-pack valuation here (engine/packs P.value; set by P.known_value's own view)
-- The view is memoised per state, so the engine's per-state caches still work inside it.
local INNER = setmetatable({}, { __mode = "k" })
function Seer.inner(gs)
  local v = INNER[gs]
  if v then return v end
  v = {}
  for k, x in pairs(gs) do v[k] = x end
  v.seer_inner, v.seer_pack_inner, v.seer_created = true, true, nil
  INNER[gs] = v
  return v
end

-- ---- what the panel shows -------------------------------------------------------------------------------------
-- The next `n` cards you will draw, next first.
function Seer.next_cards(gs, n)
  local pile = gs and gs.remaining
  if not (pile and Seer.is_known(pile)) then return nil end
  return Seer.next_draws(pile, n or 8)
end

-- "hit"/"miss" for the next `n` checks of a chance `1 in den` on `key`.
function Seer.outcomes(gs, key, den, n)
  local r = gs and gs.seer_rolls
  local list = type(r) == "table" and r[key]
  if type(list) ~= "table" then return nil end
  local p = Seer.normal(gs) / den
  local out = {}
  for i = 1, math.min(n or 4, #list) do out[i] = (list[i] < p) end
  return out
end

return Seer
