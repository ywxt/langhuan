-- ==Feed==
-- @id           biquge-tw
-- @name         筆趣閣（biquge.tw）
-- @version      1.1.0
-- @author       GitHub Copilot
-- @description  適配 biquge.tw 的書源，支持搜尋、詳情、目錄、正文（含多頁章節）
-- @base_url     https://www.biquge.tw
-- @allowed_domain www.biquge.tw
-- @allowed_domain m.biquge.tw
-- @allowed_domain img.biquge.tw
-- ==/Feed==

-- The runtime injects `meta` as a global table from the feed header.
-- luacheck: globals meta
---@diagnostic disable: undefined-global

local html = require("@langhuan/html")

--- Build browser-mimicking HTTP headers to bypass Cloudflare
local function get_headers()
    return {
        ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
        ["Referer"] = "https://www.google.com/",
        ["DNT"] = "1",
        ["Upgrade-Insecure-Requests"] = "1",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "none",
        ["Cache-Control"] = "max-age=0",
    }
end

local function trim(s)
    if s == nil then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
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
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("</p>", "\n")
    s = s:gsub("<[^>]->", " ")
    s = html_unescape(s)
    s = s:gsub("[ \t\r]+", " ")
    s = s:gsub("\n+", "\n")
    return trim(s)
end

local function is_cf_challenge(body)
    if body == nil then
        return false
    end
    return body:find("Just a moment", 1, true) ~= nil
        and body:find("cf_chl_opt", 1, true) ~= nil
end

local function ensure_not_blocked(resp)
    if is_cf_challenge(resp.body) then
        error("biquge.tw returned Cloudflare challenge page; source cannot continue")
    end
end

local function urlencode(s)
    if s == nil then
        return ""
    end
    return (s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function extract_book_id(url)
    if url == nil then
        return nil
    end
    return url:match("/book/(%d+)%.html")
end

local function split_chapter_composite_id(chapter_id)
    if chapter_id == nil then
        return nil, nil
    end
    local book_id, ch_id = tostring(chapter_id):match("^(%d+)%/(%d+)$")
    return book_id, ch_id
end

local function to_chapter_composite_id(book_id, chapter_id)
    return tostring(book_id) .. "/" .. tostring(chapter_id)
end

local function clean_text(s)
    s = strip_tags(s)
    s = s:gsub("\194\160", " ")
    s = s:gsub("%s+", " ")
    return trim(s)
end

local function parse_doc(body)
    local ok, doc = pcall(html.parse, body or "")
    if ok then
        return doc
    end
    return nil
end

local function parse_next_search_cursor(doc)
    if not doc then
        return nil
    end

    local links = doc:select("a")
    for i = 1, #links do
        local link = links[i]
        local text = clean_text(link:text())
        if text:find("下一", 1, true) ~= nil then
            local href = link:attr("href") or ""
            local page = href:match("[?&]page=(%d+)")
            if page then
                return tonumber(page)
            end
        end
    end

    return nil
end

local function parse_search_items(body)
    local doc = parse_doc(body)
    local items = {}
    local seen = {}

    if not doc then
        return items
    end

    local nodes = doc:select('a[href*="/book/"][href$=".html"]')
    for i = 1, #nodes do
        local node = nodes[i]
        local href = node and node:attr("href") or ""
        local id = extract_book_id(href)
        if id and not seen[id] then
            local title = clean_text(node:text())
            if title ~= "" then
                table.insert(items, {
                    id = id,
                    title = title,
                    author = "未知",
                    cover_url = nil,
                    description = nil,
                })
                seen[id] = true
            end
        end
    end

    return items
end

local function parse_book_info(resp)
    local body = resp.body or ""
    local id = extract_book_id(resp.url) or ""
    local doc = parse_doc(body)

    local title = ""
    local author = "未知"
    local description = ""
    local cover = nil

    if doc then
        local title_node = doc:select("h1"):first()
        if title_node then
            title = clean_text(title_node:text())
        end

        local info_ps = doc:select("#info p")
        if #info_ps == 0 then
            info_ps = doc:select("p")
        end
        for i = 1, #info_ps do
            local text = clean_text(info_ps[i]:text())
            if text:find("作者", 1, true) ~= nil then
                local v = trim((text:gsub("^.-[:：]", "")))
                if v ~= "" then
                    author = v
                    break
                end
            end
        end

        local intro = doc:select("#intro"):first()
        if not intro then
            intro = doc:select(".intro"):first()
        end
        if intro then
            description = clean_text(intro:text())
        end

        local img = doc:select(".fmimg img"):first()
        if not img then
            img = doc:select("img"):first()
        end
        if img then
            cover = img:attr("src")
        end
    end

    if title == "" then
        title = "未知书名"
    end
    if author == "" then
        author = "未知"
    end

    return {
        id = id,
        title = title,
        author = author,
        cover_url = cover,
        description = description ~= "" and description or nil,
    }
end

local function parse_chapter_items(resp)
    local body = resp.body or ""
    local book_id = resp.url:match("/book/(%d+)/") or resp.url:match("/book/(%d+)$") or ""
    local doc = parse_doc(body)

    local items = {}
    local seen = {}
    local index = 0

    if doc and book_id ~= "" then
        local selector = 'a[href*="/book/' .. book_id .. '/"][href$=".html"]'
        local nodes = doc:select(selector)
        for i = 1, #nodes do
            local node = nodes[i]
            local href = node and node:attr("href") or ""
            local b_id, ch_id = href:match("/book/(%d+)/(%d+)%.html")
            if b_id == book_id and ch_id and not seen[ch_id] then
                local clean_title = clean_text(node:text())
                if clean_title ~= "" then
                    table.insert(items, {
                        id = to_chapter_composite_id(b_id, ch_id),
                        title = clean_title,
                        index = index,
                    })
                    index = index + 1
                    seen[ch_id] = true
                end
            end
        end
    end

    return items
end

local function parse_paragraph_items(resp)
    local body = resp.body or ""
    local doc = parse_doc(body)
    local items = {}

    local title = ""
    if doc then
        local title_node = doc:select("h1"):first()
        if title_node then
            title = clean_text(title_node:text())
        end
    end
    if title ~= "" then
        table.insert(items, {
            type = "title",
            text = title,
        })
    end

    if doc then
        local lines = doc:select("#content p")
        if #lines == 0 then
            lines = doc:select("#chaptercontent p")
        end
        if #lines == 0 then
            lines = doc:select("article p")
        end
        if #lines == 0 then
            lines = doc:select(".Readarea p")
        end

        if #lines > 0 then
            for i = 1, #lines do
                local text = clean_text(lines[i]:text())
                if text ~= ""
                    and text ~= "上一章"
                    and text ~= "下一页"
                    and text ~= "目录"
                    and text ~= "返回目录"
                    and text ~= "本章未完"
                then
                    table.insert(items, {
                        type = "text",
                        content = text,
                    })
                end
            end
        else
            local content = doc:select("#content"):first()
            if not content then
                content = doc:select("#chaptercontent"):first()
            end
            if not content then
                content = doc:select("article"):first()
            end
            if not content then
                content = doc:select(".Readarea"):first()
            end
            if content then
                local text = clean_text(content:text())
                if text ~= "" then
                    table.insert(items, {
                        type = "text",
                        content = text,
                    })
                end
            end

            if #items == 0 then
                local raw = body:match('<div[^>]-id=["\']chaptercontent["\'][^>]*>(.-)</div>')
                if not raw then
                    raw = body:match('<div[^>]-id=["\']content["\'][^>]*>(.-)</div>')
                end
                if raw then
                    local text = clean_text(raw)
                    if text ~= "" then
                        table.insert(items, {
                            type = "text",
                            content = text,
                        })
                    end
                end
            end
        end
    end

    local next_cursor = nil
    if doc then
        local links = doc:select("a")
        for i = 1, #links do
            local a = links[i]
            local t = clean_text(a:text())
            if t:find("下一页", 1, true) ~= nil then
                local href = a:attr("href") or ""
                local p = href:match("_(%d+)%.html")
                if p then
                    next_cursor = tonumber(p)
                    break
                end
            end
        end
    end

    return {
        items = items,
        next_cursor = next_cursor,
    }
end

return {
    search = {
        request = function(keyword, cursor)
            local params = {
                searchkey = keyword,
            }
            if cursor ~= nil then
                params.page = tostring(cursor)
            end
            return {
                url = meta.base_url .. "/search/",
                method = "GET",
                params = params,
                headers = get_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)

            local body = resp.body or ""
            local doc = parse_doc(body)
            local items = parse_search_items(body)
            local next_cursor = parse_next_search_cursor(doc)

            return {
                items = items,
                next_cursor = next_cursor,
            }
        end,
    },

    book_info = {
        request = function(id)
            return {
                url = meta.base_url .. "/book/" .. tostring(id) .. ".html",
                method = "GET",
                headers = get_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            return parse_book_info(resp)
        end,
    },

    chapters = {
        request = function(book_id, _cursor)
            return {
                url = meta.base_url .. "/book/" .. tostring(book_id) .. "/",
                method = "GET",
                headers = get_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)

            return {
                items = parse_chapter_items(resp),
                next_cursor = nil,
            }
        end,
    },

    paragraphs = {
        request = function(chapter_id, cursor)
            local book_id, ch_id = split_chapter_composite_id(chapter_id)
            if not book_id or not ch_id then
                error("invalid chapter id, expected 'book_id/chapter_id'")
            end

            local suffix = ""
            if cursor ~= nil then
                suffix = "_" .. tostring(cursor)
            end

            return {
                url = meta.base_url .. "/book/" .. book_id .. "/" .. ch_id .. suffix .. ".html",
                method = "GET",
                headers = get_headers(),
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            return parse_paragraph_items(resp)
        end,
    },
}
