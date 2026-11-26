-- core/seer_peek.lua  (EngineSim BR) -- the seer's look into PACKS and the SHOP (reads the live game)
--
-- engine/seer.lua explains why Balatro's future can be read: every random pick reads its own NAMED stream
-- (G.GAME.pseudorandom[name]), and the game's own functions produce the same values in the same order whenever
-- they run from the same stream state. This file uses that to answer three questions BEFORE you act:
--
--   * what is inside a booster pack (in the shop, or the one a skip tag would open),
--   * what the next shop rerolls will put on the shelf,
--   * which joker a Rare / Uncommon / Top-up tag would give.
--
-- HOW, without touching the run:
--   1. Copy the whole G.GAME.pseudorandom table and G.GAME.used_jokers (the game never offers a card that is already
--      out -- owned, on the shelf, or earlier in the same pack -- and that list lives in used_jokers).
--   2. Replay the game's card recipe step by step with the game's OWN primitives -- get_current_pool,
--      pseudorandom_element, pseudoseed, pseudorandom, poll_edition, SMODS.poll_seal -- in the order the game calls
--      them (create_card in functions/common_events.lua as Steamodded patches it: lovely/center.toml, pool.toml,
--      rarity.toml, sticker.toml, edition.toml; SMODS.create_card in src/utils.lua; the pack recipes in
--      src/game_object.lua; create_card_for_shop in functions/UI_definitions.lua + lovely/shop.toml).
--   3. Put both tables back exactly (keys the replay created are removed again).
--
-- It never calls create_card / create_card_for_shop themselves: those build real Card objects (sprites, sounds,
-- discoveries, unlock checks) and consume shop tags. The replay builds plain tables instead.
--
-- Where the replay cannot be exact it says so and returns nil: Steamodded's optional object-weight system (another
-- mod turned it on), a shop tag that will replace a slot, the tutorial's scripted shop, a modded booster.
-- main.lua also CHECKS every prediction against what really appears and stops using them if they miss.

local GS = require("model.game_state")
local Extract = require("core.state_extraction")

local Peek = {}

local RANK_ID = { ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9, ["10"] = 10,
                  Jack = 11, Queen = 12, King = 13, Ace = 14 }
local VANILLA_PACK = { Arcana = true, Celestial = true, Spectral = true, Standard = true, Buffoon = true }
-- edition -> extra shop cost (Card:set_cost); a modded edition carries its own extra_cost
local EDITION_COST = { foil = 2, holo = 3, polychrome = 5, negative = 5 }

local function live()
  local G = _G.G
  return G and G.GAME and type(G.GAME.pseudorandom) == "table" and type(G.GAME.used_jokers) == "table"
    and G.GAME.round_resets and type(_G.pseudorandom) == "function" and type(_G.pseudoseed) == "function"
    and type(_G.pseudorandom_element) == "function" and type(_G.get_current_pool) == "function"
    and G.P_CENTERS and true or false
end

-- ---- why a prediction is not possible right now (nil = it is) ----------------------------------------------------
-- "weights": Steamodded's object-weight system replaces the vanilla picks (a mod enabled it).
function Peek.blocked()
  if not live() then return "no_game" end
  local S = rawget(_G, "SMODS")
  if S and S.optional_features and S.optional_features.object_weights then return "weights" end
  return nil
end

-- ---- 1 + 3: run a replay in a sandbox ----------------------------------------------------------------------------
local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end
local function put_back(t, saved)
  for k in pairs(t) do if saved[k] == nil then t[k] = nil end end
  for k, v in pairs(saved) do t[k] = v end
end

-- fn(...) runs with the run's streams and used-card list saved; both are restored afterwards, whatever happens.
-- Returns fn's (single) result, or nil + the error.
function Peek.sandbox(fn, ...)
  if not live() then return nil, "no_game" end
  local GAME = _G.G.GAME
  local pr, uj = GAME.pseudorandom, GAME.used_jokers
  local ante = GAME.round_resets.ante
  local saved_pr, saved_uj = copy(pr), copy(uj)
  local ok, res = pcall(fn, ...)
  GAME.pseudorandom, GAME.used_jokers = pr, uj      -- (in case the replay swapped a table)
  put_back(pr, saved_pr)
  put_back(uj, saved_uj)
  GAME.round_resets.ante = ante
  if not ok then return nil, res end
  return res
end

-- ---- 2: one card, the way the game makes it ----------------------------------------------------------------------
local function showman(key)
  local S = rawget(_G, "SMODS")
  if S and type(S.showman) == "function" then return S.showman(key) end
  return type(_G.find_joker) == "function" and next(_G.find_joker("Showman")) ~= nil
end

-- Is a copy of `key` held in a joker area? (Card:remove only frees the key when none is left: SMODS.find_card)
local function owned(key)
  local S = rawget(_G, "SMODS")
  if S and type(S.find_card) == "function" then return next(S.find_card(key, true)) ~= nil end
  local G = _G.G
  for _, c in ipairs((G.jokers and G.jokers.cards) or {}) do
    if c.config and c.config.center and c.config.center.key == key then return true end
  end
  return false
end
-- what Card:remove does to the used list
local function release(key)
  if key and not owned(key) then _G.G.GAME.used_jokers[key] = nil end
end

-- create_card's pool pick: the pool, its stream, and a re-roll while the pick is 'UNAVAILABLE' (a culled slot)
local function pick_from_pool(_type, rarity, legendary, append)
  local pool, pool_key = _G.get_current_pool(_type, rarity, legendary, append)
  local key = _G.pseudorandom_element(pool, _G.pseudoseed(pool_key))
  local it = 1
  while key == "UNAVAILABLE" do
    it = it + 1
    if it > 500 then error("pool never resolved: " .. tostring(pool_key)) end
    key = _G.pseudorandom_element(pool, _G.pseudoseed(pool_key .. "_resample" .. it))
  end
  return key
end

local function short_edition(e)
  if type(e) == "table" then e = e.type or e.key end
  if type(e) ~= "string" then return nil end
  return (e:gsub("^e_", ""))
end

-- the ability table Card:set_ability builds from a center (the engine reads ability.extra and friends)
local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end
local function ability_of(center)
  local cfg = center.config or {}
  return {
    name = center.name, effect = center.effect, set = center.set,
    mult = cfg.mult or 0, h_mult = cfg.h_mult or 0, h_x_mult = cfg.h_x_mult or 0, h_dollars = cfg.h_dollars or 0,
    p_dollars = cfg.p_dollars or 0, t_mult = cfg.t_mult or 0, t_chips = cfg.t_chips or 0, x_mult = cfg.Xmult or 1,
    h_size = cfg.h_size or 0, d_size = cfg.d_size or 0, extra = deep(cfg.extra), extra_value = 0,
    type = cfg.type or "", order = center.order, perma_bonus = 0, bonus = cfg.bonus or 0,
  }
end

-- the shop price (Card:set_cost)
local function price(center, edition, rental)
  local G = _G.G
  local GAME = G.GAME
  if rental then return 1 end
  if center.set == "Planet" and type(_G.find_joker) == "function" and #_G.find_joker("Astronomer") > 0 then return 0 end
  local extra = GAME.inflation or 0
  if edition then
    local ec = G.P_CENTERS["e_" .. edition]
    extra = extra + ((ec and tonumber(ec.extra_cost)) or EDITION_COST[edition] or 0)
  end
  return math.max(1, math.floor(((center.cost or 1) + extra + 0.5) * (100 - (GAME.discount_percent or 0)) / 100))
end

-- One card: SMODS.create_card(t) -> create_card(set, area, legendary, rarity, ..., soulable, key, key_append) with the
-- object weights off. `where` = "pack" | "shop" | "jokers" (where the real card would land: stickers roll only in the
-- shop and in packs). Marks the card as used, as Card:set_ability does, so the next card of the same pack / shelf
-- cannot repeat it. Returns a plain item: { set, key, name, edition, joker = GS.joker | card = GS.card, ... }.
local function make(spec, where, idx)
  local G = _G.G
  local GAME = G.GAME
  local ante = GAME.round_resets.ante
  local S = rawget(_G, "SMODS")
  local t = copy(spec)
  -- SMODS.create_card: setting an enhancement means "an Enhanced card with that key"
  if t.enhancement then t.key = t.enhancement; t.set = "Enhanced" end
  if not t.key and t.attributes then error("attribute polls are not modelled") end
  -- SMODS.create_card: playing cards (a pack/shop recipe passes front = false: the face is picked in create_card)
  if t.set == "Playing Card" or t.set == "Base" or t.set == "Enhanced" or (not t.set and (t.front or t.rank or t.suit)) then
    t.set = (not t.set or t.set == "Playing Card")
      and (t.key and "Enhanced" or (_G.pseudorandom("sccset" .. (t.key_append or "") .. ante) > (t.enhanced_poll or 0.6) and "Enhanced" or "Base"))
      or t.set or "Base"
    if t.front == nil then
      local r_suit, r_rank
      if not t.suit or not t.rank then
        r_suit = _G.pseudorandom_element(S.Suits, _G.pseudoseed("sccsuit" .. (t.key_append or "") .. ante)).card_key
        r_rank = _G.pseudorandom_element(S.Ranks, _G.pseudoseed("sccrank" .. (t.key_append or "") .. ante)).card_key
      end
      t.suit = t.suit and (S.Suits["" .. t.suit] or {}).card_key or t.suit or r_suit
      t.rank = t.rank and (S.Ranks["" .. t.rank] or {}).card_key or t.rank or r_rank
    end
    t.front = t.front or (t.suit and t.rank and (t.suit .. "_" .. t.rank)) or nil
  end
  local set_front = t.front and G.P_CARDS and G.P_CARDS[t.front] or nil

  -- create_card: The Soul / Black Hole (and Steamodded's modded legendaries) replace a card 0.3% of the time
  local _type, forced_key, key_append = t.set, t.key, t.key_append
  local banned = GAME.banned_keys or {}
  if not forced_key and t.soulable and not banned.c_soul then
    local legends = S and S.Consumable and S.Consumable.legendaries
    if type(legends) == "table" then
      local soul_total, non_soul, modded = 0, 1, {}
      for _, v in ipairs(legends) do
        if (_type == (v.type and v.type.key) or _type == v.soul_set)
          and not (GAME.used_jokers[v.key] and not showman(v.key) and not v.can_repeat_soul)
          and (type(S.add_to_pool) ~= "function" or S.add_to_pool(v)) then
          soul_total = soul_total + v.soul_rate
          non_soul = math.max(non_soul * (1 - v.soul_rate), 0)
          modded[#modded + 1] = v
        end
      end
      local roll = _G.pseudorandom("soul_smods_" .. _type .. ante)
      local threshold = 1
      for _, v in ipairs(modded) do
        threshold = threshold - v.soul_rate / soul_total * (1 - non_soul)
        if roll > threshold then forced_key = v.key; break end
      end
    end
    if (_type == "Tarot" or _type == "Spectral" or _type == "Tarot_Planet")
      and not (GAME.used_jokers.c_soul and not showman("c_soul")) then
      if _G.pseudorandom("soul_" .. _type .. ante) > 0.997 then forced_key = "c_soul" end
    end
    if (_type == "Planet" or _type == "Spectral")
      and not (GAME.used_jokers.c_black_hole and not showman("c_black_hole")) then
      if _G.pseudorandom("soul_" .. _type .. ante) > 0.997 then forced_key = "c_black_hole" end
    end
  end
  if _type == "Base" then forced_key = "c_base" end

  local key
  if forced_key and not banned[forced_key] then
    key = forced_key
    local c = G.P_CENTERS[key]
    _type = (c and c.set ~= "Default" and c.set) or _type
  else
    key = pick_from_pool(_type, t.rarity, t.legendary, key_append)
  end
  local center = G.P_CENTERS[key]
  if not center then error("unknown card " .. tostring(key)) end

  -- the face of a playing card
  local front = set_front
  if not front and (_type == "Base" or _type == "Enhanced") then
    front = _G.pseudorandom_element(G.P_CARDS, _G.pseudoseed("front" .. (key_append or "") .. ante))
  end

  local item = { set = center.set, key = key, soul = (key == "c_soul" or key == "c_black_hole") or nil }
  if center.set == "Joker" or _type == "Joker" then
    local mods = GAME.modifiers or {}
    local eternal = mods.all_eternal and center.eternal_compat and true or nil
    local perishable, rental
    if where == "shop" or where == "pack" then
      local poll = _G.pseudorandom((where == "pack" and "packetper" or "etperpoll") .. ante)
      if mods.enable_eternals_in_shop and poll > 0.7 then
        if center.eternal_compat then eternal = true end
      elseif mods.enable_perishables_in_shop and poll > 0.4 and poll <= 0.7 then
        if center.perishable_compat and not eternal then perishable = true end
      end
      if mods.enable_rentals_in_shop and _G.pseudorandom((where == "pack" and "packssjr" or "ssjr") .. ante) > 0.7 then
        rental = true
      end
    end
    local edition = short_edition(t.edition)
    if not (t.no_edition or t.edition) and type(_G.poll_edition) == "function" then
      edition = short_edition(_G.poll_edition("edi" .. (key_append or "") .. ante))
    end
    item.edition, item.eternal, item.perishable, item.rental = edition, eternal, perishable, rental
    item.legendary = (center.rarity == 4) or nil
    local ab = ability_of(center)
    ab.eternal, ab.perishable, ab.rental = eternal, perishable, rental
    item.name = Extract.loc_name("Joker", key, center.name)
    item.cost = price(center, edition, rental)
    item.joker = GS.joker{ id = -(idx or 1), key = key, name = item.name, edition = edition, ability = ab,
      cost = item.cost, rarity = center.rarity, sell_value = math.max(1, math.floor(item.cost / 2)) }
  elseif front then
    local enh = (key ~= "c_base") and key or nil
    local edition = short_edition(t.edition)
    item.edition = edition
    local rid = (S and S.Ranks and S.Ranks[front.value] and tonumber(S.Ranks[front.value].id)) or RANK_ID[front.value]
    item.card = GS.card{ id = -(idx or 1), rank = front.value, rank_id = rid, suit = front.suit,
      enhancement = enh, edition = edition, seal = t.seal }
    item.name = front.name or (tostring(front.value) .. " of " .. tostring(front.suit))
    item.cost = price(center, edition, false)
  else
    item.name = Extract.loc_name(center.set, key, center.name)
    item.cost = price(center, nil, false)
  end
  -- Card:set_ability: the card is now "out"
  if not G.OVERLAY_MENU then GAME.used_jokers[key] = true end
  return item
end
Peek._make = make   -- (tests)

-- ---- packs -------------------------------------------------------------------------------------------------------
local function booster_center(key)
  local G = _G.G
  local c = key and G.P_CENTERS[key]
  if not (c and c.set == "Booster") then return nil, "not_a_pack" end
  if not VANILLA_PACK[c.kind or ""] or c.original_mod then return nil, "modded_pack" end
  if type(c.create_card) ~= "function" then return nil, "no_recipe" end
  return c
end

-- The cards of a pack, in the order the game deals them, if it were opened NOW. `size` = the booster card's
-- ability.extra (defaults to the center's). Two packs of the same kind share their streams: the prediction is for the
-- one opened first.
function Peek.pack(key, size)
  local why = Peek.blocked()
  if why then return nil, why end
  local center, err = booster_center(key)
  if not center then return nil, err end
  local GAME = _G.G.GAME
  local extra = size or (center.config and center.config.extra) or 1
  local n = math.max(1, extra + ((GAME.modifiers and GAME.modifiers.booster_size_mod) or 0))
  return Peek.sandbox(function()
    -- the booster's own recipe (SMODS.Booster.create_card): it rolls Omen Globe, Telescope, the Standard pack's
    -- edition / seal / enhanced-or-not with the live streams, then hands back a spec for SMODS.create_card
    local fake = { ability = { extra = extra, choose = center.config and center.config.choose },
                   config = { center = center } }
    local out = {}
    for i = 1, n do
      local spec = center:create_card(fake, i)
      if type(spec) ~= "table" or type(spec.is) == "function" then error("pack recipe returned a card") end
      out[i] = make(spec, "pack", i)
    end
    return out
  end)
end

-- ---- the shop shelf ----------------------------------------------------------------------------------------------
-- Tags that create or replace a shop card (Rare / Uncommon) while they wait in G.GAME.tags.
local function pending_shop_tag()
  local G = _G.G
  for _, tag in ipairs(G.GAME.tags or {}) do
    local cfg = tag.config or {}
    if not tag.triggered and cfg.type == "store_joker_create" then return tag.key or tag.name or "tag" end
  end
  return nil
end
local function tutorial_shop()
  local G = _G.G
  local tp = G.SETTINGS and G.SETTINGS.tutorial_progress
  return tp and tp.forced_shop and tp.forced_shop[#tp.forced_shop] and true or false
end

-- One shelf card (create_card_for_shop): a type by the shop rates ('cdt'), Illusion's playing-card edition, the card.
local function shop_card(idx)
  local G = _G.G
  local GAME = G.GAME
  local ante = GAME.round_resets.ante
  local S = rawget(_G, "SMODS")
  local buffer = (S and S.ConsumableType and S.ConsumableType.obj_buffer) or { "Tarot", "Planet", "Spectral" }
  local total = (GAME.joker_rate or 0) + (GAME.playing_card_rate or 0)
  for _, v in ipairs(buffer) do total = total + (GAME[v:lower() .. "_rate"] or 0) end
  local polled = _G.pseudorandom(_G.pseudoseed("cdt" .. ante)) * total
  local illusion = GAME.used_vouchers and GAME.used_vouchers.v_illusion
  local rates = {
    { type = "Joker", val = GAME.joker_rate or 0 },
    { type = "Tarot", val = GAME.tarot_rate or 0 },
    { type = "Planet", val = GAME.planet_rate or 0 },
    { type = (illusion and _G.pseudorandom(_G.pseudoseed("illusion")) > 0.6) and "Enhanced" or "Base",
      val = GAME.playing_card_rate or 0 },
    { type = "Spectral", val = GAME.spectral_rate or 0 },
  }
  for _, v in ipairs(buffer) do
    if not (v == "Tarot" or v == "Planet" or v == "Spectral") then
      rates[#rates + 1] = { type = v, val = GAME[v:lower() .. "_rate"] or 0 }
    end
  end
  local check = 0
  for _, v in ipairs(rates) do
    if polled > check and polled <= check + v.val then
      local item = make({ set = v.type, key_append = "sho", front = false }, "shop", idx)
      if (v.type == "Base" or v.type == "Enhanced") and illusion and _G.pseudorandom(_G.pseudoseed("illusion")) > 0.8 then
        local ed = short_edition(_G.poll_edition("illusion", nil, true, true))
        item.edition = ed
        if item.card then item.card.edition = ed end
      end
      return item
    end
    check = check + v.val
  end
  error("no shop type matched")
end

-- The next `n` rerolls of the current shop: { [1] = { item, item }, [2] = {...}, ... }. A reroll first removes the
-- shelf (freeing each card for the pool again unless you own a copy), then deals G.GAME.shop.joker_max new cards.
function Peek.rerolls(n)
  local why = Peek.blocked()
  if why then return nil, why end
  local G = _G.G
  if tutorial_shop() then return nil, "tutorial" end
  local tag = pending_shop_tag()
  if tag then return nil, "tag" end
  return Peek.sandbox(function()
    local max = (G.GAME.shop and G.GAME.shop.joker_max) or 2
    for _, c in ipairs((G.shop_jokers and G.shop_jokers.cards) or {}) do
      release(c.config and c.config.center and c.config.center.key)
    end
    local out = {}
    for r = 1, n or 2 do
      local row = {}
      for i = 1, max do row[i] = shop_card(i) end
      out[r] = row
      for _, it in ipairs(row) do release(it.key) end
    end
    return out
  end)
end

-- The shelf of the NEXT shop (the one after the blind being played), before you get there: the same deal as a reroll,
-- on an empty shelf. `ante_up` = the shop comes after a Boss, when the ante has already gone up (its streams are the
-- next ante's). Cards that come or go before then (a tarot made and kept meanwhile) can change it; main.lua checks.
function Peek.next_shop(ante_up)
  local why = Peek.blocked()
  if why then return nil, why end
  local G = _G.G
  if tutorial_shop() then return nil, "tutorial" end
  if pending_shop_tag() then return nil, "tag" end
  return Peek.sandbox(function()
    if ante_up then G.GAME.round_resets.ante = G.GAME.round_resets.ante + 1 end
    local max = (G.GAME.shop and G.GAME.shop.joker_max) or 2
    local row = {}
    for i = 1, max do row[i] = shop_card(i) end
    return row
  end)
end

-- ---- skip tags -----------------------------------------------------------------------------------------------------
-- What a skip tag would hand over. Pack tags open a Mega (Ethereal: normal Spectral) pack at once; Top-up creates up
-- to 2 Commons at once; Rare / Uncommon put a free joker in the NEXT shop -- after the Big blind when you skip the
-- Small one (same ante), after the Boss when you skip the Big one (the ante has gone up by then).
Peek.TAG_PACK = { tag_buffoon = "p_buffoon_mega_1", tag_charm = "p_arcana_mega_1", tag_meteor = "p_celestial_mega_1",
                  tag_ethereal = "p_spectral_normal_1", tag_standard = "p_standard_mega_1" }
local TAG_JOKER = { tag_rare = { rarity = 1, append = "rta", where = "shop", n = 1 },
                    tag_uncommon = { rarity = 0.9, append = "uta", where = "shop", n = 1 },
                    tag_top_up = { rarity = 0, append = "top", where = "jokers", n = 2 } }

-- -> { kind = "pack", pack = key, items = {...} } | { kind = "jokers", items = {...}, next_shop = bool } | nil, why
function Peek.tag(tag_key, blind_on_deck)
  local why = Peek.blocked()
  if why then return nil, why end
  local pack = Peek.TAG_PACK[tag_key]
  if pack then
    local items, err = Peek.pack(pack)
    if not items then return nil, err end
    return { kind = "pack", pack = pack, items = items }
  end
  local tj = TAG_JOKER[tag_key]
  if not tj then return nil, "not_modelled" end
  local G = _G.G
  local items, err = Peek.sandbox(function()
    -- the shop after the Boss belongs to the next ante
    if tj.where == "shop" and blind_on_deck == "Big" then G.GAME.round_resets.ante = G.GAME.round_resets.ante + 1 end
    local n = tj.n
    if tj.where == "jokers" then   -- Top-up: only as many as fit
      local limit = (G.jokers and G.jokers.config and G.jokers.config.card_limit) or 5
      n = math.max(0, math.min(n, limit - #((G.jokers and G.jokers.cards) or {})))
    end
    local out = {}
    for i = 1, n do
      out[i] = make({ set = "Joker", rarity = tj.rarity, key_append = tj.append }, tj.where, i)
    end
    return out
  end)
  if not items then return nil, err end
  return { kind = "jokers", items = items, next_shop = (tj.where == "shop") }
end

-- ---- what a card will create when used -----------------------------------------------------------------------------
-- The Soul makes a Legendary ('sou'), Judgement a random joker ('jud'), Wraith a Rare one ('wra'), straight into your
-- jokers (card.lua Card:use_consumeable). Each reads its own streams, so the joker it would make NOW can be dealt.
Peek.CREATES = {
  c_soul = { set = "Joker", legendary = true, key_append = "sou" },
  c_judgement = { set = "Joker", key_append = "jud" },
  c_wraith = { set = "Joker", rarity = 0.99, key_append = "wra" },
}
function Peek.created(key)
  local why = Peek.blocked()
  if why then return nil, why end
  local spec = Peek.CREATES[key]
  if not spec then return nil, "not_modelled" end
  return Peek.sandbox(function() return make(spec, "jokers", 1) end)
end

-- ---- the next round's draw order ---------------------------------------------------------------------------------
-- When a round starts the game shuffles the deck ONCE: G.deck:shuffle('nr'..ante) -> pseudoshuffle(cards, seed), and
-- pseudoshuffle FIRST sorts the cards by sort_id, then swaps them with math.random seeded from the stream. So the
-- result does not depend on where the cards sit now -- only on WHICH cards are in the deck and on the stream's next
-- value. The whole draw order of the next round can therefore be dealt now, on a copy (the game's own pseudoshuffle,
-- in the sandbox). Returns the deck's cards (the game's card objects) in DRAW order, next first. Not when a Marble
-- Joker will slip a Stone card in when the blind is selected (that happens before the shuffle).
function Peek.next_round()
  if not live() then return nil, "no_game" end
  local G = _G.G
  if type(_G.pseudoshuffle) ~= "function" or not (G.deck and G.deck.cards) then return nil, "no_game" end
  if owned("j_marble") then return nil, "marble" end
  return Peek.sandbox(function()
    local list = {}
    for _, c in ipairs(G.deck.cards) do list[#list + 1] = c end
    for _, c in ipairs((G.hand and G.hand.cards) or {}) do list[#list + 1] = c end   -- a pack's hand goes back first
    _G.pseudoshuffle(list, _G.pseudoseed("nr" .. G.GAME.round_resets.ante))
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end   -- the game draws from the end
    return out
  end)
end

-- ---- comparing a prediction with what really came ----------------------------------------------------------------
-- A short signature per card: its key, and for a playing card its face.
function Peek.sig(item)
  if not item then return "?" end
  local c = item.card
  if c then return tostring(item.key) .. ":" .. tostring(c.suit) .. ":" .. tostring(c.rank_id) end
  return tostring(item.key)
end
function Peek.sigs(items)
  local out = {}
  for i, it in ipairs(items or {}) do out[i] = Peek.sig(it) end
  return out
end
-- The pack family a booster key belongs to ("p_arcana_mega_2" -> "p_arcana_mega"): the art variants share a recipe.
function Peek.family(key)
  return (tostring(key or ""):gsub("_%d+$", ""))
end

return Peek
