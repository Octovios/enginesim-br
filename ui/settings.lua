-- ui/settings.lua
-- The mod's settings page in Steamodded's Mods menu (owner 2026-10-02), built from the game's own toggle and
-- option-cycle widgets. Steamodded loads `config.lua` (defaults) merged with the saved config/<id>.jkr into
-- SMODS.current_mod.config before main.lua runs, and saves it when the Mods menu is left.
-- S.apply (called every frame by main.lua) pushes the values to the panel, the tags and fast self-play, so a
-- change takes effect at once. F9 flips `show_panel` too, so the key and the menu never disagree.
--
-- EngineSim BR: language (Portuguese by default), skip policy, the build to force at the start of every run, and a
-- button that opens the build menu. All labels follow the chosen language.

local I18N = require("util.i18n")

local S = {}
S.DEFAULTS = { show_panel = true, show_tags = true, fast_selfplay = true, fast_speed = 16, think_mode = "balanced",
               language = "pt_BR", skip_policy = "auto", default_build = "auto", seer_mode = false }
S.SPEEDS = { 4, 8, 16, 32, 64 }
-- "While thinking": how much of each frame the engine may use (main.lua BES.slice_budget)
S.THINK_MODES = { "smooth", "balanced", "fast" }
S.THINK_LABELS = { en = { "Smooth", "Balanced", "Fast" }, pt_BR = { "Suave", "Equilibrado", "Rápido" } }
S.LANGS = { "pt_BR", "en", "auto" }
S.LANG_LABELS = { "Português (BR)", "English", "Auto" }
S.SKIP_POLICIES = { "auto", "conservative", "never" }
S.SKIP_LABELS = { en = { "Analyse (recommended)", "Conservative", "Never skip" },
                  pt_BR = { "Analisar (recomendado)", "Conservador", "Nunca pular" } }
S.cfg = nil
S._applied_panel = nil
S._applied_lang = nil
S.builds_fn = nil       -- function() -> { { id, name }, ... }  (main.lua: the build catalogue)
S.game_lang_fn = nil    -- function() -> the game's language code (main.lua)

-- Bind to the mod's config table (filling any missing default); headless callers pass nil.
function S.init(mod)
  local cfg = (mod and type(mod.config) == "table") and mod.config or {}
  for k, v in pairs(S.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
  if mod then mod.config = cfg end
  S.mod = mod
  S.cfg = cfg
  S._applied_panel = nil
  S._applied_lang = nil
  return cfg
end

-- The language the mod speaks: the setting, or for "auto" the game's own language.
function S.language()
  local c = S.cfg or S.DEFAULTS
  local l = c.language or "pt_BR"
  if l == "auto" then
    local g = S.game_lang_fn and S.game_lang_fn() or nil
    return (type(g) == "string" and g:sub(1, 2) == "pt") and "pt_BR" or "en"
  end
  return l
end

-- Push the settings to the live modules: ctx = { overlay =, highlights =, fast =, scheduler =, skip = }.
-- show_panel is applied on CHANGE only, so it never fights a transient state.
function S.apply(ctx)
  local c = S.cfg
  if not c then return end
  if c.show_panel ~= S._applied_panel then
    S._applied_panel = c.show_panel
    if ctx.overlay then ctx.overlay.visible = c.show_panel and true or false end
  end
  if ctx.highlights then ctx.highlights.enabled = c.show_tags and true or false end
  if ctx.fast then
    ctx.fast.enabled = c.fast_selfplay and true or false
    ctx.fast.SPEED = tonumber(c.fast_speed) or S.DEFAULTS.fast_speed
  end
  if ctx.scheduler then ctx.scheduler.think_mode = c.think_mode or S.DEFAULTS.think_mode end
  if ctx.skip and ctx.skip.set_policy and ctx.skip.POLICY ~= c.skip_policy then ctx.skip.set_policy(c.skip_policy) end
  local lang = S.language()
  if lang ~= S._applied_lang then
    S._applied_lang = lang
    I18N.set_lang(lang)
    if ctx.on_language then pcall(ctx.on_language, lang) end
  end
end

local function save()
  if S.mod and SMODS and SMODS.save_mod_config then pcall(SMODS.save_mod_config, S.mod) end
end
S.save = save

-- F9: flip the panel setting (S.apply shows / hides it next frame) and SAVE it. Steamodded saves the config only
-- when the Mods menu is left, so a panel switched on with F9 was off again at the next launch (live 2026-11-14).
function S.toggle_panel()
  if not S.cfg then return nil end
  S.cfg.show_panel = not S.cfg.show_panel
  save()
  return S.cfg.show_panel
end

local function index_of(list, v, default)
  for i, s in ipairs(list) do if s == v then return i end end
  return default or 1
end

local function labels(t) return t[I18N.lang] or t.en end

-- the build cycle: "auto" + every build id, with display names
local function build_options()
  local ids, names = { "auto" }, { I18N.is_pt() and "Automático" or "Automatic" }
  for _, b in ipairs((S.builds_fn and S.builds_fn()) or {}) do ids[#ids + 1] = b.id; names[#names + 1] = b.name end
  return ids, names
end

-- The settings page (Steamodded calls this when the mod's Config tab opens).
function S.tab()
  local cfg = S.cfg or S.init(nil)
  local pt = I18N.is_pt()
  local speeds = {}
  for i, v in ipairs(S.SPEEDS) do speeds[i] = "x" .. v end
  local function heading(t)
    return { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.T, config = { text = t, scale = 0.45, colour = G.C.GOLD, shadow = true } },
    } }
  end
  local bids, bnames = build_options()
  S._build_ids = bids
  return { n = G.UIT.ROOT, config = { align = "cm", padding = 0.12, colour = G.C.BLACK, r = 0.1, emboss = 0.05, minw = 8 }, nodes = {
    heading(pt and "Conselhos" or "Advice"),
    create_option_cycle({ label = pt and "Idioma do mod" or "Mod language", options = S.LANG_LABELS,
      current_option = index_of(S.LANGS, cfg.language, 1), opt_callback = "bes_cfg_language", scale = 0.8, w = 4 }),
    create_toggle({ label = pt and "Mostrar o painel (F9)" or "Show the advice panel (F9)", ref_table = cfg, ref_value = "show_panel", w = 4.5 }),
    create_toggle({ label = pt and "Marcar as cartas recomendadas" or "Tag the recommended cards", ref_table = cfg, ref_value = "show_tags", w = 4.5 }),
    create_option_cycle({ label = pt and "Enquanto pensa" or "While thinking", options = labels(S.THINK_LABELS),
      current_option = index_of(S.THINK_MODES, cfg.think_mode, 2), opt_callback = "bes_cfg_think_mode", scale = 0.8, w = 3,
      info = { pt and "Suave: taxa de quadros cheia. Equilibrado: 60 fps. Rápido: responde antes, perde quadros."
                  or "Smooth: full frame rate.  Balanced: 60 fps.  Fast: answers sooner, frames drop." } }),
    create_option_cycle({ label = pt and "Pular blinds" or "Skipping blinds", options = labels(S.SKIP_LABELS),
      current_option = index_of(S.SKIP_POLICIES, cfg.skip_policy, 1), opt_callback = "bes_cfg_skip_policy", scale = 0.8, w = 4,
      info = { pt and "Analisar: compara a tag com jogar (recompensa da ficha, loja, juros, coringas que crescem)."
                  or "Analyse: weighs the tag against playing (stake reward, shop, interest, growing jokers)." } }),
    create_toggle({ label = I18N.say("seer_setting"), ref_table = cfg, ref_value = "seer_mode", w = 4.5,
      info = { I18N.say("seer_setting_info") } }),
    heading(pt and "Build" or "Build"),
    create_option_cycle({ label = pt and "Build ao começar uma run" or "Build to force at run start", options = bnames,
      current_option = index_of(bids, cfg.default_build, 1), opt_callback = "bes_cfg_default_build", scale = 0.8, w = 5,
      info = { pt and "F3 durante a run abre o menu de builds com a viabilidade de cada uma."
                  or "F3 during a run opens the build menu with each build's viability." } }),
    heading(pt and "Autoplay (F11)" or "Self-play (F11)"),
    create_toggle({ label = pt and "Pular animações no autoplay" or "Skip animations while it plays", ref_table = cfg, ref_value = "fast_selfplay", w = 4.5,
      info = { pt and "Usa o pulo de animação do mod Handy. Sua própria jogada não é afetada."
                  or "Uses the Handy mod's animation skip. Your own play is never affected." } }),
    create_option_cycle({ label = pt and "Velocidade do autoplay" or "Self-play speed", options = speeds, current_option = index_of(S.SPEEDS, cfg.fast_speed, 3),
      opt_callback = "bes_cfg_fast_speed", scale = 0.8, w = 3 }),
    { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = {
      { n = G.UIT.T, config = { text = pt and "Salvo ao sair do menu de Mods." or "Saved when you leave the Mods menu.", scale = 0.28, colour = G.C.UI.TEXT_INACTIVE } },
    } },
  } }
end

-- option-cycle callbacks (the game passes { to_key, to_val, ... })
function S.on_speed(args)
  if S.cfg and args then S.cfg.fast_speed = S.SPEEDS[args.to_key] or S.cfg.fast_speed end
end
function S.on_think_mode(args)
  if S.cfg and args then S.cfg.think_mode = S.THINK_MODES[args.to_key] or S.cfg.think_mode end
end
function S.on_language(args)
  if S.cfg and args then S.cfg.language = S.LANGS[args.to_key] or S.cfg.language end
end
function S.on_skip_policy(args)
  if S.cfg and args then S.cfg.skip_policy = S.SKIP_POLICIES[args.to_key] or S.cfg.skip_policy end
end
function S.on_default_build(args)
  if S.cfg and args then
    local ids = S._build_ids or build_options()
    S.cfg.default_build = ids[args.to_key] or "auto"
  end
end

-- Register with Steamodded (in-game only).
function S.install(mod)
  S.init(mod)
  if G and G.FUNCS then
    G.FUNCS.bes_cfg_fast_speed = S.on_speed
    G.FUNCS.bes_cfg_think_mode = S.on_think_mode
    G.FUNCS.bes_cfg_language = S.on_language
    G.FUNCS.bes_cfg_skip_policy = S.on_skip_policy
    G.FUNCS.bes_cfg_default_build = S.on_default_build
  end
  if mod then mod.config_tab = S.tab end
end

return S
