-- ui/overlay.lua
-- Owns the recommendation DISPLAY STATE: Overlay.set() turns the engine's RankedActionList into the
-- strings and numbers the native HUD panel (ui/hud_panel.lua) and the in-world highlights read.
-- Pure: no G, no love -- headless-testable.
--
-- EngineSim BR: every string goes through util/i18n (Portuguese by default in-game, English headless), with a final
-- pass that swaps the game's internal English names for the names the player sees. The state also carries the
-- itemised WHY (`details`), the next-best options like a chess engine's lines (`alts`), the run's stake/deck notes
-- (`context`), the build plan (`build`) and an ordering instruction (`order_note`, e.g. Death's drag).

local Cards = require("util.cards")
local I18N = require("util.i18n")

local Overlay = {}

Overlay.state = {
  title    = "ENGINE SIM",
  move     = "-",     -- full one-line move (verb, target, pack size, cost, tarot target)
  headline = "-",     -- the move WITHOUT the cost (the panel shows the cost as its own money tag)
  conf     = "",
  ev       = "",
  winp     = "",
  reorder  = "",
  reason   = "Waiting for a decision.",
  details  = nil,     -- list of strings: the itemised reasoning (skip / play breakdown, ...)
  alts     = nil,     -- list of strings: the next-best options
  context  = nil,     -- list of strings: stake / deck notes for this run (set by main.lua)
  build    = nil,     -- list of strings: the build plan (set by main.lua)
  order_note = nil,   -- an ordering instruction (Death: drag X to the left of Y)
  -- structured numbers for the panel's tags (nil = not applicable)
  cost = nil, banked = nil, conf_pct = nil, sim_backed = false,
  ev_pct = nil, ev_label = nil, win_pct = nil, run_pct = nil,
  version  = 0,       -- bumped on every change; the panel rebuilds when it moves
  -- the engine is working out the advice for the live state (main.lua BES.think_begin / think_end)
  thinking = false, thinking_since = 0, progress = 0,
}
-- Show "Thinking" only once it has lasted this long, so a quick answer doesn't flash the panel.
Overlay.THINK_SHOW_AFTER = 0.15

-- Engine errors (util/log on_error): the panel shows a red "!" while any is recent, the popup lists them.
Overlay.errors = {}            -- newest last: { t = <seconds>, clock = "HH:MM", msg = "..." }
Overlay.ERRORS_KEEP = 5
Overlay.ERROR_SHOW_FOR = 600   -- seconds an error keeps the indicator lit

function Overlay.add_error(msg, now, clock)
  local e = Overlay.errors
  e[#e + 1] = { t = now or 0, clock = clock or "", msg = tostring(msg) }
  while #e > Overlay.ERRORS_KEEP do table.remove(e, 1) end
end

-- A short confirmation tag on the panel (e.g. "Flagged (12)" after F5), shown for `dur` seconds.
Overlay.notice = nil           -- { text, until_t }
function Overlay.notify(text, now, dur)
  Overlay.notice = { text = tostring(text), until_t = (now or 0) + (dur or 3) }
  Overlay.state.version = (Overlay.state.version or 0) + 1
end
function Overlay.active_notice(now)
  local n = Overlay.notice
  if n and (now or 0) < n.until_t then return n.text end
  return nil
end

-- the errors still worth showing at time `now` (newest last)
function Overlay.recent_errors(now)
  local out = {}
  for _, e in ipairs(Overlay.errors) do
    if (now or 0) - e.t <= Overlay.ERROR_SHOW_FOR then out[#out + 1] = e end
  end
  return out
end
Overlay.action  = nil -- the raw best action (the in-world highlights read its cards / target ids)
Overlay.visible = true

local function cards_str(cards)
  local out = {}
  for _, c in ipairs(cards or {}) do out[#out + 1] = Cards.label(c) end
  return table.concat(out, " ")
end

local function jokers_str(list)
  local out = {}
  for _, j in ipairs(list or {}) do out[#out + 1] = j.name or j.key or "?" end
  return table.concat(out, " > ")
end

local function pct(x) return math.floor((x or 0) * 100 + 0.5) end

local VERB = {
  PLAY = "Play", DISCARD = "Discard", BUY_JOKER = "Buy", SELL_JOKER = "Sell",
  BUY_VOUCHER = "Buy", BUY_PACK = "Open", REROLL = "Reroll", SAVE = "Save",
  SKIP = "Skip", CONTINUE = "Play blind", PICK = "Take", BUY_CONSUMABLE = "Buy",
  USE_CONSUMABLE = "Use", SELL_TO_BUY = "Sell",
}
local VERB_PT = {
  PLAY = "Jogar", DISCARD = "Descartar", BUY_JOKER = "Comprar", SELL_JOKER = "Vender",
  BUY_VOUCHER = "Comprar", BUY_PACK = "Abrir", REROLL = "Reroll", SAVE = "Guardar $ (próxima rodada)",
  SKIP = "Pular", CONTINUE = "Jogar o blind", PICK = "Pegar", BUY_CONSUMABLE = "Comprar",
  USE_CONSUMABLE = "Usar", SELL_TO_BUY = "Vender",
}
local BUYS = { BUY_PACK = true, BUY_JOKER = true, BUY_CONSUMABLE = true, BUY_VOUCHER = true, SELL_TO_BUY = true }

function Overlay.verb(t)
  if I18N.is_pt() then return VERB_PT[t] or VERB[t] or t end
  return VERB[t] or t
end

-- the game's internal English names -> the player's language (identity in English)
local function L(s) return I18N.localize_names(s) end

-- 1234567 -> "1,234,567"; >= 10 million -> "12.3M" (keeps the panel tag short). Portuguese: "1.234.567" / "12,3M".
function Overlay.fmt_num(n)
  n = math.floor((n or 0) + 0.5)
  local pt = I18N.is_pt()
  if n >= 1e7 then
    local s = string.format("%.1fM", n / 1e6)
    return pt and (s:gsub("%.", ",")) or s
  end
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", pt and "%1." or "%1,"):reverse()
  return (out:gsub(pt and "^%." or "^,", ""))
end

-- One action as a short line ("Play KS KH (~1,240)" / "Buy Blueprint ($10)"), for the alternatives list.
function Overlay.describe(a)
  if type(a) ~= "table" or type(a.type) ~= "string" then return nil end
  local verb = Overlay.verb(a.type)
  local what = (a.cards and #a.cards > 0) and cards_str(a.cards)
    or (a.target and (a.target.name or a.target.key)) or ""
  local s = (what ~= "") and (verb .. " " .. what) or verb
  if a.target_note and a.target_note ~= "" then s = s .. " — " .. a.target_note end
  if a.hand_type and (a.type == "PLAY") then s = s .. " [" .. I18N.hand(a.hand_type) .. "]" end
  if a.type == "PLAY" and a.score then s = s .. " (~" .. Overlay.fmt_num(a.score) .. ")" end
  if BUYS[a.type] and a.cost and a.cost > 0 then s = s .. " ($" .. a.cost .. ")" end
  return L(s)
end

Overlay.ALTS_SHOWN = 3

-- Populate display state from a RankedActionList (engine output). `gs` (optional) is the state it
-- was decided on: for a PLAY it gives the chips still needed, so the panel can show the prediction.
function Overlay.set(ranked, gs)
  local s = Overlay.state
  s.version = (s.version or 0) + 1
  s.cost, s.banked, s.conf_pct, s.sim_backed = nil, nil, nil, false
  s.ev_pct, s.ev_label, s.win_pct, s.run_pct = nil, nil, nil, nil
  s.score_pred, s.score_need = nil, nil
  s.reorder = ""
  s.details, s.alts, s.order_note = nil, nil, nil
  if not ranked or not ranked.best then
    Overlay.action = nil
    s.move, s.headline, s.conf, s.ev, s.winp = "-", "-", "", "", ""
    s.reason = L(ranked and ranked.reason or (I18N.is_pt() and I18N.say("ui_no_rec") or "No recommendation."))
    return
  end
  local a = ranked.best
  Overlay.action = a
  local verb = Overlay.verb(a.type)
  local what = (a.cards and #a.cards > 0) and cards_str(a.cards)
    or (a.target and (a.target.name or a.target.key)) or ""
  local head = (what ~= "") and string.format("%s %s", verb, what) or verb
  -- For a pack, its pick-count so Normal/Jumbo (pick 1) vs Mega (pick 2) is unmistakable.
  -- 2026-08-26 advice-review request.
  if a.type == "BUY_PACK" and a.target and a.target.key then
    local ok, P = pcall(require, "engine.packs")
    if ok and P and P.size_label then
      local sz = P.size_label(a.target.key)          -- "Mega" / "Jumbo" / "Normal"
      local pick = (sz == "Mega") and 2 or 1
      head = head .. (I18N.is_pt() and string.format(" [%s, escolha %d]", sz, pick)
        or string.format(" [%s, pick %d]", sz, pick))
    end
  end
  local cost_str = ""
  if a.cost and a.cost > 0 and BUYS[a.type] then
    s.cost = a.cost
    cost_str = string.format(" — $%d", a.cost)
  end
  -- The target ("on which cards") is the actionable part of using a Tarot, so it goes in the
  -- headline, not just the reason: "Use Empress — apply to AS, KS" instead of a bare "Use Empress".
  local note = (a.target_note and a.target_note ~= "") and (" — " .. I18N.t(a.target_note)) or ""
  s.headline = L(head .. note)
  s.move = L(head .. cost_str .. note)
  -- Death: the drag instruction gets its own highlighted line in the popup (EngineSim BR)
  local oh = a.order_hint
  if oh and oh.kind == "death" then
    s.order_note = L(I18N.say("death_rule") .. (oh.swap and (" " .. I18N.say("death_drag", oh.target_label or "?",
      oh.source_label or "?") .. ".") or ""))
  end
  -- Be honest about what "confidence" means: a calibrated probability (from the
  -- simulation) vs a heuristic preference strength. Likewise only call the
  -- number "EV" when it is sim-backed; a heuristic ratio is shown as "Edge".
  local basis = a.confidence_basis or "heuristic_margin"
  local sim_backed = (basis == "win_probability" or basis == "draw_probability")
  s.sim_backed = sim_backed
  s.conf_pct = pct(a.confidence)
  if I18N.is_pt() then
    s.conf = string.format("Confiança: %d%%%s", s.conf_pct, sim_backed and " (simulada)" or " (heurística)")
    s.ev_label = sim_backed and "VE" or "Vantagem"
  else
    s.conf = string.format("Confidence: %d%%%s", s.conf_pct, sim_backed and " (sim)" or " (heuristic)")
    s.ev_label = sim_backed and "EV" or "Edge"
  end
  s.ev_pct = pct(a.expected_value)
  s.ev = string.format("%s: %+d%%", s.ev_label, s.ev_pct)
  if a.banked_money and a.banked_money > 0 then
    s.banked = a.banked_money
    s.ev = s.ev .. string.format(I18N.is_pt() and "   Guarda $%d" or "   Banks $%d", a.banked_money)
  end
  if a.win_probability ~= nil then
    s.win_pct, s.run_pct = pct(a.win_probability), pct(a.run_strength)
    s.winp = string.format(I18N.is_pt() and "Vencer: %d%%   Run: %d%%" or "Win: %d%%   Run: %d%%", s.win_pct, s.run_pct)
  else
    s.winp = ""
  end
  if a.reorder then -- decision_engine only sets this when a reorder is worth it
    local o, parts = a.reorder, {}
    local pt = I18N.is_pt()
    local tail
    if o.objective == "money" then tail = string.format(" (+$%g)", o.money_gain)
    elseif o.gain and o.gain > 0 then tail = string.format(" (+%d)", o.gain)
    else tail = pt and " (mais seguro)" or " (safer)" end
    if pt then
      -- (EngineSim BR) say it as an instruction: which order, left to right (the card tags number them 1..n)
      if o.card_changed then parts[#parts + 1] = I18N.say("reorder_play", cards_str(o.card_order)) end
      if o.joker_changed then parts[#parts + 1] = I18N.say("reorder_jokers", jokers_str(o.joker_order)) end
      s.reorder = L(table.concat(parts, ". ") .. tail)
    else
      if o.joker_changed then parts[#parts + 1] = "jokers " .. jokers_str(o.joker_order) end
      if o.card_changed then parts[#parts + 1] = "cards " .. cards_str(o.card_order) end
      s.reorder = "Reorder: " .. table.concat(parts, ", ") .. tail
    end
  end
  -- (EngineSim BR) the standing joker order suggested at blind select / in the shop
  if a.arrange_note and a.arrange_note ~= "" and s.reorder == "" then s.reorder = L(a.arrange_note) end
  -- predicted score of this play vs the chips still needed this blind (the engine's expected score)
  local b = gs and gs.blind
  if a.type == "PLAY" and a.score and b and (b.target_chips or 0) > 0 then
    local need = math.max(0, (b.target_chips or 0) - (b.chips_scored or 0))
    if need > 0 then s.score_pred, s.score_need = a.score, need end
  end
  s.reason = L(I18N.t(a.reason or ""))
  if type(a.details) == "table" and #a.details > 0 then
    s.details = {}
    for i, d in ipairs(a.details) do s.details[i] = L(d) end
  end
  -- the next-best options (a chess engine's other lines)
  if type(ranked.alternatives) == "table" and #ranked.alternatives > 0 then
    local alts, seen = {}, { [s.headline] = true }
    for _, alt in ipairs(ranked.alternatives) do
      if #alts >= Overlay.ALTS_SHOWN then break end
      local line = Overlay.describe(alt)
      if line and not seen[line] then seen[line] = true; alts[#alts + 1] = line end
    end
    if #alts > 0 then s.alts = alts end
  end
end

-- Context lines (stake / deck notes) and the build plan: set by main.lua, shown in the popup.
local function localized(lines)
  if type(lines) ~= "table" or #lines == 0 then return nil end
  local out = {}
  for i, l in ipairs(lines) do out[i] = L(l) end
  return out
end

function Overlay.set_context(lines)
  local s = Overlay.state
  local new = localized(lines)
  local old = s.context
  local same = (old == nil and new == nil)
  if old and new and #old == #new then
    same = true
    for i = 1, #new do if old[i] ~= new[i] then same = false end end
  end
  if not same then s.context = new; s.version = (s.version or 0) + 1 end
end
function Overlay.set_seer(lines)
  local s = Overlay.state
  local new = localized(lines)
  local old = s.seer
  local same = (old == nil and new == nil)
  if old and new and #old == #new then
    same = true
    for i = 1, #new do if old[i] ~= new[i] then same = false end end
  end
  if not same then s.seer = new; s.version = (s.version or 0) + 1 end
end

function Overlay.set_build(lines)
  local s = Overlay.state
  local new = localized(lines)
  local old = s.build
  local same = (old == nil and new == nil)
  if old and new and #old == #new then
    same = true
    for i = 1, #new do if old[i] ~= new[i] then same = false end end
  end
  if not same then s.build = new; s.version = (s.version or 0) + 1 end
end

function Overlay.set_thinking(on, now)
  local s = Overlay.state
  s.thinking = on and true or false
  s.thinking_since = now or 0
  s.progress = 0
end

-- Is the thinking state worth SHOWING at time `now`? (past the anti-flash delay)
function Overlay.show_thinking(now)
  local s = Overlay.state
  return s.thinking and ((now or 0) - (s.thinking_since or 0)) >= Overlay.THINK_SHOW_AFTER
end

-- Replace only the reason line (a transient status such as "Evaluating pack…").
function Overlay.set_reason(text)
  Overlay.state.reason = L(I18N.t(text or ""))
  Overlay.state.version = (Overlay.state.version or 0) + 1
end

return Overlay
