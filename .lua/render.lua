-- render.lua — HTML layout and partial helpers.
--
-- render.layout(title, body_html)  → full HTML page
-- render.partial(fragment_html)    → raw fragment (for HTMX sub-requests)
--
-- Handlers decide which to call by checking GetHeader("HX-Request").

local M = {}

-- Tiny inline script applied before CSS to avoid flash-of-wrong-theme.
local THEME_INIT = '<script>(function(){'
  .. "var t=localStorage.getItem('theme');"
  .. "if(t==='dark'||t==='light')document.documentElement.dataset.theme=t;"
  .. '})();</script>'

-- Inline SVG icons for the theme toggle button.
local ICON_SUN = '<svg class="icon-sun" xmlns="http://www.w3.org/2000/svg"'
  .. ' width="16" height="16" viewBox="0 0 24 24" fill="none"'
  .. ' stroke="currentColor" stroke-width="2"'
  .. ' stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
  .. '<circle cx="12" cy="12" r="5"/>'
  .. '<line x1="12" y1="1" x2="12" y2="3"/>'
  .. '<line x1="12" y1="21" x2="12" y2="23"/>'
  .. '<line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/>'
  .. '<line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>'
  .. '<line x1="1" y1="12" x2="3" y2="12"/>'
  .. '<line x1="21" y1="12" x2="23" y2="12"/>'
  .. '<line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/>'
  .. '<line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>'
  .. '</svg>'

local ICON_MOON = '<svg class="icon-moon" xmlns="http://www.w3.org/2000/svg"'
  .. ' width="16" height="16" viewBox="0 0 24 24" fill="none"'
  .. ' stroke="currentColor" stroke-width="2"'
  .. ' stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
  .. '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>'
  .. '</svg>'

local NAV_HTML = '<header class="site-header">'
  .. '<div class="header-inner">'
  .. '<a href="/" class="site-brand">Stephen&#8201;Szwiec</a>'
  .. '<nav class="site-nav"'
  ..   ' hx-boost="true"'
  ..   ' hx-target="#content"'
  ..   ' hx-swap="outerHTML"'
  ..   ' hx-select="#content">'
  ..   '<ul class="nav-list">'
  ..     '<li><a href="/"       class="nav-link">Home</a></li>'
  ..     '<li><a href="/blog"   class="nav-link">Blog</a></li>'
  ..     '<li><a href="/wiki"   class="nav-link">Wiki</a></li>'
  ..     '<li><a href="/contact" class="nav-link">Contact</a></li>'
  ..   '</ul>'
  .. '</nav>'
  .. '<div class="nav-end">'
  ..   '<form class="nav-search" action="/search" method="get">'
  ..     '<input id="nav-q" name="q" type="search" class="nav-search-input"'
  ..            ' placeholder="Search\226\128\166" aria-label="Site search"'
  ..            ' hx-get="/search"'
  ..            ' hx-trigger="input changed delay:400ms"'
  ..            ' hx-target="#content"'
  ..            ' hx-push-url="true">'
  ..   '</form>'
  ..   '<button class="theme-toggle" onclick="toggleTheme()"'
  ..           ' aria-label="Toggle dark/light theme">'
  ..     ICON_SUN .. ICON_MOON
  ..   '</button>'
  .. '</div>'
  .. '</div>'
  .. '</header>'

--- Return a complete HTML document wrapping body_html in the site shell.
--- Always returns a full page; callers check GetHeader("HX-Request") and
--- call render.partial() instead when only a fragment is needed.
function M.layout(title, body_html)
  local safe_title = EscapeHtml(title) .. " \226\128\148 Stephen Szwiec"
  return "<!DOCTYPE html>\n"
    .. '<html lang="en" data-theme="light">\n'
    .. "<head>\n"
    .. '<meta charset="UTF-8">\n'
    .. '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
    .. "<title>" .. safe_title .. "</title>\n"
    .. THEME_INIT .. "\n"
    .. '<link rel="stylesheet" href="/static/style.css">\n'
    .. '<script src="/static/theme.js"></script>\n'
    .. '<script src="/static/htmx.min.js"></script>\n'
    .. "</head>\n"
    .. "<body>\n"
    .. NAV_HTML .. "\n"
    .. '<main id="content" class="main-content">\n'
    .. body_html .. "\n"
    .. "</main>\n"
    .. "</body>\n"
    .. "</html>"
end

--- Return the fragment as-is for HTMX partial responses.
function M.partial(fragment_html)
  return fragment_html
end

--- Smart dispatch: return the right response for the request type.
---
--- Three cases:
---   1. Direct browser navigation  → full layout  (no HX-Request header)
---   2. hx-boost nav click         → full layout  (HX-Request + HX-Boosted;
---                                                 hx-select="#content" then
---                                                 extracts <main> from it)
---   3. True HTMX fragment request → bare partial (HX-Request, no HX-Boosted;
---                                                 e.g. search box, POST reply)
---
--- All page-returning handlers should call this instead of checking
--- GetHeader("HX-Request") themselves.
function M.respond(title, body_html)
  if GetHeader("HX-Request") and not GetHeader("HX-Boosted") then
    return M.partial(body_html)
  end
  return M.layout(title, body_html)
end

return M
