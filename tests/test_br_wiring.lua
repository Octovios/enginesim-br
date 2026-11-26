-- tests/test_br_wiring.lua  (EngineSim BR)
-- Smoke test of the IN-GAME wiring of main.lua: loads it against a stand-in game (G, SMODS, love and the UI
-- builders it calls), then drives what a player does -- open the build menu with F3, pick a build, let the frame
-- ticks evaluate a blind-select and a shop. The real UIBox layout needs the game; this catches nil references and
-- wrong call shapes in the wiring, which headless engine tests never execute.

return function(t)
  local saved = {}
  local SAVED_KEYS = { "G", "SMODS", "love", "localize", "create_toggle", "create_option_cycle",
    "create_UIBox_generic_options", "create_UIBox_HUD", "UIBox", "lighten", "darken", "Node", "Moveable",
    "pseudorandom", "get_new_boss" }
  for _, k in ipairs(SAVED_KEYS) do saved[k] = rawget(_G, k) end
  local Log = require("util.log")
  local saved_level = Log.level
  local files = {}
  local T = 1000
  local function col(n) return { n, n, n, 1 } end
  local overlay_def, saved_cfg

  local ok, err = pcall(function()
    Log.level = "off"
    _G.love = {
      timer = { getTime = function() return T end },
      filesystem = {
        append = function(name, s) files[name] = (files[name] or "") .. s; return true end,
        write = function(name, s) files[name] = s; return true end,
        read = function(name) return files[name] end,
        getInfo = function(name) return files[name] and { type = "file" } or nil end,
        getSaveDirectory = function() return "/save" end,
      },
      window = { getMode = function() return 1920, 1080, { refreshrate = 60 } end },
      graphics = { getHeight = function() return 1080 end },
    }
    _G.localize = function(args, cat)
      if type(args) == "table" then
        local names = { j_baron = "Barão", c_death = "A Morte", stake_red = "Ficha Vermelha", b_red = "Baralho Vermelho" }
        return names[args.key] or "ERROR"
      end
      return args
    end
    _G.create_toggle = function(a) return { n = 4, config = {}, nodes = {} } end
    _G.create_option_cycle = function(a) return { n = 4, config = {}, nodes = {} } end
    _G.create_UIBox_generic_options = function(a) return { n = 7, config = {}, nodes = a.contents } end
    _G.create_UIBox_HUD = function() return { n = 7, config = {}, nodes = {} } end
    _G.lighten = function(c) return c end
    _G.darken = function(c) return c end
    local STATES = { SELECTING_HAND = 1, HAND_PLAYED = 2, DRAW_TO_HAND = 3, GAME_OVER = 4, SHOP = 5,
      PLAY_TAROT = 6, BLIND_SELECT = 7, ROUND_EVAL = 8, TAROT_PACK = 9, PLANET_PACK = 10, MENU = 11,
      SPECTRAL_PACK = 15, STANDARD_PACK = 17, BUFFOON_PACK = 18, NEW_ROUND = 19 }
    local cards = {}
    local function pcard(i, value, id, suit)
      return { sort_id = i, base = { value = value, id = id, suit = suit, nominal = math.min(id, 10) },
        config = { center = { key = "c_base", set = "Default" } }, ability = { set = "Default", name = "Default Base" } }
    end
    local vals = { [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "10",
                   [11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace" }
    local n = 0
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do n = n + 1; cards[n] = pcard(n, vals[r], r, s) end
    end
    local baron = { sort_id = 900, config = { center = { key = "j_baron", set = "Joker", rarity = 3 } },
      ability = { name = "Baron", set = "Joker", extra = 1.5 }, sell_cost = 4 }
    local overlay_calls = 0
    _G.G = {
      STATES = STATES, STATE = STATES.BLIND_SELECT, STAGES = { MAIN_MENU = 1, RUN = 2 }, STAGE = 2,
      SETTINGS = { language = "pt_BR" },
      UIT = { T = 1, B = 2, C = 3, R = 4, O = 5, ROOT = 7 },
      C = { WHITE = col(1), BLACK = col(0), CLEAR = col(0), GREEN = col(0.2), RED = col(0.3), BLUE = col(0.4),
        FILTER = col(0.5), MONEY = col(0.6), JOKER_GREY = col(0.7), GOLD = col(0.8), PURPLE = col(0.9), ORANGE = col(0.5),
        UI = { TEXT_LIGHT = col(1), TEXT_DARK = col(0.1), TEXT_INACTIVE = col(0.5), BACKGROUND_WHITE = col(1),
               BACKGROUND_INACTIVE = col(0.4) },
        DYN_UI = { MAIN = col(0.8), BOSS_MAIN = col(0.2), BOSS_DARK = col(0.1) } },
      FUNCS = {
        overlay_menu = function(a) overlay_calls = overlay_calls + 1; overlay_def = a.definition end,
        exit_overlay_menu = function() end,
      },
      P_CENTERS = { j_baron = { key = "j_baron", set = "Joker", name = "Baron" },
                    c_death = { key = "c_death", set = "Tarot", name = "Death" } },
      P_TAGS = {}, P_BLINDS = { bl_small = { name = "Small Blind", dollars = 3 }, bl_big = { name = "Big Blind", dollars = 4 },
        bl_hook = { name = "The Hook", dollars = 5 } }, P_STAKES = {},
      P_CENTER_POOLS = { Stake = { { key = "stake_white" }, { key = "stake_red" } } },
      playing_cards = cards,
      deck = { cards = cards },
      hand = { cards = {}, config = { card_limit = 8 } },
      jokers = { cards = { baron }, config = { card_limit = 5 } },
      consumeables = { cards = {}, config = { card_limit = 2 } },
      GAME = {
        stake = 2, dollars = 9, interest_cap = 25, round = 1, skips = 0,
        modifiers = { no_blind_reward = { Small = true } },
        starting_params = { ante_scaling = 1 },
        selected_back = { name = "Red Deck", effect = { center = { key = "b_red" } } },
        hands = { Pair = { level = 1, chips = 10, mult = 2, played = 0, played_this_round = 0 },
                  ["High Card"] = { level = 1, chips = 5, mult = 1, played = 0, played_this_round = 0 } },
        blind = { name = "", chips = 0, config = {} },
        current_round = { hands_left = 4, discards_left = 3, reroll_cost = 5 },
        round_resets = { ante = 1, hands = 4, discards = 3,
          blind_choices = { Small = "bl_small", Big = "bl_big", Boss = "bl_hook" },
          blind_states = { Small = "Select", Big = "Upcoming", Boss = "Upcoming" },
          blind_tags = { Small = "tag_economy", Big = "tag_coupon" } },
        blind_on_deck = "Small",
        pseudorandom = { seed = "TESTSEED" },
        used_vouchers = {}, tags = {},
      },
    }
    saved_cfg = { config = { language = "pt_BR" } }
    _G.SMODS = { current_mod = { id = "enginesim_br", config = saved_cfg.config },
      save_mod_config = function() return true end, stake_from_index = function(i) return ({ "stake_white", "stake_red" })[i] end }

    -- a fresh load of every module the wiring touches, so the stand-in G is the one they see
    for _, m in ipairs({ "ui.settings", "ui.hud_panel", "ui.build_menu", "ui.highlights" }) do package.loaded[m] = nil end
    local BES = dofile(package.searchpath("main", package.path))
    Log.level = "off"
    local I18N = require("util.i18n")
    t.eq(I18N.lang, "pt_BR", "wiring: the mod speaks Portuguese by default")
    t.ok(type(G.FUNCS.bes_build_pick) == "function", "wiring: the build-menu button handler is registered")
    t.ok(type(SMODS.current_mod.config_tab) == "function", "wiring: the settings page is registered")

    -- a few frames: the blind-select is evaluated (the skip advice) with the stake and deck read from the game
    for _ = 1, 8 do T = T + 0.3; love.update(0.3); love.draw() end
    for _ = 1, 400 do if not BES.job then break end; T = T + 0.016; love.update(0.016) end
    local last = BES.last
    t.ok(last ~= nil and last.gs ~= nil, "wiring: the live tick evaluated a state")
    if last and last.gs then
      t.eq(last.gs.run.stake, 2, "wiring: the stake is read from G.GAME.stake")
      t.eq(last.gs.run.blind_rewards and last.gs.run.blind_rewards.Small, 0, "wiring: Red Stake's Small Blind pays $0")
      t.eq(last.gs.run.deck_key, "b_red", "wiring: the deck key is read")
      t.eq(last.gs.jokers[1] and last.gs.jokers[1].name, "Barão", "wiring: joker names come from the game's localization")
    end
    local Overlay = require("ui.overlay")
    t.ok((Overlay.state.reason or ""):find("Jogue", 1, true) ~= nil or (Overlay.state.reason or ""):find("Pule", 1, true) ~= nil,
      "wiring: the skip advice is shown in Portuguese")
    t.ok(table.concat(Overlay.state.context or {}, "\n"):find("Small Blind", 1, true) ~= nil,
      "wiring: the panel notes the Red Stake rule")

    -- F3 opens the build menu; picking a build forces it for this run and saves it
    love.keypressed("f3")
    t.eq(overlay_calls, 1, "wiring: F3 opens the build menu")
    t.ok(overlay_def ~= nil, "wiring: the menu has a definition")
    G.FUNCS.bes_build_pick({ config = { ref_table = { id = "flush_hearts" } } })
    t.eq(BES.forced.id, "flush_hearts", "wiring: the pick forces the build")
    t.eq(saved_cfg.config.run_build and saved_cfg.config.run_build.id, "flush_hearts", "wiring: and it is saved with the run seed")
    for _ = 1, 4 do T = T + 0.3; love.update(0.3) end
    for _ = 1, 400 do if not BES.job then break end; T = T + 0.016; love.update(0.016) end
    t.eq(BES.last and BES.last.gs and BES.last.gs.run.forced_build, "flush_hearts", "wiring: the next evaluation sees the build")
    t.ok(table.concat(Overlay.state.build or {}, "\n"):find("Flush de Copas", 1, true) ~= nil, "wiring: the panel shows the forced build")
    -- "Automatic" clears it
    G.FUNCS.bes_build_pick({ config = { ref_table = { id = "__auto" } } })
    t.eq(BES.forced.id, nil, "wiring: Automatic clears the forced build")

    -- the shop: jokers on offer are recorded as seen for the build advisor
    G.STATE = STATES.SHOP
    G.shop_jokers = { cards = { { sort_id = 950, config = { center = { key = "j_trio", set = "Joker", rarity = 3 } },
      ability = { name = "The Trio", set = "Joker" }, cost = 8 } } }
    G.shop_vouchers = { cards = {} }
    G.shop_booster = { cards = {} }
    for _ = 1, 4 do T = T + 0.3; love.update(0.3) end
    for _ = 1, 2000 do if not BES.job then break end; T = T + 0.016; love.update(0.016) end
    t.ok(BES.seen.keys.j_trio ~= nil, "wiring: a joker seen in the shop is remembered")
    t.ok(files.enginesim_br_seen ~= nil or files["enginesim_br_seen.json"] ~= nil, "wiring: and saved for a continued run")
    t.ok(BES.last and BES.last.shop, "wiring: the shop was evaluated")

    -- seer mode (F4): the real draw order is used, checked after every draw, and shown on the panel
    G.STATE = STATES.SELECTING_HAND
    G.shop_jokers, G.shop_vouchers, G.shop_booster = nil, nil, nil
    G.GAME.blind = { name = "Small Blind", chips = 300, config = {} }
    G.GAME.round_resets.blind_states = { Small = "Current", Big = "Upcoming", Boss = "Upcoming" }
    G.GAME.current_round.hands_left, G.GAME.current_round.discards_left = 4, 3
    G.GAME.pseudorandom = {}
    G.GAME.probabilities = { normal = 1 }
    _G.pseudorandom = function(key, min, max)
      local pr = G.GAME.pseudorandom
      pr[key] = ((pr[key] or 0.5) * 1.7 + 0.13) % 1
      if min and max then return min + math.floor(pr[key] * (max - min + 1)) end
      return pr[key]
    end
    _G.get_new_boss = function() return "bl_hook" end
    local hand_cards, deck_cards = {}, {}
    for i, c in ipairs(cards) do if i <= 8 then hand_cards[#hand_cards + 1] = c else deck_cards[#deck_cards + 1] = c end end
    G.hand.cards, G.deck.cards = hand_cards, deck_cards
    G.playing_cards = cards
    love.keypressed("f4")
    t.ok(BES.seer_on(), "wiring: F4 turns the seer mode on")
    local function settle()
      for _ = 1, 4 do T = T + 0.3; love.update(0.3) end
      for _ = 1, 3000 do if not BES.job then break end; T = T + 0.016; love.update(0.016) end
    end
    settle()
    t.ok(table.concat(Overlay.state.seer or {}, "\n"):find("próximas cartas", 1, true) ~= nil, "wiring: the panel shows the next cards")
    -- a real draw: two cards leave the hand and the deck's LAST two arrive (the game draws from the end)
    table.remove(hand_cards, 1); table.remove(hand_cards, 1)
    hand_cards[#hand_cards + 1] = table.remove(deck_cards); hand_cards[#hand_cards + 1] = table.remove(deck_cards)
    G.GAME.current_round.discards_left = 2
    settle()
    t.eq(BES.seer.ok, 1, "wiring: the draw matched the predicted order")
    -- two cards from the wrong end of the deck: caught
    table.remove(hand_cards, 1); table.remove(hand_cards, 1)
    hand_cards[#hand_cards + 1] = table.remove(deck_cards, 1); hand_cards[#hand_cards + 1] = table.remove(deck_cards, 1)
    G.GAME.current_round.discards_left = 1
    settle()
    t.eq(BES.seer.miss, 1, "wiring: a draw that does not match the order is caught")

    -- seer mode in the shop: the pack's cards and the next rerolls are predicted, shown, and checked when the pack
    -- opens and when the shop rerolls (core/seer_peek against tests/standin_game)
    local Standin = require("tests.standin_game")
    local uninstall_standin = Standin.install(G, SMODS)
    local sok, serr = pcall(function()
      G.GAME.round_resets.ante = 2
      G.GAME.round_scores = { times_rerolled = { amt = 0 } }
      G.STATE = STATES.SHOP
      G.shop_jokers = { cards = {} }
      G.shop_vouchers = { cards = {} }
      local booster = { sort_id = 970, config = { center = G.P_CENTERS.p_arcana_normal_1 },
        ability = { set = "Booster", name = "Arcana Pack", extra = 3 }, cost = 4 }
      G.shop_booster = { cards = { booster } }
      settle()
      local shop = BES.last and BES.last.gs and BES.last.gs.shop
      t.ok(shop and shop.boosters[1] and shop.boosters[1].seer and #shop.boosters[1].seer.items == 3,
        "wiring: the seer deals the Arcana pack before it is bought")
      t.ok(shop and shop.seer_rerolls and #shop.seer_rerolls == 3, "wiring: ... and the next three rerolls")
      local panel = table.concat(Overlay.state.seer or {}, "\n")
      t.ok(panel:find("reroll 1:", 1, true) ~= nil, "wiring: the panel lists the next rerolls")
      t.ok(panel:find(" tem: ", 1, true) ~= nil, "wiring: ... and what the pack holds")
      -- the pack is bought and opened: the game deals it
      G.STATE = STATES.TAROT_PACK
      G.shop_booster = { cards = {} }
      SMODS.OPENED_BOOSTER = booster
      G.pack_cards = { cards = Standin.real_open("p_arcana_normal_1") }
      settle()
      t.eq(BES.seer.shop_ok, 1, "wiring: the opened pack matched the prediction")
      -- the pack closes; back in the shop, a reroll
      for _, c in ipairs(G.pack_cards.cards) do G.GAME.used_jokers[c.config.center.key] = nil end
      G.pack_cards = { cards = {} }
      SMODS.OPENED_BOOSTER = nil
      G.STATE = STATES.SHOP
      settle()
      Standin.real_reroll()
      G.GAME.round_scores.times_rerolled.amt = 1
      settle()
      t.eq(BES.seer.shop_ok, 2, "wiring: the reroll matched the prediction")
      t.eq(BES.seer.shop_miss, 0, "wiring: no pack/reroll miss")
      -- a reroll the prediction did not see coming (a stream moved behind its back): still checked
      settle()
      pseudoseed("cdt2"); pseudoseed("Joker1sho2"); pseudoseed("rarity2sho")
      Standin.real_reroll()
      G.GAME.round_scores.times_rerolled.amt = 2
      settle()
      t.eq(BES.seer.shop_miss + BES.seer.shop_ok, 3, "wiring: the next reroll was checked too")

      -- the blind select: the next round's opening hand is dealt from the round-start shuffle, shown, then checked
      G.shop_jokers, G.shop_vouchers, G.shop_booster = nil, nil, nil
      local all = {}
      for _, c in ipairs(cards) do all[#all + 1] = c end
      G.deck.cards, G.hand.cards = all, {}
      G.STATE = STATES.BLIND_SELECT
      G.GAME.round_resets.blind_states = { Small = "Select", Big = "Upcoming", Boss = "Upcoming" }
      settle()
      t.ok(BES.seer.round_pred ~= nil, "wiring: the next round's order is predicted at the blind select")
      local panel2 = table.concat(Overlay.state.seer or {}, "\n")
      t.ok(panel2:find("mão inicial da próxima rodada", 1, true) ~= nil, "wiring: the panel shows the next opening hand")
      t.ok(panel2:find("próximas cartas", 1, true) == nil, "wiring: ... and not the current deck order (it gets reshuffled)")
      -- the blind is selected: the game shuffles and deals
      G.STATE = STATES.SELECTING_HAND
      G.GAME.round_resets.blind_states = { Small = "Current", Big = "Upcoming", Boss = "Upcoming" }
      Standin.real_round_start(8)
      settle()
      t.eq(BES.seer.round_ok, 1, "wiring: the opening hand matched the predicted shuffle")
      t.eq(BES.seer.round_miss, 0, "wiring: no opening-hand miss")
      -- in the round, the shop that comes after it is predicted and shown
      t.ok(BES.seer.next_shop ~= nil, "wiring: the next shop is predicted during the round")
      t.ok(table.concat(Overlay.state.seer or {}, "\n"):find("próxima loja", 1, true) ~= nil, "wiring: ... and shown")
      -- the round ends, the shop opens: its shelf is checked against the prediction
      for _, c in ipairs(G.hand.cards) do G.deck.cards[#G.deck.cards + 1] = c end
      G.hand.cards = {}
      G.STATE = STATES.SHOP
      G.shop_jokers = { cards = { Standin.real_shop_card(), Standin.real_shop_card() } }
      G.shop_vouchers, G.shop_booster = { cards = {} }, { cards = {} }
      settle()
      t.eq(BES.seer.nshop_ok, 1, "wiring: the shop that opened is the predicted next shop")
    end)
    t.ok(sok, "wiring: the seer shop flow ran: " .. tostring(serr))
    uninstall_standin()
    G.shop_jokers, G.shop_vouchers, G.shop_booster, G.pack_cards = nil, nil, nil, nil
    love.keypressed("f4")
    t.ok(not BES.seer_on(), "wiring: F4 turns it off again")
  end)
  t.ok(ok, "EngineSim BR wiring smoke test ran without error: " .. tostring(err))
  for _, k in ipairs(SAVED_KEYS) do _G[k] = saved[k] end   -- every key, so a global that was nil is cleared again
  Log.level = saved_level
  require("util.i18n").set_lang("en")
  for _, m in ipairs({ "ui.settings", "ui.hud_panel", "ui.build_menu", "ui.highlights" }) do package.loaded[m] = nil end
end
