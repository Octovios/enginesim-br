-- ui/build_menu.lua  (EngineSim BR)
-- The "force a build" menu (F3 in a run, or the button on the settings page): every build of engine/archetypes with
-- how viable it is for THIS run (deck, stake, jokers you own / were offered), built from the game's own overlay
-- menu and button nodes so it looks like the rest of Balatro. Picking one tells main.lua (M.on_pick); "Automatic"
-- clears it. Runtime-only (needs G); M.cells is headless-testable with a stub G.

local I18N = require("util.i18n")
local Log = require("util.log")

local M = {}
M.on_pick = nil      -- function(id_or_nil)        set by main.lua
M.rows_fn = nil      -- function() -> rows          (engine/build_advisor.menu_rows on the live state)
M.current_fn = nil   -- function() -> forced id or nil
M.COLS = 3

local function txt(s, scale, colour)
  return { n = G.UIT.T, config = { text = tostring(s or ""), scale = scale, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } }
end

local function cell(label, sub, id, colour)
  return { n = G.UIT.C, config = { align = "cm", padding = 0.05 }, nodes = {
    { n = G.UIT.C, config = { align = "cm", padding = 0.07, r = 0.1, hover = true, shadow = true, colour = colour,
        minw = 3.7, maxw = 3.7, minh = 0.8, button = "bes_build_pick", ref_table = { id = id } }, nodes = {
      { n = G.UIT.R, config = { align = "cm", maxw = 3.5 }, nodes = { txt(label, 0.33) } },
      { n = G.UIT.R, config = { align = "cm", maxw = 3.5 }, nodes = { txt(sub, 0.26, G.C.UI.TEXT_LIGHT) } },
    } },
  } }
end

-- The grid cells (pure apart from G colours/UIT): "Automatic" first, then every build best-first.
function M.cells(rows, current)
  local out = {}
  out[#out + 1] = cell(I18N.say("build_menu_auto"), "", "__auto", current == nil and G.C.GREEN or G.C.BLUE)
  for _, r in ipairs(rows or {}) do
    local sub
    if r.blocked then sub = I18N.say("build_menu_infeasible", r.reason or "?")
    elseif r.viability then sub = I18N.say("build_menu_viability", r.viability)
    else sub = "" end
    local colour = (r.id == current) and G.C.GREEN or (r.blocked and G.C.UI.BACKGROUND_INACTIVE or G.C.RED)
    out[#out + 1] = cell(r.name, sub, r.id, colour)
  end
  return out
end

function M.definition()
  local rows = (M.rows_fn and M.rows_fn()) or {}
  local current = M.current_fn and M.current_fn() or nil
  local cells = M.cells(rows, current)
  local grid = {}
  for i = 1, #cells, M.COLS do
    local r = { n = G.UIT.R, config = { align = "cm" }, nodes = {} }
    for j = i, math.min(i + M.COLS - 1, #cells) do r.nodes[#r.nodes + 1] = cells[j] end
    grid[#grid + 1] = r
  end
  local contents = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = { txt(I18N.say("build_menu_title"), 0.55, G.C.WHITE) } },
    { n = G.UIT.R, config = { align = "cm" }, nodes = { { n = G.UIT.C, config = { align = "cm" }, nodes = grid } } },
    { n = G.UIT.R, config = { align = "cm", padding = 0.05, maxw = 11.5 }, nodes = {
      txt(I18N.say("build_menu_hint"), 0.27, G.C.UI.TEXT_LIGHT) } },
  }
  return create_UIBox_generic_options({ contents = contents })
end

function M.open()
  if not (_G.G and G.FUNCS and G.FUNCS.overlay_menu and type(_G.create_UIBox_generic_options) == "function") then return end
  local ok, def = pcall(M.definition)
  if not ok then Log.error("build menu failed:", def); return end
  G.FUNCS.overlay_menu({ definition = def })
end

function M.install()
  if not (_G.G and G.FUNCS) then return end
  G.FUNCS.bes_build_pick = function(e)
    local id = e and e.config and e.config.ref_table and e.config.ref_table.id
    if id == "__auto" then id = nil end
    local ok, err = pcall(function() if M.on_pick then M.on_pick(id) end end)
    if not ok then Log.error("build pick failed:", err) end
    if G.FUNCS.exit_overlay_menu then G.FUNCS.exit_overlay_menu() end
  end
  G.FUNCS.bes_open_build_menu = function() M.open() end
end

return M
