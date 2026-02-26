-- app.lua — main entry point, loaded by .init.lua via require "app"
local fm     = require "fm"
local db     = require "db"
local render = require "render"
local md     = require "md"
local auth   = require "auth"

-- Open blog.db and apply schema (idempotent).
db.init()

-- ── Config ─────────────────────────────────────────────────────────────
local CONTACT_RECIPIENT = ""

-- Public-facing contact / social links (edit before deployment).
local BIO_NAME       = ""
local BIO_TAGLINE    = ""
local BIO_BLURB      = ""
local CONTACT_EMAIL  = ""
local GITHUB_URL     = ""
local LINKEDIN_URL   = ""
local CV_URL         = ""

-- ── Inline SVG icons (subset of Lucide) ────────────────────────────────
local function svg(paths, extra_attrs)
  return '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"'
    .. ' viewBox="0 0 24 24" fill="none" stroke="currentColor"'
    .. ' stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
    .. (extra_attrs or "") .. ' aria-hidden="true">'
    .. paths .. '</svg>'
end

-- Terminal  >_
local SVG_TERMINAL = svg(
  '<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>')
-- Book
local SVG_BOOK = svg(
  '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/>'
  .. '<path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>')
-- Mail
local SVG_MAIL = svg(
  '<path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/>'
  .. '<polyline points="22,6 12,13 2,6"/>')
-- FileText (resume)
local SVG_FILE = svg(
  '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>'
  .. '<polyline points="14 2 14 8 20 8"/>'
  .. '<line x1="16" y1="13" x2="8" y2="13"/>'
  .. '<line x1="16" y1="17" x2="8" y2="17"/>'
  .. '<line x1="10" y1="9" x2="8" y2="9"/>')
-- GitHub mark
local SVG_GITHUB = svg(
  '<path d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61'
  .. 'c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 4.77'
  .. ' 5.07 5.07 0 0 0 19.91 1S18.73.65 16 2.48a13.38 13.38 0 0 0-7 0'
  .. 'C6.27.65 5.09 1 5.09 1A5.07 5.07 0 0 0 5 4.77'
  .. 'a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7'
  .. 'A3.37 3.37 0 0 0 9 18.13V22"/>')
-- LinkedIn "in" box
local SVG_LINKEDIN = svg(
  '<path d="M16 8a6 6 0 0 1 6 6v7h-4v-7a2 2 0 0 0-2-2 2 2 0 0 0-2 2v7h-4v-7a6 6 0 0 1 6-6z"/>'
  .. '<rect x="2" y="9" width="4" height="12"/>'
  .. '<circle cx="4" cy="4" r="2"/>')

-- ── SMTP helper ────────────────────────────────────────────────────────
-- Send a plain-text email via the local Postfix Unix-socket listener.
-- Returns true on success, or false + error string on failure.
local function smtp_send(from_name, from_email, subject, body_text)
  local ok, result = pcall(function()
    local fd = assert(unix.socket(unix.AF_INET, unix.SOCK_STREAM, 0))
    assert(unix.connect(fd, ParseIp("127.0.0.1"), 25))

    local function wr(line) assert(unix.write(fd, line .. "\r\n")) end
    local function rd()    return unix.read(fd, 512) or "" end

    rd()  -- server banner
    wr("HELO localhost")                             rd()
    wr("MAIL FROM:<" .. from_email .. ">")           rd()
    wr("RCPT TO:<"   .. CONTACT_RECIPIENT .. ">")    rd()
    wr("DATA")                                       rd()
    wr("From: "    .. EscapeHtml(from_name) .. " <" .. from_email .. ">")
    wr("To: "      .. CONTACT_RECIPIENT)
    wr("Subject: " .. subject)
    wr("MIME-Version: 1.0")
    wr("Content-Type: text/plain; charset=UTF-8")
    wr("")
    -- RFC 5321 dot-stuffing
    for line in (body_text .. "\n"):gmatch("([^\n]*)\n") do
      wr((line:sub(1, 1) == "." and "." or "") .. line)
    end
    wr(".")  rd()
    wr("QUIT")
    unix.close(fd)
  end)
  if not ok then
    Log(kLogWarn, "smtp_send: " .. tostring(result))
    return false, tostring(result)
  end
  return true, nil
end

-- ── Shared 404 body ───────────────────────────────────────────────────
local BODY_404 = [[
<div class="error-page">
  <div class="error-code">404</div>
  <h1>Page Not Found</h1>
  <p>The page you&#8217;re looking for doesn&#8217;t exist.</p>
  <a href="/">&#8592; Go home</a>
</div>
]]

local BODY_500 = [[
<div class="error-page">
  <div class="error-code">500</div>
  <h1>Internal Error</h1>
  <p>Something went wrong on our end. Please try again later.</p>
  <a href="/">&#8592; Go home</a>
</div>
]]

-- Security response headers applied to every route.
local SEC_HEADERS = {
  ["Content-Security-Policy"] =
    "default-src 'self'; script-src 'self' 'unsafe-inline';"
    .. " style-src 'self' 'unsafe-inline'; img-src 'self' data:;"
    .. " connect-src 'self'; font-src 'self'; frame-ancestors 'none'",
  ["X-Frame-Options"]        = "DENY",
  ["X-Content-Type-Options"] = "nosniff",
  ["Referrer-Policy"]        = "strict-origin-when-cross-origin",
}

-- Route wrapper: applies security headers and guards each handler with pcall.
-- Passes string handlers (static asset patterns) straight through unchanged.
--
-- Security headers are applied AFTER the handler returns, not before.
-- Reason: SetStatus() resets the entire response buffer (see Redbean docs).
-- Any SetHeader/SetCookie call made before a SetStatus call is silently
-- discarded.  By applying SEC_HEADERS after pcall(handler), we ensure they
-- are always set after the last SetStatus call in the handler.
local function route(pattern, handler)
  if type(handler) == "string" then
    fm.setRoute(pattern, handler)
    return
  end
  fm.setRoute(pattern, function(r)
    local ok, result, extra = pcall(handler, r)
    -- Apply security headers after the handler so they survive any SetStatus
    -- call the handler may have made (SetStatus resets the response buffer).
    for k, v in pairs(SEC_HEADERS) do SetHeader(k, v) end
    if not ok then
      Log(kLogWarn, "route error: " .. tostring(result))
      SetStatus(500)
      -- Re-apply after SetStatus(500) which also resets the buffer.
      for k, v in pairs(SEC_HEADERS) do SetHeader(k, v) end
      return render.respond("Error", BODY_500)
    end
    -- Forward the optional second return value so Fullmoon uses it as the
    -- response headers table, suppressing detectType() auto-detection.
    -- Binary routes (e.g. /docs/:slug) use this to pass {ContentType = mime}.
    return result, extra
  end)
end

-- ── Helpers ───────────────────────────────────────────────────────────

-- Extract YYYY-MM-DD from an ISO timestamp.
local function fmt_date(iso)
  return iso and iso:sub(1, 10) or ""
end

-- ── CSRF helpers ──────────────────────────────────────────────────────

-- Return (and optionally mint) the CSRF token for this session.
-- Sets a Set-Cookie header when a new token is generated.
local function csrf_token()
  local tok = GetCookie("csrf")
  if not tok or tok == "" then
    math.randomseed(os.time() + math.floor(os.clock() * 1e6) % 1000000)
    tok = string.format("%09d%09d",
      math.random(1, 999999999), math.random(1, 999999999))
    SetHeader("Set-Cookie",
      "csrf=" .. tok .. "; Path=/; HttpOnly; SameSite=Strict")
  end
  return tok
end

-- Returns true only when the submitted csrf_token matches the session cookie.
local function csrf_check(r)
  local tok = GetCookie("csrf")
  local sub = (r.params and r.params.csrf_token) or ""
  return tok ~= nil and tok ~= "" and sub == tok
end

-- ── Rate-limit helpers (contact form: 3 per IP per hour) ─────────────

local rate_log = {}  -- [ip] = { unix_timestamp, ... }

local function client_ip()
  -- GetRemoteAddr returns uint32, uint16.  It already consults X-Forwarded-For
  -- when the socket IP is a trusted proxy, so no manual XFF parsing needed.
  local ip = GetRemoteAddr()
  if ip then return FormatIp(ip) end
  -- Fallback for IPv6 or addresses that didn't parse as IPv4.
  local fwd = GetHeader("X-Forwarded-For")
  if fwd and fwd ~= "" then
    local a = fwd:match("^%s*([^,%s]+)")
    if a then return a end
  end
  return "unknown"
end

-- Returns true if the IP is within the rate limit (< 3 per hour).
-- Prunes stale entries and records the current timestamp on success.
local function rate_ok(ip)
  local now  = os.time()
  local list = rate_log[ip] or {}
  local fresh = {}
  for _, t in ipairs(list) do
    if now - t < 3600 then fresh[#fresh + 1] = t end
  end
  if #fresh >= 3 then
    rate_log[ip] = fresh
    return false
  end
  fresh[#fresh + 1] = now
  rate_log[ip] = fresh
  return true
end

-- ── Rate-limit helpers (login: 5 per IP per 15 minutes) ─────────────

local login_rate_log = {}  -- [ip] = { unix_timestamp, ... }

local function login_rate_ok(ip)
  local now  = os.time()
  local list = login_rate_log[ip] or {}
  local fresh = {}
  for _, t in ipairs(list) do
    if now - t < 900 then fresh[#fresh + 1] = t end  -- 15-minute window
  end
  if #fresh >= 5 then
    login_rate_log[ip] = fresh
    return false
  end
  fresh[#fresh + 1] = now
  login_rate_log[ip] = fresh
  return true
end

-- Issue a redirect that actually reaches the browser.
--
-- Redbean's ServeRedirect / SetHeader calls accumulate in the C layer but are
-- only flushed when Write() is called.  Fullmoon only calls Write() when the
-- handler returns a non-empty string (`if #res > 0 then Write(res) end`).
-- Returning "" or relying on ServeRedirect alone causes the 302 to arrive with
-- no Location or Set-Cookie headers.  Returning " " (one space) forces Write
-- and flushes everything.
local function do_redirect(url)
  SetStatus(302)
  SetHeader("Location", url)
  return " "
end

-- Split a comma-separated tag string into a trimmed list.
local function split_tags(s)
  if not s or s == "" then return {} end
  local list = {}
  for tag in s:gmatch("[^,]+") do
    tag = tag:match("^%s*(.-)%s*$")
    if tag ~= "" then list[#list+1] = tag end
  end
  return list
end

-- Render tag pills for a list of tag strings.
-- kind scopes the filter link to that section (nil = global /search).
-- htmx=true  → include hx-get/hx-target/hx-swap for list pages (where #post-list exists)
-- htmx=false → plain href links only, for detail pages (no #post-list in DOM)
local function tag_pills_html(tags_list, kind, htmx)
  if #tags_list == 0 then return "" end
  local base = kind and ("/" .. kind) or "/search"
  local search_path = kind and ("/" .. kind .. "/search") or "/search"
  local pills = {}
  for _, tag in ipairs(tags_list) do
    local pill = '<a class="tag-pill"'
      .. ' href="' .. base .. '?tag=' .. EscapePath(tag) .. '"'
    if htmx then
      pill = pill
        .. ' hx-get="' .. search_path .. '?tag=' .. EscapePath(tag) .. '"'
        .. ' hx-target="#post-list"'
        .. ' hx-swap="outerHTML"'
    end
    pill = pill .. '>' .. EscapeHtml(tag) .. '</a>'
    pills[#pills+1] = pill
  end
  return table.concat(pills, " ")
end

-- Render the tag cloud for a list page (with active-tag state).
local function tag_cloud(kind, active_tag)
  local tags_list = db.list_tags(kind)
  if #tags_list == 0 then return "" end
  local search_path = kind and ("/" .. kind .. "/search") or "/search"
  local base = kind and ("/" .. kind) or "/search"
  local pills = {}
  for _, t in ipairs(tags_list) do
    local is_active = t.tag == active_tag
    local cls = is_active and "tag-pill tag-pill-active" or "tag-pill"
    -- Active tag: clicking clears the filter.
    local href   = is_active and base or (base .. "?tag=" .. EscapePath(t.tag))
    local hx_get = is_active and search_path
                              or (search_path .. "?tag=" .. EscapePath(t.tag))
    pills[#pills+1] = '<a class="' .. cls .. '"'
      .. ' href="' .. href .. '"'
      .. ' hx-get="' .. hx_get .. '"'
      .. ' hx-target="#post-list"'
      .. ' hx-swap="outerHTML">'
      .. EscapeHtml(t.tag) .. '</a>'
  end
  return '<div class="tag-cloud">' .. table.concat(pills, "\n") .. '</div>'
end

-- Render a single post/wiki card for use in list and search results.
local function post_card(post, kind)
  local date    = fmt_date(post.created_at)
  local summary = (post.summary ~= "" and post.summary)
                  or (post.excerpt and post.excerpt ~= "" and post.excerpt)
                  or post.body:sub(1, 160) .. "…"
  local tags_list = split_tags(post.tags or "")
  local tags_html = ""
  if #tags_list > 0 then
    tags_html = '<div class="post-card-tags">'
      .. tag_pills_html(tags_list, kind, true) .. '</div>'
  end
  return '<article class="post-card">'
    .. '<a href="/' .. kind .. '/' .. EscapePath(post.slug) .. '">'
    .. '<h2>' .. EscapeHtml(post.title) .. '</h2>'
    .. '<div class="post-meta"><time datetime="' .. date .. '">' .. date .. '</time></div>'
    .. '<p class="post-excerpt">' .. EscapeHtml(summary) .. '</p>'
    .. '</a>'
    .. tags_html
    .. '</article>'
end

-- Render the swappable list div containing post cards.
-- kind is used to set a CSS modifier class (.post-list-wiki gets a 2-col grid).
local function post_list_html(posts, kind)
  if #posts == 0 then
    return '<div id="post-list" class="post-list post-list-' .. kind
      .. '"><div class="no-results">No posts found.</div></div>'
  end
  local cards = {}
  for _, post in ipairs(posts) do
    cards[#cards + 1] = post_card(post, kind)
  end
  return '<div id="post-list" class="post-list post-list-' .. kind .. '">'
    .. table.concat(cards, "\n") .. '</div>'
end

-- Render search results fragment (no layout wrapper — HTMX target).
local function search_fragment(q, kind, tag)
  local results = db.search(q, kind, tag)
  local label = tag and ("tag: " .. tag) or q
  if #results == 0 then
    return '<div id="post-list" class="post-list post-list-' .. (kind or "blog")
      .. '"><div class="no-results">No results for &#8220;'
      .. EscapeHtml(label) .. '&#8221;.</div></div>'
  end
  local cards = {}
  for _, post in ipairs(results) do
    cards[#cards + 1] = post_card(post, kind or post.kind)
  end
  return '<div id="post-list" class="post-list post-list-' .. (kind or "blog") .. '">'
    .. table.concat(cards, "\n") .. '</div>'
end

-- ── /blog and /blog/search ────────────────────────────────────────────

route(fm.GET "/blog", function(r)
  local tag   = r.params.tag
  local posts = tag and db.search(nil, "blog", tag) or db.list_published("blog")
  local body = '<div class="section-header">'
    .. '<h1>Blog</h1>'
    .. '<p>Technical writing on programming, systems, and design.</p>'
    .. '</div>'
    .. tag_cloud("blog", tag)
    .. '<div class="search-wrap">'
    .. '<input type="search" class="search-input" name="q"'
    .. '  placeholder="Search posts\226\128\166"'
    .. '  hx-get="/blog/search"'
    .. '  hx-trigger="input changed delay:300ms"'
    .. '  hx-target="#post-list"'
    .. '  hx-swap="outerHTML"'
    .. '  aria-label="Search blog posts">'
    .. '</div>'
    .. post_list_html(posts, "blog")
  return render.respond("Blog", body)
end)

-- /blog/search must be registered before /blog/:slug
route(fm.GET "/blog/search", function(r)
  local q   = r.params.q or ""
  local tag = r.params.tag
  -- Always a fragment — this endpoint is only called by HTMX.
  if q ~= "" or tag then
    return render.partial(search_fragment(q, "blog", tag))
  end
  return render.partial(post_list_html(db.list_published("blog"), "blog"))
end)

route(fm.GET "/blog/:slug", function(r)
  local post = db.get_content("blog", r.params.slug)
  if not post then
    SetStatus(404)
    return render.respond("Not Found", BODY_404)
  end

  local date     = fmt_date(post.created_at)
  local updated  = fmt_date(post.updated_at)
  local date_str = date
  if updated ~= date then
    date_str = date_str .. ' <span style="opacity:.6">(updated ' .. updated .. ')</span>'
  end

  local tags_list = split_tags(post.tags or "")
  local tags_html = ""
  if #tags_list > 0 then
    -- Plain links on detail pages — no #post-list in the DOM to swap into.
    tags_html = '<div class="post-meta-tags">'
      .. tag_pills_html(tags_list, "blog", false) .. '</div>'
  end

  local body = '<article class="post-detail">'
    .. '<header class="post-header">'
    .. '<a href="/blog" class="back-link">&#8592; Blog</a>'
    .. '<h1>' .. EscapeHtml(post.title) .. '</h1>'
    .. '<div class="post-meta"><time datetime="' .. date .. '">' .. date_str .. '</time></div>'
    .. tags_html
    .. '</header>'
    .. '<div class="post-body">' .. md.render(post.body) .. '</div>'
    .. '</article>'

  return render.respond(post.title, body)
end)

-- ── /wiki and /wiki/search ────────────────────────────────────────────

route(fm.GET "/wiki", function(r)
  local tag   = r.params.tag
  local pages = tag and db.search(nil, "wiki", tag) or db.list_published("wiki")
  local body = '<div class="section-header">'
    .. '<h1>Wiki</h1>'
    .. '<p>Personal knowledge base covering tools, languages, and concepts.</p>'
    .. '</div>'
    .. tag_cloud("wiki", tag)
    .. '<div class="search-wrap">'
    .. '<input type="search" class="search-input" name="q"'
    .. '  placeholder="Search wiki\226\128\166"'
    .. '  hx-get="/wiki/search"'
    .. '  hx-trigger="input changed delay:300ms"'
    .. '  hx-target="#post-list"'
    .. '  hx-swap="outerHTML"'
    .. '  aria-label="Search wiki pages">'
    .. '</div>'
    .. post_list_html(pages, "wiki")
  return render.respond("Wiki", body)
end)

-- /wiki/search must be registered before /wiki/:slug
route(fm.GET "/wiki/search", function(r)
  local q   = r.params.q or ""
  local tag = r.params.tag
  if q ~= "" or tag then
    return render.partial(search_fragment(q, "wiki", tag))
  end
  return render.partial(post_list_html(db.list_published("wiki"), "wiki"))
end)

route(fm.GET "/wiki/:slug", function(r)
  local page = db.get_content("wiki", r.params.slug)
  if not page then
    SetStatus(404)
    return render.respond("Not Found", BODY_404)
  end

  local date    = fmt_date(page.created_at)
  local updated = fmt_date(page.updated_at)
  local date_str = date
  if updated ~= date then
    date_str = date_str .. ' <span style="opacity:.6">(updated ' .. updated .. ')</span>'
  end

  local tags_list = split_tags(page.tags or "")
  local tags_html = ""
  if #tags_list > 0 then
    -- Plain links on detail pages — no #post-list in the DOM to swap into.
    tags_html = '<div class="post-meta-tags">'
      .. tag_pills_html(tags_list, "wiki", false) .. '</div>'
  end

  -- Edit affordance — only shown when a valid client cert is present (Phase 5).
  local edit_bar = ""
  if auth.has_client_cert() then
    edit_bar = '<div class="wiki-edit-bar">'
      .. '<a href="/edit/' .. page.id .. '" class="wiki-edit-link">Edit this page</a>'
      .. '</div>'
  end

  local body = '<article class="post-detail">'
    .. '<header class="post-header">'
    .. '<a href="/wiki" class="back-link">&#8592; Wiki</a>'
    .. '<h1>' .. EscapeHtml(page.title) .. '</h1>'
    .. '<div class="post-meta"><time datetime="' .. date .. '">' .. date_str .. '</time></div>'
    .. tags_html
    .. '</header>'
    .. '<div class="post-body">' .. md.render(page.body) .. '</div>'
    .. edit_bar
    .. '</article>'

  return render.respond(page.title, body)
end)

-- ── Public routes ─────────────────────────────────────────────────────

route(fm.GET "/", function(r)
  -- Recent activity log (3 most recently updated published items).
  local recent = db.list_recent(3)
  local activity_rows = {}
  for _, item in ipairs(recent) do
    local date = fmt_date(item.updated_at)
    local action
    if item.kind == "wiki" then
      action = 'Updated wiki: <a href="/wiki/' .. EscapePath(item.slug) .. '">'
        .. EscapeHtml(item.title) .. '</a>'
    else
      action = 'Published &#8220;<a href="/' .. item.kind .. '/' .. EscapePath(item.slug)
        .. '">' .. EscapeHtml(item.title) .. '</a>&#8221;'
    end
    activity_rows[#activity_rows + 1] =
      '<div class="activity-row">'
      .. '<span class="activity-date">' .. date .. '</span>'
      .. '<span class="activity-gt">&gt;</span>'
      .. '<span class="activity-text">' .. action .. '</span>'
      .. '</div>'
  end
  local activity_html = #activity_rows > 0
    and table.concat(activity_rows, "\n")
    or  '<div class="activity-row"><span class="activity-text text-muted">No recent activity.</span></div>'

  local body =
    -- ── Hero card ─────────────────────────────────────────────────────
    '<header class="home-hero">'
    .. '<div class="home-hero-top">'
    .. '<div class="home-accent-dot"></div>'
    .. '<div>'
    .. '<h1 class="home-name">' .. BIO_NAME .. '</h1>'
    .. '<p class="home-subtitle">' ..  BIO_TAGLINE  .. '</p>'
    .. '</div>'
    .. '</div>'
    .. '<div class="home-hero-bio">'
    .. '<p>'  .. BIO_BLURB .. '</p>'
    .. '</div>'
    .. '</header>'

    -- ── Quick-link grid ───────────────────────────────────────────────
    .. '<div class="quick-links">'

    .. '<a href="/blog" class="quick-link-card ql-blog">'
    .. '<div class="ql-icon">' .. SVG_TERMINAL .. '</div>'
    .. '<div><h2 class="ql-title">Blog</h2>'
    .. '<p class="ql-desc">Longer form writing: project designs, post-mortems, and non-technical thoughts.</p>'
    .. '</div></a>'

    .. '<a href="/wiki" class="quick-link-card ql-wiki">'
    .. '<div class="ql-icon">' .. SVG_BOOK .. '</div>'
    .. '<div><h2 class="ql-title">Wiki</h2>'
    .. '<p class="ql-desc">Personal knowledge base covering tools, languages, and concepts.</p>'
    .. '</div></a>'

    .. '<a href="/contact" class="quick-link-card ql-contact">'
    .. '<div class="ql-icon">' .. SVG_MAIL .. '</div>'
    .. '<div><h2 class="ql-title">Contact</h2>'
    .. '<p class="ql-desc">Get in touch for collaborations, questions, or opportunities.</p>'
    .. '</div></a>'

    .. '<div class="quick-link-card ql-resume">'
    .. '<div class="ql-icon">' .. SVG_FILE .. '</div>'
    .. '<div><h2 class="ql-title">Resume</h2>'
    .. '<p class="ql-desc">My current CV in PDF format.</p>'
    .. '<a href="' .. CV_URL .. '" class="ql-download">DOWNLOAD_CV.PDF</a>'
    .. '</div></div>'

    .. '</div>'

    -- ── Recent activity ───────────────────────────────────────────────
    .. '<div class="recent-activity">'
    .. '<h2 class="recent-activity-label">Recent Activity</h2>'
    .. activity_html
    .. '</div>'

    -- ── Footer ────────────────────────────────────────────────────────
    .. '<footer class="home-footer">'
    .. '<p>&#169; 2026 Stephen Szwiec.</p>'
    .. '</footer>'

  return render.respond("Home", body)
end)

-- Static files (added by hook — serves /static/* assets natively)
route(fm.GET "/static/*", "/static/*")

-- ── Docs: binary file server ──────────────────────────────────────────
-- Docs entries are not listed in the nav or search — they are linked directly.
-- /docs/:slug serves the stored blob with the correct Content-Type so the
-- browser can handle it natively (PDF viewer, etc.).

local MIME_EXT = {
  ["application/pdf"]              = ".pdf",
  ["application/epub+zip"]         = ".epub",
  ["text/plain"]                   = ".txt",
  ["application/zip"]              = ".zip",
}

local MIME_LABELS = {
  ["application/pdf"]              = "PDF Document",
  ["application/epub+zip"]         = "EPUB e-book",
  ["text/plain"]                   = "Plain text",
  ["application/zip"]              = "ZIP archive",
  ["application/octet-stream"]     = "Other binary",
}

route(fm.GET "/docs/:slug", function(r)
  local doc = db.get_doc(r.params.slug)
  if not doc or not doc.file_data or doc.file_data == "" then
    SetStatus(404)
    return render.respond("Not Found", BODY_404)
  end
  local mime = (doc.mime_type ~= "" and doc.mime_type) or "application/octet-stream"
  local ext  = MIME_EXT[mime] or ""
  -- Content-Disposition is set directly; Content-Type is passed as the second
  -- return value so Fullmoon uses it verbatim and skips detectType() sniffing.
  SetHeader("Content-Disposition", 'inline; filename="' .. doc.slug .. ext .. '"')
  return doc.file_data, {ContentType = mime}
end)

-- Contact
route(fm.GET "/contact", function(r)
  local tok  = csrf_token()
  local body =
    -- ── Header ────────────────────────────────────────────────────────
    '<header class="section-header">'
    .. '<h1>Contact</h1>'
    .. '<p>Get in touch for collaborations, questions, or opportunities.</p>'
    .. '</header>'

    -- ── Two-column grid ───────────────────────────────────────────────
    .. '<div class="contact-grid">'

    -- Left column: info + response time
    .. '<div class="contact-left">'

    .. '<div class="contact-info-card">'
    .. '<h2 class="contact-card-label">Contact Information</h2>'

    .. '<div class="contact-info-row">'
    .. '<span class="contact-info-icon ci-magenta">' .. SVG_MAIL .. '</span>'
    .. '<div>'
    .. '<div class="contact-info-type">Email</div>'
    .. '<a href="mailto:' .. CONTACT_EMAIL .. '">' .. EscapeHtml(CONTACT_EMAIL) .. '</a>'
    .. '</div></div>'

    .. '<div class="contact-info-row">'
    .. '<span class="contact-info-icon ci-violet">' .. SVG_GITHUB .. '</span>'
    .. '<div>'
    .. '<div class="contact-info-type">GitHub</div>'
    .. '<a href="' .. GITHUB_URL .. '" target="_blank" rel="noopener noreferrer">'
    .. EscapeHtml(GITHUB_URL:gsub("https://", "")) .. '</a>'
    .. '</div></div>'

    .. '<div class="contact-info-row">'
    .. '<span class="contact-info-icon ci-blue">' .. SVG_LINKEDIN .. '</span>'
    .. '<div>'
    .. '<div class="contact-info-type">LinkedIn</div>'
    .. '<a href="' .. LINKEDIN_URL .. '" target="_blank" rel="noopener noreferrer">'
    .. EscapeHtml(LINKEDIN_URL:gsub("https://", "")) .. '</a>'
    .. '</div></div>'

    .. '</div>'  -- /contact-info-card

    .. '<div class="contact-response-card">'
    .. '<h2 class="contact-card-label">Response Time</h2>'
    .. '<p>I typically respond within 24&#8211;48 hours during weekdays. '
    .. 'For urgent matters, please indicate so in your message.</p>'
    .. '</div>'

    .. '</div>'  -- /contact-left

    -- Right column: form
    .. '<div class="contact-form-card">'
    .. '<h2 class="contact-card-label">Send a Message</h2>'
    .. '<form id="contact-form"'
    .. '  hx-post="/contact"'
    .. '  hx-target="#contact-result"'
    .. '  hx-swap="innerHTML">'
    .. '<input type="hidden" name="csrf_token" value="' .. tok .. '">'
    .. '<div class="form-group">'
    .. '<label for="cf-name">Name</label>'
    .. '<input type="text" id="cf-name" name="name"'
    .. '  placeholder="Your name" autocomplete="name">'
    .. '</div>'
    .. '<div class="form-group">'
    .. '<label for="cf-email">Email</label>'
    .. '<input type="email" id="cf-email" name="email"'
    .. '  placeholder="you@example.com" autocomplete="email">'
    .. '</div>'
    .. '<div class="form-group">'
    .. '<label for="cf-message">Message</label>'
    .. '<textarea id="cf-message" name="message" rows="6"'
    .. '  placeholder="Your message\226\128\166"></textarea>'
    .. '</div>'
    .. '<button type="submit" class="btn btn-send">SEND_MESSAGE</button>'
    .. '</form>'
    .. '<div id="contact-result"></div>'
    .. '</div>'  -- /contact-form-card

    .. '</div>'  -- /contact-grid

    -- ── Footer note ───────────────────────────────────────────────────
    .. '<footer class="contact-footer">'
    .. '<p>All communications are appreciated and will be read personally.</p>'
    .. '</footer>'

  return render.respond("Contact", body)
end)

route(fm.POST "/contact", function(r)
  -- CSRF guard
  if not csrf_check(r) then
    return render.partial(
      '<div class="contact-result contact-result-error">'
      .. "<p>Invalid request token. Please reload the page and try again.</p>"
      .. "</div>"
    )
  end
  -- Rate limit: 3 submissions per IP per hour
  local ip = client_ip()
  if not rate_ok(ip) then
    SetStatus(429)
    return render.partial(
      '<div class="contact-result contact-result-error">'
      .. "<p>Too many messages sent recently. Please wait a while before trying again.</p>"
      .. "</div>"
    )
  end

  local name    = (r.params.name    or ""):match("^%s*(.-)%s*$")
  local email   = (r.params.email   or ""):match("^%s*(.-)%s*$")
  local message = (r.params.message or ""):match("^%s*(.-)%s*$")

  -- Validate
  local errors = {}
  if name == "" then
    errors[#errors + 1] = "Name is required."
  end
  if email == "" then
    errors[#errors + 1] = "Email is required."
  elseif not email:find("@", 1, true) then
    errors[#errors + 1] = "A valid email address is required."
  end
  if message == "" then
    errors[#errors + 1] = "Message is required."
  end

  if #errors > 0 then
    local items = {}
    for _, e in ipairs(errors) do
      items[#items + 1] = "<li>" .. EscapeHtml(e) .. "</li>"
    end
    return render.partial(
      '<div class="contact-result contact-result-error">'
      .. '<ul class="contact-errors">' .. table.concat(items) .. "</ul>"
      .. "</div>"
    )
  end

  local subject   = "Contact: " .. name
  local body_text = "Name: "    .. name .. "\r\n"
                  .. "Email: "  .. email .. "\r\n\r\n"
                  .. message

  local ok = smtp_send(name, email, subject, body_text)
  if not ok then
    return render.partial(
      '<div class="contact-result contact-result-error">'
      .. "<p>Sorry, the message could not be delivered. Please try again later.</p>"
      .. "</div>"
    )
  end

  return render.partial(
    '<div class="contact-result contact-result-ok">'
    .. "<p>Message sent &#8212; thank you. I&#8217;ll be in touch.</p>"
    .. "</div>"
  )
end)

-- ── Global search ─────────────────────────────────────────────────────

route(fm.GET "/search", function(r)
  local q      = r.params.q or ""
  local target = GetHeader("HX-Target") or ""

  -- Build grouped results HTML (or empty/prompt message).
  local results_html
  if q == "" then
    results_html = '<div id="search-results">'
      .. '<div class="no-results">Type to search across all content.</div>'
      .. '</div>'
  else
    local results = db.search(q, nil, nil)
    if #results == 0 then
      results_html = '<div id="search-results">'
        .. '<div class="no-results">No results for &#8220;' .. EscapeHtml(q) .. '&#8221;.</div>'
        .. '</div>'
    else
      local by_kind = { blog={}, wiki={} }
      for _, item in ipairs(results) do
        local k = item.kind
        if by_kind[k] then by_kind[k][#by_kind[k]+1] = item end
      end
      local groups = {}
      for _, kind in ipairs({"blog", "wiki"}) do
        if #by_kind[kind] > 0 then
          local cards = {}
          for _, post in ipairs(by_kind[kind]) do
            cards[#cards+1] = post_card(post, kind)
          end
          groups[#groups+1] = '<div class="search-group">'
            .. '<div class="search-group-label">' .. kind .. '</div>'
            .. table.concat(cards, "\n")
            .. '</div>'
        end
      end
      results_html = '<div id="search-results">' .. table.concat(groups, "\n") .. '</div>'
    end
  end

  -- If HTMX is targeting just #search-results (from the page's own input), return only that.
  if GetHeader("HX-Request") and target == "search-results" then
    return render.partial(results_html)
  end

  -- Nav search or direct nav → return the full search page body.
  local body = '<div class="section-header">'
    .. '<h1>Search</h1>'
    .. (q ~= "" and ('<p>Results for &#8220;' .. EscapeHtml(q) .. '&#8221;</p>') or '')
    .. '</div>'
    .. '<div class="search-wrap">'
    .. '<input type="search" class="search-input"'
    .. '  value="' .. EscapeHtml(q) .. '"'
    .. '  name="q"'
    .. '  placeholder="Search all content\226\128\166"'
    .. '  hx-get="/search"'
    .. '  hx-trigger="input changed delay:300ms"'
    .. '  hx-target="#search-results"'
    .. '  aria-label="Search all content">'
    .. '</div>'
    .. results_html

  return render.respond("Search", body)
end)

-- ── Login / logout ────────────────────────────────────────────────────

local LOGIN_ERRORS = {
  token = "Invalid request token. Please try again.",
  rate  = "Too many login attempts. Please wait before trying again.",
  cred  = "Incorrect password.",
}

route(fm.GET "/login", function(r)
  -- Already logged in: go straight to the dashboard.
  if auth.has_client_cert() then
    return do_redirect("/edit")
  end

  local tok     = csrf_token()
  local err_msg = LOGIN_ERRORS[r.params.e or ""] or ""
  local err_html = err_msg ~= ""
    and '<div class="login-error"><p>' .. err_msg .. '</p></div>'
    or  ""

  local body =
    '<div class="login-wrap">'
    .. '<h1>Admin Login</h1>'
    .. err_html
    .. '<form method="post" action="/login">'
    .. '<input type="hidden" name="csrf_token" value="' .. tok .. '">'
    .. '<div class="form-group">'
    .. '<label for="lp">Password</label>'
    .. '<input type="password" id="lp" name="password" autocomplete="current-password">'
    .. '</div>'
    .. '<button type="submit" class="btn btn-primary">SIGN_IN</button>'
    .. '</form>'
    .. '</div>'

  return render.respond("Login", body)
end)

route(fm.POST "/login", function(r)
  if not csrf_check(r) then
    return do_redirect("/login?e=token")
  end

  local ip = client_ip()
  if not login_rate_ok(ip) then
    return do_redirect("/login?e=rate")
  end

  local token, err = auth.login(r.params.password or "")
  if not token then
    Log(kLogWarn, "login failed for " .. ip .. ": " .. tostring(err))
    return do_redirect("/login?e=cred")
  end

  -- SetStatus MUST come before SetCookie/SetHeader: SetStatus resets the
  -- response buffer, discarding any headers set before it.
  SetStatus(302)
  SetHeader("Location", "/edit")
  SetCookie("session", token, {
    MaxAge   = 7 * 24 * 3600,
    Path     = "/",
    HttpOnly = true,
    SameSite = "Strict",
  })
  return " "
end)

route(fm.POST "/logout", function(r)
  local tok = GetCookie("session")
  if tok then auth.logout(tok) end
  -- SetStatus before SetCookie — SetStatus resets the response buffer.
  SetStatus(302)
  SetHeader("Location", "/")
  SetCookie("session", "", {MaxAge = 0, Path = "/", HttpOnly = true, SameSite = "Strict"})
  return " "
end)

-- ── Admin (Phase 5) ───────────────────────────────────────────────────

-- Shared 403 body (auth module uses render.respond; no separate constant needed).

-- Slug helpers.
local function slugify(s)
  return (s:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
end

local function valid_slug(s)
  return s ~= ""
    and (s:match("^[a-z0-9]$") or s:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$")) ~= nil
end

-- Build the editor form page (shared by GET /edit/new and GET /edit/:id).
-- item = nil for new, or a DB row for editing.
-- kind = "blog" | "wiki" | "docs" (used when item is nil).
-- err  = optional error string to display above the form.
local function editor_page(item, kind, err)
  local is_new  = item == nil
  kind          = (item and item.kind) or kind or "blog"
  local action  = is_new and "/edit/new" or ("/edit/" .. item.id)

  local title_val   = (item and item.title)  or ""
  local slug_val    = (item and item.slug)   or ""
  local body_val    = (item and item.body)   or ""
  local tags_val    = (item and item.tags)   or ""
  local pub_checked = (item and item.published == 1) and " checked" or ""

  local kind_label  = kind:sub(1, 1):upper() .. kind:sub(2)
  local page_title  = is_new and ("New " .. kind_label)
                              or ("Edit: " .. title_val)

  local err_html = err
    and '<div class="editor-error"><p>' .. EscapeHtml(err) .. '</p></div>'
    or  ""

  local preview_html = body_val ~= ""
    and md.render(body_val)
    or  '<p class="text-muted">Preview will appear here\226\128\166</p>'

  -- View-live link (edit mode only, shown when slug is known).
  local view_link = (not is_new and slug_val ~= "")
    and ('<a href="/' .. EscapeHtml(kind) .. '/' .. EscapeHtml(slug_val) .. '"'
      .. ' class="btn" target="_blank" rel="noopener">View live</a>')
    or  ""

  local tok = csrf_token()

  -- ── Content section: varies by kind ─────────────────────────────────
  -- blog/wiki: tags field + two-column markdown editor with live preview.
  -- docs:      MIME type selector + file upload input; no tags, no preview.
  local content_section_html
  if kind == "docs" then
    local mime_val = (item and item.mime_type ~= "" and item.mime_type) or "application/pdf"
    local mime_opts = ""
    for _, m in ipairs({
      "application/pdf", "application/epub+zip",
      "text/plain", "application/zip", "application/octet-stream",
    }) do
      local sel = (m == mime_val) and " selected" or ""
      mime_opts = mime_opts
        .. '<option value="' .. m .. '"' .. sel .. '>'
        .. (MIME_LABELS[m] or m) .. "</option>"
    end
    local file_note = (item and item.mime_type ~= "")
      and ("Current file type: " .. EscapeHtml(item.mime_type) .. ".  Upload a new file to replace it.")
      or  "No file stored yet."
    content_section_html =
      '<div class="form-group">'
      .. '<label for="ed-mime">Document type</label>'
      .. '<select id="ed-mime" name="mime_type" class="select-input">'
      .. mime_opts .. '</select>'
      .. '</div>'
      .. '<div class="form-group">'
      .. '<label for="ed-file">File</label>'
      .. '<p class="field-note">' .. file_note .. '</p>'
      .. '<input type="file" id="ed-file" name="file">'
      .. '</div>'
  else
    content_section_html =
      -- Tags field (full-width)
      '<div class="form-group">'
      .. '<label for="ed-tags">Tags</label>'
      .. '<input type="text" id="ed-tags" name="tags"'
      .. '  value="' .. EscapeHtml(tags_val) .. '"'
      .. '  placeholder="comma, separated, tags" autocomplete="off">'
      .. '</div>'
      -- Two-column editor / preview
      .. '<div class="editor-layout">'
      .. '<div class="editor-pane">'
      .. '<div class="pane-label">Markdown</div>'
      .. '<textarea id="ed-body" name="body" class="editor-textarea"'
      .. '  hx-post="/edit/preview"'
      .. '  hx-trigger="keyup changed delay:400ms"'
      .. '  hx-target="#preview-pane"'
      .. '  hx-include="[name=csrf_token]"'
      .. '  placeholder="Write your content in Markdown\226\128\166">'
      .. EscapeHtml(body_val)
      .. '</textarea>'
      .. '</div>'
      .. '<div class="preview-col">'
      .. '<div class="pane-label">Preview</div>'
      .. '<div id="preview-pane" class="preview-pane post-body">'
      .. preview_html
      .. '</div>'
      .. '</div>'
      .. '</div>'  -- /editor-layout
  end

  local enctype = (kind == "docs") and ' enctype="multipart/form-data"' or ""

  local body =
    '<div class="editor-wrap">'

    -- Header
    .. '<header class="post-header">'
    .. '<a href="/edit" class="back-link">&#8592; Dashboard</a>'
    .. '<h1>' .. EscapeHtml(page_title) .. '</h1>'
    .. '</header>'

    .. err_html

    -- Form
    .. '<form method="post" action="' .. action .. '"' .. enctype .. '>'
    .. '<input type="hidden" name="kind" value="' .. EscapeHtml(kind) .. '">'
    .. '<input type="hidden" name="csrf_token" value="' .. tok .. '">'

    -- Meta row: title / slug / published
    .. '<div class="editor-meta-row">'

    .. '<div class="form-group">'
    .. '<label for="ed-title">Title</label>'
    .. '<input type="text" id="ed-title" name="title"'
    .. '  value="' .. EscapeHtml(title_val) .. '"'
    .. '  placeholder="Post title" autocomplete="off">'
    .. '</div>'

    .. '<div class="form-group">'
    .. '<label for="ed-slug">Slug</label>'
    .. '<input type="text" id="ed-slug" name="slug"'
    .. '  value="' .. EscapeHtml(slug_val) .. '"'
    .. '  placeholder="url-friendly-slug" autocomplete="off" class="slug-input">'
    .. '</div>'

    .. '<div class="form-group-inline">'
    .. '<label class="checkbox-label">'
    .. '<input type="checkbox" name="published" value="1"' .. pub_checked .. '>'
    .. ' Published'
    .. '</label>'
    .. '</div>'

    .. '</div>'  -- /editor-meta-row

    .. content_section_html

    -- Actions
    .. '<div class="editor-actions">'
    .. view_link
    .. '<button type="submit" class="btn btn-primary">'
    .. (is_new and "Create" or "Save changes")
    .. '</button>'
    .. '</div>'

    .. '</form>'

    -- Slug auto-derive (runs once on DOMContentLoaded).
    .. '<script>(function(){'
    .. 'var t=document.getElementById("ed-title");'
    .. 'var s=document.getElementById("ed-slug");'
    .. 'var manual=s.value.length>0;'
    .. 't.addEventListener("input",function(){'
    ..   'if(manual)return;'
    ..   's.value=this.value.toLowerCase()'
    ..     '.replace(/[^a-z0-9]+/g,"-")'
    ..     '.replace(/^-+|-+$/g,"");'
    .. '});'
    .. 's.addEventListener("input",function(){manual=true;});'
    .. '})();</script>'

    .. '</div>'  -- /editor-wrap

  return render.respond(page_title, body)
end

-- ── GET /edit — admin dashboard ────────────────────────────────────────
route(fm.GET "/edit", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end

  local tok  = csrf_token()
  local all  = db.list_all()
  local rows = {}
  for _, item in ipairs(all) do
    local date = fmt_date(item.created_at)
    local pub_badge = item.published == 1
      and '<span class="status-badge status-published">Published</span>'
      or  '<span class="status-badge status-draft">Draft</span>'
    local kind_badge =
      '<span class="kind-badge kind-' .. item.kind .. '">' .. item.kind .. '</span>'
    rows[#rows + 1] =
      '<tr>'
      .. '<td>' .. kind_badge .. '</td>'
      .. '<td><a href="/edit/' .. item.id .. '">' .. EscapeHtml(item.title) .. '</a></td>'
      .. '<td class="col-mono">' .. EscapeHtml(item.slug) .. '</td>'
      .. '<td>' .. pub_badge .. '</td>'
      .. '<td class="col-mono">' .. date .. '</td>'
      .. '<td class="col-actions">'
      ..   '<a href="/edit/' .. item.id .. '" class="action-link">Edit</a>'
      ..   '<form method="post" action="/edit/' .. item.id .. '/delete"'
      ..        ' hx-post="/edit/' .. item.id .. '/delete"'
      ..        ' hx-confirm="Delete this post?"'
      ..        ' class="action-delete-form">'
      ..     '<input type="hidden" name="csrf_token" value="' .. tok .. '">'
      ..     '<button type="submit" class="action-link action-link-danger">Delete</button>'
      ..   '</form>'
      .. '</td>'
      .. '</tr>'
  end

  local table_html = #rows == 0
    and '<div class="no-results">No content yet. Use the buttons above to create your first post.</div>'
    or  '<div class="admin-table-wrap">'
        .. '<table class="admin-table">'
        .. '<thead><tr>'
        .. '<th>Kind</th><th>Title</th><th>Slug</th>'
        .. '<th>Status</th><th>Created</th><th>Actions</th>'
        .. '</tr></thead>'
        .. '<tbody>' .. table.concat(rows, "\n") .. '</tbody>'
        .. '</table>'
        .. '</div>'

  local body =
    '<div class="section-header admin-section-header">'
    .. '<h1>Dashboard</h1>'
    .. '<form method="post" action="/logout" class="logout-form">'
    .. '<input type="hidden" name="csrf_token" value="' .. tok .. '">'
    .. '<button type="submit" class="btn btn-logout">SIGN_OUT</button>'
    .. '</form>'
    .. '</div>'
    .. '<div class="admin-new-row">'
    .. '<a href="/edit/new?kind=blog" class="btn btn-primary">+ Blog post</a>'
    .. '<a href="/edit/new?kind=wiki" class="btn btn-primary">+ Wiki page</a>'
    .. '<a href="/edit/new?kind=docs" class="btn btn-primary">+ Docs page</a>'
    .. '</div>'
    .. table_html

  return render.respond("Dashboard", body)
end)

-- ── GET /edit/new?kind=:kind ───────────────────────────────────────────
route(fm.GET "/edit/new", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end

  local kind = r.params.kind
  if kind ~= "blog" and kind ~= "wiki" and kind ~= "docs" then kind = "blog" end

  return editor_page(nil, kind, nil)
end)

-- ── POST /edit/new ─────────────────────────────────────────────────────
route(fm.POST "/edit/new", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end
  if not csrf_check(r) then
    SetStatus(403)
    return render.respond("Forbidden", '<div class="error-page"><p>Invalid request token. Please go back and try again.</p></div>')
  end

  local kind  = r.params.kind or "blog"
  local title = (r.params.title or ""):match("^%s*(.-)%s*$")
  local slug  = (r.params.slug  or ""):match("^%s*(.-)%s*$")
  local body  = r.params.body  or ""
  local tags  = (r.params.tags  or ""):match("^%s*(.-)%s*$")
  local pub   = (r.params.published == "1") and 1 or 0

  if kind ~= "blog" and kind ~= "wiki" and kind ~= "docs" then kind = "blog" end
  if slug == "" then slug = slugify(title) end

  if title == "" then
    return editor_page(nil, kind, "Title is required.")
  end
  if not valid_slug(slug) then
    return editor_page(nil, kind,
      "Slug must contain only lowercase letters, digits, and hyphens (no leading or trailing hyphens).")
  end

  local ok, err
  if kind == "docs" then
    local file_data = r.params.file or ""
    local mime_type = r.params.mime_type or "application/pdf"
    if file_data == "" then
      return editor_page(nil, kind, "A file is required.")
    end
    ok, err = pcall(db.insert_doc, slug, title, mime_type, file_data, pub)
  else
    if body:match("^%s*$") then
      return editor_page(nil, kind, "Body cannot be empty.")
    end
    ok, err = pcall(db.insert_content, kind, slug, title, body, "", pub, tags)
  end

  if not ok then
    local msg = tostring(err):find("UNIQUE")
      and "A post with that slug already exists for this section."
      or  "Database error: " .. tostring(err)
    return editor_page(nil, kind, msg)
  end

  return do_redirect("/" .. kind .. "/" .. slug)
end)

-- ── POST /edit/preview ─────────────────────────────────────────────────
route(fm.POST "/edit/preview", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end
  if not csrf_check(r) then
    return render.partial('<p class="text-muted">Invalid request token.</p>')
  end

  local body = r.params.body or ""
  if body:match("^%s*$") then
    return render.partial('<p class="text-muted">Preview will appear here\226\128\166</p>')
  end
  return render.partial(md.render(body))
end)

-- ── GET /edit/:id ──────────────────────────────────────────────────────
route(fm.GET "/edit/:id", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end

  local id = tonumber(r.params.id)
  if not id then SetStatus(404); return render.respond("Not Found", BODY_404) end

  local item = db.get_by_id(id)
  if not item then SetStatus(404); return render.respond("Not Found", BODY_404) end

  return editor_page(item, item.kind, nil)
end)

-- ── POST /edit/:id ─────────────────────────────────────────────────────
route(fm.POST "/edit/:id", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end
  if not csrf_check(r) then
    SetStatus(403)
    return render.respond("Forbidden", '<div class="error-page"><p>Invalid request token. Please go back and try again.</p></div>')
  end

  local id = tonumber(r.params.id)
  if not id then SetStatus(404); return render.respond("Not Found", BODY_404) end

  local item = db.get_by_id(id)
  if not item then SetStatus(404); return render.respond("Not Found", BODY_404) end

  local title = (r.params.title or ""):match("^%s*(.-)%s*$")
  local slug  = (r.params.slug  or ""):match("^%s*(.-)%s*$")
  local pub   = (r.params.published == "1") and 1 or 0

  if title == "" then
    return editor_page(item, item.kind, "Title is required.")
  end
  if not valid_slug(slug) then
    return editor_page(item, item.kind,
      "Slug must contain only lowercase letters, digits, and hyphens.")
  end

  local ok, err
  if item.kind == "docs" then
    local file_data = r.params.file or ""
    local mime_type = r.params.mime_type or ""
    local fields = { title=title, slug=slug, published=pub }
    -- Only update file if a new one was uploaded; keep existing blob otherwise.
    if file_data ~= "" then fields.file_data = file_data end
    if mime_type ~= "" then fields.mime_type = mime_type end
    ok, err = pcall(db.update_content, id, fields)
  else
    local body = r.params.body or ""
    local tags = (r.params.tags or ""):match("^%s*(.-)%s*$")
    if body:match("^%s*$") then
      return editor_page(item, item.kind, "Body cannot be empty.")
    end
    ok, err = pcall(db.update_content, id,
      { title=title, slug=slug, body=body, tags=tags, published=pub })
  end

  if not ok then
    local msg = tostring(err):find("UNIQUE")
      and "A post with that slug already exists for this section."
      or  "Database error: " .. tostring(err)
    return editor_page(item, item.kind, msg)
  end

  return do_redirect("/" .. item.kind .. "/" .. slug)
end)

-- ── POST /edit/:id/delete ──────────────────────────────────────────────
route(fm.POST "/edit/:id/delete", function(r)
  local denied = auth.require_client_cert()
  if denied then return denied end
  if not csrf_check(r) then
    SetStatus(403)
    return render.respond("Forbidden", '<div class="error-page"><p>Invalid request token. Please go back and try again.</p></div>')
  end

  local id = tonumber(r.params.id)
  if id then
    local ok, err = pcall(db.delete_content, id)
    if not ok then Log(kLogWarn, "delete failed: " .. tostring(err)) end
  end

  return do_redirect("/edit")
end)

-- ── Catch-all 404 (must be last) ──────────────────────────────────────
route("/*", function(r)
  SetStatus(404)
  return render.respond("Page Not Found", BODY_404)
end)
