-- engine/archetypes.lua  (EngineSim BR)
-- The catalogue of BUILDS a run can aim for: what defines each one (its core jokers), what supports it, what the
-- DECK must contain for it to work, which hands to level, which tarots/spectrals shape the deck toward it and what
-- the deck plan should keep (suit / ranks / faces). PURE data + small pure helpers.
--
-- Used by engine/build_advisor (ranking builds for the panel, the forced-build mode) and through it by the
-- engine's planning hooks (engine/build_plan fit / keep, engine/deck_plan target, consumable valuation).
-- Joker keys are the live game keys (the base game spells Gluttonous Joker "j_gluttenous_joker").

local A = {}

-- Standard 52-card reference shares (what a fresh deck holds), for "how much of the deck can this use".
A.REF = { faces = 12 / 52, kings = 4 / 52, queens = 4 / 52, suit = 13 / 52, evens = 20 / 52, odds = 20 / 52,
          fib = 20 / 52, low = 16 / 52, twos = 4 / 52, aces = 4 / 52 }

local function share(x, n) return (x or 0) / math.max(1, n or 0) end
local function clamp01(x) return math.max(0, math.min(1, x)) end

-- deck-feasibility helpers: return f (0..1), reason key, reason argument
local function need_count(count, n, ref, reason, arg)
  if (count or 0) <= 0 then return 0, reason, arg end
  return clamp01(share(count, n) / ref), nil, nil
end

local function low_count(p) return (p.ranks[2] or 0) + (p.ranks[3] or 0) + (p.ranks[4] or 0) + (p.ranks[5] or 0) end

local function faces_or_pareidolia(p, owned)
  if owned and owned.j_pareidolia then return 1, nil end
  return need_count(p.faces, p.n, A.REF.faces, "build_reason_no_faces")
end

local function suit_fit(suit)
  return function(p, owned)
    if owned and owned.j_smeared and (suit == "Hearts" or suit == "Diamonds") then
      return clamp01(share((p.suits.Hearts or 0) + (p.suits.Diamonds or 0) + p.wilds, p.n) / (2 * A.REF.suit)), nil
    elseif owned and owned.j_smeared then
      return clamp01(share((p.suits.Spades or 0) + (p.suits.Clubs or 0) + p.wilds, p.n) / (2 * A.REF.suit)), nil
    end
    local c = (p.suits[suit] or 0) + p.wilds
    if c <= 0 then return 0, "build_reason_no_suit", suit end
    -- a quarter of the deck is the baseline (0.5); half the deck or more is a full fit
    return clamp01(0.5 * share(c, p.n) / A.REF.suit), nil
  end
end

local function rank_concentration(p)
  -- how concentrated the ranks are: the top rank's copies vs a fresh deck's 4
  return clamp01(0.55 + 0.15 * math.max(0, (p.top_rank_n or 0) - 4))
end

-- Each build:
--   id, name = { en, pt }, desc = { en, pt }
--   hands    = hands to level (first = the main one; nil for hand-agnostic builds)
--   core     = joker keys that DEFINE the build;  support = joker keys that help it;  anti = joker keys that fight it
--   tarots   = consumable keys that shape the deck toward it (enhancements, suit converters, rank tools)
--   enh      = the enhancement it wants (counts toward readiness)
--   deck(p, owned) -> f (0..1), reason_key, reason_arg   -- what the DECK allows (p = RunContext.deck_profile)
--   target(p) -> DeckPlan target fields { suit =, ranks =, face = }
--   need     = core-piece weight that makes the build "complete" (default 2.5)
--   kind     = "hand" (default when hands) | "economy" | "free"
A.LIST = {
  { id = "flush_any",
    name = { en = "Flush (any suit)", pt = "Flush (qualquer naipe)" },
    desc = { en = "Five of one suit; level Flush with Jupiter.", pt = "Cinco do mesmo naipe; suba Flush com Jupiter." },
    hands = { "Flush" },
    core = { "j_tribe", "j_droll", "j_crafty", "j_smeared", "j_four_fingers" },
    support = { "j_seance", "j_blueprint", "j_brainstorm", "j_lusty_joker", "j_greedy_joker", "j_wrathful_joker",
                "j_gluttenous_joker", "j_bloodstone", "j_arrowhead", "j_onyx_agate", "j_rough_gem", "j_blackboard" },
    anti = { "j_flower_pot", "j_seeing_double" },
    tarots = { "c_star", "c_moon", "c_sun", "c_world", "c_lovers", "c_death", "c_hanged_man", "c_sigil" },
    enh = "m_wild",
    deck = function(p) return clamp01(0.55 + 2 * math.max(0, (p.dominant_share or 0.25) - 0.25)), nil end,
    target = function(p) return { suit = p.dominant_suit } end },

  { id = "flush_hearts",
    name = { en = "Hearts Flush (Bloodstone)", pt = "Flush de Copas (Bloodstone)" },
    desc = { en = "All-in on Hearts: Bloodstone xMult, Lusty Joker.", pt = "Tudo em Copas: Bloodstone xMult, Lusty Joker." },
    hands = { "Flush" }, suit = "Hearts",
    core = { "j_bloodstone", "j_lusty_joker", "j_tribe", "j_droll", "j_crafty" },
    support = { "j_smeared", "j_four_fingers", "j_oops", "j_blueprint", "j_brainstorm", "j_seance" },
    anti = { "j_flower_pot", "j_seeing_double", "j_wrathful_joker", "j_gluttenous_joker", "j_greedy_joker" },
    tarots = { "c_sun", "c_lovers", "c_death", "c_hanged_man", "c_sigil" }, enh = "m_wild",
    deck = suit_fit("Hearts"), target = function() return { suit = "Hearts" } end },

  { id = "flush_diamonds",
    name = { en = "Diamonds Flush (Rough Gem)", pt = "Flush de Ouros (Rough Gem)" },
    desc = { en = "Diamonds pay: Rough Gem $1 each, Greedy Joker.", pt = "Ouros dão dinheiro: Rough Gem $1 cada, Greedy Joker." },
    hands = { "Flush" }, suit = "Diamonds",
    core = { "j_rough_gem", "j_greedy_joker", "j_tribe", "j_droll", "j_crafty" },
    support = { "j_smeared", "j_four_fingers", "j_bull", "j_bootstraps", "j_blueprint", "j_brainstorm", "j_seance" },
    anti = { "j_flower_pot", "j_seeing_double", "j_wrathful_joker", "j_gluttenous_joker", "j_lusty_joker" },
    tarots = { "c_star", "c_lovers", "c_death", "c_hanged_man", "c_sigil" }, enh = "m_wild",
    deck = suit_fit("Diamonds"), target = function() return { suit = "Diamonds" } end },

  { id = "flush_spades",
    name = { en = "Spades Flush (Arrowhead)", pt = "Flush de Espadas (Arrowhead)" },
    desc = { en = "Spades: Arrowhead +50 Chips each, Wrathful Joker, Blackboard.", pt = "Espadas: Arrowhead +50 Fichas cada, Wrathful Joker, Blackboard." },
    hands = { "Flush" }, suit = "Spades",
    core = { "j_arrowhead", "j_wrathful_joker", "j_blackboard", "j_tribe", "j_droll", "j_crafty" },
    support = { "j_smeared", "j_four_fingers", "j_blueprint", "j_brainstorm", "j_seance" },
    anti = { "j_flower_pot", "j_seeing_double", "j_lusty_joker", "j_greedy_joker" },
    tarots = { "c_world", "c_lovers", "c_death", "c_hanged_man", "c_sigil" }, enh = "m_wild",
    deck = suit_fit("Spades"), target = function() return { suit = "Spades" } end },

  { id = "flush_clubs",
    name = { en = "Clubs Flush (Onyx Agate)", pt = "Flush de Paus (Onyx Agate)" },
    desc = { en = "Clubs: Onyx Agate +7 Mult each, Gluttonous Joker, Blackboard.", pt = "Paus: Onyx Agate +7 Mult cada, Gluttonous Joker, Blackboard." },
    hands = { "Flush" }, suit = "Clubs",
    core = { "j_onyx_agate", "j_gluttenous_joker", "j_blackboard", "j_tribe", "j_droll", "j_crafty" },
    support = { "j_smeared", "j_four_fingers", "j_blueprint", "j_brainstorm", "j_seance" },
    anti = { "j_flower_pot", "j_lusty_joker", "j_greedy_joker" },
    tarots = { "c_moon", "c_lovers", "c_death", "c_hanged_man", "c_sigil" }, enh = "m_wild",
    deck = suit_fit("Clubs"), target = function() return { suit = "Clubs" } end },

  { id = "straight",
    name = { en = "Straight", pt = "Sequência" },
    desc = { en = "Straights with The Order x3, Runner growing, Shortcut.", pt = "Sequências com The Order x3, Runner crescendo, Shortcut." },
    hands = { "Straight" },
    core = { "j_order", "j_crazy", "j_devious", "j_runner", "j_shortcut", "j_four_fingers" },
    support = { "j_superposition", "j_seance", "j_blueprint", "j_brainstorm", "j_hanging_chad" },
    anti = {},
    tarots = { "c_strength", "c_death" },
    deck = function(p) return (p.n_suits > 0 and 1 or 0.6), nil end,
    target = function() return {} end },

  { id = "pairs",
    name = { en = "Pair / Two Pair", pt = "Par e Dois Pares" },
    desc = { en = "Small hands: The Duo, Jolly, Mad, Spare Trousers.", pt = "Mãos pequenas: The Duo, Jolly, Mad, Spare Trousers." },
    hands = { "Two Pair", "Pair" },
    core = { "j_duo", "j_jolly", "j_sly", "j_mad", "j_clever", "j_trousers" },
    support = { "j_half", "j_hanging_chad", "j_blueprint", "j_brainstorm", "j_card_sharp" },
    anti = {},
    tarots = { "c_death", "c_strength", "c_hanged_man" },
    deck = function(p) return rank_concentration(p), nil end,
    target = function(p) return { ranks = p.top_rank and { [p.top_rank] = true } or nil } end },

  { id = "fullhouse",
    name = { en = "Three of a Kind / Full House", pt = "Trinca e Full House" },
    desc = { en = "The Trio x3 + The Duo x2 both fire on a Full House.", pt = "The Trio x3 e The Duo x2 disparam juntos no Full House." },
    hands = { "Full House", "Three of a Kind" },
    core = { "j_trio", "j_duo", "j_zany", "j_wily", "j_jolly", "j_trousers" },
    support = { "j_mad", "j_clever", "j_sly", "j_blueprint", "j_brainstorm", "j_hanging_chad" },
    anti = { "j_half" },
    tarots = { "c_death", "c_strength", "c_hanged_man", "c_cryptid" },
    deck = function(p) return rank_concentration(p), nil end,
    target = function(p) return { ranks = p.top_rank and { [p.top_rank] = true } or nil } end },

  { id = "four",
    name = { en = "Four of a Kind", pt = "Quadra" },
    desc = { en = "The Family x4 (plus Trio and Duo); concentrate one rank.", pt = "The Family x4 (mais Trio e Duo); concentre um valor." },
    hands = { "Four of a Kind" },
    core = { "j_family", "j_trio", "j_duo", "j_zany", "j_wily" },
    support = { "j_jolly", "j_sly", "j_blueprint", "j_brainstorm", "j_dna" },
    anti = { "j_half" },
    tarots = { "c_death", "c_strength", "c_hanged_man", "c_cryptid" },
    deck = function(p) return rank_concentration(p), nil end,
    target = function(p) return { ranks = p.top_rank and { [p.top_rank] = true } or nil } end },

  { id = "five",
    name = { en = "Five of a Kind / Flush Five", pt = "Quina / Flush Five" },
    desc = { en = "Copy one card many times (Death, Cryptid, DNA); secret hands score huge.",
             pt = "Copie uma carta várias vezes (Death, Cryptid, DNA); mãos secretas pontuam muito." },
    hands = { "Five of a Kind", "Flush Five" }, need = 3,
    core = { "j_family", "j_trio", "j_duo", "j_dna", "j_smeared" },
    support = { "j_zany", "j_jolly", "j_blueprint", "j_brainstorm", "j_hanging_chad" },
    anti = { "j_half" },
    tarots = { "c_death", "c_cryptid", "c_ouija", "c_sigil", "c_hanged_man" },
    deck = function(p) return clamp01(0.35 + 0.15 * math.max(0, (p.top_rank_n or 0) - 4)), nil end,
    target = function(p) return { ranks = p.top_rank and { [p.top_rank] = true } or nil } end },

  { id = "faces",
    name = { en = "Face cards (J/Q/K)", pt = "Realeza (J/Q/K)" },
    desc = { en = "Photograph, Sock and Buskin, Smiley/Scary Face on every face card.",
             pt = "Photograph, Sock and Buskin, Smiley/Scary Face em cada carta de realeza." },
    hands = nil, kind = "free",
    core = { "j_photograph", "j_sock_and_buskin", "j_smiley", "j_scary_face", "j_pareidolia", "j_triboulet", "j_caino" },
    support = { "j_hanging_chad", "j_business", "j_reserved_parking", "j_midas_mask", "j_blueprint", "j_brainstorm", "j_faceless" },
    anti = { "j_ride_the_bus" },
    tarots = { "c_strength", "c_death", "c_familiar", "c_hanged_man" },
    deck = faces_or_pareidolia,
    target = function() return { face = true } end },

  { id = "steel_kings",
    name = { en = "Steel Kings (Baron + Mime)", pt = "Reis de Aço (Baron + Mime)" },
    desc = { en = "Hold Kings (Steel, Red Seal): Baron x1.5 each, Mime retriggers, Shoot the Moon on Queens.",
             pt = "Segure Reis (de Aço, Selo Vermelho): Baron x1.5 cada, Mime repete, Shoot the Moon nas Rainhas." },
    hands = nil, kind = "free", need = 2,
    core = { "j_baron", "j_mime", "j_steel_joker", "j_shoot_the_moon", "j_triboulet" },
    support = { "j_blueprint", "j_brainstorm", "j_raised_fist", "j_sock_and_buskin", "j_pareidolia" },
    anti = {},
    tarots = { "c_chariot", "c_strength", "c_death", "c_deja_vu", "c_familiar" }, enh = "m_steel",
    deck = function(p, owned)
      local k = (p.kings or 0) + 0.6 * (p.queens or 0)
      if k <= 0 then
        if (p.faces or 0) > 0 then return 0.15, "build_reason_no_kings" end
        return 0, "build_reason_no_faces"
      end
      return clamp01(share(k, p.n) / A.REF.kings * 0.6), nil
    end,
    target = function() return { ranks = { [13] = true, [12] = true } } end },

  { id = "even",
    name = { en = "Even ranks (Even Steven)", pt = "Números pares (Even Steven)" },
    desc = { en = "2/4/6/8/10: Even Steven +4 Mult each, Walkie Talkie on 10s and 4s.",
             pt = "2/4/6/8/10: Even Steven +4 Mult cada, Walkie Talkie nos 10 e 4." },
    hands = nil, kind = "free",
    core = { "j_even_steven", "j_walkie_talkie", "j_hack" },
    support = { "j_wee", "j_hanging_chad", "j_blueprint", "j_brainstorm", "j_dusk" },
    anti = { "j_odd_todd", "j_fibonacci", "j_scholar" },
    tarots = { "c_strength", "c_death", "c_hanged_man", "c_incantation" },
    deck = function(p) return need_count(p.evens, p.n, A.REF.evens, "build_reason_few_ranks") end,
    target = function() return { ranks = { [2] = true, [4] = true, [6] = true, [8] = true, [10] = true } } end },

  { id = "odd_fib",
    name = { en = "Fibonacci / odd ranks", pt = "Fibonacci e ímpares" },
    desc = { en = "A/2/3/5/8 for Fibonacci +8 Mult; Odd Todd and Scholar on Aces.",
             pt = "A/2/3/5/8 para Fibonacci +8 Mult; Odd Todd e Scholar nos Ases." },
    hands = nil, kind = "free",
    core = { "j_fibonacci", "j_odd_todd", "j_scholar", "j_hack" },
    support = { "j_wee", "j_superposition", "j_hanging_chad", "j_blueprint", "j_brainstorm" },
    anti = { "j_even_steven", "j_walkie_talkie" },
    tarots = { "c_strength", "c_death", "c_hanged_man", "c_grim" },
    deck = function(p) return need_count(p.fib + 0.5 * math.max(0, p.odds - p.fib), p.n, A.REF.fib, "build_reason_few_ranks") end,
    target = function() return { ranks = { [14] = true, [2] = true, [3] = true, [5] = true, [8] = true } } end },

  { id = "hack_low",
    name = { en = "Low cards (Hack + Wee Joker)", pt = "Cartas baixas (Hack + Wee Joker)" },
    desc = { en = "Hack retriggers 2-5; Wee Joker grows on every scored 2.",
             pt = "Hack repete 2 a 5; Wee Joker cresce a cada 2 pontuado." },
    hands = nil, kind = "free",
    core = { "j_hack", "j_wee", "j_walkie_talkie", "j_fibonacci" },
    support = { "j_even_steven", "j_odd_todd", "j_hanging_chad", "j_blueprint", "j_brainstorm", "j_dusk" },
    anti = { "j_scary_face", "j_smiley", "j_photograph" },
    tarots = { "c_death", "c_hanged_man", "c_incantation" },
    deck = function(p)
      local f = clamp01(share(low_count(p), p.n) / A.REF.low)
      if (p.twos or 0) <= 0 and low_count(p) <= 0 then return 0, "build_reason_few_ranks" end
      return f, nil
    end,
    target = function() return { ranks = { [2] = true, [3] = true, [4] = true, [5] = true } } end },

  { id = "lucky",
    name = { en = "Lucky cards (Lucky Cat + Oops)", pt = "Cartas da Sorte (Lucky Cat + Oops)" },
    desc = { en = "Magician makes Lucky cards; Lucky Cat grows on every trigger, Oops! All 6s doubles the odds.",
             pt = "The Magician cria cartas da Sorte; Lucky Cat cresce a cada acerto, Oops! All 6s dobra as chances." },
    hands = nil, kind = "free",
    core = { "j_lucky_cat", "j_oops", "j_bloodstone" },
    support = { "j_hanging_chad", "j_sock_and_buskin", "j_blueprint", "j_brainstorm", "j_business", "j_space" },
    anti = {},
    tarots = { "c_magician", "c_deja_vu" }, enh = "m_lucky",
    deck = function() return 0.8, nil end,
    target = function() return {} end },

  { id = "glass",
    name = { en = "Glass cards (Glass Joker)", pt = "Cartas de Vidro (Glass Joker)" },
    desc = { en = "Justice makes Glass (x2); Glass Joker grows when they break; Hanging Chad retriggers.",
             pt = "Justice cria Vidro (x2); Glass Joker cresce quando quebram; Hanging Chad repete." },
    hands = nil, kind = "free",
    core = { "j_glass", "j_hanging_chad", "j_sock_and_buskin", "j_photograph" },
    support = { "j_oops", "j_blueprint", "j_brainstorm", "j_dusk", "j_hack" },
    anti = { "j_vampire" },
    tarots = { "c_justice", "c_deja_vu" }, enh = "m_glass",
    deck = function() return 0.8, nil end,
    target = function() return {} end },

  { id = "stone",
    name = { en = "Stone cards (Stone Joker)", pt = "Cartas de Pedra (Stone Joker)" },
    desc = { en = "Tower and Marble Joker add Stone cards (+50 Chips, always score); Stone Joker +25 per Stone.",
             pt = "The Tower e Marble Joker criam Pedras (+50 Fichas, sempre pontuam); Stone Joker +25 por Pedra." },
    hands = nil, kind = "free",
    core = { "j_stone", "j_marble", "j_splash" },
    support = { "j_hologram", "j_bull", "j_blueprint", "j_brainstorm", "j_hanging_chad" },
    anti = { "j_vampire" },
    tarots = { "c_tower" }, enh = "m_stone",
    deck = function() return 0.75, nil end,
    target = function() return {} end },

  { id = "gold_money",
    name = { en = "Money (Bull / Bootstraps / Gold)", pt = "Dinheiro (Bull / Bootstraps / Ouro)" },
    desc = { en = "Bank cash and turn it into score: Bull +2 Chips per $, Bootstraps +2 Mult per $5; Gold cards pay.",
             pt = "Acumule dinheiro e transforme em pontos: Bull +2 Fichas por $, Bootstraps +2 Mult por $5; cartas de Ouro pagam." },
    hands = nil, kind = "economy",
    core = { "j_bull", "j_bootstraps", "j_ticket", "j_to_the_moon", "j_midas_mask" },
    support = { "j_golden", "j_rocket", "j_cloud_9", "j_rough_gem", "j_egg", "j_business", "j_reserved_parking" },
    anti = {},
    tarots = { "c_devil", "c_hermit", "c_temperance", "c_talisman" }, enh = "m_gold",
    deck = function() return 0.8, nil end,
    target = function() return {} end },

  { id = "discard",
    name = { en = "Discards (Yorick / Castle / Burnt)", pt = "Descartes (Yorick / Castle / Burnt)" },
    desc = { en = "Grow on discards: Yorick, Castle, Hit the Road; Burnt Joker levels your first discarded hand.",
             pt = "Cresça descartando: Yorick, Castle, Hit the Road; Burnt Joker sobe a primeira mão descartada." },
    hands = nil, kind = "free",
    core = { "j_yorick", "j_castle", "j_hit_the_road", "j_burnt", "j_drunkard", "j_merry_andy" },
    support = { "j_faceless", "j_mail", "j_trading", "j_blueprint", "j_brainstorm" },
    anti = { "j_green_joker", "j_ramen", "j_delayed_grat", "j_banner" },
    tarots = {},
    deck = function() return 0.8, nil end,
    target = function() return {} end },

  { id = "planets",
    name = { en = "Planets (Constellation)", pt = "Planetas (Constellation)" },
    desc = { en = "Every planet feeds Constellation; Satellite and Astronomer pay for them; level one hand hard.",
             pt = "Cada planeta alimenta a Constellation; Satellite e Astronomer pagam por eles; suba muito uma mão." },
    hands = nil, kind = "free",
    core = { "j_constellation", "j_satellite", "j_astronomer", "j_space" },
    support = { "j_supernova", "j_blueprint", "j_brainstorm", "j_burnt" },
    anti = {},
    tarots = { "c_high_priestess", "c_trance", "c_black_hole" },
    deck = function() return 0.85, nil end,
    target = function() return {} end },

  { id = "retrigger",
    name = { en = "Retriggers (Hanging Chad / Dusk)", pt = "Repetições (Hanging Chad / Dusk)" },
    desc = { en = "Retrigger your best card: Hanging Chad, Dusk, Seltzer, Red Seals; Photograph doubles it.",
             pt = "Repita sua melhor carta: Hanging Chad, Dusk, Seltzer, Selos Vermelhos; Photograph dobra." },
    hands = nil, kind = "free",
    core = { "j_hanging_chad", "j_dusk", "j_selzer", "j_sock_and_buskin", "j_hack" },
    support = { "j_photograph", "j_mime", "j_blueprint", "j_brainstorm" },
    anti = {},
    tarots = { "c_deja_vu", "c_justice", "c_chariot" },
    deck = function() return 0.9, nil end,
    target = function() return {} end },

  { id = "highcard",
    name = { en = "High Card / single card (Supernova)", pt = "Carta Alta / carta única (Supernova)" },
    desc = { en = "Small hands: Supernova grows with every play, Half Joker +20 Mult on 3 cards or fewer; level High Card with Pluto.",
             pt = "Mãos pequenas: Supernova cresce a cada jogada, Half Joker +20 Mult com 3 cartas ou menos; suba Carta Alta com Pluto." },
    hands = { "High Card" },
    core = { "j_supernova", "j_half", "j_card_sharp", "j_dna" },
    support = { "j_hanging_chad", "j_raised_fist", "j_blueprint", "j_brainstorm", "j_scholar" },
    anti = { "j_square" },
    tarots = { "c_death", "c_justice" },
    deck = function() return 0.7, nil end,
    target = function() return {} end },
}

A.BY_ID = {}
for i, a in ipairs(A.LIST) do
  a.order = i
  A.BY_ID[a.id] = a
  a.need = a.need or 2.5
  a.kind = a.kind or (a.hands and "hand" or "free")
  a._core, a._support, a._anti, a._tarots = {}, {}, {}, {}
  for _, k in ipairs(a.core or {}) do a._core[k] = true end
  for _, k in ipairs(a.support or {}) do a._support[k] = true end
  for _, k in ipairs(a.anti or {}) do a._anti[k] = true end
  for _, k in ipairs(a.tarots or {}) do a._tarots[k] = true end
end

-- the base game's misspelled key for Gluttonous Joker: accept both spellings everywhere
local ALIAS = { j_gluttonous_joker = "j_gluttenous_joker" }
function A.norm(key) return ALIAS[key] or key end

function A.get(id) return id and A.BY_ID[id] or nil end

function A.name(arch, lang)
  if not arch then return "?" end
  return (lang == "pt_BR" and arch.name.pt) or arch.name.en
end
function A.desc(arch, lang)
  if not arch then return "" end
  return (lang == "pt_BR" and arch.desc.pt) or arch.desc.en
end

-- role of a joker key in a build: "core" | "support" | "anti" | nil
function A.role(arch, key)
  if not arch or not key then return nil end
  key = A.norm(key)
  if arch._core[key] then return "core" end
  if arch._support[key] then return "support" end
  if arch._anti[key] then return "anti" end
  return nil
end

-- the commitment a forced build hands to engine/build_plan (nil for hand-agnostic builds, which keep the auto plan
-- for leveling)
function A.commitment(arch, ante)
  if not arch then return nil end
  if arch.kind == "economy" then
    return { kind = "economy", committed_ante = ante or 1, strength = 10, via = "user", archetype = arch.id }
  end
  if arch.hands and arch.hands[1] then
    return { kind = "hand", hand = arch.hands[1], committed_ante = ante or 1, strength = 10, anchors = {},
             via = "user", archetype = arch.id }
  end
  return nil
end

return A
