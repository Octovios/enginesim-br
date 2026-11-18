-- tests/test_br.lua  (EngineSim BR)
-- The additions of the Brazilian fork: stake / deck awareness, the skip-or-play breakdown with joker growth, the
-- Death ordering instruction, the build catalogue and advisor (deck feasibility, forced build hooks), Plasma and
-- Observatory scoring, and the language layer.

local GS = require("model.game_state")
local I18N = require("util.i18n")
local RC = require("engine.run_context")
local Mechanics = require("engine.mechanics")
local HandEval = require("engine.hand_eval")
local Skip = require("engine.skip_advisor")
local Tarot = require("engine.tarot")
local A = require("engine.archetypes")
local BA = require("engine.build_advisor")
local BP = require("engine.build_plan")
local DP = require("engine.deck_plan")
local DS = require("engine.decision_state")
local SG = require("engine.scaling_growth")
local Cards = require("util.cards")

local function card(id, rank, suit, extra)
  local c = GS.card{ id = id, rank_id = rank, suit = suit }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

local function full_deck(opts)
  opts = opts or {}
  local deck, id = {}, 0
  for _, s in ipairs(opts.suits or Cards.SUITS) do
    for r = 2, 14 do
      local face = (r >= 11 and r <= 13)
      if not (opts.no_faces and face) then
        id = id + 1
        deck[#deck + 1] = card(id, r, s)
      end
    end
  end
  return deck
end

return function(t)
  I18N.set_lang("en")

  -- ---- stake / deck context ----------------------------------------------------------------------------------
  do
    local white = GS.new{ run = { hand_levels = {} } }
    t.eq(RC.stake(white), 1, "context: no stake field -> White")
    t.eq(RC.blind_reward(white, "Small"), 3, "context: White Stake Small Blind pays $3")
    local red = GS.new{ run = { hand_levels = {}, stake = 2, no_blind_reward = { Small = true } } }
    t.eq(RC.blind_reward(red, "Small"), 0, "context: Red Stake Small Blind pays $0")
    t.eq(RC.blind_reward(red, "Big"), 4, "context: Red Stake Big Blind still pays $4")
    local red_nomods = GS.new{ run = { hand_levels = {}, stake = 3 } }
    t.eq(RC.blind_reward(red_nomods, "Small"), 0, "context: stake known without modifiers -> Small unpaid from Red up")
    local live = GS.new{ run = { hand_levels = {}, stake = 2, blind_rewards = { Small = 0, Big = 4, Boss = 5 } } }
    t.eq(RC.blind_reward(live, "Boss"), 5, "context: the live per-blind rewards are used as read")

    -- blind sizes follow the stake curve and the deck multiplier
    t.eq(Mechanics.blind_requirement(4, "Boss"), 10000, "requirement: White ante 4 boss 10k")
    t.eq(Mechanics.blind_requirement(4, "Boss", nil, { run = { scaling = 2 } }), 16000, "requirement: Green+ ante 4 boss 16k")
    t.eq(Mechanics.blind_requirement(8, "Boss", nil, { run = { scaling = 3 } }), 400000, "requirement: Purple+ ante 8 boss 400k")
    t.eq(Mechanics.blind_requirement(2, "Small", nil, { run = { deck_key = "b_plasma" } }), 1600, "requirement: Plasma Deck x2")
    t.eq(Mechanics.blind_requirement(3, "Big", nil, { run = { stake = 6 } }), 4800, "requirement: stake 6 implies scaling 3")

    -- Green Deck economy
    local green = GS.new{ economy = { dollars = 30, interest_cap = 5 }, run = { hand_levels = {}, deck_key = "b_green" } }
    t.eq(RC.hand_money(green), 2, "Green Deck: $2 per unused hand")
    t.eq(RC.discard_money(green), 1, "Green Deck: $1 per unused discard")
    t.eq(RC.interest(green, 30), 0, "Green Deck: no interest")
    t.eq(RC.interest(white, 30), 5, "standard deck: interest capped at $5")

    -- deck traits
    local ab = GS.new{ deck = full_deck({ no_faces = true }), run = { hand_levels = {}, deck_key = "b_abandoned" } }
    t.ok(RC.deck_traits(ab).no_faces, "Abandoned Deck: no faces read from the deck")
    local ch = GS.new{ deck = full_deck({ suits = { "Spades", "Hearts" } }), run = { hand_levels = {}, deck_key = "b_checkered" } }
    t.ok(RC.deck_traits(ch).two_suits, "Checkered Deck: two suits")
    t.eq(RC.deck_profile(ch).dominant_share, 0.5, "Checkered Deck: each suit is half the deck")
  end

  -- ---- Plasma Deck and Observatory scoring -------------------------------------------------------------------
  do
    local hand = { card(1, 14, "Spades"), card(2, 14, "Hearts") }
    local base = GS.new{ run = { hand_levels = {} } }
    local ev = HandEval.score(base, hand)
    t.eq(ev.score, (10 + 22) * 2, "standard: Pair of Aces = (10 + 22) x 2")
    local plasma = GS.new{ run = { hand_levels = {}, deck_key = "b_plasma" } }
    local ep = HandEval.score(plasma, hand)
    t.eq(ep.score, 17 * 17, "Plasma Deck: chips and mult averaged -> 17 x 17")
    local obs = GS.new{ run = { hand_levels = {}, vouchers_owned = { v_observatory = true } },
      consumables = { GS.consumable{ key = "c_mercury", set = "Planet" }, GS.consumable{ key = "c_mercury", set = "Planet" },
                      GS.consumable{ key = "c_venus", set = "Planet" } } }
    t.near(HandEval.score(obs, hand).score, math.floor(32 * 2 * 1.5 * 1.5), "Observatory: x1.5 per held Mercury on a Pair", 1)
    local noobs = GS.new{ run = { hand_levels = {} }, consumables = obs.consumables }
    t.eq(HandEval.score(noobs, hand).score, 64, "no Observatory: held planets do nothing")
  end

  -- ---- skip or play --------------------------------------------------------------------------------------------
  do
    local deck = full_deck()
    local function st(stake, jokers, tag)
      return GS.new{ deck = deck, jokers = jokers or {}, economy = { dollars = 10, interest_cap = 5 },
        meta = { ante = 2, state = "BLIND_SELECT", seed_hash = "T" },
        run = { hand_levels = {}, joker_slots = 5, hand_size = 8, stake = stake },
        blind = { blind_type = "Small", base_hands = 4, base_discards = 3, skip_tag = tag or "tag_coupon" } }
    end
    local w = Skip.recommend(st(1))
    local r = Skip.recommend(st(2))
    t.ok(w and r, "skip: advice on both stakes")
    t.eq(w.parts.reward, 3, "skip: White Stake counts the $3 reward")
    t.eq(r.parts.reward, 0, "skip: Red Stake counts $0 for the Small Blind")
    t.ok(r.play_value < w.play_value, "skip: playing is worth less on Red Stake")
    local txt = table.concat(r.details, "\n")
    t.ok(txt:find("Small Blind pays nothing", 1, true) ~= nil, "skip: the breakdown says why the reward is $0")

    -- a growing joker makes playing worth more
    local green = { GS.joker{ key = "j_green_joker", name = "Green Joker", ability = { mult = 4 } } }
    local plain = { GS.joker{ key = "j_joker", name = "Joker" } }
    local gp = SG.play_vs_skip(st(2, green))
    t.ok(gp.measured, "growth: measured on the deck")
    t.ok(gp.play_dollars > 0, "growth: Green Joker grows by playing")
    t.ok(gp.play_items[1] and gp.play_items[1].key == "j_green_joker", "growth: and is named in the breakdown")
    local pp = SG.play_vs_skip(st(2, plain))
    t.eq(pp.play_dollars, 0, "growth: a plain Joker does not grow")
    local ice = SG.play_vs_skip(st(2, { GS.joker{ key = "j_ice_cream", name = "Ice Cream", ability = { extra = { chips = 100 } } } }))
    t.ok(ice.play_dollars < 0, "growth: Ice Cream loses value by playing")
    local tb = SG.play_vs_skip(st(2, { GS.joker{ key = "j_throwback", name = "Throwback", ability = { x_mult = 1.5 } } }))
    t.ok(tb.skip_dollars > 0, "growth: Throwback grows by skipping")
    local sg = Skip.recommend(st(2, green))
    t.ok(sg.play_value > Skip.recommend(st(2, plain)).play_value - 1e-9, "skip: Green Joker's growth is credited to playing")
    t.ok(table.concat(sg.details, "\n"):find("Green Joker grows", 1, true) ~= nil, "skip: and listed in the breakdown")
  end

  -- ---- Death ordering ------------------------------------------------------------------------------------------
  do
    -- the hand sits high -> low: King of Spades LEFT of the 3 of Clubs. Death should turn the 3 into the King, so
    -- the 3 must be dragged to the LEFT of the King first.
    local hand = { card(1, 13, "Spades"), card(2, 9, "Hearts"), card(3, 3, "Clubs") }
    local gs = GS.new{ hand = hand, run = { hand_levels = {} } }
    local d = Tarot.death_info(gs, hand)
    t.ok(d ~= nil, "death: a pick is made")
    t.eq(d.source.id, 1, "death: the King is the card to copy")
    t.eq(d.target.id, 3, "death: the 3 becomes the King")
    t.ok(d.swap, "death: the 3 is right of the King -> drag it left first")
    t.ok(d.note:find("first drag 3C to the LEFT of KS", 1, true) == 1, "death: the note starts with what to drag where")
    t.ok(d.note:find("3C becomes a copy of KS", 1, true) ~= nil, "death: and says which card becomes which")
    local hint = Tarot.order_hint(gs, "c_death", hand)
    t.eq(hint.target_id, 3, "death hint: target id")
    t.eq(hint.source_id, 1, "death hint: source id")
    -- already in order: the 3 on the left
    local hand2 = { card(3, 3, "Clubs"), card(2, 9, "Hearts"), card(1, 13, "Spades") }
    local d2 = Tarot.death_info(GS.new{ hand = hand2, run = { hand_levels = {} } }, hand2)
    t.ok(not d2.swap, "death: target already left of the source -> no drag")
    t.ok(d2.note:find("already right", 1, true) ~= nil, "death: the note says the order is right")
    -- the in-world tags name the roles
    local H = require("ui.highlights")
    local plan = H.plan({ type = "USE_CONSUMABLE", target = { key = "c_death", id = 9 },
      target_cards = { { id = 3 }, { id = 1 } }, order_hint = hint })
    local labels = {}
    for _, w in ipairs(plan) do labels[#labels + 1] = w.label end
    t.eq(table.concat(labels, "|"), "USE|<< DRAG\n1 BECOMES|2 SOURCE", "death tags: drag + becomes on the target, source on the King")
  end

  -- ---- builds: deck feasibility ----------------------------------------------------------------------------------
  do
    local ab = GS.new{ deck = full_deck({ no_faces = true }), jokers = { GS.joker{ key = "j_baron" } },
      run = { hand_levels = {}, deck_key = "b_abandoned" } }
    local kings = BA.entry(ab, "steel_kings")
    t.ok(kings.f < BA.VIABLE_MIN, "builds: Steel Kings is not viable without faces")
    t.eq(kings.reason, "build_reason_no_faces", "builds: ... because the deck has no face cards")
    local faces = BA.entry(ab, "faces")
    t.ok(faces.f < BA.VIABLE_MIN, "builds: the face build is not viable on an Abandoned Deck")
    -- ...unless Pareidolia makes every card a face card
    local par = GS.new{ deck = ab.deck, jokers = { GS.joker{ key = "j_pareidolia" } }, run = { hand_levels = {} } }
    t.ok(BA.entry(par, "faces").f >= 0.99, "builds: Pareidolia makes the face build viable again")
    local lines = table.concat(BA.summary_lines(ab), "\n")
    t.ok(lines:find("not viable here", 1, true) ~= nil, "builds: the panel flags the owned Baron's build as not viable")
    t.ok(not lines:find("1. Steel Kings", 1, true), "builds: and never suggests it")
    local ctx = table.concat(BA.context_lines(ab), "\n")
    t.ok(ctx:find("no face cards", 1, true) ~= nil, "context: the deck note says there are no faces")

    -- Checkered Deck: no Diamonds -> the Diamonds flush is out; the Hearts flush fits
    local ch = GS.new{ deck = full_deck({ suits = { "Spades", "Hearts" } }), run = { hand_levels = {}, deck_key = "b_checkered" } }
    t.eq(BA.entry(ch, "flush_diamonds").f, 0, "builds: no Diamonds in a Checkered Deck")
    t.ok(BA.entry(ch, "flush_hearts").f >= 0.99, "builds: Hearts are half the Checkered Deck")
    t.ok(BA.entry(ch, "flush_any").f > BA.entry(GS.new{ deck = full_deck(), run = { hand_levels = {} } }, "flush_any").f,
      "builds: a two-suit deck favours flushes")

    -- the panel names what the deck favours before any build has started (never on a standard deck)
    local fav = table.concat(BA.summary_lines(ch), "\n")
    t.ok(fav:find("your deck favours", 1, true) ~= nil and fav:find("Hearts Flush", 1, true) ~= nil,
      "builds: a Checkered Deck is said to favour the Hearts flush")
    t.ok(not table.concat(BA.summary_lines(GS.new{ deck = full_deck(), run = { hand_levels = {} } }), "\n"):find("favours", 1, true),
      "builds: a standard deck favours nothing in particular")
    t.ok(table.concat(BA.summary_lines(ch), "\n"):find("no build started", 1, true) ~= nil,
      "builds: with no pieces, the panel says no build has started")

    -- owned + offered + seen pieces raise a build's readiness
    local deck = full_deck()
    local base = BA.entry(GS.new{ deck = deck, run = { hand_levels = {} } }, "fullhouse")
    local own = BA.entry(GS.new{ deck = deck, jokers = { GS.joker{ key = "j_trio" } }, run = { hand_levels = {} } }, "fullhouse")
    local off = BA.entry(GS.new{ deck = deck, shop = { jokers = { GS.joker{ key = "j_trio" } } }, run = { hand_levels = {} } }, "fullhouse")
    local seen = BA.entry(GS.new{ deck = deck, run = { hand_levels = {}, seen_jokers = { j_trio = { ante = 1 } } } }, "fullhouse")
    t.ok(own.progress > off.progress and off.progress > seen.progress and seen.progress > base.progress,
      "builds: owned > offered now > seen earlier > nothing")
  end

  -- ---- builds: forced mode hooks ---------------------------------------------------------------------------------
  do
    local deck = full_deck()
    local function st(forced, jokers)
      return GS.new{ deck = deck, jokers = jokers or {}, meta = { ante = 2, seed_hash = "S" },
        run = { hand_levels = {}, forced_build = forced } }
    end
    local plan = BP.analyze(st(nil))
    local f0 = BP.fit(st(nil), { key = "j_baron" }, plan, false)
    local f1, note = BP.fit(st("steel_kings"), { key = "j_baron" }, plan, false)
    t.ok(f1 >= f0 + BA.FORCE_CORE_FIT - 1e-9, "forced: a core piece gets the forced fit")
    t.ok(note and note:find("Steel Kings", 1, true) ~= nil, "forced: and the reason names the build")
    local fa = BP.fit(st("flush_hearts"), { key = "j_flower_pot" }, plan, false)
    t.ok(fa < 0, "forced: a piece that fights the build is penalised")
    -- keep protection
    t.ok(BP.keep_bias("j_mime", st("steel_kings")) >= BP.CORE_KEEP, "forced: its pieces are protected from selling")
    -- deck plan target
    local tg = DP.target(st("flush_hearts"))
    t.eq(tg.suit, "Hearts", "forced: the deck plan aims at Hearts")
    t.eq(DP.target(st("steel_kings")).ranks[13], true, "forced: Steel Kings keeps Kings")
    -- the commitment levels the build's hand
    local carried = DS.carry(st("fullhouse"), {}, nil)
    t.eq(carried.plan and carried.plan.hand, "Full House", "forced: the plan commits to Full House")
    t.eq(carried.plan and carried.plan.via, "user", "forced: marked as the player's choice")
    local mem = {}
    DS.remember(mem, carried)
    local back = DS.carry(st(nil), mem, nil)
    t.eq(back.plan, nil, "forced: back to automatic drops the forced commitment")
    -- consumables
    t.ok(BA.consumable_bonus(st("steel_kings"), "c_chariot") > 0, "forced: The Chariot helps Steel Kings")
    t.ok(BA.consumable_bonus(st("flush_hearts"), "c_star") < 0, "forced: The Star (Diamonds) is off-plan for Hearts")
    t.eq(BA.consumable_bonus(st(nil), "c_chariot"), 0, "auto: no consumable bias")
    local fl = table.concat(BA.summary_lines(st("steel_kings", { GS.joker{ key = "j_baron" } })), "\n")
    t.ok(fl:find("Forcing build: Steel Kings", 1, true) ~= nil, "forced: the panel says which build is forced")
    t.ok(fl:find("look for", 1, true) ~= nil, "forced: and what to look for")
    -- menu rows cover the catalogue
    t.eq(#BA.menu_rows(st(nil)), #A.LIST, "menu: one row per build")
  end

  -- ---- forced Five of a Kind / Flush Five: identical cards, a thinner deck --------------------------------------
  do
    local deck = full_deck()
    -- two extra Kings of Hearts: K-hearts is the most duplicated exact card
    deck[#deck + 1] = card(201, 13, "Hearts"); deck[#deck + 1] = card(202, 13, "Hearts")
    local function st(forced, hand)
      return GS.new{ deck = deck, hand = hand or {}, meta = { ante = 3, seed_hash = "F" },
        run = { hand_levels = {}, forced_build = forced } }
    end
    local prof = RC.deck_profile(st(nil))
    t.eq(prof.top_card and prof.top_card.rank, 13, "five: the most duplicated card is a King")
    t.eq(prof.top_card and prof.top_card.suit, "Hearts", "five: ... of Hearts")
    t.eq(prof.top_card and prof.top_card.n, 3, "five: three copies")
    local tg = DP.target(st("five"))
    t.ok(tg.ranks and tg.ranks[13] and tg.suit == "Hearts", "five: the deck plan aims at the exact card (King of Hearts)")
    t.eq(tg.ideal_size, 25, "five: wants a small deck")
    -- thinning an off-target card is worth more when Flush Five is forced
    local junk = card(301, 7, "Spades")
    local v_auto = DP.removal_value(st(nil), junk)
    local v_five = DP.removal_value(st("five"), junk)
    t.ok(v_five > v_auto, "five: cutting an off-target card is worth more")
    -- Death copies the King of Hearts onto the junk; Cryptid copies the King of Hearts
    local hand = { card(201, 13, "Hearts"), card(110, 9, "Clubs"), card(301, 7, "Spades"), card(120, 4, "Diamonds") }
    local d = Tarot.death_info(st("five", hand), hand)
    t.eq(d and d.source.id, 201, "five: Death copies the King of Hearts")
    t.ok(d and d.target.id ~= 201 and d.target.rank_id ~= 13, "five: onto an off-target card")
    local cr = Tarot.best_targets(st("five", hand), "c_cryptid", hand)
    t.eq(cr and cr[1] and cr[1].id, 201, "five: Cryptid copies the King of Hearts")
    -- Standard packs: the target card is wanted, unrelated cards are bloat
    t.eq(BA.card_bonus(st("five"), card(401, 13, "Hearts")), BA.CARD_ON_TARGET, "five: a King of Hearts from a pack is a target")
    t.eq(BA.card_bonus(st("five"), card(402, 6, "Clubs")), BA.CARD_OFF_TARGET, "five: an unrelated card dilutes")
    t.eq(BA.card_bonus(st("five"), card(403, 13, "Spades")), 0, "five: a King of another suit is neutral")
    t.eq(BA.card_bonus(st(nil), card(401, 13, "Hearts")), 0, "auto: no card bias")
    t.ok(BA.consumable_bonus(st("five"), "c_cryptid") > 0, "five: Cryptid is favoured")
  end

  -- ---- joker order: additive before multiplicative (live report: "it never moves the multipliers last") ----------
  do
    local Ordering = require("engine.ordering")
    local deck = full_deck()
    local xm = GS.joker{ id = 501, key = "j_cavendish", name = "Cavendish", position = 1 }
    local add = GS.joker{ id = 502, key = "j_joker", name = "Joker", position = 2 }
    local function st(jokers)
      return GS.new{ deck = deck, jokers = jokers, meta = { ante = 2, seed_hash = "O" },
        run = { hand_levels = {}, hand_size = 8, joker_slots = 5 } }
    end
    local so = Ordering.standing_order(st({ xm, add }))
    t.ok(so ~= nil, "order: an xMult left of a +Mult joker gets a standing order")
    t.eq(so and so.order[1].key, "j_joker", "order: the +Mult joker goes first")
    t.eq(so and so.order[2].key, "j_cavendish", "order: the xMult joker goes last")
    t.ok(so and so.gain > 0.01, "order: with a real gain on typical hands")
    t.eq(Ordering.standing_order(st({ add, xm })), nil, "order: an already good row is left alone")
    t.eq(Ordering.standing_order(st({ add, GS.joker{ id = 503, key = "j_ceremonial", name = "Ceremonial Dagger" }, xm })), nil,
      "order: Ceremonial Dagger boards are left to the Dagger plan")
    -- a locked clear (money objective) still fixes the joker order when it costs no money
    local hand = { card(1, 14, "Spades"), card(2, 14, "Hearts"), card(3, 9, "Clubs") }
    local g = st({ xm, add }); g.hand = hand
    local o = Ordering.optimize(g, { hand[1], hand[2] }, { objective = "money", remaining = 1 })
    t.ok(o.joker_changed, "order: a guaranteed clear still reorders the jokers")
    t.ok((o.joker_score_gain or 0) > 0, "order: ... for score, at no money cost")
    t.eq(o.joker_order[1].key, "j_joker", "order: +Mult first on the play too")
    -- end to end: an easy blind (the clear is locked) still gets the joker reorder on the play
    local DEng = require("engine.decision_engine")
    local hand8 = { card(11, 14, "Spades"), card(12, 14, "Hearts"), card(13, 13, "Clubs"), card(14, 9, "Diamonds"),
                    card(15, 7, "Spades"), card(16, 5, "Hearts"), card(17, 4, "Clubs"), card(18, 2, "Diamonds") }
    local bgs = GS.new{ deck = deck, remaining = deck, hand = hand8, jokers = { xm, add },
      meta = { ante = 1, round = 1, state = "SELECTING_HAND", seed_hash = "O" },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2 },
      blind = { target_chips = 100, chips_scored = 0, hands_left = 4, discards_left = 3, base_hands = 4,
                base_discards = 3, blind_type = "Small" } }
    local r = DEng.decide(bgs, {})
    t.eq(r.best and r.best.type, "PLAY", "order e2e: plays the easy blind")
    t.ok(r.best and r.best.reorder and r.best.reorder.joker_changed, "order e2e: and asks to put the +Mult joker first")

    -- the panel numbers the jokers on a shop action that carries the order
    local H = require("ui.highlights")
    local plan = H.plan({ type = "BUY_JOKER", target = { key = "j_duo", id = 9 }, arrange = so and so.order })
    local nums = {}
    for _, w in ipairs(plan) do if w.areas[1] == "jokers" then nums[#nums + 1] = w.label .. ":" .. tostring(w.target.id) end end
    t.eq(table.concat(nums, ","), "1:502,2:501", "order: shop advice numbers the jokers 1..n")
  end

  -- ---- Negative jokers need no slot (live report: self-play sold a joker to fit a Negative one) -------------------
  do
    local SA = require("engine.shop_advisor")
    local PO = require("engine.pack_open_advisor")
    local deck = full_deck()
    local board = {}
    for i = 1, 5 do board[i] = GS.joker{ id = 100 + i, key = "j_joker", name = "Joker", position = i, sell_value = 1 } end
    local function shop_gs(edition)
      return GS.new{ deck = deck, jokers = board, economy = { dollars = 60, interest_cap = 5 },
        meta = { ante = 3, round = 7, state = "SHOP", seed_hash = "N" },
        run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2, vouchers_owned = {}, tags = {} },
        blind = { base_hands = 4, base_discards = 3, hands_left = 4, discards_left = 3 },
        shop = { jokers = { GS.joker{ id = 900, key = "j_duo", name = "The Duo", cost = 8, edition = edition } },
          consumables = {}, vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5 } }
    end
    t.ok(SA.needs_slot({ edition = nil }) and not SA.needs_slot({ edition = "negative" }), "negative: needs_slot rule")
    local r = SA.recommend(shop_gs("negative"), {})
    local all = { r.best }
    for _, a in ipairs(r.alternatives or {}) do all[#all + 1] = a end
    local buy, sell_for_it = nil, false
    for _, a in ipairs(all) do
      if a.type == "BUY_JOKER" and a.target and a.target.id == 900 then buy = a end
      if (a.type == "SELL_JOKER" and a.swap_for and a.swap_for.id == 900)
         or (a.type == "SELL_TO_BUY" and a.then_buy and a.then_buy.id == 900) then sell_for_it = true end
    end
    t.ok(buy ~= nil, "negative: a Negative joker is offered as a direct buy on a full board")
    t.eq(buy and buy.need_jslot, false, "negative: and it needs no slot")
    t.ok(not sell_for_it, "negative: no joker is sold to make room for it")
    -- the same joker without the edition still needs a sale on a full board (the old behaviour is kept there)
    local r2 = SA.recommend(shop_gs(nil), {})
    local direct = false
    for _, a in ipairs({ r2.best, table.unpack and table.unpack(r2.alternatives or {}) or nil }) do
      if a and a.type == "BUY_JOKER" and a.target and a.target.id == 900 then direct = true end
    end
    for _, a in ipairs(r2.alternatives or {}) do
      if a.type == "BUY_JOKER" and a.target and a.target.id == 900 then direct = true end
    end
    t.ok(not direct, "negative: a plain joker is never a direct buy on a full board")

    -- packs: a Negative top pick is simply taken
    local pgs = GS.new{ deck = deck, hand = {}, jokers = board, economy = { dollars = 10, interest_cap = 5 },
      meta = { ante = 3, round = 7, state = "BUFFOON_PACK", seed_hash = "N" },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2, vouchers_owned = {}, tags = {} },
      blind = { base_hands = 4, base_discards = 3 },
      pack = { picks_left = 1, items = { { set = "Joker", key = "j_duo", name = "The Duo",
        joker = GS.joker{ id = 901, key = "j_duo", name = "The Duo", edition = "negative" } } } } }
    local po = PO.recommend(pgs, { cheap = true })
    t.ok(po and po.best and po.best.key == "j_duo", "negative pack: the Negative joker is the pick")
    t.eq(po and po.sell, nil, "negative pack: nothing is sold to make room")
    t.ok(po and not po.skip, "negative pack: the pack is not skipped for a full board")
  end

  -- ---- language layer --------------------------------------------------------------------------------------------
  do
    I18N.set_lang("pt_BR")
    t.eq(Cards.label(card(1, 13, "Spades")), "Ke", "pt: King of Spades -> Ke")
    t.eq(Cards.label(card(1, 10, "Diamonds")), "10o", "pt: 10 of Diamonds -> 10o")
    t.eq(Cards.describe(card(1, 12, "Hearts")), "Rainha de Copas", "pt: Queen of Hearts")
    I18N.register_name("Green Joker", "Coringa Verde")
    I18N.register_name("Joker", "Coringa")
    t.eq(I18N.localize_names("Buy Green Joker and Joker"), "Buy Coringa Verde and Coringa", "pt: longest names first")
    t.eq(I18N.localize_names("Two Pair beats Pair"), "Dois Pares beats Par", "pt: poker hands")
    t.eq(I18N.localize_names("Jokers"), "Jokers", "pt: only whole words")
    t.eq(I18N.say("skip_reward", 3), "  recompensa $3", "pt: keyed messages")
    local Overlay = require("ui.overlay")
    t.eq(Overlay.fmt_num(1234567), "1.234.567", "pt: thousands with dots")
    t.eq(Overlay.verb("PLAY"), "Jogar", "pt: verbs")
    local hand = { card(1, 13, "Spades"), card(3, 3, "Clubs") }
    local d = Tarot.death_info(GS.new{ hand = hand, run = { hand_levels = {} } }, hand)
    t.ok(d.note:find("arraste 3p para a ESQUERDA de Ke", 1, true) ~= nil, "pt: the Death drag instruction")
    I18N.names = {}
    I18N._name_list = nil
    I18N.set_lang("en")
    t.eq(Cards.label(card(1, 13, "Spades")), "KS", "en: labels unchanged")
  end
end
