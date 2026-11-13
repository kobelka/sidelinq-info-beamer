-- Sidelinq Turnier: Live-Anzeige für info-beamer (Raspberry Pi, ohne Browser).
-- Der Dienst (service) schreibt data.json; hier wird nur gezeichnet.
-- Layout wie die Beamer-Seite in Sidelinq (/t/<slug>/beamer), Grundgröße 1920 × 1080.

gl.setup(1920, 1080)

local W, H = 1920, 1080
local EM = 20 -- entspricht 1.05vw bei 1920 px in der Browser-Ansicht

local font_regular = resource.load_font "Inter-Regular.ttf"
local font_semi = resource.load_font "Inter-SemiBold.ttf"
local font_bold = resource.load_font "Inter-ExtraBold.ttf"
local sidelinq_icon = resource.load_image "sidelinq-icon.png"

local ROTATE_SECONDS = 15
local FLASH_SECONDS = 8
local STALE_SECONDS = 45
local MAX_LIVE = 8

-- Farben (Tailwind wie in der Browser-Ansicht)
local function hex(h, a)
    return {
        tonumber(h:sub(2, 3), 16) / 255,
        tonumber(h:sub(4, 5), 16) / 255,
        tonumber(h:sub(6, 7), 16) / 255,
        a or 1,
    }
end

local C = {
    bg = hex "#020617",          -- slate-950
    panel = hex "#0f172a",       -- slate-900
    line = hex "#1e293b",        -- slate-800
    dot = hex "#334155",         -- slate-700
    muted = hex "#64748b",       -- slate-500
    soft = hex "#94a3b8",        -- slate-400
    light = hex "#cbd5e1",       -- slate-300
    lighter = hex "#e2e8f0",     -- slate-200
    white = hex "#ffffff",
    ink = hex "#0f172a",
    amber300 = hex "#fcd34d",
    amber400 = hex "#fbbf24",
    amber50 = hex "#fffbeb",
    amber900 = hex "#78350f",
    amber950 = hex("#451a03", 0.7),
    amberRow = hex("#fbbf24", 0.15),
    cyan300 = hex "#67e8f9",
    cyan200 = hex "#a5f3fc",
    emerald300 = hex "#6ee7b7",
    emerald400 = hex "#34d399",
    emeraldRow = hex("#022c22", 0.6),
    red400 = hex "#f87171",
    linq = hex "#22e88b",        -- Sidelinq-Grün der Wortmarke
}

local textures = {}
local function tex(c)
    local key = table.concat(c, ",")
    local t = textures[key]
    if not t then
        t = resource.create_colored_texture(c[1], c[2], c[3], c[4])
        textures[key] = t
    end
    return t
end

local function rect(x1, y1, x2, y2, c, alpha)
    tex(c):draw(x1, y1, x2, y2, alpha or 1)
end

local function frame(x1, y1, x2, y2, c, w)
    w = w or 2
    rect(x1, y1, x2, y1 + w, c)
    rect(x1, y2 - w, x2, y2, c)
    rect(x1, y1, x1 + w, y2, c)
    rect(x2 - w, y1, x2, y2, c)
end

-- ---------- Text ----------

-- Letztes UTF-8-Zeichen entfernen (Folgebytes 128–191 gehören zum Zeichen davor)
local function drop_last_char(s)
    local i = #s
    while i > 1 and s:byte(i) >= 128 and s:byte(i) < 192 do i = i - 1 end
    return s:sub(1, i - 1)
end

local function fit(font, text, size, maxw)
    text = text or ""
    if maxw <= 0 then return "" end
    if font:width(text, size) <= maxw then return text end
    local t = text
    while #t > 0 and font:width(t .. "…", size) > maxw do
        t = drop_last_char(t)
    end
    return t .. "…"
end

-- y = Oberkante der Zeile, h = Zeilenhöhe: Text vertikal mittig
local function text(font, x, y, h, s, size, c, maxw, align)
    s = s or ""
    if maxw then s = fit(font, s, size, maxw) end
    local w = font:width(s, size)
    if align == "right" then
        x = x + (maxw or 0) - w
    elseif align == "center" then
        x = x + ((maxw or 0) - w) / 2
    end
    font:write(x, y + (h - size) / 2, s, size, c[1], c[2], c[3], c[4])
    return w
end

-- ---------- Bilder (Logos) ----------

local images = {}
local function image(name)
    if not name then return nil end
    local e = images[name]
    if not e then
        local ok, img = pcall(resource.load_image, name)
        e = { img = ok and img or nil, used = sys.now(), tried = sys.now() }
        images[name] = e
    elseif not e.img and sys.now() - e.tried > 5 then
        local ok, img = pcall(resource.load_image, name)
        e.img = ok and img or nil
        e.tried = sys.now()
    end
    e.used = sys.now()
    if e.img and e.img:state() == "loaded" then return e.img end
    return nil
end

local function drop_unused_images()
    local now = sys.now()
    for name, e in pairs(images) do
        if now - e.used > 120 then
            if e.img then e.img:dispose() end
            images[name] = nil
        end
    end
end

-- Logo als Quadrat; ohne Logo bleibt der Platz frei (wie im Browser)
local function logo(name, x, y, size)
    local img = image(name)
    if img then img:draw(x, y, x + size, y + size) end
end

-- ---------- Daten ----------

local data = nil
local received = 0
local flash_until = {}
local last_scores = {}

local function each_match(feed, fn)
    for _, key in ipairs { "live", "next", "recent" } do
        for _, m in ipairs(feed[key] or {}) do fn(m) end
    end
    for _, page in ipairs(feed.pages or {}) do
        for _, panel in ipairs(page) do
            if panel.kind == "ko" then
                for _, m in ipairs(panel.matches or {}) do fn(m) end
            end
        end
    end
end

util.json_watch("data.json", function(d)
    data = d
    received = sys.now()
    if d.feed then
        local scores = {}
        each_match(d.feed, function(m)
            scores[m.id] = m.score
            local before = last_scores[m.id]
            if before and before ~= m.score then
                flash_until[m.id] = sys.now() + FLASH_SECONDS
            end
        end)
        last_scores = scores
    end
end)

local function flashing(id)
    local t = flash_until[id]
    if not t then return false end
    if sys.now() > t then
        flash_until[id] = nil
        return false
    end
    return math.floor(sys.now() * 2) % 2 == 0
end

local function side_name(side)
    if side.noShow then return "Nicht angetreten", C.red400 end
    return side.name, nil
end

-- Ganze Zahl ohne Nachkommastellen (JSON-Zahlen sind Gleitkommazahlen)
local function int(n)
    return string.format("%d", math.floor(n + 0.5))
end

local function is_placeholder(score)
    return score:sub(1, 3) == "—"
end

-- ---------- Kopf- und Fußzeile ----------

local function clock_text()
    if not data or not data.clock then return "" end
    local s = (data.clock + (sys.now() - received)) % 86400
    return string.format("%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60)
end

local function stand_text()
    if not data or not data.clock then return "" end
    local s = data.clock % 86400
    return string.format("%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60)
end

local HEADER_H = 128
local FOOTER_H = 162

local function draw_header(feed)
    rect(0, 0, W, HEADER_H, C.panel)
    rect(0, HEADER_H - 2, W, HEADER_H, C.line)
    local x = 32
    if feed.organizerLogo then
        -- Freies Logo mit Schein: das Wappen selbst füllt etwa 0,84 der Bildfläche,
        -- deshalb größer zeichnen, damit es so groß wirkt wie früher die Plakette.
        local size = 92
        logo(feed.organizerLogo, x - 10, (HEADER_H - size) / 2, size)
        x = x + 72 + 24
    end
    local right = 300
    local reserve = right
    if feed.sponsorLogo then
        -- Sponsor („Präsentiert von“) prominent oben links neben der Uhr
        local size = 92  -- gleich groß wie das Gastgeber-Logo
        local cw = math.max(font_bold:width(clock_text(), 52), 160)
        local sx = W - 32 - cw - 24 - size
        logo(feed.sponsorLogo, sx, (HEADER_H - size) / 2, size)
        reserve = W - 32 - sx + 24
    end
    local maxw = W - x - reserve - 32
    text(font_bold, x, 18, 58, feed.title, 48, C.white, maxw)
    local sub = feed.date or ""
    if feed.venue and feed.venue ~= "" then sub = sub .. " · " .. feed.venue end
    text(font_regular, x, 76, 32, sub, 24, C.soft, maxw)

    -- Uhr und „Live“ bzw. Hinweis bei Verbindungsproblemen
    local cx = W - 32 - right
    text(font_bold, cx, 18, 60, clock_text(), 52, C.white, right, "right")
    local stale = data.status ~= "ok" or (sys.now() - received > STALE_SECONDS)
    if stale then
        text(font_semi, cx, 82, 26, "Stand " .. stand_text() .. " Uhr", 19, C.amber300, right, "right")
    else
        local lw = font_bold:width("LIVE", 19)
        local lx = W - 32 - lw
        text(font_bold, lx, 82, 26, "LIVE", 19, C.emerald300)
        local pulse = 0.4 + 0.6 * math.abs(math.sin(sys.now() * 2))
        rect(lx - 22, 89, lx - 10, 101, C.emerald400, pulse)
    end
end

local function draw_footer(feed)
    local y = H - FOOTER_H
    rect(0, y, W, y + 2, C.line)
    local x = 32
    if feed.qr then
        local qr = image(feed.qr)
        if qr then
            rect(x, y + 16, x + 130, y + 146, C.white)
            qr:draw(x + 4, y + 20, x + 126, y + 142)
        end
        text(font_semi, x + 148, y + 50, 30, "Spielplan und Tabellen", 23, C.lighter)
        text(font_semi, x + 148, y + 80, 30, "live auf dem Handy", 23, C.lighter)
        x = x + 148 + font_semi:width("Spielplan und Tabellen", 23) + 40
    end
    -- Sidelinq-Wortmarke groß (Werbung), darunter die Adresse
    sidelinq_icon:draw(x, y + 30, x + 72, y + 102)
    local w = text(font_bold, x + 86, y + 28, 64, "Side", 54, C.white)
    text(font_bold, x + 86 + w, y + 28, 64, "linq", 54, C.linq)
    text(font_regular, x + 88, y + 96, 30, "Turnierplaner · sidelinq.de", 21, C.soft)
end

-- ---------- Linke Spalte ----------

local function draw_live(feed, x, y, w)
    local live = feed.live or {}
    if #live == 0 then return y end
    text(font_bold, x, y, 30, "LÄUFT GERADE", 22, C.amber300)
    y = y + 40
    local n = math.min(#live, MAX_LIVE)
    local cols = n > 1 and 2 or 1
    local compact = n > 4
    local s = compact and 0.75 or 1
    local gap = 16
    local cw = (w - (cols - 1) * gap) / cols
    local card_h = math.floor(150 * s)
    for i = 1, n do
        local m = live[i]
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = x + col * (cw + gap)
        local cy = y + row * (card_h + gap)
        local bg = flashing(m.id) and C.amber300 or C.amber50
        rect(cx, cy, cx + cw, cy + card_h, bg)
        frame(cx, cy, cx + cw, cy + card_h, C.amber400, 3)
        local pad = math.floor(20 * s)
        local label = math.floor(19 * s)
        text(font_bold, cx + pad, cy + 10 * s, 28 * s, m.pitch, label, C.amber900)
        text(font_regular, cx + pad + 160 * s, cy + 10 * s, 28 * s, m.section, label, C.amber950, cw - 2 * pad - 160 * s, "right")
        local size = math.floor(29 * s)
        local logo_size = math.floor(44 * s)
        local goals_size = math.floor(39 * s)
        local rows = { { m.home, m.homeScore }, { m.away, m.awayScore } }
        for r = 1, 2 do
            local ry = cy + 46 * s + (r - 1) * 50 * s
            local side, goals = rows[r][1], rows[r][2]
            logo(side.logoLight or side.logo, cx + pad, ry + (46 * s - logo_size) / 2, logo_size)
            local name, color = side_name(side)
            local nx = cx + pad + logo_size + 12 * s
            local gw = 64 * s
            text(font_semi, nx, ry, 46 * s, name, size, color or C.ink, cx + cw - pad - gw - nx - 8)
            text(font_bold, cx + cw - pad - gw, ry, 46 * s, goals, goals_size, C.ink, gw, "right")
        end
        if m.note then
            text(font_bold, cx + pad, cy + card_h - 30 * s, 24 * s, m.note, label, C.amber900, cw - 2 * pad, "right")
        end
    end
    local rows = math.ceil(n / cols)
    return y + rows * card_h + (rows - 1) * gap + 24
end

local function draw_upcoming(feed, x, y, w, bottom)
    local next_matches = feed.next or {}
    if #next_matches == 0 then return y end
    local live_n = math.min(#(feed.live or {}), MAX_LIVE)
    local max_rows = math.max(2, 6 - math.ceil(live_n / 2))
    text(font_bold, x, y, 30, "ALS NÄCHSTES", 22, C.cyan300)
    y = y + 40
    local row_h = 58
    local space = math.floor((bottom - y) / row_h)
    local n = math.min(#next_matches, max_rows, math.max(space, 0))
    if n <= 0 then return y end
    rect(x, y, x + w, y + n * row_h, C.panel)
    frame(x, y, x + w, y + n * row_h, C.line, 2)
    for i = 1, n do
        local m = next_matches[i]
        local ry = y + (i - 1) * row_h
        if i > 1 then rect(x, ry, x + w, ry + 2, C.line) end
        local size = 26
        local px = x + 20
        text(font_bold, px, ry, row_h, m.time, size, C.cyan200, 110)
        text(font_semi, px + 118, ry, row_h, m.pitch, 22, C.soft, 104)
        local lx = px + 118 + 112
        local ls = 36
        local mid = x + w / 2 + 110
        logo(m.home.logo, lx, ry + (row_h - ls) / 2, ls)
        local hn, hc = side_name(m.home)
        text(font_semi, lx + ls + 12, ry, row_h, hn, size, hc or C.white, mid - 20 - (lx + ls + 12))
        text(font_regular, mid - 8, ry, row_h, "–", size, C.muted)
        local an, ac = side_name(m.away)
        local rx = x + w - 20 - ls
        logo(m.away.logo, rx, ry + (row_h - ls) / 2, ls)
        text(font_semi, mid + 20, ry, row_h, an, size, ac or C.white, rx - 12 - (mid + 20), "right")
    end
    return y + n * row_h + 24
end

-- ---------- Rechte Spalte ----------

local function panel_rows(panel)
    if panel.kind == "table" then return #(panel.rows or {}) end
    return #(panel.matches or {})
end

local function draw_dots(x_right, y, h, count, idx)
    if count <= 1 then return end
    local d, gap = 11, 7
    local x = x_right - count * (d + gap) + gap
    for i = 1, count do
        rect(x, y + (h - d) / 2, x + d, y + (h + d) / 2, i == idx and C.cyan300 or C.dot)
        x = x + d + gap
    end
end

local function draw_table(panel, x, y, w, row_h, size, dots)
    local head_h = 54
    local cols_h = 30
    local has_stats = false
    for _, r in ipairs(panel.rows or {}) do
        if r.points ~= nil then has_stats = true end
    end
    local total = head_h + (has_stats and cols_h or 0) + #panel.rows * row_h
    rect(x, y, x + w, y + total, C.panel)
    frame(x, y, x + w, y + total, C.line, 2)
    text(font_bold, x + 20, y, head_h, panel.title, 27, C.white, w - 200)
    if dots then dots(x + w - 20, y, head_h) end
    rect(x, y + head_h - 2, x + w, y + head_h, C.line)
    local cy = y + head_h
    local right = x + w - 20
    local c_pts, c_diff, c_goals, c_sp = right - 64, right - 64 - 64, right - 128 - 90, right - 218 - 56
    if has_stats then
        local hs = 17
        text(font_semi, x + 20, cy, cols_h, "#", hs, C.soft)
        text(font_semi, x + 72, cy, cols_h, "TEAM", hs, C.soft)
        text(font_semi, c_sp, cy, cols_h, "SP", hs, C.soft, 50, "right")
        text(font_semi, c_goals, cy, cols_h, "TORE", hs, C.soft, 84, "right")
        text(font_semi, c_diff, cy, cols_h, "DIFF", hs, C.soft, 58, "right")
        text(font_semi, c_pts, cy, cols_h, "PKT", hs, C.soft, 64, "right")
        cy = cy + cols_h
    end
    local name_right = has_stats and (c_sp - 12) or (right)
    for _, r in ipairs(panel.rows) do
        rect(x, cy, x + w, cy + 2, C.line)
        if r.highlight then rect(x + 2, cy + 2, x + w - 2, cy + row_h, C.emeraldRow) end
        text(font_bold, x + 20, cy, row_h, int(r.rank), size, C.light)
        local ls = math.floor(row_h * 0.7)
        logo(r.logo, x + 72, cy + (row_h - ls) / 2, ls)
        local nx = x + 72 + ls + 10
        text(font_semi, nx, cy, row_h, r.name, size, C.white, name_right - nx)
        if has_stats and r.points ~= nil then
            local diff = r.diff > 0 and ("+" .. int(r.diff)) or int(r.diff)
            text(font_regular, c_sp, cy, row_h, int(r.played), size, C.light, 50, "right")
            text(font_regular, c_goals, cy, row_h, r.goals, size, C.light, 84, "right")
            text(font_regular, c_diff, cy, row_h, diff, size, C.light, 58, "right")
            text(font_bold, c_pts, cy, row_h, int(r.points), size, C.white, 64, "right")
        end
        cy = cy + row_h
    end
    return y + total
end

local function draw_ko(panel, x, y, w, row_h, size, dots)
    local head_h = 54
    local total = head_h + #panel.matches * row_h
    rect(x, y, x + w, y + total, C.panel)
    frame(x, y, x + w, y + total, C.line, 2)
    text(font_bold, x + 20, y, head_h, panel.title, 27, C.white, w - 200)
    if dots then dots(x + w - 20, y, head_h) end
    local cy = y + head_h
    local ls = math.floor(row_h * 0.65)
    for _, m in ipairs(panel.matches) do
        rect(x, cy - 2, x + w, cy, C.line)
        if m.live then rect(x + 2, cy, x + w - 2, cy + row_h, C.amberRow) end
        if flashing(m.id) then rect(x + 2, cy, x + w - 2, cy + row_h, C.amber300, 0.35) end
        if m.live then
            local p = 0.5 + 0.5 * math.abs(math.sin(sys.now() * 3))
            rect(x + 16, cy + row_h / 2 - 6, x + 28, cy + row_h / 2 + 6, C.amber400, p)
        end
        local placeholder = is_placeholder(m.score)
        local mid_text = (m.live or not placeholder) and m.score or m.time
        local mid_font = (not m.live and placeholder) and font_semi or font_bold
        local mid_color = m.live and C.amber300 or (placeholder and C.soft or C.white)
        local mw = mid_font:width(mid_text, size)
        local mx = x + w / 2 - mw / 2
        local lx = x + 40
        logo(m.home.logo, lx, cy + (row_h - ls) / 2, ls)
        local hn, hc = side_name(m.home)
        text(font_semi, lx + ls + 10, cy, row_h, hn, size, hc or C.white, mx - 14 - (lx + ls + 10))
        text(mid_font, mx, cy, row_h, mid_text, size, mid_color)
        local rx = x + w - 20 - ls
        logo(m.away.logo, rx, cy + (row_h - ls) / 2, ls)
        local an, ac = side_name(m.away)
        text(font_semi, mx + mw + 14, cy, row_h, an, size, ac or C.white, rx - 10 - (mx + mw + 14), "right")
        cy = cy + row_h
    end
    return y + total
end

local function draw_recent(feed, x, y, w, bottom)
    local recent = feed.recent or {}
    if #recent == 0 then return end
    if bottom - y < 40 + 54 * 2 then return end
    text(font_bold, x, y, 30, "LETZTE ERGEBNISSE", 22, C.soft)
    y = y + 40
    local row_h = 54
    local n = math.min(#recent, math.floor((bottom - y) / row_h))
    rect(x, y, x + w, y + n * row_h, C.panel)
    frame(x, y, x + w, y + n * row_h, C.line, 2)
    for i = 1, n do
        local m = recent[i]
        local ry = y + (i - 1) * row_h
        if i > 1 then rect(x, ry, x + w, ry + 2, C.line) end
        if flashing(m.id) then rect(x + 2, ry, x + w - 2, ry + row_h, C.amber300, 0.35) end
        local size = 23
        local sw = font_bold:width(m.score, size)
        local sx = x + w / 2 - sw / 2
        local hn, hc = side_name(m.home)
        local an, ac = side_name(m.away)
        text(font_semi, x + 20, ry, row_h, hn, size, hc or C.white, sx - 14 - (x + 20))
        text(font_bold, sx, ry, row_h, m.score, size, C.white)
        text(font_semi, sx + sw + 14, ry, row_h, an, size, ac or C.white, x + w - 20 - (sx + sw + 14), "right")
    end
end

local function draw_right(feed, x, y, w, bottom)
    local pages = feed.pages or {}
    local count = #pages
    if count == 0 then
        draw_recent(feed, x, y, w, bottom)
        return
    end
    local idx = (math.floor(sys.now() / ROTATE_SECONDS) % count) + 1
    local page = pages[idx]
    local rows, has_ko = 0, false
    for _, p in ipairs(page) do
        rows = rows + panel_rows(p)
        if p.kind == "ko" then has_ko = true end
    end
    local show_recent = #(feed.recent or {}) > 0 and rows <= 8 and not has_ko
    local dense = #page > 1
    -- Zeilenhöhe so wählen, dass die Seite in die Spalte passt
    local avail = bottom - y - (show_recent and (40 + 54 * 3 + 24) or 0)
    local fixed = #page * (54 + 30 + 24)
    local row_h = math.floor(math.min(dense and 42 or 48, math.max(28, (avail - fixed) / math.max(rows, 1))))
    local size = math.floor(math.min(dense and 21 or 24, row_h * 0.55))
    local dots = function(xr, dy, dh) draw_dots(xr, dy, dh, count, idx) end
    for i, p in ipairs(page) do
        local d = (i == 1) and dots or nil
        if p.kind == "ko" then
            y = draw_ko(p, x, y, w, row_h, size, d)
        else
            y = draw_table(p, x, y, w, row_h, size, d)
        end
        y = y + 24
    end
    if show_recent then draw_recent(feed, x, y, w, bottom) end
end

-- ---------- Hinweisbildschirm ----------

local function draw_message(title, msg)
    text(font_bold, 0, H / 2 - 90, 70, title, 56, C.white, W, "center")
    text(font_regular, 0, H / 2, 50, msg or "", 30, C.soft, W, "center")
    local x = W / 2 - 160
    sidelinq_icon:draw(x, H - 120, x + 40, H - 80)
    text(font_regular, x + 54, H - 120, 40, "Turnierplaner · sidelinq.de", 24, C.muted)
end

function node.render()
    gl.clear(C.bg[1], C.bg[2], C.bg[3], 1)
    if not data then
        draw_message("Sidelinq Turnier", "Daten werden geladen …")
        return
    end
    local feed = data.feed
    if not feed then
        local titles = {
            no_link = "Beamer-Link fehlt",
            not_found = "Turnier nicht gefunden",
            stale = "Keine Verbindung",
            update = "Paket veraltet",
        }
        draw_message(titles[data.status] or "Sidelinq Turnier", data.message)
        return
    end

    draw_header(feed)
    local top = HEADER_H + 28
    local bottom = H - FOOTER_H - 28
    local gap = 28
    local left_w = math.floor((W - 2 * 28 - gap) * 3 / 5)
    local lx = 28
    local rx = lx + left_w + gap
    local rw = W - 28 - rx

    local y = draw_live(feed, lx, top, left_w)
    draw_upcoming(feed, lx, y, left_w, bottom)
    if #(feed.live or {}) == 0 and #(feed.next or {}) == 0 and #(feed.recent or {}) == 0 then
        text(font_regular, lx, (top + bottom) / 2 - 30, 60, "Der Spielplan erscheint hier, sobald er steht.", 32, C.soft, left_w, "center")
    end
    draw_right(feed, rx, top, rw, bottom)
    draw_footer(feed)
    drop_unused_images()
end
