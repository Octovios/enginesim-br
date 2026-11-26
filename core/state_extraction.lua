-- core/state_extraction.lua
-- THE ONLY FILE THAT READS THE GLOBAL `G`.
-- Converts live Balatro game objects into the normalised GameState POD.
-- Every fragile field name lives here, so Steamodded/base-game API drift
-- touches exactly one file (see DESIGN.md Phase 7: field-name drift).
--
-- Field paths were verified against the Steamodded wiki + decompiled source
-- (June 2026). Items marked  -- VERIFY  should be re-confirmed against the
-- installed game version before relying on them.

local GS = require("model.game_state")

local Extract = {}

-- ---- low-level readers (defensive: tolerate nils so we never crash the game)

-- The blind the next blind-select offers, from G.GAME.round_resets.blind_states: the first of Small/Big/Boss not yet
-- Defeated/Skipped (the game's rule in create_UIBox_blind_select); all three done (just after the boss) -> "Small".
-- Pure (takes the states table), so it is unit-tested headless.
function Extract.next_blind_of(st)
  if type(st) ~= "table" then return nil end
  local function done(v) return v == "Defeated" or v == "Skipped" or v == "Hide" end
  return (not done(st.Small) and "Small") or (not done(st.Big) and "Big") or (not done(st.Boss) and "Boss") or "Small"
end

-- ---- (EngineSim BR) localized names ---------------------------------------------------------------------------
-- The engine's advice names cards by `name`. The game's own `ability.name` is the INTERNAL English name ("Death",
-- "Green Joker"), so a Portuguese player read "Use Death" for "A Morte". Ask the game's localization for the name it
-- shows (G.localization via localize{type = "name_text"}); fall back to the internal name. Cached per key + language.
local loc_cache, loc_lang = {}, nil
local function loc_name(set, key, fallback)
  if not key then return fallback end
  local G = _G.G
  local lang = G and G.SETTINGS and G.SETTINGS.language or "?"
  if lang ~= loc_lang then loc_cache, loc_lang = {}, lang end
  local ck = tostring(set) .. "|" .. key
  local hit = loc_cache[ck]
  if hit ~= nil then return hit or fallback end
  local out = false
  if type(_G.localize) == "function" then
    local tries = { set }
    if set == "Booster" then tries = { "Other", "Booster" } end
    for _, st in ipairs(tries) do
      local k = key
      if set == "Booster" and st == "Other" then k = key:gsub("_%d+$", "") end
      local ok, s = pcall(_G.localize, { type = "name_text", set = st, key = k })
      if ok and type(s) == "string" and s ~= "" and not s:find("ERROR") then out = s; break end
    end
  end
  loc_cache[ck] = out
  return out or fallback
end
Extract.loc_name = loc_name

-- The run's rules that the STAKE and the DECK change (engine/run_context reads these). -- VERIFY field paths
-- (game: Game:start_run applies the stake's modifiers; Back:apply_to_run the deck's; Blind:set_blind zeroes the
-- reward of a blind in G.GAME.modifiers.no_blind_reward).
local function read_run_rules(G, GAME, resets)
  local mods = GAME.modifiers or {}
  local sp = GAME.starting_params or {}
  local out = {}
  out.stake = tonumber(GAME.stake) or 1
  local skey
  if _G.SMODS and type(_G.SMODS.stake_from_index) == "function" then
    local ok, k = pcall(_G.SMODS.stake_from_index, out.stake)
    if ok and type(k) == "string" then skey = k end
  end
  if not skey then
    local pool = G.P_CENTER_POOLS and G.P_CENTER_POOLS.Stake
    local sc = pool and pool[out.stake]
    skey = sc and sc.key or nil
  end
  out.stake_key = skey
  out.stake_name = skey and loc_name("Stake", skey, nil) or nil
  out.scaling = tonumber(mods.scaling) or 1
  out.ante_scaling = tonumber(sp.ante_scaling) or 1
  if type(mods.no_blind_reward) == "table" then
    out.no_blind_reward = {}
    for k, v in pairs(mods.no_blind_reward) do if v then out.no_blind_reward[k] = true end end
  else
    out.no_blind_reward = {}
  end
  out.no_interest = mods.no_interest and true or false
  out.money_per_hand = tonumber(mods.money_per_hand) or 1
  out.money_per_discard = tonumber(mods.money_per_discard) or 0
  out.no_extra_hand_money = mods.no_extra_hand_money and true or nil
  out.interest_amount = tonumber(GAME.interest_amount) or 1
  out.eternals = mods.enable_eternals_in_shop and true or false
  out.perishables = mods.enable_perishables_in_shop and true or false
  out.rentals = mods.enable_rentals_in_shop and true or false
  out.no_faces = sp.no_faces and true or nil
  out.erratic = sp.erratic_suits_and_ranks and true or nil
  out.skips = tonumber(GAME.skips) or 0
  local back = GAME.selected_back
  local center = back and back.effect and back.effect.center
  out.deck_key = (center and center.key) or nil
  out.deck_name = out.deck_key and loc_name("Back", out.deck_key, back and back.name) or (back and back.name)
  out.balance_scoring = (out.deck_key == "b_plasma") or (back and back.name == "Plasma Deck") or false
  -- the money each blind of this ante pays when beaten, after the stake
  local rewards = {}
  for _, t in ipairs({ "Small", "Big", "Boss" }) do
    local bk = resets.blind_choices and resets.blind_choices[t]
    local bl = bk and G.P_BLINDS and G.P_BLINDS[bk]
    if bl and type(bl.dollars) == "number" then
      rewards[t] = out.no_blind_reward[t] and 0 or bl.dollars
    end
  end
  out.blind_rewards = rewards
  return out
end

local function read_card(c)
  if not c then return nil end
  local base = c.base or {}
  -- enhancement: the center key, e.g. "m_steel"; nil/"c_base" => no enhancement
  local enh = c.config and c.config.center and c.config.center.key
  if enh == "c_base" then enh = nil end
  -- edition: c.edition.type is the short string ("foil"/"holo"/...)
  local ed = c.edition and c.edition.type
  return GS.card{
    id          = c.sort_id or c.unique_val or nil,   -- VERIFY: stable id field
    rank        = base.value,                          -- "King", "Ace", ...
    rank_id     = base.id,                             -- 2..14
    suit        = base.suit,                           -- "Spades"...
    enhancement = enh,
    edition     = ed,
    seal        = c.seal,                              -- string or nil
    debuffed    = c.debuff or false,
    forced      = (c.ability and c.ability.forced_selection) and true or nil,  -- Cerulean Bell
  }
end

local function read_area(area)
  local out = {}
  if area and area.cards then
    for _, c in ipairs(area.cards) do
      local rc = read_card(c)
      if rc then out[#out + 1] = rc end
    end
  end
  return out
end

-- ROUND TARGETS (2026-10-17): The Idol / Ancient Joker / Castle / Mail-In Rebate re-pick their card, suit or rank each
-- round, and the game keeps it in G.GAME.current_round (idol_card / ancient_card / castle_card / mail_card), NOT in the
-- joker's ability (a live fixture's Idol ability is just extra = 2, Mail-In's extra = 5). The engine reads ability.id /
-- ability.suit / ability.mail_rank, so these jokers scored or targeted NOTHING live. Copied into a COPY of the ability
-- (the live table is never written).  -- VERIFY field names (functions/common_events.lua reset_idol_card etc.)
local ROUND_TARGET = { j_idol = "idol_card", j_ancient = "ancient_card", j_castle = "castle_card", j_mail = "mail_card" }
local function with_round_target(key, ab)
  local field = ROUND_TARGET[key]
  local G = _G.G
  local t = field and G and G.GAME and G.GAME.current_round and G.GAME.current_round[field]
  if type(t) ~= "table" then return ab end
  local out = {}
  for k, v in pairs(ab) do out[k] = v end
  if key == "j_mail" then out.mail_rank = t.id
  else
    if t.suit then out.suit = t.suit end
    if key == "j_idol" and t.id then out.id = t.id end
  end
  return out
end

local function read_joker(c, idx)
  if not c then return nil end
  local key = c.config and c.config.center and c.config.center.key
  local ab = with_round_target(key, c.ability or {})
  return GS.joker{
    id         = c.sort_id or c.unique_val,
    key        = key,  -- "j_blueprint"
    name       = loc_name("Joker", key, ab.name),   -- display name in the game's language (EngineSim BR)
    position   = idx,
    edition    = c.edition and c.edition.type,
    ability    = ab,
    sell_value = c.sell_cost,                           -- VERIFY
    cost       = c.cost,                                -- shop price  -- VERIFY
    rarity     = c.config and c.config.center and c.config.center.rarity,
    debuffed   = c.debuff and true or nil,                -- Crimson Heart disables one joker per hand
  }
end

local function read_jokers(area)
  local out = {}
  if area and area.cards then
    for i, c in ipairs(area.cards) do
      local rj = read_joker(c, i); if rj then out[#out + 1] = rj end
    end
  end
  return out
end

local function read_consumable(c)
  if not c then return nil end
  local center = c.config and c.config.center
  return GS.consumable{
    id  = c.sort_id or c.unique_val,
    key = center and center.key,
    set = center and center.set,                        -- "Tarot"/"Planet"/"Spectral"
    name = loc_name(center and center.set, center and center.key, c.ability and c.ability.name),
    edition = c.edition and c.edition.type,             -- Perkeo's Negative copies are free to use
  }
end

-- ---- public: snapshot G into a GameState ------------------------------------

function Extract.snapshot()
  local G = _G.G
  if not G or not G.GAME then return nil end
  local GAME = G.GAME

  -- jokers (ORDER-SIGNIFICANT)
  local jokers = {}
  if G.jokers and G.jokers.cards then
    for i, c in ipairs(G.jokers.cards) do jokers[#jokers + 1] = read_joker(c, i) end
  end

  -- consumables  (note in-game misspelling: G.consumeables)
  local consumables = {}
  if G.consumeables and G.consumeables.cards then
    for _, c in ipairs(G.consumeables.cards) do
      local rc = read_consumable(c); if rc then consumables[#consumables + 1] = rc end
    end
  end

  -- hand levels  ->  run.hand_levels[name] = { level, chips, mult }
  -- and the run's PLAY COUNTS  ->  run.hand_type_plays[name] = n.  The sim world has tracked
  -- these all along (for Supernova); the live extractor did not, so `BP.commitment_signals`
  -- earned-direction credit would have been silently dead in the actual mod while working in
  -- every batch. Same shape as sim/world.lua's `run.hand_type_plays`.  -- VERIFY field
  local hand_levels, hand_type_plays, hands_played = {}, {}, 0
  -- played_hand_types: the set of hand types played THIS BLIND (not the whole run). The boss
  -- play-legality filter (The Mouth: one hand type all round; The Eye: no repeats) needs it, and
  -- WITHOUT it the filter was silently INERT in the live game -- it only ever worked in the sim,
  -- which threads the state itself. The engine happily recommended a Two Pair after a Straight
  -- under The Mouth (both scoring 0 after the first) and lost the run (owner report 2026-08-31).
  -- Source is GAME.hands[name].played_this_round -- the exact field The Mouth's own debuff reads,
  -- reset by the game each round.  -- VERIFY field
  local played_hand_types = nil
  for name, h in pairs(GAME.hands or {}) do
    hand_levels[name] = { level = h.level, chips = h.chips, mult = h.mult }
    if (h.played or 0) > 0 then
      hand_type_plays[name] = h.played
      hands_played = hands_played + h.played
    end
    if (h.played_this_round or 0) > 0 then
      played_hand_types = played_hand_types or {}
      played_hand_types[name] = h.played_this_round
    end
  end

  -- blind
  local blind = GAME.blind or {}
  local cur = GAME.current_round or {}
  local resets = GAME.round_resets or {}

  -- offered skip tag for the current selectable blind (field path uncertain)
  local skip_tag = nil
  do
    local bt = resets.blind_tags or resets.tags   -- VERIFY: where skip tags live
    if type(bt) == "table" then
      local key = (GAME.blind_on_deck and bt[GAME.blind_on_deck]) or bt.Small or bt.Big
      skip_tag = (type(key) == "table") and key.key or key
    end
  end
  -- The Orbital tag levels ONE specific hand, chosen in advance and shown on the tag -- not your best hand.
  -- The game keeps it in G.GAME.orbital_choices[ante][blind] (functions/UI_definitions.lua). Without it the
  -- engine priced every Orbital as +3 levels to its BEST planet hand (owner 2026-09-23: skipped ante 2's Big
  -- blind for an Orbital valued ~$124 that then levelled a random hand).
  local skip_tag_hand = nil
  do
    local oc = GAME.orbital_choices and GAME.orbital_choices[resets.ante or 0]
    if type(oc) == "table" and GAME.blind_on_deck then skip_tag_hand = oc[GAME.blind_on_deck] end
    if type(skip_tag_hand) ~= "string" then skip_tag_hand = nil end
  end

  -- The blind the next blind-select offers: the first of Small/Big/Boss not yet Defeated/Skipped (the game's own rule,
  -- functions/UI_definitions.lua create_UIBox_blind_select). blind_on_deck still names the blind JUST played while the
  -- shop is open, so the shop reads this instead: after the Big blind it is "Boss" (the final shop of the win ante, see
  -- SA.final_shop); after the boss all three stay Defeated until the next select resets them -> "Small".
  local next_blind = Extract.next_blind_of(resets.blind_states)

  -- opened booster pack: read the revealed choices so we can value each one
  -- (jokers get measured). G.pack_cards holds the options while a pack is open.
  local pack = nil
  if G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then
    local items = {}
    for _, c in ipairs(G.pack_cards.cards) do
      local center = c.config and c.config.center
      local set = c.ability and c.ability.set
      local item = { set = set, key = center and center.key,
        name = loc_name(set, center and center.key, c.ability and c.ability.name) }
      if set == "Joker" then item.joker = read_joker(c)
      elseif set ~= "Tarot" and set ~= "Planet" and set ~= "Spectral" then
        item.card = read_card(c)   -- standard pack: a playing card
      end
      items[#items + 1] = item
    end
    pack = { items = items, picks_left = (GAME.pack_choices) or 1 }  -- VERIFY pack_choices
  end

  -- shop (only populated while ACTUALLY in the shop). The shop CardAreas keep
  -- their cards after you leave, so we must gate on the game STATE -- otherwise
  -- the assistant thinks you're shopping forever and stops evaluating blinds.
  -- read a shop "center" item (voucher / booster) as { key, name, cost }
  local function read_center(c)
    local center = c.config and c.config.center
    return {
      key = center and center.key,
      name = loc_name(center and center.set, center and center.key, c.ability and c.ability.name),
      cost = c.cost,
    }
  end
  local function read_centers(area)
    local out = {}
    if area and area.cards then for _, c in ipairs(area.cards) do out[#out + 1] = read_center(c) end end
    return out
  end

  local in_shop = G.STATES and G.STATE == G.STATES.SHOP
  local shop = nil
  if in_shop and (G.shop_jokers or G.shop_vouchers or G.shop_booster) then
    -- the main shop slots hold JOKERS *and* standalone tarots/planets/spectrals
    local sj, sc = {}, {}
    if G.shop_jokers and G.shop_jokers.cards then
      for i, c in ipairs(G.shop_jokers.cards) do
        local set = c.ability and c.ability.set
        if set == "Joker" then
          sj[#sj + 1] = read_joker(c, i)
        elseif set == "Tarot" or set == "Planet" or set == "Spectral" then
          local item = read_center(c); item.set = set
          sc[#sc + 1] = item
        end
      end
    end
    shop = {
      jokers      = sj,
      consumables = sc,                       -- tarots/planets/spectrals for sale
      vouchers    = read_centers(G.shop_vouchers),
      boosters    = read_centers(G.shop_booster),
      reroll_cost = GAME.current_round and GAME.current_round.reroll_cost,  -- VERIFY
      -- free rerolls remaining this shop (Chaos the Clown / Director's Cut). The
      -- game also zeroes reroll_cost while one is available, but extract the count
      -- too so the advisor never re-recommends a reroll once it's been spent. VERIFY
      free_rerolls = GAME.current_round and GAME.current_round.free_rerolls,
      joker_slots = (G.jokers and G.jokers.config and G.jokers.config.card_limit) or 5,
    }
  end

  local rules = read_run_rules(G, GAME, resets)

  return GS.new{
    meta = {
      ante = resets.ante,
      round = GAME.round,
      state = G.STATE and Extract.state_name(G.STATE) or tostring(G.STATE),
      in_blind_select = (G.STATES and G.STATE == G.STATES.BLIND_SELECT) or false,
      seed_hash = GAME.pseudorandom and GAME.pseudorandom.seed or "",
    },
    -- deck = the WHOLE deck, remaining = the undrawn pile -- the same split the sim's build_gs uses. Reading G.deck for
    -- both meant that mid-blind "the deck" was only the undrawn cards: Erosion counted every drawn/played card as missing
    -- (+4 Mult each; live 58TL2YMH scored 0.13-0.25x of prediction) and deck counters (Steel/Stone Joker, Driver's
    -- License, Cloud 9) missed the cards in hand. G.playing_cards is the whole deck wherever each card is.
    deck = (G.playing_cards and read_area({ cards = G.playing_cards })) or read_area(G.deck),
    remaining = read_area(G.deck),       -- undrawn live in G.deck after a draw
    hand = read_area(G.hand),
    jokers = jokers,
    consumables = consumables,
    economy = {
      dollars = GAME.dollars or 0,
      -- The live game stores the interest cap in DOLLARS (25/50/100); the whole engine (and the sim) works in
      -- INTEREST units (5/10/20, x5 = the max-interest bankroll). Read raw, live believed max interest needed
      -- $125 -- it hoarded and barely rerolled. Converting HERE makes live see exactly what the sim sees.
      -- Measured (2026-09-23): putting the live bug INTO the sim cost wins 28 -> 19 (19 vs 10 discordant,
      -- p~0.14) and progress -0.208 (p~0.06) on 160 paired seeds; 4-seed smoke: rerolls 22 -> 3, $61 -> $143
      -- hoarded. Owner decision: the sim outcome, not the winners' corpus, decides (the corpus had vetoed
      -- this twice). Values < 25 are already interest units and pass through.
      interest_cap = (function(c) c = c or 5; return (c >= 25) and math.floor(c / 5) or c end)(GAME.interest_cap),
    },
    blind = {
      name = blind.name or "",
      target_chips = blind.chips or 0,
      chips_scored = GAME.chips or 0,        -- running chips this round  -- VERIFY
      boss = blind.boss or false,
      blind_type = GAME.blind_on_deck,       -- "Small"|"Big"|"Boss"  -- VERIFY
      next_blind = next_blind,               -- the blind the next select offers (in the shop: the one after this)
      skip_tag = skip_tag,                    -- offered skip tag key  -- VERIFY
      skip_tag_name = skip_tag and loc_name("Tag", skip_tag, nil) or nil,   -- (EngineSim BR) as the game shows it
      skip_tag_hand = skip_tag_hand,          -- the hand an Orbital tag would level (nil if unknown)
      boss_effect_key = blind.config and blind.config.blind and blind.config.blind.key,
      reward = tonumber(blind.dollars),       -- what THIS blind pays when beaten (stake-adjusted by the game)
      played_hand_types = played_hand_types,  -- hand types played THIS blind (Mouth/Eye legality)
      hands_played_round = cur.hands_played,  -- hands played this round (first-hand lock, main.lua)  -- VERIFY field
      last_hand_played = GAME.last_hand_played, -- the most recent played hand type  -- VERIFY field
      hands_left = cur.hands_left or 0,
      discards_left = cur.discards_left or 0,
      discards_used = cur.discards_used,     -- this round (Burnt Joker: the FIRST discard levels its hand; card.lua:3214)
      base_hands = resets.hands or 0,
      base_discards = resets.discards or 0,
    },
    shop = shop,
    pack = pack,
    -- last Tarot/Planet used this run (what The Fool would copy)  -- VERIFY field
    last_tarot_planet = GAME.last_tarot_planet and { key = GAME.last_tarot_planet } or nil,
    run = {
      hand_levels = hand_levels,
      hand_type_plays = hand_type_plays,
      -- summed from the per-type counts rather than guessed at a GAME field: Loyalty Card
      -- (engine/joker_effects) has been reading 0 live for want of this.
      hands_played = hands_played,
      vouchers_owned = GAME.used_vouchers or {},
      tags = GAME.tags or {},
      deck_back = GAME.selected_back and GAME.selected_back.name,
      hand_size = (G.hand and G.hand.config and G.hand.config.card_limit) or 8,  -- VERIFY
      consumable_slots = (G.consumeables and G.consumeables.config and G.consumeables.config.card_limit) or 2,
      joker_slots = (G.jokers and G.jokers.config and G.jokers.config.card_limit) or 5,
      -- the UPCOMING boss of this ante (so shop/sim can adapt). Boss is chosen at
      -- ante start and visible from blind select.  -- VERIFY field path
      boss_key = (resets.blind_choices and resets.blind_choices.Boss)
        or (GAME.round_resets and GAME.round_resets.blind_choices and GAME.round_resets.blind_choices.Boss),
      -- (EngineSim BR) stake + deck rules: engine/run_context
      stake = rules.stake, stake_key = rules.stake_key, stake_name = rules.stake_name,
      scaling = rules.scaling, ante_scaling = rules.ante_scaling,
      no_blind_reward = rules.no_blind_reward, blind_rewards = rules.blind_rewards,
      no_interest = rules.no_interest, money_per_hand = rules.money_per_hand,
      money_per_discard = rules.money_per_discard, no_extra_hand_money = rules.no_extra_hand_money,
      interest_amount = rules.interest_amount,
      eternals = rules.eternals, perishables = rules.perishables, rentals = rules.rentals,
      no_faces = rules.no_faces, erratic = rules.erratic, skips = rules.skips,
      deck_key = rules.deck_key, deck_name = rules.deck_name, balance_scoring = rules.balance_scoring,
    },
  }
end

-- (EngineSim BR) Teach util/i18n the game's names in the player's language: every joker, tarot, planet, spectral,
-- voucher, booster, enhancement, edition, deck, stake, tag and blind (internal English name -> shown name), plus the
-- poker hands and suits. The advice text is built with the internal names; util/i18n swaps them on the way to the
-- panel. Returns how many names were registered (0 outside the game).
function Extract.register_names(I18N)
  local G = _G.G
  if not (G and I18N and type(_G.localize) == "function") then return 0 end
  local n = 0
  local function reg(en, loc)
    if type(en) == "string" and type(loc) == "string" and loc ~= "" and not loc:find("ERROR") then
      I18N.register_name(en, loc); n = n + 1
    end
  end
  local SETS = { Joker = true, Tarot = true, Planet = true, Spectral = true, Voucher = true, Booster = true,
                 Enhanced = true, Edition = true, Back = true }
  for key, c in pairs(G.P_CENTERS or {}) do
    if type(c) == "table" and type(c.name) == "string" and SETS[c.set] then
      -- "Mult" / "Bonus" (enhancements) and "Base" (edition) are also everyday scoring words ("+3 Mult"):
      -- registering them would rewrite those words, so only the unambiguous "... Card" names go in
      local ambiguous = (c.set == "Enhanced" and not c.name:find(" Card$")) or (c.set == "Edition" and c.name == "Base")
      if not ambiguous and #c.name >= 3 then reg(c.name, loc_name(c.set, key, nil)) end
    end
  end
  for key, t in pairs(G.P_TAGS or {}) do
    if type(t) == "table" and t.name then reg(t.name, loc_name("Tag", key, nil)) end
  end
  for key, b in pairs(G.P_BLINDS or {}) do
    if type(b) == "table" and b.name then reg(b.name, loc_name("Blind", key, nil)) end
  end
  for key, st in pairs(G.P_STAKES or {}) do
    if type(st) == "table" and st.name then reg(st.name, loc_name("Stake", key, nil)) end
  end
  local hands = { "Flush Five", "Flush House", "Five of a Kind", "Straight Flush", "Four of a Kind", "Full House",
                  "Flush", "Straight", "Three of a Kind", "Two Pair", "Pair", "High Card" }
  for _, h in ipairs(hands) do
    local ok, s = pcall(_G.localize, h, "poker_hands")
    if ok then reg(h, s) end
  end
  for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    local ok, s = pcall(_G.localize, su, "suits_plural")
    if ok then reg(su, s) end
  end
  return n
end

-- ---- (EngineSim BR) SEER MODE: peeking at the run's future ---------------------------------------------------------
-- Every chance check in Balatro reads a NAMED stream: pseudorandom('lucky_mult') advances only
-- G.GAME.pseudorandom['lucky_mult'] (pseudoseed steps that one number) and then seeds math.random with it. So the
-- next values of a stream can be read by calling the game's own pseudorandom() a few times and putting the stream's
-- number back: the game will produce exactly those values, in that order, when it next checks. A stream the game has
-- not used yet is nil; restoring nil lets the game create it from the seed later, identically.
-- (math.random's own state is re-seeded on every game call, so re-seeding it here changes nothing the game uses.)
Extract.SEER_STREAMS = {
  { key = "lucky_mult", n = 8 },  { key = "lucky_money", n = 8 },
  { key = "misprint", n = 4, min = 0, max = 23 },
  { key = "bloodstone", n = 8 }, { key = "business", n = 8 }, { key = "parking", n = 8 },
  { key = "glass", n = 6 },       { key = "wheel_of_fortune", n = 3 },
  { key = "gros_michel", n = 2 }, { key = "cavendish", n = 2 },
  { key = "8ball", n = 4 },       { key = "space", n = 4 },
}
function Extract.peek_rolls(streams)
  local G = _G.G
  if not (G and G.GAME and type(G.GAME.pseudorandom) == "table" and type(_G.pseudorandom) == "function") then return nil end
  local pr = G.GAME.pseudorandom
  local out = { normal = (G.GAME.probabilities and G.GAME.probabilities.normal) or 1 }
  for _, st in ipairs(streams or Extract.SEER_STREAMS) do
    local saved = pr[st.key]
    local vals = {}
    local ok = pcall(function()
      for i = 1, st.n do vals[i] = _G.pseudorandom(st.key, st.min, st.max) end
    end)
    pr[st.key] = saved                     -- put the stream back exactly where it was
    if ok then out[st.key] = vals end
  end
  return out
end

-- The NEXT ante's boss (experimental): the game's own get_new_boss() as it will run when this ante's boss falls --
-- with the ante set one higher -- then every bit of state it touches is put back (the 'boss' stream, the
-- bosses-used counts, a prescribed boss, the ante). A Boss Tag / Director's Cut reroll in between changes it.
function Extract.peek_next_boss()
  local G = _G.G
  if not (G and G.GAME and G.GAME.round_resets and type(_G.get_new_boss) == "function") then return nil end
  local GAME = G.GAME
  local rr = GAME.round_resets
  local ante = rr.ante
  local pr = GAME.pseudorandom or {}
  local saved_boss = pr.boss
  local used = {}
  for k, v in pairs(GAME.bosses_used or {}) do used[k] = v end
  local presc = GAME.perscribed_bosses and GAME.perscribed_bosses[(ante or 0) + 1]
  local key
  local ok = pcall(function()
    rr.ante = (ante or 0) + 1
    key = _G.get_new_boss()
  end)
  rr.ante = ante                                           -- restore everything, success or not
  pr.boss = saved_boss
  if GAME.bosses_used then
    for k in pairs(GAME.bosses_used) do GAME.bosses_used[k] = used[k] end
  end
  if GAME.perscribed_bosses then GAME.perscribed_bosses[(ante or 0) + 1] = presc end
  if not ok or type(key) ~= "string" then return nil end
  return { key = key, name = loc_name("Blind", key, G.P_BLINDS and G.P_BLINDS[key] and G.P_BLINDS[key].name), ante = (ante or 0) + 1 }
end

-- Is a run on screen (not the main menu)?
function Extract.in_run()
  local G = _G.G
  return (G and G.STAGES and G.STAGE == G.STAGES.RUN) and true or false
end

-- The game's language code ("pt_BR", "en-us", ...), or nil outside the game.
function Extract.game_language()
  local G = _G.G
  return G and G.SETTINGS and G.SETTINGS.language or nil
end

-- The WHOLE deck (G.playing_cards), wherever each card currently is. gs.deck is G.deck, the undrawn pile, which at
-- a blind or ante boundary is missing the cards in hand / played / discarded -- telemetry measured capacity on that
-- partial pile and read live boards as weaker than they are (live-vs-sim audit 2026-09-28). nil when unavailable.
function Extract.full_deck()
  local G = _G.G
  if not (G and G.playing_cards) then return nil end
  return read_area({ cards = G.playing_cards })
end

-- Map G.STATE numeric ids to readable names where possible.
function Extract.state_name(state_id)
  local G = _G.G
  if G and G.STATES then
    for name, id in pairs(G.STATES) do if id == state_id then return name end end
  end
  return tostring(state_id)
end

return Extract
