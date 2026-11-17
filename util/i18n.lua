-- util/i18n.lua  (EngineSim BR)
-- The mod's language layer. PURE (no G): the live mod tells it the language and feeds it the game's own names.
--
-- Three mechanisms, so the existing engine did not have to be rewritten string by string:
--   * I.f(fmt, ...) / I.t(s): gettext-style. The ENGLISH template is the key; util/lang_pt_br.lua maps it to the
--     Portuguese template (same %-specifiers, same order). Unknown templates fall back to English, so a missed
--     string shows in English instead of breaking.
--   * I.say(key, ...): keyed messages for the NEW advisors (util/i18n_msgs.lua holds both languages).
--   * I.localize_names(text): a last pass over what the panel shows, replacing the game's internal English names
--     (cards, jokers, tags, poker hands, suits) with the names the game shows in the player's language. Names come
--     from the game's own localization (registered by core/state_extraction / main.lua), with static Portuguese
--     fallbacks for poker hands, suits and ranks.
--
-- Headless (tests, simulator): language "en" and every function is the identity -> byte-identical behaviour.

local I = {}

I.lang = "en"            -- "en" | "pt_BR"
I._dict = nil            -- loaded Portuguese template table
I._msgs = nil            -- keyed messages
I.names = {}             -- English internal name -> localized display name
I._name_list = nil       -- names sorted longest-first (rebuilt on change)

function I.set_lang(lang)
  if lang == "pt" or lang == "pt-BR" or lang == "pt_br" then lang = "pt_BR" end
  if lang ~= "pt_BR" then lang = "en" end
  if lang ~= I.lang then
    I.lang = lang
    I._name_list = nil
  end
  return I.lang
end

function I.is_pt() return I.lang == "pt_BR" end

local function dict()
  if I.lang ~= "pt_BR" then return nil end
  if not I._dict then
    local ok, d = pcall(require, "util.lang_pt_br")
    I._dict = (ok and type(d) == "table") and d or {}
  end
  return I._dict
end

local function msgs()
  if not I._msgs then
    local ok, m = pcall(require, "util.i18n_msgs")
    I._msgs = (ok and type(m) == "table") and m or {}
  end
  return I._msgs
end

-- Translate a fixed string (the English text is the key).
function I.t(s)
  local d = dict()
  if d and s then return d[s] or s end
  return s
end

-- string.format with a translated template. A translation that fails to format (a wrong specifier) falls back to
-- the English template rather than raising inside an advisor.
function I.f(fmt, ...)
  local d = dict()
  local tf = d and d[fmt]
  if tf then
    local ok, out = pcall(string.format, tf, ...)
    if ok then return out end
  end
  return string.format(fmt, ...)
end

-- A keyed message (util/i18n_msgs.lua): { en = "...", pt = "..." }, formatted with the arguments.
function I.say(key, ...)
  local m = msgs()[key]
  if not m then return key end
  local tf = (I.lang == "pt_BR" and m.pt) or m.en or key
  if select("#", ...) == 0 then return tf end
  local ok, out = pcall(string.format, tf, ...)
  if ok then return out end
  return tf
end

-- Pick between two literal variants by language (for short labels).
function I.pick(en, pt) return (I.lang == "pt_BR" and pt) or en end

-- ---- names -------------------------------------------------------------------------------------------------------

-- Static Portuguese fallbacks (the game's localization replaces them in-game when it has an entry).
I.PT_FALLBACK = {
  -- poker hands (Balatro PT-BR)
  ["Flush Five"] = "Flush Five", ["Flush House"] = "Flush House", ["Five of a Kind"] = "Quina",
  ["Straight Flush"] = "Straight Flush", ["Four of a Kind"] = "Quadra", ["Full House"] = "Full House",
  ["Flush"] = "Flush", ["Straight"] = "Sequência", ["Three of a Kind"] = "Trinca", ["Two Pair"] = "Dois Pares",
  ["Pair"] = "Par", ["High Card"] = "Carta Alta",
  -- suits
  Spades = "Espadas", Hearts = "Copas", Clubs = "Paus", Diamonds = "Ouros",
  -- blinds
  ["Small Blind"] = "Small Blind", ["Big Blind"] = "Big Blind",
}

function I.register_name(en, loc)
  if type(en) ~= "string" or type(loc) ~= "string" or en == "" or loc == "" then return end
  if I.names[en] ~= loc then
    I.names[en] = loc
    I._name_list = nil
  end
end

local function name_list()
  if I._name_list then return I._name_list end
  local merged = {}
  if I.lang == "pt_BR" then for k, v in pairs(I.PT_FALLBACK) do merged[k] = v end end
  for k, v in pairs(I.names) do merged[k] = v end
  local list = {}
  for k, v in pairs(merged) do if k ~= v then list[#list + 1] = { k, v } end end
  -- longest first ("Two Pair" before "Pair", "Green Joker" before "Joker"); ties by name for determinism
  table.sort(list, function(a, b)
    if #a[1] ~= #b[1] then return #a[1] > #b[1] end
    return a[1] < b[1]
  end)
  I._name_list = list
  return list
end

local function is_word_byte(b)
  return b and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b >= 128)
end

-- Replace every whole-word occurrence of a registered English name with its localized name.
function I.localize_names(text)
  if I.lang == "en" or type(text) ~= "string" or text == "" then return text end
  local list = name_list()
  if #list == 0 then return text end
  -- placeholders keep a replacement from being matched again by a shorter name
  local slots, out = {}, text
  for _, pair in ipairs(list) do
    local en, loc = pair[1], pair[2]
    local init, acc, changed = 1, {}, false
    while true do
      local a, b = out:find(en, init, true)
      if not a then break end
      local before, after = out:byte(a - 1), out:byte(b + 1)
      if not is_word_byte(before) and not is_word_byte(after) then
        acc[#acc + 1] = out:sub(init, a - 1)
        slots[#slots + 1] = loc
        acc[#acc + 1] = "\1" .. #slots .. "\2"
        changed = true
      else
        acc[#acc + 1] = out:sub(init, b)
      end
      init = b + 1
    end
    if changed then
      acc[#acc + 1] = out:sub(init)
      out = table.concat(acc)
    end
  end
  if #slots > 0 then out = out:gsub("\1(%d+)\2", function(i) return slots[tonumber(i)] end) end
  return out
end

-- ---- card labels -------------------------------------------------------------------------------------------------
-- Short card labels: English "KS" (King of Spades); Portuguese "Ke" (Rei de espadas): rank letter + lowercase suit
-- initial -- e = espadas, c = copas, p = paus, o = ouros. The game's pixel font has no suit glyphs.
I.SUIT_LETTER = {
  en = { Spades = "S", Hearts = "H", Clubs = "C", Diamonds = "D" },
  pt_BR = { Spades = "e", Hearts = "c", Clubs = "p", Diamonds = "o" },
}
function I.suit_letter(suit)
  local t = I.SUIT_LETTER[I.lang] or I.SUIT_LETTER.en
  return t[suit] or "?"
end

I.RANK_WORD = {
  en = { [11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace" },
  pt_BR = { [11] = "Valete", [12] = "Rainha", [13] = "Rei", [14] = "Ás" },
}
function I.rank_word(id)
  local t = I.RANK_WORD[I.lang] or I.RANK_WORD.en
  return t[id] or tostring(id)
end

I.SUIT_WORD = {
  en = { Spades = "Spades", Hearts = "Hearts", Clubs = "Clubs", Diamonds = "Diamonds" },
  pt_BR = { Spades = "Espadas", Hearts = "Copas", Clubs = "Paus", Diamonds = "Ouros" },
}
function I.suit_word(suit)
  local t = I.SUIT_WORD[I.lang] or I.SUIT_WORD.en
  return t[suit] or tostring(suit)
end

-- "King of Spades" / "Rei de Espadas"
function I.card_name(rank_id, suit)
  if I.lang == "pt_BR" then return I.rank_word(rank_id) .. " de " .. I.suit_word(suit) end
  return I.rank_word(rank_id) .. " of " .. tostring(suit)
end

-- Hand names for keyed messages (engine strings carry the English name; this localizes one directly).
function I.hand(ht)
  if I.lang == "en" or not ht then return ht end
  return I.names[ht] or I.PT_FALLBACK[ht] or ht
end

-- Money: "$12"
function I.money(n) return "$" .. tostring(math.floor((n or 0) + 0.5)) end

return I
