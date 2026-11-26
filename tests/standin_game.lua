-- tests/standin_game.lua  (EngineSim BR)
-- A stand-in for the parts of Balatro + Steamodded that the seer's pack / shop replay (core/seer_peek) calls: the named
-- RNG streams (pseudoseed / pseudorandom / pseudorandom_element), get_current_pool, poll_edition, SMODS.poll_seal, the
-- vanilla booster recipes and a handful of cards. Real shapes, simple numbers: a stream's state is a COUNTER (how
-- many times it was used) and its next value is a hash of (stream, count) -- unless a test FORCES it.
--
-- Also a reference "real game" -- create_card, opening a pack, a shop reroll -- transcribed from the game's code
-- (functions/common_events.lua, UI_definitions.lua and button_callbacks.lua, as Steamodded patches them), so a test
-- can let the "game" really do the thing after the seer predicted it, and compare.

local M = {}
M.FORCE = {}   -- M.FORCE[stream] = { [use number] = value }

local GLOBALS = { "pseudoseed", "pseudorandom", "pseudorandom_element", "get_current_pool", "poll_edition", "find_joker",
                  "pseudoshuffle" }

local function hash01(s)
  local h = 7
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
  h = (h * 48271) % 2147483647
  return (h % 1000003) / 1000003
end

local function center(key, set, t)
  local c = { key = key, set = set, name = key }
  for k, v in pairs(t or {}) do c[k] = v end
  c.config = c.config or {}
  return c
end

-- ---- the cards -------------------------------------------------------------------------------------------------
local function build_centers()
  local C = {}
  local function add(c) C[c.key] = c; return c end
  local commons = {
    add(center("j_joker", "Joker", { rarity = 1, cost = 2, name = "Joker", config = { mult = 4 }, eternal_compat = true, perishable_compat = true })),
    add(center("j_greedy_joker", "Joker", { rarity = 1, cost = 5, name = "Greedy Joker", config = { extra = { s_mult = 3, suit = "Diamonds" } }, eternal_compat = true, perishable_compat = true })),
    add(center("j_lusty_joker", "Joker", { rarity = 1, cost = 5, name = "Lusty Joker", config = { extra = { s_mult = 3, suit = "Hearts" } }, eternal_compat = true, perishable_compat = true })),
    add(center("j_wrathful_joker", "Joker", { rarity = 1, cost = 5, name = "Wrathful Joker", config = { extra = { s_mult = 3, suit = "Spades" } }, eternal_compat = true, perishable_compat = true })),
  }
  local uncommons = {
    add(center("j_hologram", "Joker", { rarity = 2, cost = 7, name = "Hologram", config = { extra = 0.25, Xmult = 1 }, eternal_compat = true })),
    add(center("j_steel_joker", "Joker", { rarity = 2, cost = 7, name = "Steel Joker", config = { extra = 0.2 }, eternal_compat = true, perishable_compat = true })),
  }
  local rares = {
    add(center("j_blueprint", "Joker", { rarity = 3, cost = 10, name = "Blueprint", eternal_compat = true })),
    add(center("j_baron", "Joker", { rarity = 3, cost = 8, name = "Baron", config = { extra = 1.5 }, eternal_compat = true, perishable_compat = true })),
  }
  local legendaries = {
    add(center("j_perkeo", "Joker", { rarity = 4, cost = 20, name = "Perkeo", config = { extra = 1 }, eternal_compat = true })),
    add(center("j_triboulet", "Joker", { rarity = 4, cost = 20, name = "Triboulet", config = { extra = 2 }, eternal_compat = true })),
    add(center("j_chicot", "Joker", { rarity = 4, cost = 20, name = "Chicot", eternal_compat = true })),
  }
  local tarots = {}
  for _, k in ipairs({ "c_fool", "c_magician", "c_death", "c_strength", "c_hermit" }) do
    tarots[#tarots + 1] = add(center(k, "Tarot", { cost = 3, consumeable = true }))
  end
  local planets = {
    add(center("c_mercury", "Planet", { cost = 3, consumeable = true, config = { hand_type = "Pair" } })),
    add(center("c_jupiter", "Planet", { cost = 3, consumeable = true, config = { hand_type = "Flush" } })),
    add(center("c_pluto", "Planet", { cost = 3, consumeable = true, config = { hand_type = "High Card" } })),
  }
  local spectrals = {}
  for _, k in ipairs({ "c_familiar", "c_grim", "c_incantation" }) do
    spectrals[#spectrals + 1] = add(center(k, "Spectral", { cost = 4, consumeable = true }))
  end
  spectrals[#spectrals + 1] = add(center("c_soul", "Spectral", { cost = 4, consumeable = true, hidden = true, name = "The Soul" }))
  spectrals[#spectrals + 1] = add(center("c_black_hole", "Spectral", { cost = 4, consumeable = true, hidden = true, name = "Black Hole" }))
  local enhanced = {}
  for _, k in ipairs({ "m_bonus", "m_mult", "m_gold", "m_glass" }) do enhanced[#enhanced + 1] = add(center(k, "Enhanced", {})) end
  add(center("c_base", "Default", { name = "Default Base" }))
  return C, { [1] = commons, [2] = uncommons, [3] = rares, [4] = legendaries },
    { Tarot = tarots, Planet = planets, Spectral = spectrals, Enhanced = enhanced }
end

-- the booster recipes (Steamodded src/game_object.lua, take_ownership_by_kind)
local function arcana(self, card, i)
  local G = _G.G
  if G.GAME.used_vouchers.v_omen_globe and pseudorandom("omen_globe") > 0.8 then
    return { set = "Spectral", area = G.pack_cards, skip_materialize = true, soulable = true, key_append = "ar2" }
  end
  return { set = "Tarot", area = G.pack_cards, skip_materialize = true, soulable = true, key_append = "ar1" }
end
local function buffoon(self, card)
  return { set = "Joker", area = _G.G.pack_cards, skip_materialize = true, soulable = true, key_append = "buf" }
end
local function standard(self, card, i)
  local G = _G.G
  local _edition = poll_edition("standard_edition" .. G.GAME.round_resets.ante, 2, true)
  local _seal = SMODS.poll_seal({ mod = 10 })
  return { set = (pseudorandom(pseudoseed("stdset" .. G.GAME.round_resets.ante)) > 0.6) and "Enhanced" or "Base",
    edition = _edition, seal = _seal, area = G.pack_cards, skip_materialize = true, soulable = true, key_append = "sta",
    front = false }
end
local function spectral(self, card, i)
  return { set = "Spectral", area = _G.G.pack_cards, skip_materialize = true, soulable = true, key_append = "spe" }
end
local function celestial(self, card, i)
  return { set = "Planet", area = _G.G.pack_cards, skip_materialize = true, soulable = true, key_append = "pl1" }
end

local function boosters(C)
  local list = {
    center("p_arcana_normal_1", "Booster", { kind = "Arcana", cost = 4, config = { extra = 3, choose = 1 }, create_card = arcana }),
    center("p_arcana_mega_1", "Booster", { kind = "Arcana", cost = 8, config = { extra = 5, choose = 2 }, create_card = arcana }),
    center("p_buffoon_normal_1", "Booster", { kind = "Buffoon", cost = 4, config = { extra = 2, choose = 1 }, create_card = buffoon }),
    center("p_buffoon_mega_1", "Booster", { kind = "Buffoon", cost = 8, config = { extra = 4, choose = 2 }, create_card = buffoon }),
    center("p_standard_normal_1", "Booster", { kind = "Standard", cost = 4, config = { extra = 3, choose = 1 }, create_card = standard }),
    center("p_spectral_normal_1", "Booster", { kind = "Spectral", cost = 4, config = { extra = 2, choose = 1 }, create_card = spectral }),
    center("p_celestial_normal_1", "Booster", { kind = "Celestial", cost = 4, config = { extra = 3, choose = 1 }, create_card = celestial }),
    center("p_modded_1", "Booster", { kind = "Mystery", cost = 4, config = { extra = 2, choose = 1 }, create_card = buffoon, original_mod = {} }),
  }
  for _, b in ipairs(list) do C[b.key] = b end
  return list
end

local P_CARDS = {
  H_K = { name = "King of Hearts", value = "King", suit = "Hearts" },
  S_A = { name = "Ace of Spades", value = "Ace", suit = "Spades" },
  D_7 = { name = "7 of Diamonds", value = "7", suit = "Diamonds" },
  C_2 = { name = "2 of Clubs", value = "2", suit = "Clubs" },
  H_T = { name = "10 of Hearts", value = "10", suit = "Hearts" },
}
local RANK_ID = { ["2"] = 2, ["7"] = 7, ["10"] = 10, King = 13, Ace = 14 }

-- ---- install / uninstall ---------------------------------------------------------------------------------------
-- Fills `G` (a table the test owns) with what the replay reads, defines the game's global functions, and adds the
-- Steamodded bits to `S` (SMODS). Returns a function that puts every global and SMODS field back.
function M.install(G, S)
  local saved, saved_s = {}, {}
  for _, k in ipairs(GLOBALS) do saved[k] = rawget(_G, k) end
  local had_smods = rawget(_G, "SMODS")
  S = S or had_smods or {}
  _G.SMODS = S
  local SFIELDS = { "poll_seal", "showman", "find_card", "Consumable", "ConsumableType", "optional_features", "OPENED_BOOSTER",
                    "add_to_pool", "Ranks", "Suits" }
  for _, k in ipairs(SFIELDS) do saved_s[k] = S[k] end
  M.FORCE = {}

  local C, rarity_pools, pools = build_centers()
  local blist = boosters(C)
  pools.Booster = blist
  G.P_CENTERS = setmetatable(C, { __index = G.P_CENTERS })   -- keep whatever the test had
  G.P_JOKER_RARITY_POOLS = rarity_pools
  G.P_CENTER_POOLS = setmetatable(pools, { __index = G.P_CENTER_POOLS })
  G.P_CARDS = P_CARDS
  G.GAME = G.GAME or {}
  local GAME = G.GAME
  GAME.pseudorandom = GAME.pseudorandom or { seed = "TEST" }
  GAME.used_jokers = GAME.used_jokers or {}
  GAME.round_resets = GAME.round_resets or { ante = 1 }
  GAME.round_resets.ante = GAME.round_resets.ante or 1
  GAME.banned_keys = GAME.banned_keys or {}
  GAME.used_vouchers = GAME.used_vouchers or {}
  GAME.modifiers = GAME.modifiers or {}
  GAME.joker_rate, GAME.tarot_rate, GAME.planet_rate = 20, 4, 4
  GAME.playing_card_rate, GAME.spectral_rate = GAME.playing_card_rate or 0, GAME.spectral_rate or 0
  GAME.shop = GAME.shop or { joker_max = 2 }
  GAME.tags = GAME.tags or {}
  GAME.inflation, GAME.discount_percent = 0, 0
  GAME.probabilities = GAME.probabilities or { normal = 1 }
  G.jokers = G.jokers or { cards = {}, config = { card_limit = 5 } }
  G.shop_jokers = G.shop_jokers or { cards = {} }
  G.SETTINGS = G.SETTINGS or {}

  _G.pseudoseed = function(key)
    local pr = _G.G.GAME.pseudorandom
    pr[key] = (pr[key] or 0) + 1
    local f = M.FORCE[key] and M.FORCE[key][pr[key]]
    if f then return f end
    return hash01(key .. "#" .. pr[key] .. "#" .. tostring(pr.seed))
  end
  _G.pseudorandom = function(seed, min, max)
    if type(seed) == "string" then seed = _G.pseudoseed(seed) end
    if min and max then return min + math.floor(seed * (max - min + 1)) end
    return seed
  end
  _G.pseudorandom_element = function(t, seed)
    if type(seed) == "string" then seed = _G.pseudoseed(seed) end
    local keys = {}
    for k, v in pairs(t) do keys[#keys + 1] = { k = k, v = v } end
    if #keys == 0 then return nil, nil end
    table.sort(keys, function(a, b)
      if type(a.k) == type(b.k) then return a.k < b.k end
      return tostring(a.k) < tostring(b.k)
    end)
    local pick = keys[math.floor(seed * #keys) + 1].k
    return t[pick], pick
  end
  _G.get_current_pool = function(_type, _rarity, _legendary, _append)
    local G = _G.G
    local ante = G.GAME.round_resets.ante
    local start, pool_key
    if _type == "Joker" then
      local r = _legendary and 4 or _rarity
      if type(r) == "number" and not _legendary then r = (r > 0.95 and 3) or (r > 0.7 and 2) or 1 end
      if not r then
        local p = _G.pseudorandom("rarity" .. ante .. (_append or ""))
        r = (p > 0.95 and 3) or (p > 0.7 and 2) or 1
      end
      -- a Legendary pool has no append and no ante in its stream name (functions/common_events.lua)
      start, pool_key = G.P_JOKER_RARITY_POOLS[r], "Joker" .. r .. ((not _legendary and _append) or "")
      if _legendary then return (function()
        local pool, size = {}, 0
        for _, v in ipairs(start) do
          if not G.GAME.used_jokers[v.key] then pool[#pool + 1] = v.key; size = size + 1 else pool[#pool + 1] = "UNAVAILABLE" end
        end
        if size == 0 then pool = { "j_joker" } end
        return pool, pool_key
      end)() end
    else
      start, pool_key = G.P_CENTER_POOLS[_type] or {}, _type .. (_append or "")
    end
    local pool, size = {}, 0
    for _, v in ipairs(start) do
      local add = (_type == "Enhanced") or (_type == "Edition") or not G.GAME.used_jokers[v.key]
      if v.key == "c_soul" or v.key == "c_black_hole" then add = false end
      if add and not G.GAME.banned_keys[v.key] then pool[#pool + 1] = v.key; size = size + 1
      else pool[#pool + 1] = "UNAVAILABLE" end
    end
    if size == 0 then pool = { (_type == "Joker" and "j_joker") or (_type == "Planet" and "c_pluto") or "c_strength" } end
    return pool, pool_key .. ante
  end
  _G.poll_edition = function(_key, _mod, _no_neg, _guaranteed)
    local p = _G.pseudorandom(_G.pseudoseed(_key or "edition_generic"))
    local m = _guaranteed and 25 or (_mod or 1)
    if p > 1 - 0.003 * m and not _no_neg then return "e_negative" end
    if p > 1 - 0.006 * m then return "e_polychrome" end
    if p > 1 - 0.02 * m then return "e_holo" end
    if p > 1 - 0.04 * m then return "e_foil" end
    return nil
  end
  -- pseudoshuffle (functions/misc_functions.lua): sort by sort_id, then Fisher-Yates from the seed
  _G.pseudoshuffle = function(list, seed)
    if type(seed) == "string" then seed = _G.pseudoseed(seed) end
    if list[1] and list[1].sort_id then
      table.sort(list, function(a, b) return (a.sort_id or 1) < (b.sort_id or 2) end)
    end
    local x = math.floor((seed or 0.5) * 2147483645) + 1
    for i = #list, 2, -1 do
      x = (x * 48271) % 2147483647
      local j = (x % i) + 1
      list[i], list[j] = list[j], list[i]
    end
  end
  _G.find_joker = function(name)
    local out = {}
    for _, c in ipairs(_G.G.jokers.cards or {}) do if c.ability and c.ability.name == name then out[#out + 1] = c end end
    return out
  end
  S.poll_seal = function(args)
    local ante = _G.G.GAME.round_resets.ante
    if _G.pseudorandom(_G.pseudoseed("stdseal" .. ante)) > 1 - 0.02 * ((args and args.mod) or 1) then
      local p = _G.pseudorandom(_G.pseudoseed("stdsealtype" .. ante))
      return (p > 0.75 and "Red") or (p > 0.5 and "Blue") or (p > 0.25 and "Gold") or "Purple"
    end
    return nil
  end
  S.showman = function() return false end
  S.find_card = function(key)
    local out = {}
    for _, c in ipairs(_G.G.jokers.cards or {}) do
      if c.config and c.config.center and c.config.center.key == key then out[#out + 1] = c end
    end
    return out
  end
  S.Consumable = { legendaries = {} }
  S.ConsumableType = { obj_buffer = { "Tarot", "Planet", "Spectral" } }
  S.optional_features = {}
  S.add_to_pool = function() return true end
  S.Ranks = nil
  S.Suits = nil

  return function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
    for _, k in ipairs(SFIELDS) do S[k] = saved_s[k] end
    _G.SMODS = had_smods
    M.FORCE = {}
  end
end

-- ---- the reference "real game" ---------------------------------------------------------------------------------
-- A stand-in card: what the game's Card would carry that the mod reads.
local function new_card(center, front)
  local c = { config = { center = center }, ability = { set = center.set, name = center.name } }
  if front then c.base = { value = front.value, suit = front.suit, id = RANK_ID[front.value] } end
  return c
end

-- create_card (functions/common_events.lua, with Steamodded's patches; no modded legendaries)
function M.real_create_card(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
  local G = _G.G
  local ante = G.GAME.round_resets.ante
  if not forced_key and soulable and not G.GAME.banned_keys["c_soul"] then
    pseudorandom("soul_smods_" .. _type .. ante)
    if (_type == "Tarot" or _type == "Spectral" or _type == "Tarot_Planet") and not G.GAME.used_jokers["c_soul"] then
      if pseudorandom("soul_" .. _type .. ante) > 0.997 then forced_key = "c_soul" end
    end
    if (_type == "Planet" or _type == "Spectral") and not G.GAME.used_jokers["c_black_hole"] then
      if pseudorandom("soul_" .. _type .. ante) > 0.997 then forced_key = "c_black_hole" end
    end
  end
  if _type == "Base" then forced_key = "c_base" end
  local c
  if forced_key and not G.GAME.banned_keys[forced_key] then
    c = G.P_CENTERS[forced_key]
    _type = (c.set ~= "Default" and c.set or _type)
  else
    local _pool, _pool_key = get_current_pool(_type, _rarity, legendary, key_append)
    local key = pseudorandom_element(_pool, pseudoseed(_pool_key))
    local it = 1
    while key == "UNAVAILABLE" do
      it = it + 1
      key = pseudorandom_element(_pool, pseudoseed(_pool_key .. "_resample" .. it))
    end
    c = G.P_CENTERS[key]
  end
  local front = ((_type == "Base" or _type == "Enhanced") and pseudorandom_element(G.P_CARDS, pseudoseed("front" .. (key_append or "") .. ante))) or nil
  local card = new_card(c, front)
  G.GAME.used_jokers[c.key] = true          -- Card:set_ability
  if _type == "Joker" then
    if area == "shop" or area == "pack" then
      local poll = pseudorandom((area == "pack" and "packetper" or "etperpoll") .. ante)
      if G.GAME.modifiers.enable_eternals_in_shop and poll > 0.7 then
        if c.eternal_compat then card.ability.eternal = true end
      elseif G.GAME.modifiers.enable_perishables_in_shop and poll > 0.4 and poll <= 0.7 then
        if c.perishable_compat then card.ability.perishable = true end
      end
      if G.GAME.modifiers.enable_rentals_in_shop and pseudorandom((area == "pack" and "packssjr" or "ssjr") .. ante) > 0.7 then
        card.ability.rental = true
      end
    end
    local ed = poll_edition("edi" .. (key_append or "") .. ante)
    if ed then card.edition = { type = ed:gsub("^e_", "") } end
  end
  return card
end

-- Card:open for a booster: the recipe, then SMODS.create_card for each card
function M.real_open(key)
  local G = _G.G
  local c = G.P_CENTERS[key]
  local out = {}
  for i = 1, c.config.extra do
    local spec = c:create_card({ ability = c.config, config = { center = c } }, i)
    local card = M.real_create_card(spec.set, "pack", spec.legendary, spec.rarity, true, spec.soulable, spec.key, spec.key_append)
    if spec.edition then card.edition = { type = spec.edition:gsub("^e_", "") } end
    if spec.seal then card.seal = spec.seal end
    out[i] = card
  end
  return out
end

-- create_card_for_shop (no shop tags), then G.FUNCS.reroll_shop
function M.real_shop_card()
  local G = _G.G
  local GAME = G.GAME
  local ante = GAME.round_resets.ante
  local total = GAME.joker_rate + GAME.playing_card_rate + GAME.tarot_rate + GAME.planet_rate + GAME.spectral_rate
  local polled = pseudorandom(pseudoseed("cdt" .. ante)) * total
  local check = 0
  for _, v in ipairs({
    { type = "Joker", val = GAME.joker_rate }, { type = "Tarot", val = GAME.tarot_rate },
    { type = "Planet", val = GAME.planet_rate },
    { type = (GAME.used_vouchers["v_illusion"] and pseudorandom(pseudoseed("illusion")) > 0.6) and "Enhanced" or "Base", val = GAME.playing_card_rate },
    { type = "Spectral", val = GAME.spectral_rate },
  }) do
    if polled > check and polled <= check + v.val then
      return M.real_create_card(v.type, "shop", nil, nil, nil, nil, nil, "sho")
    end
    check = check + v.val
  end
end
function M.real_reroll()
  local G = _G.G
  for i = #G.shop_jokers.cards, 1, -1 do
    local c = table.remove(G.shop_jokers.cards, i)
    if not next(SMODS.find_card(c.config.center.key)) then G.GAME.used_jokers[c.config.center.key] = nil end  -- Card:remove
  end
  for i = 1, G.GAME.shop.joker_max do G.shop_jokers.cards[i] = M.real_shop_card() end
  return G.shop_jokers.cards
end

-- new_round: G.deck:shuffle('nr'..ante), then the hand is drawn from the END of the deck
function M.real_round_start(hand_size)
  local G = _G.G
  pseudoshuffle(G.deck.cards, pseudoseed("nr" .. G.GAME.round_resets.ante))
  for _ = 1, hand_size do G.hand.cards[#G.hand.cards + 1] = table.remove(G.deck.cards) end
  return G.hand.cards
end

-- the same signature core/seer_peek gives a predicted item: key, and for a playing card its face
function M.card_sig(card)
  local k = card.config.center.key
  if card.base then return k .. ":" .. tostring(card.base.suit) .. ":" .. tostring(card.base.id) end
  return k
end
function M.card_sigs(cards)
  local out = {}
  for i, c in ipairs(cards) do out[i] = M.card_sig(c) end
  return out
end
M.new_card = new_card

return M
