-- config.lua -- default settings, loaded by Steamodded (the Mods menu > Engine Sim BR > Config page edits them;
-- your changes are saved to config/enginesim_br.jkr in the save folder). See ui/settings.lua.
return {
  language = "pt_BR",     -- "pt_BR" (Português), "en" (English) ou "auto" (o idioma do jogo)
  show_panel = true,      -- the advice panel in the left HUD (F9 toggles this)
  show_tags = true,       -- tags on the recommended card / shop item / button
  skip_policy = "auto",   -- skipping blinds: "auto" (measured), "conservative" (Investment tag at ante 1 only), "never"
  default_build = "auto", -- the build to force at the start of every new run ("auto" or a build id; F3 in a run)
  seer_mode = false,      -- seer mode (F4): use the real draw order and the next luck rolls (sees the run's future)
  fast_selfplay = true,   -- skip animations while the F11 self-player plays (via the Handy mod)
  fast_speed = 16,        -- Handy speed multiplier while self-playing: 4, 8, 16, 32 or 64
  think_mode = "balanced",-- while the engine thinks: "smooth" (full refresh rate), "balanced" (60 fps), "fast"
}
