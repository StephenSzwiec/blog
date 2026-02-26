-- md.lua — pure-Lua Markdown → HTML renderer.
-- Handles the Markdown subset used by this site's content:
--   ATX headings, fenced code blocks, blockquotes, unordered and
--   ordered lists, pipe tables, paragraphs, horizontal rules, and
--   inline: bold, italic, bold+italic, inline code, links, images.
--
-- No mutable global state — safe to call concurrently from handlers.

local M = {}

-- ── HTML escaping ─────────────────────────────────────────────────────
local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }
local function esc(s)
  return (s:gsub('[&<>"]', ESC))
end

-- ── Inline markup ─────────────────────────────────────────────────────
-- Processes bold, italic, inline code, links, images.
-- Code spans are extracted first so their content is not further processed.
local function inline(s)
  -- 1. Pull out code spans and replace with NUL-delimited placeholders.
  local spans = {}
  s = s:gsub("`([^`]+)`", function(code)
    spans[#spans + 1] = "<code>" .. esc(code) .. "</code>"
    return "\0" .. #spans .. "\0"
  end)

  -- 2. Escape HTML in the remaining text.
  s = esc(s)

  -- 3. Bold + italic (must come before bold and italic separately).
  s = s:gsub("%*%*%*(.-)%*%*%*", "<strong><em>%1</em></strong>")
  s = s:gsub("___(.-)___",       "<strong><em>%1</em></strong>")

  -- 4. Bold.
  s = s:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
  s = s:gsub("__(.-)__",     "<strong>%1</strong>")

  -- 5. Italic.
  s = s:gsub("%*(.-)%*", "<em>%1</em>")
  s = s:gsub("_(.-)_",   "<em>%1</em>")

  -- 6. Images (must precede links).
  s = s:gsub("!%[(.-)%]%((.-)%)", function(alt, url)
    return '<img src="' .. url .. '" alt="' .. alt .. '">'
  end)

  -- 7. Links.
  s = s:gsub("%[(.-)%]%((.-)%)", function(text, url)
    return '<a href="' .. url .. '">' .. text .. "</a>"
  end)

  -- 8. Restore code spans.
  s = s:gsub("\0(%d+)\0", function(idx)
    return spans[tonumber(idx)]
  end)

  return s
end

-- ── Table renderer ────────────────────────────────────────────────────
local function render_table(rows)
  local out = { "<table>" }
  local in_body = false
  for i, row in ipairs(rows) do
    -- Separator row (---|---) closes thead, opens tbody.
    if row:match("^[%s|%-%s:]+$") then
      if not in_body then
        out[#out + 1] = "<tbody>"
        in_body = true
      end
    else
      -- Split on |, trim whitespace.
      local raw = {}
      for cell in (row .. "|"):gmatch("([^|]*)|") do
        raw[#raw + 1] = cell:match("^%s*(.-)%s*$")
      end
      -- Remove leading/trailing empty cells from | ... | format.
      if raw[1] == "" then table.remove(raw, 1) end
      if raw[#raw] == "" then raw[#raw] = nil end

      local tag = in_body and "td" or "th"
      local tr = "<tr>"
      for _, cell in ipairs(raw) do
        tr = tr .. "<" .. tag .. ">" .. inline(cell) .. "</" .. tag .. ">"
      end
      tr = tr .. "</tr>"

      if not in_body and i == 1 then
        out[#out + 1] = "<thead>" .. tr .. "</thead>"
      else
        out[#out + 1] = tr
      end
    end
  end
  if in_body then out[#out + 1] = "</tbody>" end
  out[#out + 1] = "</table>"
  return table.concat(out, "\n")
end

-- ── List renderer ─────────────────────────────────────────────────────
local function render_list(items, ordered)
  local tag = ordered and "ol" or "ul"
  local out = { "<" .. tag .. ">" }
  for _, item in ipairs(items) do
    out[#out + 1] = "<li>" .. inline(item) .. "</li>"
  end
  out[#out + 1] = "</" .. tag .. ">"
  return table.concat(out, "\n")
end

-- ── Block parser ──────────────────────────────────────────────────────
-- Forward-declare render so blockquotes can recurse.
local render_blocks

render_blocks = function(lines)
  local out = {}
  local i = 1

  while i <= #lines do
    local line = lines[i]

    -- Fenced code block  ```[lang]
    if line:match("^```") then
      local lang = line:match("^```(%w+)") or ""
      local code = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^```%s*$") do
        code[#code + 1] = lines[i]
        i = i + 1
      end
      i = i + 1  -- consume closing ```
      local cls = lang ~= "" and (' class="language-' .. lang .. '"') or ""
      out[#out + 1] = "<pre><code" .. cls .. ">"
        .. esc(table.concat(code, "\n"))
        .. "</code></pre>"

    -- ATX headings  # through ######
    elseif line:match("^######%s") then
      out[#out + 1] = "<h6>" .. inline(line:match("^######%s+(.+)")) .. "</h6>"
      i = i + 1
    elseif line:match("^#####%s") then
      out[#out + 1] = "<h5>" .. inline(line:match("^#####%s+(.+)")) .. "</h5>"
      i = i + 1
    elseif line:match("^####%s") then
      out[#out + 1] = "<h4>" .. inline(line:match("^####%s+(.+)")) .. "</h4>"
      i = i + 1
    elseif line:match("^###%s") then
      out[#out + 1] = "<h3>" .. inline(line:match("^###%s+(.+)")) .. "</h3>"
      i = i + 1
    elseif line:match("^##%s") then
      out[#out + 1] = "<h2>" .. inline(line:match("^##%s+(.+)")) .. "</h2>"
      i = i + 1
    elseif line:match("^#%s") then
      out[#out + 1] = "<h1>" .. inline(line:match("^#%s+(.+)")) .. "</h1>"
      i = i + 1

    -- Blockquote  > ...
    elseif line:match("^>") then
      local bq = {}
      while i <= #lines and lines[i]:match("^>") do
        bq[#bq + 1] = lines[i]:match("^>%s?(.*)")
        i = i + 1
      end
      out[#out + 1] = "<blockquote>" .. render_blocks(bq) .. "</blockquote>"

    -- Horizontal rule  --- / *** / ___
    elseif line:match("^%-%-%-+%s*$")
        or line:match("^%*%*%*+%s*$")
        or line:match("^___%s*$") then
      out[#out + 1] = "<hr>"
      i = i + 1

    -- Unordered list  - / * / +
    elseif line:match("^[%-%*%+]%s") then
      local items = {}
      while i <= #lines and lines[i]:match("^[%-%*%+]%s") do
        items[#items + 1] = lines[i]:match("^[%-%*%+]%s+(.*)")
        i = i + 1
      end
      out[#out + 1] = render_list(items, false)

    -- Ordered list  1. 2. ...
    elseif line:match("^%d+%.%s") then
      local items = {}
      while i <= #lines and lines[i]:match("^%d+%.%s") do
        items[#items + 1] = lines[i]:match("^%d+%.%s+(.*)")
        i = i + 1
      end
      out[#out + 1] = render_list(items, true)

    -- Pipe table (current line has | AND next line is a separator)
    elseif line:match("|")
        and i + 1 <= #lines
        and lines[i + 1]:match("^[%s|%-%:]+$") then
      local rows = {}
      while i <= #lines and lines[i]:match("|") do
        rows[#rows + 1] = lines[i]
        i = i + 1
      end
      out[#out + 1] = render_table(rows)

    -- Blank line
    elseif line:match("^%s*$") then
      i = i + 1

    -- Paragraph — collect until blank line or block-level element
    else
      local para = {}
      while i <= #lines do
        local l = lines[i]
        if l:match("^%s*$")
            or l:match("^#")
            or l:match("^```")
            or l:match("^>")
            or l:match("^[%-%*%+]%s")
            or l:match("^%d+%.%s")
            or l:match("^%-%-%-+%s*$")
            or l:match("^%*%*%*+%s*$")
            or l:match("^___%s*$") then
          break
        end
        para[#para + 1] = l
        i = i + 1
      end
      if #para > 0 then
        out[#out + 1] = "<p>" .. inline(table.concat(para, " ")) .. "</p>"
      end
    end
  end

  return table.concat(out, "\n")
end

-- ── Public API ────────────────────────────────────────────────────────

--- Render a Markdown string to an HTML string.
--- Safe to call from concurrent request handlers (no global state mutated).
function M.render(source)
  if not source or source == "" then return "" end
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return render_blocks(lines)
end

return M
