-- ==Feed==
-- @id           biquge-tw
-- @name         筆趣閣（biquge.tw）
-- @version      1.0.0
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
    s = s:gsub("[\194\160]", " ")
    s = s:gsub("%s+", " ")
    return trim(s)
end

local function safe_sub(s, from_pos, length)
    if s == nil or from_pos == nil then
        return ""
    end
    local finish = from_pos + length
    if finish > #s then
        finish = #s
    end
    return s:sub(from_pos, finish)
end

local function parse_next_search_cursor(body)
    local href = body:match([[<a[^>]-href="([^"]-)"[^>]*>[^<]-下一[^<]-</a>]])
    if not href then
        href = body:match([[<a[^>]-href='([^']-)'[^>]*>[^<]-下一[^<]-</a>]])
    end
    if not href then
        href = body:match([[href="([^"]-page=%d+[^"]-)"[^>]->[^<]-下一]])
    end
    if not href then
        return nil
    end
    local page = href:match("[?&]page=(%d+)")
    if page then
        return tonumber(page)
    end
    return nil
end

local function parse_search_items(body)
    local items = {}
    local seen = {}

    for href, inner in body:gmatch([[<a[^>]-href="([^"]-/book/%d+%.html)"[^>]*>(.-)</a>]]) do
        local id = extract_book_id(href)
        if id and not seen[id] then
            local title = clean_text(inner)
            if title ~= "" then
                local item = {
                    id = id,
                    title = title,
                    author = "未知",
                    cover_url = nil,
                    description = nil,
                }

                -- Find a nearby snippet around this anchor to infer author/description.
                local pos = body:find(href, 1, true)
                if pos then
                    local snippet = safe_sub(body, pos, 1400)

                    local author = snippet:match("作者[:：]%s*</?[^>]*>([^<\n]-)</")
                    if not author then
                        author = snippet:match("作者[:：]%s*([^<\n|/ ]+)")
                    end
                    if not author then
                        author = snippet:match([[<p[^>]-class="author"[^>]*>(.-)</p>]])
                        author = clean_text(author)
                    else
                        author = clean_text(author)
                    end
                    if author ~= "" then
                        item.author = author
                    end

                    local desc = snippet:match([[<p[^>]-class="desc"[^>]*>(.-)</p>]])
                    if not desc then
                        desc = snippet:match([[<div[^>]-class="intro"[^>]*>(.-)</div>]])
                    end
                    desc = clean_text(desc)
                    if desc ~= "" then
                        item.description = desc
                    end
                end

                local cover = body:match("https?://img%.biquge%.tw/[^\"']+" .. id .. "[^\"']*%.jpg")
                if cover and cover ~= "" then
                    item.cover_url = cover
                end

                table.insert(items, item)
                seen[id] = true
            end
        end
    end

    return items
end

local function parse_book_info(resp)
    local body = resp.body
    local id = extract_book_id(resp.url) or ""

    local title = body:match([[<h1[^>]*>(.-)</h1>]])
    title = clean_text(title)

    local author = body:match([[作者[:：]%s*<a[^>]*>(.-)</a>]])
    if not author then
        author = body:match([[作者[:：]%s*([^<\n]+)]])
    end
    author = clean_text(author)

    local description = body:match([[小说简介[:：]%s*(.-)</p>]])
    if not description then
        description = body:match([[<div[^>]-id="intro"[^>]*>(.-)</div>]])
    end
    description = clean_text(description)

    local cover = body:match([[<img[^>]-src="(https?://img%.biquge%.tw[^"]+)"[^>]*]])
    if not cover then
        cover = body:match([[<img[^>]-src='(https?://img%.biquge%.tw[^']+)'[^>]*]])
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
    local body = resp.body
    local book_id = resp.url:match("/book/(%d+)/") or resp.url:match("/book/(%d+)$") or ""

    local items = {}
    local seen = {}
    local index = 0

    for b_id, ch_id, title in body:gmatch([[<a[^>]-href="/book/(%d+)/(%d+)%.html"[^>]*>(.-)</a>]]) do
        if b_id == book_id and not seen[ch_id] then
            local clean_title = clean_text(title)
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

    return items
end

local function parse_paragraph_items(resp)
    local body = resp.body
    local items = {}

    local title = body:match([[<h1[^>]*>(.-)</h1>]])
    title = clean_text(title)
    if title ~= "" then
        table.insert(items, {
            type = "title",
            text = title,
        })
    end

    local content = body:match([[<div[^>]-id="content"[^>]*>(.-)</div>]])
    if not content then
        content = body:match([[<article[^>]*>(.-)</article>]])
    end

    if content then
        content = content:gsub("<br%s*/?>", "\n")
        content = content:gsub("</p>", "\n")
        content = strip_tags(content)

        for line in content:gmatch("[^\n]+") do
            local text = trim(line)
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
    end

    local next_cursor = nil

    local cur, total = body:match("%((%d+)%s*/%s*(%d+)%)")
    cur = tonumber(cur)
    total = tonumber(total)
    if cur and total and cur < total then
        next_cursor = cur + 1
    else
        local p = body:match([[<a[^>]-href="[^"]-_%s*(%d+)%.html"[^>]*>[^<]-下一页[^<]-</a>]])
        if not p then
            p = body:match([[href="[^"]-_(%d+)%.html"[^>]->[^<]-下一页]])
        end
        if p then
            next_cursor = tonumber(p)
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
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)

            local body = resp.body or ""
            local items = parse_search_items(body)
            local next_cursor = parse_next_search_cursor(body)

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
            }
        end,
        parse = function(resp)
            ensure_not_blocked(resp)
            return parse_paragraph_items(resp)
        end,
    },
}
