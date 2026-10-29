// ==Feed==
// @id           biquge-tw
// @name         筆趣閣（biquge.tw）
// @version      2.1.0
// @author       Langhuan
// @description  適配 biquge.tw 的書源，支持搜尋、詳情、目錄、正文（含多頁章節）
// @base_url     https://www.biquge.tw
// @access_domain www.biquge.tw
// @access_domain m.biquge.tw
// @access_domain img.biquge.tw
// @schema_version 4
// ==/Feed==

(() => {
  "use strict";

  // schema 4：response.body 是 Uint8Array，需先解碼成字串。
  const DECODER = new TextDecoder("utf-8");

  function bodyText(response) {
    return DECODER.decode(response?.body);
  }

  function headers() {
    return {
      "User-Agent":
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
      Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    };
  }

  function unescapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&nbsp;", " ")
      .replaceAll("&amp;", "&")
      .replaceAll("&quot;", '"')
      .replaceAll("&#39;", "'")
      .replaceAll("&lt;", "<")
      .replaceAll("&gt;", ">")
      .replace(/&#(\d+);/g, (_, number) => {
        const code = Number(number);
        return Number.isInteger(code) && code <= 0x10ffff
          ? String.fromCodePoint(code)
          : "";
      });
  }

  function text(value) {
    return unescapeHtml(String(value ?? ""))
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p\s*>/gi, "\n")
      .replace(/<[^>]*>/g, " ")
      .replace(/\u00a0/g, " ")
      .replace(/[\t\r ]+/g, " ")
      .replace(/ *\n+ */g, "\n")
      .trim();
  }

  function ensureAvailable(response) {
    const body = bodyText(response);
    if (body.includes("Just a moment") && body.includes("cf_chl_opt")) {
      return FeedError.cfChallenge("biquge.tw returned Cloudflare challenge page");
    }
    return null;
  }

  function bookId(url) {
    return String(url ?? "").match(/\/book\/(\d+)\.html/)?.[1] ?? null;
  }

  function chapterIds(url) {
    const match = String(url ?? "").match(/\/book\/(\d+)\/(\d+)\.html/);
    return match ? [match[1], match[2]] : null;
  }

  function searchItems(body) {
    const document = HTML.parse(body);
    const items = [];
    const seen = new Set();
    let links = document.select(
      '.result-card .book-title[href*="/book/"][href$=".html"]',
    );
    if (links.length === 0) {
      links = document.select('h3 a[href*="/book/"][href$=".html"]');
    }
    if (links.length === 0) {
      links = document.select('a[href*="/book/"][href$=".html"]');
    }
    for (const link of links) {
      const href = link.attr("href") ?? "";
      const id = bookId(href);
      if (!id || seen.has(id)) continue;
      const title = text(link.text());
      if (!title) continue;
      let card = link.parent;
      while (card && !(card.attr("class") ?? "").split(/\s+/).includes("result-card")) {
        card = card.parent;
      }
      const authorNode = card?.select(".book-meta .author, .author").first();
      const introNode = card?.select(".book-intro").first();
      const image = card?.select(".book-cover img, img").first();
      items.push({
        id,
        title,
        author: text(authorNode?.text()) || "未知",
        cover_url: image?.attr("src") ?? null,
        description: text(introNode?.text()) || null,
      });
      seen.add(id);
    }
    return items;
  }

  function nextSearchCursor(body) {
    for (const anchor of HTML.parse(body).select("a")) {
      if (!text(anchor.text()).includes("下一")) continue;
      const page = (anchor.attr("href") ?? "").match(/[?&]page=(\d+)/)?.[1];
      if (page) return Number(page);
    }
    return null;
  }

  function parseBook(response) {
    const body = bodyText(response);
    const document = HTML.parse(body);
    const title = text(document.select("h1").first()?.text()) || "未知書名";
    let author = "未知";
    for (const node of document.select("h2, #info p, p")) {
      const value = text(node.text());
      if (!value.includes("作者")) continue;
      author = value.replace(/^.*?作者\s*[：:]\s*/, "").split(/\s+/)[0] || "未知";
      break;
    }
    const intro = document.select("#intro, .intro").first();
    const image = document
      .select('.fmimg img, img[src*="img.biquge.tw"], img')
      .first();
    return {
      id: bookId(response.url) ?? "",
      title,
      author,
      cover_url: image?.attr("src") ?? null,
      description: text(intro?.text()) || null,
    };
  }

  function parseChapters(response) {
    const body = bodyText(response);
    const document = HTML.parse(body);
    const currentBook = String(response.url).match(/\/book\/(\d+)/)?.[1] ?? "";
    const items = [];
    const seen = new Set();
    for (const anchor of document.select(
      `a[href*="/book/${currentBook}/"][href$=".html"]`,
    )) {
      const ids = chapterIds(anchor.attr("href"));
      if (!ids || ids[0] !== currentBook || seen.has(ids[1])) continue;
      const title = text(anchor.text());
      if (!title) continue;
      items.push({ id: `${ids[0]}/${ids[1]}`, title });
      seen.add(ids[1]);
    }
    return items;
  }

  function parseParagraphs(response) {
    const body = bodyText(response);
    const document = HTML.parse(body);
    const items = [];
    const title = text(document.select("h1").first()?.text())
      .replace(/[（(]\s*\d+\s*\/\s*\d+\s*[）)]\s*$/, "")
      .trim();
    if (title) items.push({ type: "title", text: title });

    const content = document
      .select("#content, #chaptercontent, article, .Readarea")
      .first();
    const paragraphs = content?.select("p").map((node) => text(node.text())) ?? [];
    const blocked = new Set([
      "上一章", "上一页", "下一页", "下一章", "目录", "返回目录",
      "本章未完", "本章未完，点击下一页继续阅读",
    ]);
    const lines = (paragraphs.length ? paragraphs : text(content?.text()).split("\n"))
      .map((line) => line.trim())
      .filter((line) => line && !blocked.has(line));
    for (const line of lines) items.push({ type: "text", content: line });

    let next_cursor = null;
    for (const anchor of document.select("a")) {
      if (!text(anchor.text()).includes("下一页")) continue;
      const page = (anchor.attr("href") ?? "").match(/_(\d+)\.html/)?.[1];
      if (page) next_cursor = Number(page);
    }
    return { items, next_cursor };
  }

  function search(event) {
    if (event.state == null) {
      const params = { searchkey: event.input.keyword };
      if (event.cursor != null) params.page = String(event.cursor);
      return {
        type: "request",
        request: { url: `${meta.base_url}/search/`, method: "GET", params, headers: headers() },
        next_state: { requested: true },
      };
    }
    const failure = ensureAvailable(event.response);
    if (failure) return failure;
    return {
      type: "complete",
      items: searchItems(bodyText(event.response)),
      next_cursor: nextSearchCursor(bodyText(event.response)),
    };
  }

  function bookInfo(event) {
    if (event.state == null) {
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/book/${event.input.bookId}.html`,
          method: "GET",
          headers: headers(),
        },
        next_state: { requested: true },
      };
    }
    const failure = ensureAvailable(event.response);
    return failure ?? { type: "complete", value: parseBook(event.response) };
  }

  function chapters(event) {
    if (event.state == null) {
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/book/${event.input.bookId}/`,
          method: "GET",
          headers: headers(),
        },
        next_state: { requested: true },
      };
    }
    const failure = ensureAvailable(event.response);
    return failure ?? { type: "complete", items: parseChapters(event.response) };
  }

  function paragraphs(event) {
    if (event.state == null) {
      const composite = String(event.input.chapterId ?? "").match(/^(\d+)\/(\d+)$/);
      const book = composite?.[1] ?? String(event.input.bookId ?? "");
      const chapter = composite?.[2] ?? String(event.input.chapterId ?? "");
      if (!book || !chapter) return FeedError.contentNotFound("invalid chapter id");
      const suffix = event.cursor == null ? "" : `_${event.cursor}`;
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/book/${book}/${chapter}${suffix}.html`,
          method: "GET",
          headers: headers(),
        },
        next_state: { requested: true },
      };
    }
    const failure = ensureAvailable(event.response);
    if (failure) return failure;
    const page = parseParagraphs(event.response);
    return { type: "complete", items: page.items, next_cursor: page.next_cursor };
  }

  return { search, bookInfo, chapters, paragraphs };
})()
