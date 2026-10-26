-- ==Feed==
-- @id           qidian
-- @name         起點中文網
-- @version      1.0.0
-- @author       Langhuan
-- @description  起點中文網書源（m 站）。支持閱文通行證登錄；VIP 章節需登錄並在起點訂閱後閱讀
-- @base_url     https://m.qidian.com
-- @access_domain m.qidian.com
-- @access_domain www.qidian.com
-- @schema_version 1
-- ==/Feed==

-- Qidian (起點中文網) book source for Langhuan.
--
-- Strategy notes:
--   * www.qidian.com sits behind a Tencent WAF JS fingerprint challenge
--     (probe.js / probev3.js) that plain HTTP clients cannot execute, so all
--     requests target the mobile site m.qidian.com instead. The mobile pages
--     are server-side rendered (vite-plugin-ssr) and embed their data as JSON
--     inside <script id="vite-plugin-ssr_pageContext">, so search / book
--     info / catalog / chapter content all come from JSON, not HTML scraping.
--   * Login uses the Yuewen passport SSO (passport.qidian.com redirects to
--     passport.yuewen.com and back to m.qidian.com). The WebView executes the
--     WAF probe and the account login; login.parse captures the .qidian.com
--     session cookies (ywkey / ywguid) which patch_request forwards on every
--     request. Login status is read from the `user` object embedded in every
--     SSR page.
--   * VIP chapters (chapterInfo.vipStatus == 1) only return a short preview
--     unless the account is logged in AND has purchased the chapter.

-- The runtime injects `meta` as a global table from the feed header.
-- luacheck: globals meta
---@diagnostic disable: undefined-global

local html = require("@langhuan/html")
local err = require("@langhuan/error")
local json = require("@langhuan/json")

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function trim(s)
    if s == nil then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Percent-encode a URL path segment (also usable for query values).
local function urlencode(s)
    if s == nil then
        return ""
    end
    return (s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function html_unescape(s)
    if s == nil then
        return ""
    end
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&amp;", "&")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#39;", "'")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&#(%d+);", function(n)
        local num = tonumber(n)
        if num and num >= 0 and num <= 255 then
            return string.char(num)
        end
        return ""
    end)
    return s
end

local function strip_tags(s)
    if s == nil then
        return ""
    end
    s = s:gsub("<script.-</script>", " ")
    s = s:gsub("<style.-</style>", " ")
    s = s:gsub("<br%s*/?>", " ")
    s = s:gsub("<[^>]->", " ")
    return html_unescape(s)
end

--- Collapse whitespace and trim. Note: Lua `%s` only matches ASCII
--- whitespace, so the fullwidth indent (U+3000) that Qidian prefixes each
--- paragraph with is intentionally preserved.
local function clean_text(s)
    s = strip_tags(s)
    s = s:gsub("\194\160", " ")
    s = s:gsub("%s+", " ")
    return trim(s)
end

--- Format a JSON number as a plain decimal id string without ever producing
--- scientific notation or a trailing ".0".
local function format_id(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.0f", v)
    end
    return tostring(v)
end

--- Protocol-relative URLs ("//bookcover...") → absolute https URLs.
local function absolute_url(u)
    if u == nil then
        return nil
    end
    u = trim(u)
    if u == "" then
        return nil
    end
    if u:sub(1, 2) == "//" then
        return "https:" .. u
    end
    return u
end

--- Safely walk nested tables: nav(ctx, "pageProps", "pageData", "user").
local function nav(t, ...)
    local cur = t
    for i = 1, select("#", ...) do
        if type(cur) ~= "table" then
            return nil
        end
        cur = cur[select(i, ...)]
    end
    return cur
end

local function request_headers()
    return {
        ["User-Agent"] = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36"
            .. " (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
    }
end

-- ── Qidian SSR page context ─────────────────────────────────────────────────

local PAGE_CONTEXT_MARKER = 'id="vite-plugin-ssr_pageContext"'

--- Extract and decode the `pageContext` JSON embedded in every m.qidian.com
--- server-rendered page. Returns nil when the page does not contain one
--- (error pages, WAF challenges, layout changes).
local function extract_page_context(body)
    if body == nil then
        return nil
    end

    local marker_at = body:find(PAGE_CONTEXT_MARKER, 1, true)
    if marker_at == nil then
        return nil
    end

    -- The JSON payload starts after the opening <script ...> tag ends.
    local tag_end = body:find(">", marker_at, true)
    if tag_end == nil then
        return nil
    end
    local payload_end = body:find("</script>", tag_end + 1, true)
    if payload_end == nil then
        return nil
    end

    local raw = body:sub(tag_end + 1, payload_end - 1)
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil
    end
    return data.pageContext
end

local function is_waf_challenge(body)
    if body == nil then
        return false
    end
    return body:find("probe.js", 1, true) ~= nil
        or body:find("probev3.js", 1, true) ~= nil
        or body:find("turing.captcha.qcloud.com", 1, true) ~= nil
end

--- Raise a structured error when the response is a Qidian WAF challenge.
local function ensure_not_blocked(resp)
    if is_waf_challenge(resp.body) then
        err.cf_challenge("起點風控攔截（probe challenge），請稍後重試")
    end
end

--- Validate the HTTP status code. 404 maps to content_not_found; other
--- non-200 statuses map to source_unavailable.
local function ensure_ok(resp, not_found_msg)
    if resp.status == 404 then
        err.content_not_found(not_found_msg or "資源不存在或已下架")
    end
    if resp.status ~= 200 then
        err.source_unavailable("起點返回 HTTP " .. tostring(resp.status))
    end
end

-- ── Search ──────────────────────────────────────────────────────────────────

--- Parse search results from the m-site `/soushu/{kw}.html` SSR page.
--- Books live at pageProps.pageData.bookInfo.records[] with fields:
--- bid, bName, bAuth, desc, imgUrl, cat, state, cnt.
local function parse_search_items(body)
    local ctx = extract_page_context(body)
    if ctx == nil then
        err.source_unavailable("無法解析起點搜索頁（頁面格式變更或被風控攔截）")
    end

    local records = nav(ctx, "pageProps", "pageData", "bookInfo", "records")
    local items = {}
    if type(records) ~= "table" then
        return items
    end

    for i = 1, #records do
        local r = records[i]
        local id = format_id(r and r.bid)
        local title = clean_text(r and r.bName)
        if id ~= "" and title ~= "" then
            table.insert(items, {
                id = id,
                title = title,
                author = clean_text(r and r.bAuth),
                cover_url = absolute_url(r and r.imgUrl),
                description = clean_text(r and r.desc),
            })
        end
    end

    return items
end

-- ── Book info ───────────────────────────────────────────────────────────────

--- Parse book details from the m-site `/book/{id}/` SSR page. The JSON
--- bookInfo table carries bookName / authorName / desc but not the cover;
--- the cover is rendered as <img data-src="//bookcover.yuewen.com/...">.
local function parse_book_info(resp)
    local body = resp.body or ""
    local ctx = extract_page_context(body)
    if ctx == nil then
        err.content_not_found("書籍不存在、已下架，或頁面格式變更")
    end

    local info = nav(ctx, "pageProps", "pageData", "bookInfo")
    if type(info) ~= "table" or info.bookName == nil then
        err.content_not_found("書籍不存在或已下架")
    end

    local cover_url = nil
    local ok, doc = pcall(html.parse, body)
    if ok and doc then
        local img = doc:select("img.detail__header-cover__img"):first()
        if img then
            cover_url = absolute_url(img:attr("data-src") or img:attr("src"))
        end
    end
    if cover_url == nil then
        -- Fallback: first bookcover.yuewen.com data-src in the raw HTML.
        cover_url = absolute_url(body:match('data%-src="(//bookcover%.yuewen%.com/[^"]+)"'))
    end

    local id = (resp.url or ""):match("/book/(%d+)") or format_id(info.bookId)

    return {
        id = id,
        title = clean_text(info.bookName),
        author = clean_text(info.authorName),
        cover_url = cover_url,
        description = clean_text(info.desc),
    }
end

-- ── Chapters ────────────────────────────────────────────────────────────────

--- Parse the chapter list from the m-site `/book/{id}/catalog/` SSR page.
--- Volumes live at pageProps.pageData.vs[] (ordered by _index); each volume
--- has vN (name) and cs[] chapters with id / cN (name).
local function parse_chapter_items(resp)
    local ctx = extract_page_context(resp.body)
    if ctx == nil then
        err.source_unavailable("無法解析起點目錄頁（頁面格式變更或被風控攔截）")
    end

    local vs = nav(ctx, "pageProps", "pageData", "vs")
    if type(vs) ~= "table" then
        err.source_unavailable("起點目錄頁缺少章節數據")
    end

    -- Defensive copy + sort so volume order never depends on JSON order.
    local volumes = {}
    for i = 1, #vs do
        volumes[i] = vs[i]
    end
    table.sort(volumes, function(a, b)
        local ai = (a and type(a._index) == "number") and a._index or 0
        local bi = (b and type(b._index) == "number") and b._index or 0
        return ai < bi
    end)

    local items = {}
    local seen = {}
    for vi = 1, #volumes do
        local cs = volumes[vi] and volumes[vi].cs
        if type(cs) == "table" then
            for ci = 1, #cs do
                local c = cs[ci]
                local id = format_id(c and c.id)
                local title = clean_text(c and c.cN)
                if id ~= "" and title ~= "" and not seen[id] then
                    seen[id] = true
                    table.insert(items, {
                        id = id,
                        title = title,
                    })
                end
            end
        end
    end

    return items
end

-- ── Chapter content ─────────────────────────────────────────────────────────

--- Split the chapterInfo.content HTML fragment into paragraphs. Qidian
--- separates paragraphs with (unclosed) <p> tags; inline illustrations appear
--- as <img> tags.
local function split_paragraphs(content)
    local items = {}

    local s = content
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("</p>", "\n")
    s = s:gsub("<p%s[^>]->", "\n")
    s = s:gsub("<p>", "\n")

    for line in s:gmatch("([^\n]+)") do
        if trim(line) ~= "" then
            if line:find("<img", 1, true) ~= nil then
                local src = line:match('<img[^>]-src="([^"]+)"')
                    or line:match("<img[^>]-src='([^']+)'")
                    or line:match("<img[^>]-src=([^%s>]+)")
                if src then
                    table.insert(items, {
                        type = "image",
                        url = absolute_url(src),
                    })
                end
            else
                local text = clean_text(line)
                if text ~= "" then
                    table.insert(items, {
                        type = "text",
                        content = text,
                    })
                end
            end
        end
    end

    return items
end

--- Parse chapter content from the m-site `/chapter/{bookId}/{chapterId}/` SSR
--- page. Raises auth_required for VIP chapters when not logged in, and
--- content_not_found when the account has not purchased the chapter.
local function parse_paragraph_items(resp)
    local ctx = extract_page_context(resp.body)
    if ctx == nil then
        err.content_not_found("章節不存在、已下架，或頁面格式變更")
    end

    local ci = nav(ctx, "pageProps", "pageData", "chapterInfo")
    if type(ci) ~= "table" then
        err.content_not_found("章節不存在或已下架")
    end

    local user = nav(ctx, "pageProps", "pageData", "user")
    local logged_in = type(user) == "table" and user.isLogin == true

    if ci.vipStatus == 1 then
        if not logged_in then
            err.auth_required("VIP 章節需要登錄起點帳號")
        end
        -- A purchased VIP chapter returns the full text; an unpurchased one
        -- only returns a short preview (~100 chars). #content counts bytes,
        -- so 1000 bytes ≈ 330 Chinese characters — far below any real
        -- chapter but well above the preview.
        if ci.isBuy == 0 and #(ci.content or "") < 1000 then
            err.content_not_found("此 VIP 章節尚未訂閱，請先在起點購買本章")
        end
    end

    local content = ci.content or ""
    if content == "" then
        err.content_not_found("章節內容為空")
    end

    local items = {}

    local title = clean_text(ci.chapterName)
    if title ~= "" then
        table.insert(items, {
            type = "title",
            text = title,
        })
    end

    for _, p in ipairs(split_paragraphs(content)) do
        table.insert(items, p)
    end

    return items
end

-- ── Login ───────────────────────────────────────────────────────────────────

--- Tracking / analytics / WAF-fingerprint cookies. The WAF cookie (w_tsfp)
--- is bound to the WebView's browser fingerprint; replaying it from the HTTP
--- client would trip additional risk control, so it is excluded.
local EXCLUDED_COOKIES = {
    ["HMACCOUNT"] = true,
    ["newstatisticUUID"] = true,
    ["fu"] = true,
    ["traffic_utm_referer"] = true,
    ["w_tsfp"] = true,
    ["x-waf-captcha-referer"] = true,
    ["seo-jump-referrer"] = true,
}

local function is_excluded_cookie(name)
    if name == nil or name == "" then
        return true
    end
    if EXCLUDED_COOKIES[name] then
        return true
    end
    -- Baidu analytics cookies all start with "Hm_".
    return name:sub(1, 3) == "Hm_"
end

local login_handlers = {
    -- Yuewen passport SSO. The WebView runs the WAF probe + account login and
    -- lands back on m.qidian.com, by which time the .qidian.com session
    -- cookies (ywkey / ywguid) have been set.
    entry = function()
        return {
            url = "https://passport.qidian.com/?returnurl="
                .. urlencode("https://m.qidian.com/"),
            title = "起點中文網登錄",
        }
    end,

    parse = function(page)
        local cookies = page.cookies or {}
        local pairs = {}
        local has_login_cookie = false

        for i = 1, #cookies do
            local c = cookies[i]
            local name = c and c.name or ""
            local value = c and c.value or ""
            local domain = c and c.domain or ""

            local domain_ok = domain == "" or domain:find("qidian.com", 1, true) ~= nil
            local value_ok = value ~= "" and value:find("[;,%c]") == nil

            if domain_ok and value_ok and not is_excluded_cookie(name) then
                table.insert(pairs, name .. "=" .. value)
                if name == "ywkey" or name == "ywguid" then
                    has_login_cookie = true
                end
            end
        end

        if not has_login_cookie then
            err.auth_required("登錄尚未完成：未檢測到起點登錄 Cookie")
        end

        return {
            cookie_header = table.concat(pairs, "; "),
            captured_url = page.current_url,
        }
    end,

    patch_request = function(_context, request, auth)
        if auth and auth.cookie_header and auth.cookie_header ~= "" then
            if request.headers == nil then
                request.headers = {}
            end
            request.headers["Cookie"] = auth.cookie_header
        end
        return request
    end,

    status = {
        -- Probe a lightweight no-match search page: it embeds the `user`
        -- object (~25 KB) without any book data.
        request = function()
            return {
                url = meta.base_url .. "/soushu/langhuan-auth-probe.html",
                method = "GET",
                headers = request_headers(),
            }
        end,
        parse = function(resp)
            local ok, result = pcall(function()
                local ctx = extract_page_context(resp.body or "")
                if ctx == nil then
                    return false
                end
                local user = nav(ctx, "pageProps", "pageData", "user")
                return type(user) == "table" and user.isLogin == true
            end)
            if ok then
                return result
            end
            return false
        end,
    },
}

-- ── Feed handlers ───────────────────────────────────────────────────────────

return {
    search = {
        request = function(keyword, _cursor)
            return {
                url = meta.base_url .. "/soushu/" .. urlencode(keyword) .. ".html",
                method = "GET",
                headers = request_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            ensure_ok(resp, "搜索頁不可用")

            -- The m-site serves a single results page (~20 books).
            return {
                items = parse_search_items(resp.body),
                next_cursor = nil,
            }
        end,
    },

    book_info = {
        request = function(book_id)
            return {
                url = meta.base_url .. "/book/" .. tostring(book_id) .. "/",
                method = "GET",
                headers = request_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            ensure_ok(resp)
            return parse_book_info(resp)
        end,
    },

    chapters = {
        request = function(book_id, _cursor)
            return {
                url = meta.base_url .. "/book/" .. tostring(book_id) .. "/catalog/",
                method = "GET",
                headers = request_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            ensure_ok(resp, "目錄頁不可用")

            -- The full catalog (all volumes) arrives in a single response.
            return {
                items = parse_chapter_items(resp),
                next_cursor = nil,
            }
        end,
    },

    paragraphs = {
        request = function(book_id, chapter_id, _cursor)
            return {
                url = meta.base_url .. "/chapter/"
                    .. tostring(book_id) .. "/" .. tostring(chapter_id) .. "/",
                method = "GET",
                headers = request_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            ensure_ok(resp)

            -- A single chapter always fits in one response.
            return {
                items = parse_paragraph_items(resp),
                next_cursor = nil,
            }
        end,
    },

    login = login_handlers,
}
