-- credit.lua
-- "tjingboem productions", written vertically (top to bottom) at the bottom right of the window, and clickable: in ReaATS it is the PIN
-- (tjingboem, 19 November 2026: in the ReaImGui tools the same label in the title bar is the pin; a gfx window has no title bar of its own to
-- draw in). gfx has no rotated text, so the text is drawn once, horizontally, into an off-screen image, read back pixel by pixel, and kept as a
-- list of (x, y, brightness) already turned a quarter turn clockwise; drawing it is then a few hundred 1x1 rectangles per frame.
-- If that read-back gives nothing (it gave nothing in a REAPER started without a visible screen), the letters are stacked under each other instead:
-- upright, one per line, still top to bottom.
local M = {}
local BUF, FONT = 901, 7

-- The quarter turn, on its own so that it can be tested without a window: `lit` is a list of {x, y, brightness} of the horizontal picture
-- (th rows high); the result is turned clockwise, so the first letter ends up at the top.
function M.rotate_cw(lit, th)
  local out = {}
  for i, p in ipairs(lit) do out[i] = { th - 1 - p[2], p[1], p[3] } end
  return out
end

function M.new(label, size, base_font, base_size)
  local self = { label = label, px = {}, w = 0, h = 0, mode = "none" }

  -- Call once after gfx.init. Leaves gfx.dest and the font slot of the editor as they were.
  function self.build()
    gfx.setfont(FONT, "Arial", size or 12)
    local tw, th = gfx.measurestr(label)
    tw, th = math.ceil(tw) + 2, math.ceil(th) + 2
    gfx.setimgdim(BUF, tw, th)
    gfx.dest = BUF
    gfx.set(0, 0, 0, 1); gfx.rect(0, 0, tw, th, 1)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = 1, 1
    gfx.drawstr(label)
    local lit = {}
    for y = 0, th - 1 do
      for x = 0, tw - 1 do
        local a = gfx.getpixel(x, y)
        if a > 0.08 then lit[#lit + 1] = { x, y, a } end
      end
    end
    gfx.dest = -1
    if #lit > 0 then
      self.px, self.w, self.h, self.mode = M.rotate_cw(lit, th), th, tw, "rotated"
    else
      local cw, ch = 0, 0
      self.letters = {}
      for c in label:gmatch(".") do
        local w, h = gfx.measurestr(c)
        self.letters[#self.letters + 1] = { c, w, h }
        if w > cw then cw = w end
        ch = ch + math.max(h - 3, 6)
      end
      self.w, self.h, self.mode = math.ceil(cw) + 2, math.ceil(ch) + 2, "stacked"
    end
    gfx.setfont(1, base_font or "Arial", base_size or 13)
    return self
  end

  -- the rectangle the text covers when its top-left corner is at (x0, y0)
  function self.rect(x0, y0) return x0, y0, self.w, self.h end

  -- bottom right of a window of w x h pixels, `margin` from the edges
  function self.corner(w, h, margin)
    margin = margin or 6
    return w - self.w - margin, h - self.h - margin
  end

  function self.draw(x0, y0, r, g, b)
    if self.mode == "rotated" then
      for _, p in ipairs(self.px) do
        gfx.set(r, g, b, p[3])
        gfx.rect(x0 + p[1], y0 + p[2], 1, 1, 1)
      end
    elseif self.mode == "stacked" then
      gfx.setfont(FONT, "Arial", size or 12)
      gfx.set(r, g, b, 1)
      local y = y0
      for _, l in ipairs(self.letters) do
        gfx.x, gfx.y = x0 + (self.w - l[2]) / 2, y
        gfx.drawstr(l[1])
        y = y + math.max(l[3] - 3, 6)
      end
      gfx.setfont(1, base_font or "Arial", base_size or 13)
    end
  end

  -- true when the mouse is over the text
  function self.hit(x0, y0, mx, my)
    return mx >= x0 and mx < x0 + self.w and my >= y0 and my < y0 + self.h
  end

  return self
end

return M
