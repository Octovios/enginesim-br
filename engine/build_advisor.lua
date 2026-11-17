-- engine/build_advisor.lua  (EngineSim BR)
-- Which BUILD should this run go for -- and, when the player has chosen one, how the rest of the engine leans
-- toward it. PURE: reads the game state (gs) and the build catalogue (engine/archetypes).
--
-- What it weighs for every build:
--   * the DECK: can it even make the build? (engine/run_context deck_profile -- an Abandoned Deck or a deck thinned
--     of faces has no King / Queen / face build; a Checkered Deck is two suits; an Erratic Deck is whatever it is)
--   * the JOKERS: owned core pieces count fully, support pieces half; pieces on offer RIGHT NOW (shop / pack) count
--     partly, and pieces SEEN earlier in this run's shops a little (gs.run.seen_jokers, recorded by main.lua) --
--     "builds based on the jokers that already showed up";
--   * what the run has already invested: hand levels, the hands it actually plays, the enhancement it needs.
--
-- FORCED BUILD (the player picks one in the F3 menu or the settings): gs.run.forced_build = archetype id. Then
--   * engine/build_plan.fit adds a large bonus for its core pieces (and a smaller one for support), a penalty for
--     pieces that fight it; keep_bias protects its pieces from being sold;
--   * the build plan commits to its hand (planets level it) through engine/decision_state;
--   * engine/deck_plan aims Death / Strength / Hanged Man / thinning at its suit, ranks or faces;
--   * consumable valuation favours the tarots/spectrals that shape the deck toward it.
-- AUTO (no forced build): only a light nudge toward the core pieces of the leading build once it has really started
-- (two-plus pieces), so the engine assembles SETS instead of a pile of unrelated jokers; the panel lists the top
-- builds with what you have and what to look for.

local A = require("engine.archetypes")
local RC = require("engine.run_context")
local JokerData = require("engine.joker_data")
local I18N = require("util.i18n")

local BA = {}

BA.FORCE_CORE_FIT = 2.6      -- shop-utility units (same as engine/build_plan fit): a strong joker's measured gain
BA.FORCE_SUPPORT_FIT = 1.2
BA.FORCE_ANTI_FIT = -1.6
BA.AUTO_CORE_FIT = 0.6
BA.AUTO_SUPPORT_FIT = 0.25
BA.AUTO_MIN_PROGRESS = 0.38  -- the leading build must have at least ~one core piece + support to steer purchases
BA.AUTO_MIN_VIABILITY = 0.45
BA.TAROT_BONUS = 0.12        -- fraction of a boss hand (engine/consumable_value units)
BA.TAROT_OFFPLAN = -0.05
BA.VIABLE_MIN = 0.15
BA.SUGGEST_N = 3

local SUIT_TAROT = { c_star = "Diamonds", c_moon = "Clubs", c_sun = "Hearts", c_world = "Spades" }

local function lang() return I18N.lang end

-- ---- sets -------------------------------------------------------------------------------------------------------
local function owned_set(gs)
  local o = {}
  for _, j in ipairs(gs.jokers or {}) do if j.key then o[A.norm(j.key)] = true end end
  return o
end
local function offered_set(gs)
  local o = {}
  for _, j in ipairs((gs.shop and gs.shop.jokers) or {}) do if j.key then o[A.norm(j.key)] = true end end
  for _, it in ipairs((gs.pack and gs.pack.items) or {}) do
    if it.set == "Joker" and it.key then o[A.norm(it.key)] = true end
  end
  return o
end
local function seen_set(gs)
  local s = gs.run and gs.run.seen_jokers
  local o = {}
  if type(s) == "table" then for k, v in pairs(s) do if v then o[A.norm(k)] = v end end end
  return o
end

local function joker_name(key)
  local d = JokerData.resolve(key)
  return (d and d.name) or key
end

-- ---- one build ----------------------------------------------------------------------------------------------------
function BA.evaluate(gs, arch, p, owned, offered, seen)
  p = p or RC.deck_profile(gs)
  owned, offered, seen = owned or owned_set(gs), offered or offered_set(gs), seen or seen_set(gs)
  local f, reason, rarg = arch.deck(p, owned)
  f = math.max(0, math.min(1, f or 0))
  -- deck-back emphasis (on top of the composition): Plasma favours chip-heavy builds, Checkered its two suits
  local dk = RC.deck_key(gs)
  if dk == "b_plasma" and (arch.id == "stone" or arch.id == "straight" or arch.id == "flush_spades") then f = math.min(1, f * 1.15) end

  local pieces, own_l, miss_l, off_l, seen_l = 0, {}, {}, {}, {}
  for _, k in ipairs(arch.core or {}) do
    if owned[k] then pieces = pieces + 1; own_l[#own_l + 1] = k
    elseif offered[k] then pieces = pieces + 0.35; off_l[#off_l + 1] = k; miss_l[#miss_l + 1] = k
    elseif seen[k] then pieces = pieces + 0.1; seen_l[#seen_l + 1] = k; miss_l[#miss_l + 1] = k
    else miss_l[#miss_l + 1] = k end
  end
  for _, k in ipairs(arch.support or {}) do
    if owned[k] then pieces = pieces + 0.45; own_l[#own_l + 1] = k
    elseif offered[k] then pieces = pieces + 0.15; off_l[#off_l + 1] = k end
  end
  local anti = 0
  for _, k in ipairs(arch.anti or {}) do if owned[k] then anti = anti + 1 end end
  local progress = math.min(1, pieces / (arch.need or 2.5))

  -- what the run already invested in it
  local bonus = 0
  local levels = gs.run and gs.run.hand_levels or {}
  for _, h in ipairs(arch.hands or {}) do
    local lv = levels[h]
    if lv then bonus = bonus + math.max(0, (lv.level or 1) - 1) * 0.04 end
  end
  bonus = math.min(0.2, bonus)
  local plays = gs.run and gs.run.hand_type_plays
  if arch.hands and type(plays) == "table" then
    local total, hit = 0, 0
    for h, n in pairs(plays) do
      total = total + (n or 0)
      for _, ah in ipairs(arch.hands) do if h == ah then hit = hit + (n or 0) end end
    end
    if total >= 6 then bonus = bonus + 0.2 * (hit / total) end
  end
  if arch.enh then bonus = bonus + math.min(0.3, 0.04 * (p.enh[arch.enh] or 0)) end
  bonus = bonus - 0.1 * anti

  local done = math.max(0, math.min(1, progress + bonus))
  local entry = {
    id = arch.id, arch = arch, f = f, reason = (f < BA.VIABLE_MIN) and reason or nil, reason_arg = rarg,
    progress = progress, ready = f * done, viability = f * (0.3 + 0.7 * done),
    owned = own_l, missing = miss_l, offered = off_l, seen = seen_l, anti = anti,
  }
  return entry
end

-- ---- ranking (cached per snapshot) -------------------------------------------------------------------------------
local CACHE = setmetatable({}, { __mode = "k" })
local function sig(gs)
  local parts = { tostring(gs.run and gs.run.forced_build), tostring(#(gs.deck or {})) }
  for _, j in ipairs(gs.jokers or {}) do parts[#parts + 1] = j.key or "?" end
  parts[#parts + 1] = "|"
  for _, j in ipairs((gs.shop and gs.shop.jokers) or {}) do parts[#parts + 1] = j.key or "?" end
  for _, it in ipairs((gs.pack and gs.pack.items) or {}) do parts[#parts + 1] = it.key or "?" end
  return table.concat(parts, ",")
end

function BA.rank(gs)
  local key = gs.run or gs
  local s = sig(gs)
  local hit = CACHE[key]
  if hit and hit.sig == s then return hit.list end
  local p = RC.deck_profile(gs)
  local owned, offered, seen = owned_set(gs), offered_set(gs), seen_set(gs)
  local list = {}
  for _, arch in ipairs(A.LIST) do list[#list + 1] = BA.evaluate(gs, arch, p, owned, offered, seen) end
  table.sort(list, function(a, b)
    if math.abs(a.viability - b.viability) > 1e-9 then return a.viability > b.viability end
    return a.arch.order < b.arch.order
  end)
  CACHE[key] = { sig = s, list = list }
  return list
end

function BA.entry(gs, id)
  for _, e in ipairs(BA.rank(gs)) do if e.id == id then return e end end
  return nil
end

-- ---- the build the engine leans toward ----------------------------------------------------------------------------
function BA.forced(gs)
  local id = gs and gs.run and gs.run.forced_build
  return A.get(id)
end

-- auto mode: the leading build, only once it has really started
function BA.auto_target(gs)
  if BA.forced(gs) then return nil end
  local top = BA.rank(gs)[1]
  if top and top.progress >= BA.AUTO_MIN_PROGRESS and top.viability >= BA.AUTO_MIN_VIABILITY then return top end
  return nil
end

-- (fit, note) for buying / keeping joker `key` (engine/build_plan.fit adds it)
function BA.joker_fit(gs, key)
  if not key then return 0, nil end
  local forced = BA.forced(gs)
  local L = lang()
  if forced then
    local role = A.role(forced, key)
    local nm = A.name(forced, L)
    if role == "core" then return BA.FORCE_CORE_FIT, I18N.say("build_fit_note", nm) end
    if role == "support" then return BA.FORCE_SUPPORT_FIT, I18N.say("build_fit_note", nm) end
    if role == "anti" then return BA.FORCE_ANTI_FIT, I18N.say("build_offplan_note", nm) end
    return 0, nil
  end
  local top = BA.auto_target(gs)
  if top then
    local role = A.role(top.arch, key)
    local nm = A.name(top.arch, L)
    if role == "core" then return BA.AUTO_CORE_FIT, I18N.say("build_fit_note", nm) end
    if role == "support" then return BA.AUTO_SUPPORT_FIT, I18N.say("build_fit_note", nm) end
    if role == "anti" then return -BA.AUTO_CORE_FIT, I18N.say("build_offplan_note", nm) end
  end
  return 0, nil
end

-- extra sell protection for the forced build's pieces (engine/build_plan.keep_bias takes the max)
function BA.keep_bias(gs, key, core_keep)
  local forced = BA.forced(gs)
  if not forced then return 0 end
  local role = A.role(forced, key)
  if role == "core" then return core_keep * 1.5 end
  if role == "support" then return core_keep end
  return 0
end

-- consumable valuation bonus (fraction of a boss hand), forced builds only
function BA.consumable_bonus(gs, key)
  local forced = BA.forced(gs)
  if not forced or not key then return 0 end
  if forced._tarots[key] then return BA.TAROT_BONUS end
  local s = SUIT_TAROT[key]
  if s and forced.suit and s ~= forced.suit then return BA.TAROT_OFFPLAN end
  return 0
end

-- the deck-plan target of the forced build (nil = let engine/deck_plan decide)
function BA.deck_target(gs)
  local forced = BA.forced(gs)
  if not forced or not forced.target then return nil end
  local p = RC.deck_profile(gs)
  local t = forced.target(p) or {}
  if not (t.suit or t.ranks or t.face) then return nil end
  return t, forced
end

-- ---- text for the panel -------------------------------------------------------------------------------------------
local function names(keys, n)
  local out = {}
  for i, k in ipairs(keys or {}) do
    if i > (n or 3) then break end
    out[#out + 1] = joker_name(k)
  end
  return table.concat(out, ", ")
end

local function pieces_text(e)
  local parts = {}
  if #e.owned > 0 then parts[#parts + 1] = I18N.say("build_have", names(e.owned, 3)) end
  if #e.missing > 0 then parts[#parts + 1] = I18N.say("build_need", names(e.missing, 2)) end
  if #parts == 0 then return I18N.say("build_none") end
  return table.concat(parts, "; ")
end

local function pct(x) return math.floor((x or 0) * 100 + 0.5) end

function BA.summary_lines(gs)
  local L = lang()
  local lines = {}
  local forced = BA.forced(gs)
  if forced then
    local e = BA.entry(gs, forced.id)
    if e then
      lines[#lines + 1] = I18N.say("build_forced", A.name(forced, L), pct(e.ready))
      lines[#lines + 1] = "  " .. pieces_text(e)
      if #e.offered > 0 then lines[#lines + 1] = "  " .. I18N.say("build_seen", names(e.offered, 3)) end
      if e.reason then
        lines[#lines + 1] = "  " .. I18N.say("build_blocked", A.name(forced, L), I18N.say(e.reason, e.reason_arg and I18N.suit_word(e.reason_arg) or nil))
      end
      local tarots = {}
      for _, k in ipairs(forced.tarots or {}) do if #tarots < 3 then tarots[#tarots + 1] = k end end
      if #tarots > 0 then
        lines[#lines + 1] = "  " .. A.desc(forced, L)
      end
    end
    return lines
  end
  local list = BA.rank(gs)
  lines[#lines + 1] = I18N.say("build_suggest")
  local n = 0
  for _, e in ipairs(list) do
    if n >= BA.SUGGEST_N then break end
    -- only builds that have STARTED (a piece owned, on offer or seen, or levels / plays invested): ranking untouched
    -- builds against each other is noise
    if e.f >= BA.VIABLE_MIN and e.ready > 0.005 then
      n = n + 1
      lines[#lines + 1] = "  " .. I18N.say("build_line", n, A.name(e.arch, L), pct(e.ready), pieces_text(e))
    end
  end
  if n == 0 then
    lines[#lines + 1] = "  " .. I18N.say("build_none_started")
    -- what the deck itself favours (a Checkered Deck's two flushes, a deck concentrated in one rank...)
    local fav, prof = {}, RC.deck_profile(gs)
    for _, e in ipairs(list) do
      if #fav >= 2 then break end
      if e.f >= BA.VIABLE_MIN and e.arch.favoured and e.arch.favoured(prof) then fav[#fav + 1] = A.name(e.arch, L) end
    end
    if #fav > 0 then lines[#lines + 1] = "  " .. I18N.say("build_deck_favours", table.concat(fav, ", ")) end
  end
  -- a build you hold pieces of but the deck can't make (Baron on an Abandoned Deck)
  for _, e in ipairs(list) do
    if e.f < BA.VIABLE_MIN and #e.owned > 0 and e.reason then
      lines[#lines + 1] = "  " .. I18N.say("build_blocked", A.name(e.arch, L),
        I18N.say(e.reason, e.reason_arg and I18N.suit_word(e.reason_arg) or nil))
      break
    end
  end
  return lines
end

-- What the stake and the deck change in this run (the panel's "This run" lines).
function BA.context_lines(gs)
  local L = lang()
  local lines = {}
  local st = RC.stake_info(gs)
  local sname = (gs.run and gs.run.stake_name) or (L == "pt_BR" and st.pt or st.en)
  if RC.small_blind_unpaid(gs) then lines[#lines + 1] = I18N.say("ctx_red_stake", sname) end
  if RC.scaling(gs) > 1 then
    local req = RC.requirement(gs, 8, "Boss")
    local s = tostring(math.floor(req))
    s = s:reverse():gsub("(%d%d%d)", L == "pt_BR" and "%1." or "%1,"):reverse():gsub(L == "pt_BR" and "^%." or "^,", "")
    lines[#lines + 1] = I18N.say("ctx_scaling", sname, s)
  end
  local stick = RC.stickers(gs)
  if stick.eternal then lines[#lines + 1] = I18N.say("ctx_eternal") end
  if stick.perishable then lines[#lines + 1] = I18N.say("ctx_perishable") end
  if stick.rental then lines[#lines + 1] = I18N.say("ctx_rental") end
  local d = RC.deck_info(gs)
  local dname = (gs.run and gs.run.deck_name) or (d and (L == "pt_BR" and d.pt or d.en)) or nil
  local traits = RC.deck_traits(gs)
  if traits.balance then lines[#lines + 1] = I18N.say("ctx_plasma", dname or "Plasma") end
  if RC.no_interest(gs) then lines[#lines + 1] = I18N.say("ctx_green_deck", dname or "?") end
  if traits.no_faces then lines[#lines + 1] = I18N.say("ctx_no_faces", dname or "?") end
  if traits.two_suits and traits.profile.n > 0 then
    local present = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      if (traits.profile.suits[s] or 0) > 0 then present[#present + 1] = I18N.suit_word(s) end
    end
    if #present == 2 then lines[#lines + 1] = I18N.say("ctx_two_suits", dname or "?", present[1], present[2]) end
  end
  if traits.erratic then lines[#lines + 1] = I18N.say("ctx_erratic", dname or "?") end
  if RC.deck_key(gs) == "b_painted" then lines[#lines + 1] = I18N.say("ctx_painted", dname or "?") end
  local v = gs.run and gs.run.vouchers_owned
  if type(v) == "table" and v.v_observatory then lines[#lines + 1] = I18N.say("ctx_observatory") end
  return lines
end

-- The menu's rows: every build with its viability for this run, best first (ui/build_menu).
function BA.menu_rows(gs)
  local L = lang()
  local rows = {}
  for _, e in ipairs(BA.rank(gs)) do
    rows[#rows + 1] = { id = e.id, name = A.name(e.arch, L), desc = A.desc(e.arch, L), viability = pct(e.viability),
      ready = pct(e.ready), blocked = e.f < BA.VIABLE_MIN,
      reason = e.reason and I18N.say(e.reason, e.reason_arg and I18N.suit_word(e.reason_arg) or nil) or nil }
  end
  return rows
end

return BA
