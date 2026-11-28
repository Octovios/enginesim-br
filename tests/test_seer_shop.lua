-- tests/test_seer_shop.lua  (EngineSim BR)
-- Seer mode, level 3: the cards inside a pack and the next shop rerolls, predicted by replaying the game's recipe in a
-- sandbox (core/seer_peek). Against a stand-in game (tests/standin_game.lua): the prediction must leave the run's
-- streams and used-card list exactly as they were, and must equal what the "game" then really deals.
-- Then the advisors: a known pack is valued by its real picks, a known reroll by the joker it really brings, a skip
-- tag by what it really gives.

local GS = require("model.game_state")
local Standin = require("tests.standin_game")

local function snapshot(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end
local function same_table(a, b)
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k, v in pairs(b) do if a[k] ~= v then return false end end
  return true
end
local function join(list) return table.concat(list, ",") end

return function(t)
  local saved_G = rawget(_G, "G")
  local G = { GAME = { pseudorandom = { seed = "TEST" }, round_resets = { ante = 1 } } }
  _G.G = G
  package.loaded["core.seer_peek"] = nil
  local Peek = require("core.seer_peek")
  local uninstall = Standin.install(G)
  local ok, err = pcall(function()
    -- ---- a pack: predicted, nothing disturbed, then dealt for real -------------------------------------------------
    for _, key in ipairs({ "p_arcana_normal_1", "p_arcana_mega_1", "p_buffoon_mega_1", "p_standard_normal_1",
                           "p_spectral_normal_1", "p_celestial_normal_1" }) do
      local pr0, uj0 = snapshot(G.GAME.pseudorandom), snapshot(G.GAME.used_jokers)
      local items, why = Peek.pack(key)
      t.ok(items ~= nil, "seer pack: " .. key .. " predicted (" .. tostring(why) .. ")")
      t.ok(same_table(G.GAME.pseudorandom, pr0), "seer pack: " .. key .. " leaves every stream as it was")
      t.ok(same_table(G.GAME.used_jokers, uj0), "seer pack: " .. key .. " leaves the used-card list as it was")
      local again = Peek.pack(key)
      t.eq(join(Peek.sigs(again or {})), join(Peek.sigs(items or {})), "seer pack: " .. key .. " predicts the same twice")
      local real = Standin.real_open(key)
      t.eq(join(Peek.sigs(items or {})), join(Standin.card_sigs(real)), "seer pack: " .. key .. " is what the game deals")
      -- the dealt cards go away again (the pack closes) -- free them for the next pack, as the game does
      for _, c in ipairs(real) do G.GAME.used_jokers[c.config.center.key] = nil end
    end

    -- the check can fail: a stream the game uses between the prediction and the deal changes the deal
    do
      G.GAME.round_resets.ante = 9
      Standin.FORCE["soul_Tarot9"] = { [2] = 0.999 }          -- the stream's 2nd roll is a Soul
      local items = Peek.pack("p_arcana_normal_1")
      t.eq(items and items[2].key, "c_soul", "seer pack: (the Soul comes second)")
      pseudoseed("soul_Tarot9")                               -- something else rolled that stream meanwhile
      local real = Standin.real_open("p_arcana_normal_1")
      t.eq(real[1].config.center.key, "c_soul", "seer pack: (now the game deals it first)")
      t.ok(join(Peek.sigs(items or {})) ~= join(Standin.card_sigs(real)), "seer pack: a deal from a moved stream differs (the check would see it)")
      for _, c in ipairs(real) do G.GAME.used_jokers[c.config.center.key] = nil end
      Standin.FORCE = {}
    end

    -- no card twice in one pack: a 4-joker pack from a 4-common pool holds 4 different jokers
    do
      G.GAME.round_resets.ante = 3   -- fresh streams
      local items = Peek.pack("p_buffoon_mega_1")
      local seen, dup = {}, false
      for _, it in ipairs(items or {}) do
        if seen[it.key] then dup = true end
        seen[it.key] = true
      end
      t.ok(items and #items == 4 and not dup, "seer pack: a pack never repeats a card (each one is marked out)")
      t.ok(items and items[1].joker and items[1].joker.key == items[1].key, "seer pack: a joker comes as a GS joker")
      t.ok(items and items[1].joker and type(items[1].joker.ability) == "table", "seer pack: ... with its ability table")
    end

    -- The Soul: forced in the first card's roll; the pack holds it once, and the next cards do not even roll for it
    do
      G.GAME.round_resets.ante = 4
      Standin.FORCE["soul_Tarot4"] = { [1] = 0.999, [2] = 0.999, [3] = 0.999 }
      local items = Peek.pack("p_arcana_normal_1")
      local souls = 0
      for _, it in ipairs(items or {}) do if it.key == "c_soul" then souls = souls + 1 end end
      t.eq(items and items[1].key, "c_soul", "seer pack: The Soul's roll hits on the first card")
      t.eq(souls, 1, "seer pack: ... and only there (once it is out, the next cards skip the roll)")
      t.ok(items and items[1].soul, "seer pack: The Soul is flagged for the panel")
      local real = Standin.real_open("p_arcana_normal_1")
      t.eq(join(Peek.sigs(items or {})), join(Standin.card_sigs(real)), "seer pack: the game deals the same Soul pack")
      t.eq(G.GAME.pseudorandom["soul_Tarot4"], 1, "seer pack: (the game rolled for the Soul once, as predicted)")
      for _, c in ipairs(real) do G.GAME.used_jokers[c.config.center.key] = nil end
      Standin.FORCE = {}
    end

    -- Omen Globe: an Arcana card can be a Spectral (its own stream)
    do
      G.GAME.round_resets.ante = 5
      G.GAME.used_vouchers.v_omen_globe = true
      Standin.FORCE["omen_globe"] = { [1] = 0.9 }
      local items = Peek.pack("p_arcana_normal_1")
      t.eq(items and items[1].set, "Spectral", "seer pack: Omen Globe turns the first Arcana card into a Spectral")
      local real = Standin.real_open("p_arcana_normal_1")
      t.eq(join(Peek.sigs(items or {})), join(Standin.card_sigs(real)), "seer pack: ... as the game does")
      for _, c in ipairs(real) do G.GAME.used_jokers[c.config.center.key] = nil end
      G.GAME.used_vouchers.v_omen_globe = nil
      Standin.FORCE = {}
    end

    -- a playing card carries its face, edition and seal
    do
      G.GAME.round_resets.ante = 6
      Standin.FORCE["stdseal6"] = { [1] = 0.99 }
      Standin.FORCE["standard_edition6"] = { [1] = 0.999 }
      local items = Peek.pack("p_standard_normal_1")
      local c = items and items[1] and items[1].card
      t.ok(c and c.suit and c.rank_id, "seer pack: a Standard card has its suit and rank")
      t.ok(c and c.seal ~= nil, "seer pack: ... its seal")
      t.ok(c and c.edition ~= nil, "seer pack: ... and its edition")
      Standin.FORCE = {}
    end

    -- what the seer will not guess
    t.eq(select(2, Peek.pack("p_modded_1")), "modded_pack", "seer pack: a modded pack is not predicted")
    SMODS.optional_features.object_weights = true
    t.eq(select(2, Peek.pack("p_arcana_normal_1")), "weights", "seer pack: not with Steamodded's object weights on")
    SMODS.optional_features.object_weights = nil

    -- ---- the shop: the next rerolls ---------------------------------------------------------------------------------
    do
      G.GAME.round_resets.ante = 2
      -- the shelf holds a Blueprint (out) and a tarot
      G.shop_jokers.cards = { Standin.new_card(G.P_CENTERS.j_blueprint), Standin.new_card(G.P_CENTERS.c_death) }
      G.GAME.used_jokers.j_blueprint, G.GAME.used_jokers.c_death = true, true
      local pr0, uj0 = snapshot(G.GAME.pseudorandom), snapshot(G.GAME.used_jokers)
      local rr = Peek.rerolls(3)
      t.ok(rr and #rr == 3 and #rr[1] == 2, "seer shop: three rerolls of two cards predicted")
      t.ok(same_table(G.GAME.pseudorandom, pr0) and same_table(G.GAME.used_jokers, uj0),
        "seer shop: predicting rerolls changes nothing")
      for r = 1, 3 do
        local real = Standin.real_reroll()
        t.eq(join(Peek.sigs(rr and rr[r] or {})), join(Standin.card_sigs(real)), "seer shop: reroll " .. r .. " is what the game deals")
      end
      t.ok(rr and rr[1][1].cost ~= nil, "seer shop: a predicted card has its price")
      -- the next shop, seen from the round before it: the same deal on an empty shelf (after a Boss: the next ante)
      G.shop_jokers.cards = {}
      local ns = Peek.next_shop(false)
      local ns_up = Peek.next_shop(true)
      t.eq(G.GAME.round_resets.ante, 2, "seer shop: looking past the Boss puts the ante back")
      local real = {}
      for i = 1, 2 do real[i] = Standin.real_shop_card() end
      t.eq(join(Peek.sigs(ns or {})), join(Standin.card_sigs(real)), "seer shop: the next shop is what the game deals")
      for _, c in ipairs(real) do G.GAME.used_jokers[c.config.center.key] = nil end   -- (that shelf is gone again)
      G.GAME.round_resets.ante = 3
      local real_up = {}
      for i = 1, 2 do real_up[i] = Standin.real_shop_card() end
      t.eq(join(Peek.sigs(ns_up or {})), join(Standin.card_sigs(real_up)), "seer shop: ... and after a Boss, the next ante's shop")
      G.GAME.round_resets.ante = 2
      for _, c in ipairs(real_up) do G.GAME.used_jokers[c.config.center.key] = nil end
      -- a pending Rare tag would replace a slot: no prediction
      G.GAME.tags = { { key = "tag_rare", config = { type = "store_joker_create" } } }
      t.eq(select(2, Peek.rerolls(2)), "tag", "seer shop: a pending shop tag turns the reroll prediction off")
      t.eq(select(2, Peek.next_shop(false)), "tag", "seer shop: ... and the next-shop prediction")
      G.GAME.tags = {}
    end

    -- ---- what The Soul / Judgement / Wraith will create -------------------------------------------------------------
    do
      G.GAME.round_resets.ante = 2
      local pr0 = snapshot(G.GAME.pseudorandom)
      local soul = Peek.created("c_soul")
      t.ok(soul and soul.joker and soul.joker.rarity == 4, "seer creates: The Soul's Legendary is dealt")
      t.ok(same_table(G.GAME.pseudorandom, pr0), "seer creates: ... without moving a stream")
      local real = Standin.real_create_card("Joker", "jokers", true, nil, nil, nil, nil, "sou")
      t.eq(soul and soul.key, real.config.center.key, "seer creates: ... and it is the one the game makes")
      G.GAME.used_jokers[real.config.center.key] = nil
      local wraith = Peek.created("c_wraith")
      t.eq(wraith and wraith.joker and wraith.joker.rarity, 3, "seer creates: Wraith makes a Rare")
      local jud = Peek.created("c_judgement")
      local real_j = Standin.real_create_card("Joker", "jokers", nil, nil, nil, nil, nil, "jud")
      t.eq(jud and jud.key, real_j.config.center.key, "seer creates: Judgement's joker is the one the game makes")
      G.GAME.used_jokers[real_j.config.center.key] = nil
      t.eq(select(2, Peek.created("c_fool")), "not_modelled", "seer creates: other cards are not modelled")
    end

    -- ---- the next round's opening hand --------------------------------------------------------------------------------
    do
      G.GAME.round_resets.ante = 3
      local deck, n = {}, 0
      for _, f in ipairs({ "H_K", "S_A", "D_7", "C_2", "H_T" }) do
        for copy = 1, 3 do
          n = n + 1
          local c = Standin.new_card(G.P_CENTERS.c_base, G.P_CARDS[f])
          c.sort_id = 100 + n
          deck[#deck + 1] = c
        end
      end
      G.deck = { cards = deck }
      G.hand = { cards = {} }
      local pr0 = snapshot(G.GAME.pseudorandom)
      local order = Peek.next_round()
      t.ok(order and #order == 15, "seer round: the whole next-round order is dealt")
      t.ok(same_table(G.GAME.pseudorandom, pr0), "seer round: ... without moving the shuffle stream")
      -- the order the cards sit in now does not matter (the game sorts by sort_id before shuffling)
      local rev = {}
      for i = #deck, 1, -1 do rev[#rev + 1] = deck[i] end
      G.deck.cards = rev
      local order2 = Peek.next_round()
      local same = true
      for i = 1, 15 do if order[i] ~= order2[i] then same = false end end
      t.ok(same, "seer round: the prediction does not depend on the deck's current order")
      local hand = Standin.real_round_start(5)
      local first = {}
      for i = 1, 5 do first[order[i]] = true end
      local all = true
      for _, c in ipairs(hand) do if not first[c] then all = false end end
      t.ok(all, "seer round: the game's opening hand is the predicted first five")
      t.eq(hand[1], order[1], "seer round: ... the first card drawn is the predicted next card")
      G.jokers.cards = { Standin.new_card({ key = "j_marble", set = "Joker", name = "Marble Joker" }) }
      t.eq(select(2, Peek.next_round()), "marble", "seer round: not with a Marble Joker (it adds a Stone card first)")
      G.jokers.cards = {}
      G.deck, G.hand = nil, nil
    end

    -- ---- skip tags ----------------------------------------------------------------------------------------------------
    do
      G.GAME.round_resets.ante = 7
      local tp = Peek.tag("tag_charm", "Small")
      t.ok(tp and tp.kind == "pack" and tp.pack == "p_arcana_mega_1" and #tp.items == 5, "seer tag: Charm opens a Mega Arcana of 5")
      local rare_small = Peek.tag("tag_rare", "Small")
      local rare_big = Peek.tag("tag_rare", "Big")
      t.ok(rare_small and rare_small.kind == "jokers" and rare_small.next_shop and #rare_small.items == 1,
        "seer tag: a Rare tag gives one joker in the next shop")
      t.eq(rare_small and rare_small.items[1].joker and rare_small.items[1].joker.rarity, 3, "seer tag: ... a Rare one")
      t.eq(G.GAME.round_resets.ante, 7, "seer tag: the ante is put back after looking one ante ahead")
      t.ok(rare_big ~= nil, "seer tag: skipping the Big blind looks at the shop after the Boss (next ante)")
      local topup = Peek.tag("tag_top_up", "Small")
      t.ok(topup and #topup.items == 2 and topup.items[1].joker.rarity == 1, "seer tag: Top-up gives two Commons")
      G.jokers.cards = { {}, {}, {}, {} }      -- one slot free
      topup = Peek.tag("tag_top_up", "Small")
      t.eq(topup and #topup.items, 1, "seer tag: ... only as many as fit")
      G.jokers.cards = {}
      t.eq(select(2, Peek.tag("tag_investment", "Small")), "not_modelled", "seer tag: an economy tag has nothing to predict")
    end
  end)
  t.ok(ok, "seer shop suite ran: " .. tostring(err))
  uninstall()
  _G.G = saved_G

  -- ---- the advisors, when the contents are known ----------------------------------------------------------------------
  local Packs = require("engine.packs")
  local SA = require("engine.shop_advisor")
  local Tags = require("engine.tags")
  local Rng = require("util.rng")
  local deck = {}
  local n = 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for r = 2, 14 do n = n + 1; deck[n] = GS.card{ id = n, rank_id = r, suit = s } end
  end
  local function base_gs(extra)
    local g = GS.new{ deck = deck, remaining = deck, jokers = {}, economy = { dollars = 30, interest_cap = 5 },
      meta = { ante = 2, round = 4, state = "SHOP", seed_hash = "T" },
      run = { hand_levels = { Pair = { level = 1, chips = 10, mult = 2 }, Flush = { level = 1, chips = 35, mult = 4 },
        ["High Card"] = { level = 1, chips = 5, mult = 1 } }, hand_size = 8, joker_slots = 5, consumable_slots = 2 } }
    for k, v in pairs(extra or {}) do g[k] = v end
    return g
  end
  local function joker_item(key, name, cost, edition)
    return { set = "Joker", key = key, name = name, cost = cost, edition = edition,
      joker = GS.joker{ id = -1, key = key, name = name, cost = cost, edition = edition, ability = { extra = {} } } }
  end
  local function tarot_item(key, name) return { set = "Tarot", key = key, name = name } end

  do
    local g = base_gs()
    local pk = { key = "p_buffoon_normal_1", name = "Buffoon Pack", cost = 4,
      seer = { pack = "p_buffoon_normal_1", items = { joker_item("j_joker", "Joker", 2), joker_item("j_baron", "Baron", 8) } } }
    local v, note, known = Packs.value(g, pk, { rng = Rng.fixed() })
    t.ok(known == true, "seer value: a pack with known contents is valued from them")
    t.ok(type(v) == "number" and v >= 0, "seer value: ... a number")
    t.ok(type(note) == "string" and note:find("seer", 1, true) ~= nil, "seer value: ... and says what you would take")
    local _, rec, names = Packs.known_value(g, pk, { rng = Rng.fixed() })
    t.ok(rec and #names == 1, "seer value: a normal pack takes one card")
    -- the items given to the valuation are copies (the pack advisor renames cards)
    t.eq(pk.seer.items[1].name, "Joker", "seer value: the predicted items are not modified")
    -- unknown contents: the old pool average
    local _, _, k2 = Packs.value(g, { key = "p_buffoon_normal_1", name = "Buffoon Pack", cost = 4 }, { rng = Rng.fixed() })
    t.ok(not k2, "seer value: without a prediction the pool average is used")
  end

  do
    local g = base_gs()
    local junk = { tarot_item("c_hermit", "The Hermit"), tarot_item("c_strength", "Strength") }
    local function S(rerolls, dollars)
      g.economy.dollars = dollars or 30
      return { gs = g, rng = Rng.fixed(), credit = 0, pace = nil,
        shop = { seer_rerolls = rerolls, free_rerolls = 0, reroll_cost = 5 } }
    end
    local best, r, it = SA._seer_reroll_best(S({ junk, { joker_item("j_baron", "Baron", 8), tarot_item("c_fool", "The Fool") } }), 5)
    t.ok(it and it.key == "j_baron" and r == 2, "seer reroll: the joker two rerolls away is found")
    t.ok(best and best > 0, "seer reroll: ... with a positive value")
    local b2 = SA._seer_reroll_best(S({ junk, junk }), 5)
    t.eq(b2, 0, "seer reroll: nothing but tarots -> nothing to reroll for")
    local _, _, it3 = SA._seer_reroll_best(S({ { joker_item("j_baron", "Baron", 8) } }, 10), 5)
    t.eq(it3, nil, "seer reroll: a joker you could not afford after the reroll does not count")
    t.eq(SA._seer_reroll_best({ gs = g, shop = {} }, 5), nil, "seer reroll: no prediction -> the usual estimate")
  end

  do
    local CV = require("engine.consumable_value")
    local g = base_gs()
    local need = require("engine.mechanics").boss_per_hand_need(g)
    t.eq(CV.seer_joker_frac(g, "c_soul", need, Rng.fixed()), nil, "seer creates value: no prediction -> nothing known")
    g.seer_created = { c_soul = joker_item("j_perkeo", "Perkeo", 20) }
    local kv, kit = CV.seer_joker_frac(g, "c_soul", need, Rng.fixed())
    t.ok(type(kv) == "number" and kv >= 0 and kit and kit.key == "j_perkeo", "seer creates value: the known Legendary is valued")
    -- (the same measurement twice: equal up to its sampling noise -- the first call warms the board caches)
    t.near(CV.soul_value(g, need, { rng = Rng.fixed() }), kv, "seer creates value: The Soul is worth that very joker", 0.05)
    local v, _, note = CV.card_value(g, "Spectral", "c_soul", nil, need, Rng.fixed())
    t.ok(type(v) == "number" and type(note) == "string" and note:find("Perkeo", 1, true) ~= nil,
      "seer creates value: ... and the note names it")
    -- a created joker whose worth comes back through the creating card must not loop (live 2026-11-28: Judgement
    -- would make 8 Ball, 8 Ball is worth the random Tarots it makes, Judgement is one of them -> "stack overflow")
    local ball = joker_item("j_8_ball", "8 Ball", 5)
    ball.joker.ability = { extra = 4 }
    g.seer_created = { c_judgement = ball }
    local okj, vj, _, nj = pcall(CV.card_value, g, "Tarot", "c_judgement", nil, need, Rng.fixed())
    t.ok(okj and type(vj) == "number", "seer creates value: Judgement -> 8 Ball -> Tarots -> Judgement does not loop ("
      .. tostring(okj and "" or vj):sub(1, 80) .. ")")
    t.ok(okj and type(nj) == "string" and nj:find("8 Ball", 1, true) ~= nil, "seer creates value: ... and still uses the prediction")
    t.ok(pcall(Packs.mean_random, g, "Tarot", { rng = Rng.fixed() }), "seer creates value: ... nor does the average Tarot")
    local inner = require("engine.seer").inner(g)
    t.ok(inner.seer_inner and inner.seer_created == nil and inner.deck == g.deck, "seer inner view: no predictions, same state")
    t.eq(require("engine.seer").inner(g), inner, "seer inner view: one per state (the engine's caches keep working)")
    t.eq(CV.seer_joker_frac(inner, "c_judgement", need, Rng.fixed()), nil, "seer inner view: no prediction used inside")
  end

  do
    local g = base_gs({ blind = { skip_tag = "tag_charm", skip_tag_seer = { tag = "tag_charm", kind = "pack",
      pack = "p_arcana_mega_1", items = { tarot_item("c_hermit", "The Hermit"), tarot_item("c_strength", "Strength") } } } })
    g.economy.dollars = 12
    local v = Tags.value(g, "tag_charm", { rng = Rng.fixed() })
    t.ok(type(v) == "number" and v >= 0, "seer tag value: a pack tag is valued from its predicted cards")
    local kv = Tags.known_value(g, g.blind.skip_tag_seer, { rng = Rng.fixed() })
    t.eq(v, kv, "seer tag value: ... the known value is the one used")
    g.blind.skip_tag_seer = { tag = "tag_rare", kind = "jokers", next_shop = true, items = { joker_item("j_baron", "Baron", 0) } }
    local rv = Tags.known_value(g, g.blind.skip_tag_seer, { rng = Rng.fixed() })
    t.ok(type(rv) == "number" and rv > 0, "seer tag value: a Rare tag is worth its predicted joker")
    g.jokers = { GS.joker{ key = "j_joker" }, GS.joker{ key = "j_joker" }, GS.joker{ key = "j_joker" },
                 GS.joker{ key = "j_joker" }, GS.joker{ key = "j_joker" } }
    t.eq(Tags.known_value(g, g.blind.skip_tag_seer, { rng = Rng.fixed() }), 2, "seer tag value: ... nothing on a full board")
  end
end
