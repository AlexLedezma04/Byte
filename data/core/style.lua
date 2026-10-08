local common = require "core.common"
local style = {}

style.padding = { x = common.round(14 * SCALE), y = common.round(7 * SCALE) }
style.divider_size = common.round(1 * SCALE)
style.scrollbar_size = common.round(4 * SCALE)
style.caret_width = common.round(2 * SCALE)
style.tab_width = common.round(170 * SCALE)

style.fallback_fonts = {
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
  "/usr/share/fonts/truetype/ancient-scripts/Symbola_hint.ttf",
  "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
  "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
  "/usr/share/fonts/google-droid-sans-fonts/DroidSansFallbackFull.ttf",
  "/usr/share/fonts/droid/DroidSansFallbackFull.ttf",
  "C:/Windows/Fonts/consola.ttf",
  "C:/Windows/Fonts/seguisym.ttf",
  "/System/Library/Fonts/Menlo.ttc",
  "/System/Library/Fonts/Apple Symbols.ttf",
  "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
}

local fallback_chains = {}

-- first font of the fallback chain for a size (loaded once per size)
local function fallback_chain(size)
  if fallback_chains[size] == nil then
    local first, last = false, nil
    for _, path in ipairs(style.fallback_fonts) do
      if system.get_file_info(path) then
        local ok, font = pcall(renderer.font.load, path, size)
        if ok then
          if last then last:set_fallback(font) else first = font end
          last = font
        end
      end
    end
    fallback_chains[size] = first
  end
  return fallback_chains[size] or nil
end

-- loads a font that falls back to style.fallback_fonts for missing characters
function style.load_font(path, size)
  local font = renderer.font.load(path, size)
  if not font.set_fallback then return font end
  local chain = fallback_chain(size)
  if chain then font:set_fallback(chain) end
  return font
end

style.font = style.load_font(EXEDIR .. "/data/fonts/font.ttf", 14 * SCALE)
style.big_font = style.load_font(EXEDIR .. "/data/fonts/font.ttf", 34 * SCALE)
style.icon_font = renderer.font.load(EXEDIR .. "/data/fonts/icons.ttf", 14 * SCALE)
style.code_font = style.load_font(EXEDIR .. "/data/fonts/monospace.ttf", 13.5 * SCALE)

style.background = { common.color "#2e2e32" }
style.background2 = { common.color "#252529" }
style.background3 = { common.color "#252529" }
style.text = { common.color "#97979c" }
style.caret = { common.color "#93DDFA" }
style.accent = { common.color "#e1e1e6" }
style.dim = { common.color "#525257" }
style.divider = { common.color "#202024" }
style.selection = { common.color "#48484f" }
style.line_number = { common.color "#525259" }
style.line_number2 = { common.color "#83838f" }
style.line_highlight = { common.color "#343438" }
style.scrollbar = { common.color "#414146" }
style.scrollbar2 = { common.color "#4b4b52" }

style.syntax = {}
style.syntax["normal"] = { common.color "#e1e1e6" }
style.syntax["symbol"] = { common.color "#e1e1e6" }
style.syntax["comment"] = { common.color "#676b6f" }
style.syntax["keyword"] = { common.color "#E58AC9" }
style.syntax["keyword2"] = { common.color "#F77483" }
style.syntax["number"] = { common.color "#FFA94D" }
style.syntax["literal"] = { common.color "#FFA94D" }
style.syntax["string"] = { common.color "#f7c95c" }
style.syntax["operator"] = { common.color "#93DDFA" }
style.syntax["function"] = { common.color "#93DDFA" }

return style
