// ==Feed==
// @id           org.eu.ywxt.langhuan.jjwxc
// @name         晉江文學城
// @version      1.1.1
// @author       Langhuan
// @description  適配晉江文學城（www.jjwxc.net）的書源：搜尋、詳情、目錄、正文（含作話），章評、段評及回覆免登入讀取；VIP 章節需站方帳號，本源暫不支持登入
// @base_url     https://www.jjwxc.net
// @access_domain www.jjwxc.net
// @access_domain i9-static.jjwxc.net
// @schema_version 6
// ==/Feed==

import { TextDecoder } from "langhuan:encoding";
import { HTML } from "langhuan:html";

// 站點 HTML 頁面聲明 charset=gb18030，評論 JSON API 爲 UTF-8。
const GBK = new TextDecoder("gbk");
const UTF8 = new TextDecoder("utf-8");

// schema 6：response.body 是 Uint8Array，需先解碼成字串。
function bodyText(response) {
  return GBK.decode(response?.body);
}

function bodyJson(response) {
  try {
    return JSON.parse(UTF8.decode(response?.body));
  } catch (_) {
    return null;
  }
}

function requestHeaders() {
  return {
    "User-Agent":
      "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
    Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
  };
}

function responseFailure(response, notFoundMessage) {
  if (response?.status === 404) {
    return FeedError.contentNotFound(notFoundMessage ?? "資源不存在或已下架");
  }
  if (response?.status !== 200) {
    return FeedError.sourceUnavailable(`晉江返回 HTTP ${response?.status}`);
  }
  return null;
}

// ── 文本清洗 ──────────────────────────────────────────────────────────────────

// 實體解碼。&amp; 必須最後處理，否則 &amp;lt; 會被二次解碼成「<」。
function unescapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&nbsp;", " ")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => {
      const code = Number(`0x${hex}`);
      return Number.isInteger(code) && code > 0 && code <= 0x10ffff
        ? String.fromCodePoint(code)
        : "";
    })
    .replace(/&#(\d+);/g, (_, number) => {
      const code = Number(number);
      return Number.isInteger(code) && code > 0 && code <= 0x10ffff
        ? String.fromCodePoint(code)
        : "";
    })
    .replaceAll("&amp;", "&");
}

// 富文本（評論、簡介、段落）：解碼實體後 <br> 轉換行、表情 <img title> 轉
// [標籤]、其餘標籤剔除。站點正文與作話以 </br> 開頭，<\/?br> 兩種都收。
function richText(value) {
  return unescapeHtml(String(value ?? ""))
    .replace(
      /<img\b[^>]*\btitle=(?:"([^"]*)"|'([^']*)')[^>]*>/gi,
      (_, first, second) => `[${first ?? second ?? ""}]`,
    )
    .replace(/<\/?br\s*\/?>/gi, "\n")
    .replace(/<[^>]*>/g, " ")
    .replace(/\u00a0/g, " ")
    .replace(/[\t ]+/g, " ")
    .replace(/ *\n+ */g, "\n")
    .trim();
}

// 單行欄位（書名、作者、章節標題）：richText 再拍平成一行。
function cleanLine(value) {
  return richText(value).replace(/\n+/g, " ").trim();
}

function toCount(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? Math.floor(number) : null;
}

// 站點時間爲北京時間（UTC+8）：YYYY-MM-DD HH:MM:SS → Unix 毫秒。
function beijingTimeMs(value) {
  const match = String(value ?? "").match(
    /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/,
  );
  if (!match) return null;
  const ms = Date.UTC(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]) - 8,
    Number(match[5]),
    Number(match[6]),
  );
  return Number.isFinite(ms) && ms >= 0 && ms <= 8_640_000_000_000_000
    ? ms
    : null;
}

// 站點回覆時間是 Unix 秒字符串（comment_date_time）。
function epochSecondsMs(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  const ms = seconds * 1000;
  return ms <= 8_640_000_000_000_000 ? ms : null;
}

function numericId(value) {
  const text = String(value ?? "").trim();
  return /^\d+$/.test(text) ? text : null;
}

function absoluteUrl(value) {
  const url = String(value ?? "").trim();
  if (!url) return null;
  if (url.startsWith("//")) return `https:${url}`;
  if (url.startsWith("/")) return `${meta.base_url}${url}`;
  return url;
}

// ── GBK 關鍵字編碼 ─────────────────────────────────────────────────────────────
// 搜尋 kw 必須是 GBK 字節的百分號編碼：UTF-8 字節會被站點按 GBK 誤解成亂碼
// 關鍵字（「天官赐福」被搜成「澶…」）。HTML.encodeURIComponents 的可選
// charset 參數直接輸出 GBK 字節的百分號編碼，無需自建碼表。

// ── 搜尋 ─────────────────────────────────────────────────────────────────────
// search.php?kw=<GBK 編碼>&t=1（按作品）。#search_result 內每個結果塊爲
// h3.title + div.intro + div.info；分頁欄 .page 的「下一页」鏈接帶 &p=N，
// 站點約在第 10 頁後截斷，空頁無下一頁自然終止。結果頁無封面圖，封面由
// novelid 構造 CDN URL（見 coverUrl），前端直接顯示、入架後統一下載。

// ── 封面 CDN ─────────────────────────────────────────────────────────────────
// 搜索頁無封面圖，但 CDN 的 novelimage.php 僅憑 novelid 即返回該書當前封面
// （image/*，實測 400×560）；詳情頁 img.noveldefaultimage 的自定義 src 同樣
// 落在該主機（@access_domain 已放行，封面下載需過域名校驗）。
function coverUrl(novelId) {
  return `https://i9-static.jjwxc.net/novelimage.php?novelid=${novelId}`;
}

function search(event) {
  if (event.state == null) {
    const raw = String(event.input.keyword ?? "").trim();
    if (!raw) {
      return { type: "complete", result: [] };
    }
    const query = [
      ["kw", raw],
      ["t", "1"],
    ];
    if (event.cursor != null) query.push(["p", String(Number(event.cursor))]);
    return {
      type: "request",
      request: {
        url:
          `${meta.base_url}/search.php?${HTML.encodeURIComponents(query, "gbk")}`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { requested: true },
    };
  }
  const failure = responseFailure(event.response, "搜索頁不可用");
  if (failure) return failure;
  const document = HTML.parse(bodyText(event.response));
  const items = [];
  const seen = new Set();
  for (const link of document.find(
    '#search_result h3.title a[href*="onebook.php?novelid="]',
  )) {
    const id = String(link.attr("href") ?? "").match(/[?&]novelid=(\d+)/)?.[1];
    const title = cleanLine(link.text());
    if (!id || seen.has(id) || !title) continue;
    const block = link.parent()?.parent(); // a → h3.title → 結果塊 div
    const author =
      cleanLine(
        block?.find('a[href*="oneauthor.php?authorid="]').first()?.text(),
      ) || "未知";
    items.push({
      id,
      title,
      author,
      cover_url: coverUrl(id),
      description: richText(block?.find("div.intro").first()?.text()) || null,
    });
    seen.add(id);
  }
  return {
    type: "complete",
    result: items,
    next_cursor: nextSearchCursor(document),
  };
}

function nextSearchCursor(document) {
  for (const anchor of document.find("#search_result .page a")) {
    if (!anchor.text().includes("下一页")) continue;
    const page = String(anchor.attr("href") ?? "").match(/[?&]p=(\d+)/)?.[1];
    if (page) return Number(page);
  }
  return null;
}

// ── 書籍詳情與目錄 ────────────────────────────────────────────────────────────
// onebook.php?novelid=N：h1[itemprop=name] 書名、span[itemprop=author] 作者、
// img.noveldefaultimage 封面（src 爲作者自定義圖，_src 爲站方默認封面）、
// #novelintro 簡介、#oneboolt 目錄表。目錄單頁全量輸出（數百章亦不分頁），
// 卷標行是 td[colspan=6]，不是 tr[itemprop=chapter]，自然跳過。

function parseBookPage(document, bookId) {
  const title = cleanLine(
    document.find('h1[itemprop="name"]').first()?.text(),
  );
  const author = cleanLine(
    document.find('span[itemprop="author"]').first()?.text(),
  );
  const image = document.find("img.noveldefaultimage").first();
  const intro = document.find("#novelintro").first();
  return {
    id: bookId,
    title: title || "未知書名",
    author: author || "未知",
    cover_url: image?.attr("src") ?? image?.attr("_src") ?? null,
    description: richText(intro?.text()) || null,
  };
}

function bookInfo(event) {
  if (event.state == null) {
    const bookId = numericId(event.input.bookId);
    if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/onebook.php?novelid=${bookId}`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { requested: true },
    };
  }
  const failure = responseFailure(event.response, "書籍頁不可用");
  if (failure) return failure;
  const bookId = numericId(event.input.bookId) ?? "";
  return {
    type: "complete",
    result: parseBookPage(HTML.parse(bodyText(event.response)), bookId),
  };
}

// 目錄行內 span[itemprop=headline] 的第一個 a[itemprop=url]：免費章節 URL
// 在 href（onebook.php），VIP 章節無 href、URL 在 rel（onebook_vip.php），
// 兩者都含 chapterid=N。被鎖定的章節（鎖章待改/管理員鎖定）行內沒有錨點
// 與 chapterid，站點亦不可讀，自然跳過。VIP 章節保留在目錄中，閱讀時按
// 登入頁優雅失敗。
function parseChapters(document) {
  const items = [];
  const seen = new Set();
  for (const row of document.find('#oneboolt tr[itemprop="chapter"]')) {
    const anchor = row
      .find("span[itemprop=headline] a[itemprop=url]")
      .first();
    if (!anchor) continue;
    const url = anchor.attr("href") ?? anchor.attr("rel") ?? "";
    const id = String(url).match(/[?&]chapterid=(\d+)/)?.[1];
    const title = cleanLine(anchor.text());
    if (!id || seen.has(id) || !title) continue;
    items.push({ id, title });
    seen.add(id);
  }
  return items;
}

function chapters(event) {
  if (event.state == null) {
    const bookId = numericId(event.input.bookId);
    if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/onebook.php?novelid=${bookId}`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { requested: true },
    };
  }
  const failure = responseFailure(event.response, "目錄頁不可用");
  if (failure) return failure;
  return {
    type: "complete",
    result: parseChapters(HTML.parse(bodyText(event.response))),
  };
}

// ── 正文 ─────────────────────────────────────────────────────────────────────
// onebook.php?novelid=N&chapterid=M。正文在 #paragraph_comment_content，只有
// 文本與 <br>（插圖章節可能含 <img>）；章節標題在 div.noveltext h2。VIP 章
// 節未登入時整頁跳轉登入表單（無正文容器）。
//
// 段落編號對齊站點規則（onebook.paragraph.comment.js 的
// buildParagraphAnchors）：按 <br> 拆段、僅非空段遞增、1 起始。站點以該
// 編號作段評地址（data-paragraphid），空段（含全角空格）不佔號。

const NOTE_PARAGRAPH_ID = "-2";

// 把 HTML 片段按 <br> 拆行：文本行產生 text 項、<img> 產生 image 項。
// 不帶 id，由調用方按站點段號規則標號（圖片不佔號：站點錨點按文本判空）。
function splitSegments(html) {
  const segments = String(html ?? "")
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
    .split(/<\/?br\s*\/?>/gi);
  const items = [];
  for (const segment of segments) {
    for (const tag of segment.match(/<img\b[^>]*>/gi) ?? []) {
      const match = String(tag).match(
        /\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i,
      );
      const url = absoluteUrl(match?.[1] ?? match?.[2] ?? match?.[3]);
      if (url) items.push({ type: "image", url });
    }
    const text = richText(segment.replace(/<img\b[^>]*>/gi, " "));
    if (text) items.push({ type: "text", content: text });
  }
  return items;
}

// 作話（作者有話說）：#note_str 是 <script type="text/html">，HTML.parse 的
// text() 會跳過 script 內容，須從原始頁面正則截取。站點把整段作話作爲一個
// 評論單元（段號 -2，評論掛在「作者有话」標題上），內部各行不單獨可評。
function noteSegments(body) {
  const match = String(body).match(
    /<script[^>]*\bid="note_str"[^>]*>([\s\S]*?)<\/script>/i,
  );
  if (!match) return [];
  return splitSegments(match[1]);
}

// 段評數角標（getNovelParagraphCommentNum）：data[] 每條
// {paragraph_id, comment_total}，僅含非零段落與作話單元，缺失補 0。
function applyCommentCounts(items, json) {
  const list = Array.isArray(json?.data) ? json.data : [];
  const byParagraph = new Map();
  for (const entry of list) {
    const count = toCount(entry?.comment_total);
    const id = String(entry?.paragraph_id ?? "");
    if (count == null || !id) continue;
    byParagraph.set(id, count);
  }
  for (const item of items) {
    if (item.id == null) continue;
    item.comment_count = byParagraph.get(item.id) ?? 0;
  }
}

function paragraphs(event) {
  const state = event.state;
  if (state == null) {
    const bookId = numericId(event.input.bookId);
    const chapterId = numericId(event.input.chapterId);
    if (!bookId || !chapterId) {
      return FeedError.contentNotFound("無效的書籍或章節 ID");
    }
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/onebook.php?${HTML.encodeURIComponents([
          ["novelid", bookId],
          ["chapterid", chapterId],
        ])}`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { stage: "chapter", bookId, chapterId },
    };
  }
  if (state.stage === "chapter") {
    const failure = responseFailure(event.response, "章節頁不可用");
    if (failure) return failure;
    const body = bodyText(event.response);
    const document = HTML.parse(body);
    const content = document.find("#paragraph_comment_content").first();
    if (content == null) {
      if (document.find('input[type="password"]').length > 0) {
        return FeedError.authRequired(
          "VIP 章節需要登入晉江文學城（本源暫不支持登入）",
        );
      }
      return FeedError.contentNotFound("章節不存在、已刪除或無法讀取");
    }
    const items = [];
    const title = cleanLine(
      document.find("div.noveltext h2").first()?.text() ??
        document.find("h2").first()?.text(),
    );
    if (title) items.push({ type: "title", text: title });
    let counter = 0;
    for (const item of splitSegments(content.html() ?? "")) {
      if (item.type === "text") {
        counter += 1;
        item.id = String(counter);
      }
      items.push(item);
    }
    const note = noteSegments(body);
    if (note.length > 0) {
      items.push({ type: "title", text: "作者有话", id: NOTE_PARAGRAPH_ID });
      items.push(...note);
    }
    return {
      type: "request",
      request: {
        url:
          `${meta.base_url}/app.jjwxc/Pc/comment/getNovelParagraphCommentNum` +
          `?${HTML.encodeURIComponents([
            ["novelid", state.bookId],
            ["chapterid", state.chapterId],
          ])}`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { stage: "counts", items },
    };
  }
  if (state.stage === "counts") {
    const items = state.items ?? [];
    const json = bodyJson(event.response);
    // 角標只是附加資訊：API 異常時省略 comment_count（未知），不影響正文。
    if (
      event.response?.status === 200 &&
      String(json?.code ?? "200") === "200"
    ) {
      applyCommentCounts(items, json);
    }
    return { type: "complete", result: items };
  }
  return FeedError.sourceUnavailable("未知狀態");
}

// ── 評論（免登入）─────────────────────────────────────────────────────────────
// 章評與段評共用 getCommentList：paragraph_id=0 章評、1..N 段評（與正文段落
// 編號對齊）、-2 作話單元，commentTotal 爲總數。回覆走 getReplyList
// （formatter=app 時欄位爲駝峰式 replyId/replyAuthor/replyBody，回應無總
// 數）。commentTotal 含已刪除條目（2958 對實際 2956），且個別條目可能無
// 正文，故游標按 API 返回的原始條數推進、以「本頁滿 COMMENT_PAGE 條」判
// 斷是否還有下一頁，短頁即終止。兩個 API 均免登入。

const COMMENT_PAGE = 20;

function commentAuthor(name, isAuthor, cover) {
  const author = cleanLine(name);
  return {
    name:
      isAuthor === "1" && author ? `[作者] ${author}` : author || "晉江書友",
    avatar_url: absoluteUrl(cover),
  };
}

function commentItems(list) {
  const items = [];
  for (const entry of Array.isArray(list) ? list : []) {
    const id = String(entry?.commentId ?? "").trim();
    if (!id) continue;
    const text = richText(entry?.commentBody);
    if (!text) continue;
    const replyCount = toCount(entry?.replyTotal);
    items.push({
      id,
      author: commentAuthor(
        entry?.commentAuthor,
        entry?.isAuthor,
        entry?.userCover,
      ),
      text,
      created_at_ms: beijingTimeMs(entry?.commentDateOrigin),
      like_count: toCount(entry?.agreenum),
      replies: replyCount == null ? null : { total_count: replyCount },
    });
  }
  return items;
}

// getReplyList（formatter=app）的回覆條目：replyId/replyAuthor/replyBody
// 爲駝峰式，comment_date_time 是 Unix 秒。無正文條目（已刪除）跳過。
function replyItems(list) {
  const items = [];
  for (const entry of Array.isArray(list) ? list : []) {
    const id = String(entry?.replyId ?? "").trim();
    if (!id) continue;
    const text = richText(entry?.replyBody);
    if (!text) continue;
    items.push({
      id,
      author: commentAuthor(
        entry?.replyAuthor,
        entry?.isAuthor,
        entry?.userCover,
      ),
      text,
      created_at_ms: epochSecondsMs(entry?.comment_date_time),
      like_count: toCount(entry?.agreenum),
    });
  }
  return items;
}

function commentsStart(event, paragraphId) {
  const bookId = numericId(event.input.bookId);
  const chapterId = numericId(event.input.chapterId);
  if (!bookId || !chapterId) {
    return FeedError.contentNotFound("無效的書籍或章節 ID");
  }
  const offset = toCount(event.cursor) ?? 0;
  if (event.input.parentId != null) {
    return {
      type: "request",
      request: {
        url:
          `${meta.base_url}/app.jjwxc/Pc/comment/getReplyList` +
          `?${HTML.encodeURIComponents([
            ["novelid", bookId],
            ["chapterid", chapterId],
            ["commentid", String(event.input.parentId)],
            ["offset", String(offset)],
            ["limit", String(COMMENT_PAGE)],
            ["formatter", "app"],
          ])}`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { bookId, chapterId, offset, reply: true },
    };
  }
  return {
    type: "request",
    request: {
      url:
        `${meta.base_url}/app.jjwxc/Pc/comment/getCommentList` +
        `?${HTML.encodeURIComponents([
          ["novelId", bookId],
          ["chapterId", chapterId],
          ["paragraph_id", paragraphId ?? "0"],
          ["offset", String(offset)],
          ["limit", String(COMMENT_PAGE)],
        ])}`,
      method: "GET",
      headers: requestHeaders(),
    },
    next_state: { bookId, chapterId, offset, reply: false },
  };
}

function commentsComplete(event, state) {
  const json = bodyJson(event.response);
  if (json == null) {
    return FeedError.sourceUnavailable("晉江評論回應不是有效的 JSON");
  }
  if (String(json.code ?? "200") !== "200") {
    return FeedError.sourceUnavailable(
      `晉江評論 API 返回錯誤（code=${json.code}，${json.message || "無錯誤消息"}）`,
    );
  }
  // getReplyList 的 data 是陣列；getCommentList 的 data 是帶 commentList
  // 的物件。游標按原始條數推進（被剔除的空正文條目也佔 API 的 offset），
  // 滿頁且未達總數才繼續；getReplyList 無總數，滿頁即認爲還有下一頁。
  const raw = Array.isArray(json.data)
    ? json.data
    : (Array.isArray(json.data?.commentList) ? json.data.commentList : []);
  const offset = toCount(state.offset) ?? 0;
  const items = state.reply ? replyItems(raw) : commentItems(raw);
  const total = state.reply ? null : toCount(json.data?.commentTotal);
  return {
    type: "complete",
    result: items,
    next_cursor:
      raw.length >= COMMENT_PAGE && (total == null || offset + raw.length < total)
        ? offset + raw.length
        : null,
  };
}

function commentsReducer(event, paragraphId) {
  if (event.state == null) return commentsStart(event, paragraphId);
  return commentsComplete(event, event.state);
}

// 章評（paragraph_id=0）與其回覆。
function chapterComments(event) {
  return commentsReducer(event, null);
}

// 段評（1..N 正文段落、-2 作話單元）與其回覆。
function paragraphComments(event) {
  const paragraphId = String(event.input.paragraphId ?? "");
  if (!/^-?\d+$/.test(paragraphId)) {
    return FeedError.contentNotFound("無效的段落 ID");
  }
  return commentsReducer(event, paragraphId);
}

export default {
  search,
  bookInfo,
  chapters,
  paragraphs,
  comments: { chapter: chapterComments, paragraph: paragraphComments },
};
