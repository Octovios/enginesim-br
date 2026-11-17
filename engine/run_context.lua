-- engine/run_context.lua  (EngineSim BR)
-- The run's RULES that the STAKE (Ficha) and the DECK (Baralho) change, read from gs.run (written by
-- core/state_extraction). PURE: no G, no love.
--
-- Why this exists: the original engine assumed White Stake + Red Deck everywhere. It paid a $3 Small Blind on
-- Red Stake and above (where the Small Blind pays nothing), projected White-Stake blind sizes on Green/Purple
-- Stake (which scale faster), scored Plasma Deck hands as chips x mult (Plasma balances them first), and paid
-- interest / $1 per hand on the Green Deck (no interest; $2 per hand and $1 per discard). Every function here
-- falls back to the White Stake / standard-deck rule when a field is absent, so the simulator, the headless tests
-- and old replay fixtures behave exactly as before.

local Mechanics = require("engine.mechanics")
local Cards = require("util.cards")

local RC = {}

-- ---- stakes --------------------------------------------------------------------------------------------------
-- Cumulative in the base game: each stake also has every lower stake's rule.
RC.STAKES = {
  { key = "stake_white",  n = 1, pt = "Ficha Branca",   en = "White Stake" },
  { key = "stake_red",    n = 2, pt = "Ficha Vermelha", en = "Red Stake" },
  { key = "stake_green",  n = 3, pt = "Ficha Verde",    en = "Green Stake" },
  { key = "stake_black",  n = 4, pt = "Ficha Preta",    en = "Black Stake" },
  { key = "stake_blue",   n = 5, pt = "Ficha Azul",     en = "Blue Stake" },
  { key = "stake_purple", n = 6, pt = "Ficha Roxa",     en = "Purple Stake" },
  { key = "stake_orange", n = 7, pt = "Ficha Laranja",  en = "Orange Stake" },
  { key = "stake_gold",   n = 8, pt = "Ficha Dourada",  en = "Gold Stake" },
}
local STAKE_BY_KEY = {}
for _, s in ipairs(RC.STAKES) do STAKE_BY_KEY[s.key] = s end

-- ---- decks ---------------------------------------------------------------------------------------------------
-- What each base-game deck changes that an ADVISOR must know (the rest -- hands, discards, slots, hand size,
-- starting money -- is already visible in the live state). `name_*` are fallbacks; the live name comes from the
-- game's own localization (state_extraction).
RC.DECKS = {
  b_red       = { pt = "Baralho Vermelho",  en = "Red Deck" },
  b_blue      = { pt = "Baralho Azul",      en = "Blue Deck" },
  b_yellow    = { pt = "Baralho Amarelo",   en = "Yellow Deck" },
  b_green     = { pt = "Baralho Verde",     en = "Green Deck", no_interest = true, money_per_hand = 2, money_per_discard = 1 },
  b_black     = { pt = "Baralho Preto",     en = "Black Deck" },
  b_magic     = { pt = "Baralho Mágico",    en = "Magic Deck" },
  b_nebula    = { pt = "Baralho Nebulosa",  en = "Nebula Deck" },
  b_ghost     = { pt = "Baralho Fantasma",  en = "Ghost Deck" },
  b_abandoned = { pt = "Baralho Abandonado", en = "Abandoned Deck", no_faces = true },
  b_checkered = { pt = "Baralho Xadrez",    en = "Checkered Deck", suits = { "Spades", "Hearts" } },
  b_zodiac    = { pt = "Baralho Zodíaco",   en = "Zodiac Deck" },
  b_painted   = { pt = "Baralho Pintado",   en = "Painted Deck" },
  b_anaglyph  = { pt = "Baralho Anáglifo",  en = "Anaglyph Deck" },
  b_plasma    = { pt = "Baralho de Plasma", en = "Plasma Deck", balance = true, ante_scaling = 2 },
  b_erratic   = { pt = "Baralho Errático",  en = "Erratic Deck", erratic = true },
}
-- the game's internal (English) deck names -> key, for snapshots that only carry the name
local DECK_BY_NAME = {}
for k, d in pairs(RC.DECKS) do DECK_BY_NAME[d.en] = k end

local function run_of(gs) return (gs and gs.run) or {} end

-- ---- reading the context -------------------------------------------------------------------------------------

function RC.stake(gs)
  local r = run_of(gs)
  local n = tonumber(r.stake)
  if n and n >= 1 then return math.floor(n) end
  local s = r.stake_key and STAKE_BY_KEY[r.stake_key]
  return s and s.n or 1
end

function RC.stake_info(gs)
  local n = RC.stake(gs)
  local r = run_of(gs)
  return (r.stake_key and STAKE_BY_KEY[r.stake_key]) or RC.STAKES[math.min(n, #RC.STAKES)] or RC.STAKES[1]
end

function RC.deck_key(gs)
  local r = run_of(gs)
  if r.deck_key then return r.deck_key end
  return r.deck_back and DECK_BY_NAME[r.deck_back] or nil
end

function RC.deck_info(gs)
  local k = RC.deck_key(gs)
  return k and RC.DECKS[k] or nil
end

-- Blind size scaling (G.GAME.modifiers.scaling): 1 White/Red, 2 from Green Stake, 3 from Purple Stake.
function RC.scaling(gs)
  local r = run_of(gs)
  local s = tonumber(r.scaling)
  if s and s >= 1 then return s end
  if r.stake ~= nil or r.stake_key ~= nil then
    local n = RC.stake(gs)
    return (n >= 6 and 3) or (n >= 3 and 2) or 1
  end
  return 1
end

-- Blind size multiplier from the deck (G.GAME.starting_params.ante_scaling): 2 on the Plasma Deck.
function RC.ante_scaling(gs)
  local r = run_of(gs)
  local a = tonumber(r.ante_scaling)
  if a and a > 0 then return a end
  local d = RC.deck_info(gs)
  return (d and d.ante_scaling) or 1
end

-- Plasma Deck: at the end of scoring, chips and mult are averaged (score = floor((c+m)/2)^2).
function RC.balanced_scoring(gs)
  local r = run_of(gs)
  if r.balance_scoring ~= nil then return r.balance_scoring and true or false end
  local d = RC.deck_info(gs)
  return (d and d.balance) and true or false
end

-- The money a blind actually pays when beaten, after the stake (Red Stake+: the Small Blind pays $0).
function RC.blind_reward(gs, btype)
  local r = run_of(gs)
  if type(r.blind_rewards) == "table" and r.blind_rewards[btype] ~= nil then return r.blind_rewards[btype] end
  if type(r.no_blind_reward) == "table" then
    if r.no_blind_reward[btype] then return 0 end
  elseif btype == "Small" and RC.stake(gs) >= 2 then
    return 0
  end
  return Mechanics.BLIND_REWARD[btype] or 3
end

function RC.small_blind_unpaid(gs) return RC.blind_reward(gs, "Small") == 0 end

-- $ per unused hand / discard at the cash-out (Green Deck: $2 / $1).
function RC.hand_money(gs)
  local r = run_of(gs)
  if r.no_extra_hand_money then return 0 end
  local v = tonumber(r.money_per_hand)
  if v then return v end
  local d = RC.deck_info(gs)
  return (d and d.money_per_hand) or Mechanics.HAND_REWARD
end

function RC.discard_money(gs)
  local r = run_of(gs)
  local v = tonumber(r.money_per_discard)
  if v then return v end
  local d = RC.deck_info(gs)
  return (d and d.money_per_discard) or 0
end

function RC.no_interest(gs)
  local r = run_of(gs)
  if r.no_interest ~= nil then return r.no_interest and true or false end
  local d = RC.deck_info(gs)
  return (d and d.no_interest) and true or false
end

-- Interest paid at the cash-out for `dollars` held (0 on the Green Deck; To the Moon raises the amount).
function RC.interest(gs, dollars)
  if RC.no_interest(gs) then return 0 end
  local e = (gs and gs.economy) or {}
  local per = tonumber(run_of(gs).interest_amount) or 1
  return Mechanics.interest(dollars or e.dollars or 0, e.interest_cap) * per
end

-- Chips needed to beat `btype` at `ante`, with this run's stake scaling and deck multiplier.
function RC.requirement(gs, ante, btype, boss_mult)
  return Mechanics.blind_requirement(ante, btype, boss_mult, gs)
end

-- Shop stickers this stake can put on jokers (Black: Eternal, Orange: Perishable, Gold: Rental).
function RC.stickers(gs)
  local r = run_of(gs)
  local n = RC.stake(gs)
  local known = r.eternals ~= nil or r.perishables ~= nil or r.rentals ~= nil
  return {
    eternal = known and (r.eternals and true or false) or (n >= 4),
    perishable = known and (r.perishables and true or false) or (n >= 7),
    rental = known and (r.rentals and true or false) or (n >= 8),
  }
end

-- ---- the deck's composition ----------------------------------------------------------------------------------
-- What the deck can actually make (counted on the WHOLE deck, gs.deck). Feeds the build planner: an Abandoned
-- Deck (or a deck thinned of faces) has no King / Queen build; a Checkered Deck is two suits; etc.
function RC.deck_profile(gs)
  local deck = (gs and gs.deck) or {}
  local p = { n = #deck, ranks = {}, suits = {}, rs = {}, enh = {}, seals = {}, editions = 0,
              faces = 0, kings = 0, queens = 0, jacks = 0, aces = 0, evens = 0, odds = 0, fib = 0, twos = 0,
              stones = 0, wilds = 0 }
  for _, c in ipairs(deck) do
    if Cards.is_stone(c) then
      p.stones = p.stones + 1
    else
      local r = Cards.rank_id(c)
      p.ranks[r] = (p.ranks[r] or 0) + 1
      if c.suit then
        p.suits[c.suit] = (p.suits[c.suit] or 0) + 1
        p.rs[r] = p.rs[r] or {}
        p.rs[r][c.suit] = (p.rs[r][c.suit] or 0) + 1
      end
      if Cards.is_face(c) then p.faces = p.faces + 1 end
      if r == 13 then p.kings = p.kings + 1 elseif r == 12 then p.queens = p.queens + 1
      elseif r == 11 then p.jacks = p.jacks + 1 elseif r == 14 then p.aces = p.aces + 1 end
      if Cards.is_even(c) then p.evens = p.evens + 1 end
      if Cards.is_odd(c) then p.odds = p.odds + 1 end
      if Cards.is_fibonacci(c) then p.fib = p.fib + 1 end
      if r == 2 then p.twos = p.twos + 1 end
      if Cards.is_wild(c) then p.wilds = p.wilds + 1 end
    end
    if c.enhancement then p.enh[c.enhancement] = (p.enh[c.enhancement] or 0) + 1 end
    if c.seal then p.seals[c.seal] = (p.seals[c.seal] or 0) + 1 end
    if c.edition then p.editions = p.editions + 1 end
  end
  -- the dominant suit (ties broken by name, never by pairs() order) and its share
  local dom, domn = nil, -1
  for _, s in ipairs({ "Clubs", "Diamonds", "Hearts", "Spades" }) do
    local k = p.suits[s] or 0
    if k > domn then dom, domn = s, k end
  end
  p.dominant_suit, p.dominant_n = dom, math.max(0, domn)
  local suited = 0
  for _, k in pairs(p.suits) do suited = suited + k end
  p.dominant_share = suited > 0 and (p.dominant_n / suited) or 0
  local nsuits = 0
  for _, s in ipairs(Cards.SUITS) do if (p.suits[s] or 0) > 0 then nsuits = nsuits + 1 end end
  p.n_suits = nsuits
  -- the most common rank and how many copies
  local topr, topn = nil, 0
  for r = 14, 2, -1 do
    local k = p.ranks[r] or 0
    if k > topn then topr, topn = r, k end
  end
  p.top_rank, p.top_rank_n = topr, topn
  -- the most duplicated EXACT card (rank + suit): what Flush Five needs five of. Ties: higher rank, then suit name.
  local tc, tcn = nil, 0
  for r = 14, 2, -1 do
    for _, s in ipairs({ "Clubs", "Diamonds", "Hearts", "Spades" }) do
      local k = p.rs[r] and p.rs[r][s] or 0
      if k > tcn then tc, tcn = { rank = r, suit = s }, k end
    end
  end
  if tc then tc.n = tcn end
  p.top_card = tc
  return p
end

-- The deck's traits the advisors should mention (deck key + what is really in the deck).
function RC.deck_traits(gs)
  local d = RC.deck_info(gs) or {}
  local p = RC.deck_profile(gs)
  local r = run_of(gs)
  local t = {
    key = RC.deck_key(gs),
    -- "no faces" is a FACT about the deck now: the Abandoned Deck starts without them, and any deck can lose them
    no_faces = (p.n > 0 and p.faces == 0) or ((d.no_faces or r.no_faces) and p.n == 0) or false,
    two_suits = (p.n > 0 and p.n_suits <= 2) or false,
    balance = RC.balanced_scoring(gs),
    erratic = d.erratic or r.erratic or false,
    profile = p,
  }
  return t
end

return RC
