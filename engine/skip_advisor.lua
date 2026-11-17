-- engine/skip_advisor.lua
-- Should you SKIP the (Small/Big) blind to take its tag, or PLAY it? Compares
-- the tag's value against what playing gives up: the blind reward, the shop
-- visit, and the unused-hand money you'd bank. Boss blinds can't be skipped.
-- PURE.
--
-- EngineSim BR rewrite (2026-11):
--   * the REAL reward of the blind for this stake (Red Stake and up: the Small Blind pays $0) and this deck (Green
--     Deck: no interest, $2 per unused hand, $1 per unused discard) -- engine/run_context;
--   * the GROWTH of the jokers you own: playing feeds Green Joker / Runner / Wee Joker / Lucky Cat / Supernova...,
--     selecting the blind fires Madness, and decaying jokers (Ice Cream, Popcorn, Gros Michel...) lose value;
--     skipping feeds Throwback -- measured on your board (engine/scaling_growth), in the same dollars as the tag;
--   * an itemised breakdown (`details`) so the panel shows WHY, e.g. "Play: $0 reward (Red Stake), but the shop
--     (~$9) and Green Joker +2 Mult (~$3) beat the Investment Tag";
--   * the engine's own judgement is the default policy again ("auto"). The original author had restricted skips to
--     the Investment Tag at ante 1 because the old valuation measured neutral; that rule remains available as the
--     "conservative" policy in the settings.

local Rng = require("util.rng")
local Flags = require("engine.flags")
local Tags = require("engine.tags")
local Mechanics = require("engine.mechanics")
local Generators = require("engine.generators")
local Eval = require("engine.eval_function")
local Income = require("engine.joker_income")
local Pacing = require("engine.pacing")
local Packs = require("engine.packs")
local VU = require("engine.value_units")
local RunContext = require("engine.run_context")
local ScalingGrowth = require("engine.scaling_growth")
local I18N = require("util.i18n")

local SK = {}

-- Rough value of the shop visit you forgo by skipping (purchasing opportunity).
SK.SHOP_VALUE = 6
-- ...but the shop is where your BUILD comes from, and it's worth far more the emptier
-- your board: skipping your FIRST shop leaves you with a bare deck into the boss (a
-- real, sim-confirmed cause of early deaths -- the engine arrived at ante-1 Big/Boss
-- with ZERO jokers because it skipped Small for a tag). Scale the forgone-shop value up
-- as the board empties, so a boardless engine plays to buy its first jokers; a full
-- board values the shop less, so a strong tag can still justify a skip.
SK.BOARDLESS_SHOP_MULT = 2.0
-- Hysteresis: skipping forgoes a guaranteed shop + reward + build progress for a
-- speculative tag, so the tag must CLEARLY beat playing, not merely edge it out --
-- otherwise the engine skips every time a tag's raw $-equivalent tops playing.
SK.SKIP_MARGIN = 1.25
-- SKIP POLICY (EngineSim BR): "auto" = the engine's measured judgement (default); "conservative" = the original
-- mod's rule (skip only for the Investment tag at ante 1); "never" = always play. Set from the settings page.
SK.POLICY = Flags.str("BES_SKIP_POLICY", "auto")
SK.SKIP_FREE = (SK.POLICY == "auto")
SK.SKIP_ALLOWED = { tag_investment = 1 }   -- tag key -> last ante a skip for it is allowed (conservative policy)
SK.TYPICAL_JOKER_COST = 5   -- \$ a shop joker costs (as SA.TYPICAL_JOKER_COST)

-- RISK-AWARE SHOP (A/B switch BES_SKIP_RISK=<k>, default off). The forgone shop is where an AT-RISK board finds
-- power, so its value grows with the calibrated P(die within 2 antes) (Pacing.risk): x(1 + k*risk). Live CYDQ4Q9N
-- a5 (2026-10-02): at ~88% risk it skipped BOTH blinds (Economy tag $25 vs a flat ~$12 for playing, then Standard),
-- reached the boss with $50 and no shop since ante 4, and died at 0.79. k = 3 puts the line where the largest money
-- tag ($25) stops beating a full board's play at ~70% risk.
SK.RISK_SHOP_MULT = Flags.num("BES_SKIP_RISK", 0)

function SK.set_policy(p)
  if p ~= "auto" and p ~= "conservative" and p ~= "never" then p = "auto" end
  SK.POLICY = p
  SK.SKIP_FREE = (p == "auto")
end

-- Deterministic per-state RNG so the measured tag values (Orbital, pack tags) are
-- stable across re-evaluations of the same blind-select.
local lcg = Rng.stream
local function state_seed(gs)
  local d = #(gs.deck or {}) * 40503 + ((gs.economy and gs.economy.dollars) or 0) * 7919
  return Rng.seed(d)
end

local function round(x) return math.floor((x or 0) + 0.5) end

-- The tag's display name: the game's own (state_extraction), else the module's English name localized.
local TAG_PT = {
  tag_investment = "Investimento", tag_economy = "Economia", tag_coupon = "Cupom", tag_voucher = "Vale",
  tag_d6 = "D6", tag_speed = "Velocidade", tag_handy = "Prática", tag_garbage = "Lixo", tag_uncommon = "Incomum",
  tag_rare = "Rara", tag_negative = "Negativa", tag_foil = "Laminada", tag_holo = "Holográfica",
  tag_polychrome = "Policromática", tag_double = "Dupla", tag_buffoon = "Bufão", tag_meteor = "Meteoro",
  tag_charm = "Amuleto", tag_ethereal = "Etérea", tag_standard = "Padrão", tag_orbital = "Orbital",
  tag_top_up = "Recarga", tag_juggle = "Malabarismo", tag_boss = "Chefe",
}
function SK.tag_name(gs, key, fallback)
  local live = gs and gs.blind and gs.blind.skip_tag_name
  if live and live ~= "" then return live end
  if I18N.is_pt() then
    local pt = TAG_PT[key]
    if pt then return "Tag " .. pt end
  end
  return (fallback or "?") .. " Tag"
end

-- recommend(gs, opts) -> { recommend="SKIP"|"PLAY", tag, tag_value, play_value, reason, details, parts }
-- or nil if not a skippable situation / no tag info.
function SK.recommend(gs, opts)
  opts = opts or {}
  local b = gs.blind or {}
  local btype = b.blind_type
  if btype == "Boss" then return nil end          -- can't skip the boss
  local tag_key = b.skip_tag
  if not tag_key then return nil end              -- no offered tag known

  local tval, tname0 = Tags.value(gs, tag_key,
    { rng = opts.rng or lcg(state_seed(gs)), samples = opts.samples or 8 })
  local tname = SK.tag_name(gs, tag_key, tname0)

  -- the REAL reward: Red Stake and up pay $0 for the Small Blind (engine/run_context)
  local reward = RunContext.blind_reward(gs, btype)
  local nominal = Mechanics.BLIND_REWARD[btype] or 3
  -- you'd also bank money per hand you don't need to play; assume you clear with a couple to spare on a non-boss
  -- blind. The deck sets the rate (Green Deck: $2 per hand and $1 per unused discard).
  local spare_hands = math.max(0, ((b.base_hands or 4) - 2))
  local hand_money = spare_hands * RunContext.hand_money(gs)
  local discard_money = RunContext.discard_money(gs) * math.max(0, (b.base_discards or 0) - 1)
  -- PLAYING the blind fires the board's MONEY jokers for a round (Business Card / Bloodstone / Faceless /
  -- Rough Gem / ...), deck-aware -- money you FORGO by skipping. econ_power is $/round the board generates.
  local joker_econ = Income.econ_power(gs) or 0
  -- jokers that fire when you SELECT the blind (Cartomancer/Riff-Raff/Marble)
  -- are free value you forgo by skipping -> credit them to PLAYING.
  local gen_v, gen_note = Generators.blind_select_value(gs)
  -- the forgone-shop value scales up as the board empties (don't skip your first joker)
  local njokers = #(gs.jokers or {})
  local slots = (gs.run and gs.run.joker_slots) or 5
  local fill = math.min(1, njokers / math.max(1, slots))
  local shop_value = SK.SHOP_VALUE * (1 + SK.BOARDLESS_SHOP_MULT * (1 - fill))
  -- THE SAME CURRENCY AS THE TAG (2026-10-03, live NUJ9ENYU a2, owner-confirmed): with a free slot the shop you skip
  -- is worth the joker you would buy there: the best of a fresh shop's jokers, measured and converted at the same
  -- rate, less its price.
  local free = slots - njokers
  if free > 0 and gs.deck and #gs.deck >= 5 then
    local ok, e = pcall(Packs.expected_shop_joker, gs, 2, { rng = lcg(state_seed(gs) + 31), samples = 3, measure_count = 4 })
    if ok and e and e > 0 then
      shop_value = math.max(shop_value, VU.frac_to_dollars(gs, e) - SK.TYPICAL_JOKER_COST)
    end
  end
  local risk_pct = nil
  if SK.RISK_SHOP_MULT > 0 then
    local ok, pc = pcall(Pacing.pace, gs, { rng = lcg(state_seed(gs) + 17) })
    local risk = ok and pc and pc.risk or 0
    shop_value = shop_value * (1 + SK.RISK_SHOP_MULT * risk)
    if risk >= 0.5 then risk_pct = round(risk * 100) end
  end
  -- INTEREST is paid only at a cash-out, which a skipped blind does not have (0 on the Green Deck)
  local e = gs.economy or {}
  local interest = RunContext.interest(gs, e.dollars or 0)

  -- JOKER GROWTH (EngineSim BR): what one more blind played / skipped does to the jokers you own
  local growth = { play_dollars = 0, skip_dollars = 0, play_items = {}, skip_items = {} }
  if opts.growth ~= false then
    local okg, g = pcall(ScalingGrowth.play_vs_skip, gs, { seed = state_seed(gs) + 101 })
    if okg and type(g) == "table" then growth = g end
  end

  local play_value = reward + shop_value + hand_money + discard_money + gen_v + joker_econ + interest
    + (growth.play_dollars or 0)
  local skip_value = tval + (growth.skip_dollars or 0)

  local skip = skip_value > play_value * SK.SKIP_MARGIN
  local held_back = false
  if skip then
    if SK.POLICY == "never" then
      skip, held_back = false, true
    elseif SK.POLICY == "conservative" then
      local until_ante = SK.SKIP_ALLOWED[tag_key]
      local ante = math.floor((gs.meta and gs.meta.ante) or 1)
      if not (until_ante and ante <= until_ante) then skip, held_back = false, true end
    end
  end

  -- ---- the explanation ----------------------------------------------------------------------------------------
  local stake = RunContext.stake_info(gs)
  local stake_name = (gs.run and gs.run.stake_name) or (I18N.is_pt() and stake.pt or stake.en)
  local details = {}
  local function line(s) details[#details + 1] = s end
  line(I18N.say("skip_play_total", round(play_value)))
  if reward == 0 and nominal > 0 then
    line(I18N.say("skip_reward_unpaid", stake_name))
  else
    line(I18N.say("skip_reward", reward))
  end
  line(I18N.say("skip_shop", round(shop_value)))
  if hand_money + discard_money >= 1 then line(I18N.say("skip_hand_money", round(hand_money + discard_money))) end
  if RunContext.no_interest(gs) then line(I18N.say("skip_no_interest"))
  elseif interest >= 1 then line(I18N.say("skip_interest", round(interest))) end
  if joker_econ >= 1 then line(I18N.say("skip_joker_econ", round(joker_econ))) end
  if gen_v >= 1 and gen_note ~= "" then line(I18N.say("skip_generators", gen_note, round(gen_v))) end
  for _, it in ipairs(growth.play_items or {}) do
    if math.abs(it.dollars or 0) >= 0.5 then
      line(I18N.say((it.dollars or 0) >= 0 and "skip_growth_item" or "skip_decay_item",
        it.name or "?", it.text or "", round(math.abs(it.dollars or 0))))
    end
  end
  if risk_pct then line(I18N.say("skip_risk", risk_pct)) end
  line(I18N.say("skip_skip_total", round(skip_value), tname, round(tval)))
  for _, it in ipairs(growth.skip_items or {}) do
    if math.abs(it.dollars or 0) >= 0.5 then
      line(I18N.say("skip_growth_item", it.name or "?", it.text or "", round(it.dollars or 0)))
    end
  end

  local pv, sv = round(play_value), round(skip_value)
  local why_play = ""
  if reward == 0 and nominal > 0 then why_play = I18N.say("skip_why_unpaid_but_play", stake_name) end
  local reason
  if skip then
    reason = I18N.say("skip_verdict_skip", tname, sv, pv)
  elseif held_back then
    reason = I18N.say(SK.POLICY == "never" and "skip_verdict_policy_never" or "skip_verdict_policy_cons", tname, sv, pv)
  else
    reason = I18N.say("skip_verdict_play", tname, sv, pv) .. why_play
  end
  -- the single most important growth item, in the one-line reason
  local top = growth.play_items and growth.play_items[1]
  if not skip and top and (top.dollars or 0) >= 1 then
    reason = reason .. " " .. I18N.say("skip_top_growth", top.name or "?", top.text or "")
  end

  return {
    recommend = skip and "SKIP" or "PLAY",
    tag = tname, tag_key = tag_key, tag_value = tval, play_value = play_value, skip_value = skip_value,
    reason = reason, details = details, held_back = held_back or nil,
    parts = { reward = reward, nominal_reward = nominal, shop = shop_value, hand_money = hand_money,
      discard_money = discard_money, interest = interest, joker_econ = joker_econ, generators = gen_v,
      growth_play = growth.play_dollars or 0, growth_skip = growth.skip_dollars or 0 },
  }
end

return SK
