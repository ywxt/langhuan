// ==Feed==
// @id           org.eu.ywxt.langhuan.qidian
// @name         起點中文網
// @version      4.1.0
// @author       Langhuan
// @description  起點中文網書源（m 站），支持登入及已購 VIP 章節，登錄後可讀章評與段評
// @base_url     https://m.qidian.com
// @access_domain m.qidian.com
// @access_domain *.image.myqcloud.com
// @schema_version 5
// ==/Feed==

import { TextDecoder, Bytes } from "langhuan:encoding";
import { HTML } from "langhuan:html";

const PAGE_CONTEXT_MARKER = 'id="vite-plugin-ssr_pageContext"';

// schema 5：response.body 是 Uint8Array，需先解碼成字串。
const DECODER = new TextDecoder("utf-8");

function bodyText(response) {
  return DECODER.decode(response?.body);
}
const USER_AGENT =
  "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

function requestHeaders() {
  return {
    "User-Agent": USER_AGENT,
    Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
  };
}

function trim(value) {
  return value == null
    ? ""
    : String(value).replace(/^[\t\r\n\f\v ]+|[\t\r\n\f\v ]+$/g, "");
}

function htmlUnescape(value) {
  return String(value ?? "")
    .replaceAll("&nbsp;", " ")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replace(/&#(\d+);/g, (_, code) => {
      const value = Number(code);
      return Number.isInteger(value) && value >= 0 && value <= 0x10ffff
        ? String.fromCodePoint(value)
        : "";
    });
}

function cleanText(value) {
  return htmlUnescape(String(value ?? ""))
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
    .replace(/<br\s*\/?>/gi, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/\u00a0/g, " ")
    .replace(/[\t\r\n ]+/g, " ")
    .replace(/^[\t\r\n\f\v ]+|[\t\r\n\f\v ]+$/g, "");
}

function formatId(value) {
  if (value == null) return "";
  if (typeof value === "number") return value.toFixed(0);
  return String(value);
}

function absoluteUrl(value) {
  const url = trim(value);
  if (!url) return null;
  if (url.startsWith("//")) return `https:${url}`;
  if (url.startsWith("/")) return `${meta.base_url}${url}`;
  return url;
}

function extractFockUrl(html) {
  const scripts = HTML.parse(String(html ?? "")).select(
    'script[rel="preload"][as="script"][src*="/coco/"][src$=".js"]',
  );
  return scripts.length ? absoluteUrl(scripts.first().attr("src")) : null;
}

function nav(value, ...path) {
  let current = value;
  for (const key of path) {
    if (current == null || typeof current !== "object") return undefined;
    current = current[key];
  }
  return current;
}

function extractPageContext(body) {
  if (typeof body !== "string") return null;
  const markerAt = body.indexOf(PAGE_CONTEXT_MARKER);
  if (markerAt < 0) return null;
  const tagEnd = body.indexOf(">", markerAt);
  if (tagEnd < 0) return null;
  const payloadEnd = body.indexOf("</script>", tagEnd + 1);
  if (payloadEnd < 0) return null;
  try {
    return JSON.parse(body.slice(tagEnd + 1, payloadEnd)).pageContext ?? null;
  } catch (_) {
    return null;
  }
}

function isWafChallenge(body) {
  const text = String(body ?? "");
  return (
    text.includes("probe.js") ||
    text.includes("probev3.js") ||
    text.includes("turing.captcha.qcloud.com")
  );
}

function responseFailure(response, notFoundMessage) {
  if (isWafChallenge(bodyText(response))) {
    return FeedError.cfChallenge("起點風控攔截（probe challenge），請稍後重試");
  }
  if (response.status === 404) {
    return FeedError.contentNotFound(notFoundMessage ?? "資源不存在或已下架");
  }
  if (response.status !== 200) {
    return FeedError.sourceUnavailable(`起點返回 HTTP ${response.status}`);
  }
  return null;
}

function parseSearchPage(body) {
  const context = extractPageContext(body);
  if (!context) return null;
  const bookInfo = nav(context, "pageProps", "pageData", "bookInfo");
  const records = bookInfo?.records;
  if (!Array.isArray(records)) return null;
  const items = records
    .map((record) => ({
      id: formatId(record?.bid),
      title: cleanText(record?.bName),
      author: cleanText(record?.bAuth),
      cover_url: absoluteUrl(record?.imgUrl),
      description: cleanText(record?.desc),
    }))
    .filter((book) => book.id && book.title);
  const pageNum = Number(bookInfo?.pageNum);
  const isLast = Number(bookInfo?.isLast);
  if (
    !Number.isInteger(pageNum) ||
    pageNum < 1 ||
    (isLast !== 0 && isLast !== 1)
  )
    return null;
  return { items, pageNum, hasNext: isLast === 0 };
}

function parseBookInfo(response, fallbackId) {
  const context = extractPageContext(bodyText(response));
  const info = nav(context, "pageProps", "pageData", "bookInfo");
  if (!info?.bookName) return null;

  const coverMatch = bodyText(response).match(
    /(?:data-src|src)="(\/\/bookcover\.yuewen\.com\/[^"]+)"/,
  );
  const idMatch = response.url.match(/\/book\/(\d+)/);
  return {
    id: formatId(info.bookId) || idMatch?.[1] || fallbackId,
    title: cleanText(info.bookName),
    author: cleanText(info.authorName),
    cover_url: absoluteUrl(coverMatch?.[1]),
    description: cleanText(info.desc),
  };
}

function parseChapterItems(response) {
  const context = extractPageContext(bodyText(response));
  const volumes = nav(context, "pageProps", "pageData", "vs");
  if (!Array.isArray(volumes)) return null;

  const seen = new Set();
  const items = [];
  for (const volume of [...volumes].sort(
    (left, right) => Number(left?._index ?? 0) - Number(right?._index ?? 0),
  )) {
    for (const chapter of Array.isArray(volume?.cs) ? volume.cs : []) {
      const id = formatId(chapter?.id);
      const title = cleanText(chapter?.cN);
      if (id && title && !seen.has(id)) {
        seen.add(id);
        items.push({ id, title });
      }
    }
  }
  return items;
}

// 服務端段落 ID（chapterreview/reviewlist4m 的 paragraphId）按 <p> 計數：
// 標題之後第 k 個 <p> 爲 k（1-based，已實測詭秘之主第一章 69 個 <p> 與
// 段評 paragraphId 1..69 一一對應）。同一 <p> 內 <br> 拆出的小段共享所
// 屬 <p> 的 id，宿主以後代路徑區分；<p> 結構之外的裸內容無法對齊服務
// 端段號，段落不帶 id。
function splitParagraphs(content) {
  const items = [];
  const chunks = String(content ?? "").split(/<p(?:\s[^>]*)?>/i);
  pushParagraphSegments(items, chunks[0], null);
  for (let index = 1; index < chunks.length; index += 1) {
    pushParagraphSegments(items, chunks[index], String(index));
  }
  return items;
}

// 一個 <p>（id 爲該段服務端序號）或無結構內容（id 爲 null）的行拆分。
function pushParagraphSegments(items, chunk, id) {
  const segments = String(chunk ?? "")
    .replace(/<\/p\s*>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n");
  for (const line of segments.split("\n")) {
    if (!line.trim()) continue;
    if (/<img\b/i.test(line)) {
      const match = line.match(
        /<img[^>]*\bsrc=(?:"([^"]+)"|'([^']+)'|([^\s>]+))/i,
      );
      const url = absoluteUrl(match?.[1] ?? match?.[2] ?? match?.[3]);
      if (url) items.push({ type: "image", url, id });
      continue;
    }
    const text = cleanText(line);
    if (text) items.push({ type: "text", content: text, id });
  }
}

function completeParagraphs(title, content) {
  const items = [];
  const cleanTitle = cleanText(title);
  if (cleanTitle) items.push({ type: "title", text: cleanTitle });
  items.push(...splitParagraphs(content));
  return { type: "complete", result: items, next_cursor: null };
}

function responseCookies(headers) {
  const cookies = [];
  for (const pair of Array.isArray(headers) ? headers : []) {
    if (String(pair?.[0] ?? "").toLowerCase() !== "set-cookie") continue;
    const first = String(pair?.[1] ?? "")
      .split(";", 1)[0]
      .trim();
    if (/^[^=;\s]+=[^;]*$/.test(first)) cookies.push(first);
  }
  return cookies.join("; ");
}

function cookieMap(header) {
  const result = new Map();
  for (const part of String(header ?? "").split(";")) {
    const separator = part.indexOf("=");
    if (separator <= 0) continue;
    const name = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (name) result.set(name, value);
  }
  return result;
}

function mergeCookieHeaders(base, overlay) {
  const cookies = cookieMap(base);
  for (const [name, value] of cookieMap(overlay)) cookies.set(name, value);
  return [...cookies].map(([name, value]) => `${name}=${value}`).join("; ");
}

const FOCK_ENV_PROGRAM = `
(() => {
  globalThis.outerHeight = 1000;
  globalThis.innerHeight = 100;
  globalThis.location = {
    protocol: "https:",
    hostname: "vipreader.qidian.com",
  };
  globalThis.window = globalThis;
  globalThis.self = globalThis;
  globalThis.navigator = { userAgent: "Langhuan QuickJS Compute" };
  globalThis.console = {
    log() {}, info() {}, warn() {}, error() {}, debug() {}, trace() {}
  };
  globalThis.performance = { now() { return Date.now(); } };
  globalThis.setTimeout = function(callback) {
    if (typeof callback === "function") callback();
    return 0;
  };
  globalThis.clearTimeout = function() {};
  globalThis.setInterval = function() { return 0; };
  globalThis.clearInterval = function() {};
  globalThis.atob = function(value) {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    let str = String(value).replace(/=+$/, "");
    let output = "";
    if (str.length % 4 === 1) throw new TypeError("invalid base64");
    for (let bc = 0, bs, buffer, index = 0;
         (buffer = str.charAt(index++));
         ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer,
         bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
      buffer = chars.indexOf(buffer);
    }
    return output;
  };
  globalThis.__commonJs = { exports: {} };
  globalThis.module = globalThis.__commonJs;
  globalThis.exports = globalThis.__commonJs.exports;
})();
`;

const FOCK_INITIALIZE_PROGRAM = `
(() => {
  globalThis.__fock =
    typeof globalThis.Fock === "object"
      ? globalThis.Fock
      : globalThis.__commonJs.exports;
  if (
    (typeof globalThis.__fock !== "object" &&
      typeof globalThis.__fock !== "function") ||
    typeof globalThis.__fock.unlock !== "function"
  ) {
    throw new Error("Fock was not exported by the official script");
  }
  globalThis.__fock.initialize();
  globalThis.__fock.setupUserKey(String(input.fuid));
})();
`;

const FOCK_UNLOCK_PROGRAM = `
export default (() => {
  let completed = false;
  let result = null;
  let failure = null;
  globalThis.__fock.unlock(
    String(input.encrypted),
    String(input.chapterId),
    (code, value) => {
      completed = true;
      if (code === 0) result = value;
      else failure = new Error("Fock.unlock failed with code " + code);
    },
  );
  if (failure) throw failure;
  if (!completed) throw new Error("Fock.unlock did not complete synchronously");
  return String(result ?? "");
})()
`;

const EXCLUDED_COOKIES = new Set([
  "HMACCOUNT",
  "newstatisticUUID",
  "fu",
  "traffic_utm_referer",
  "w_tsfp",
  "x-waf-captcha-referer",
  "seo-jump-referrer",
]);

function search(event) {
  if (event.state == null) {
    const pageNum = Number(event.cursor?.pageNum ?? 1);
    const safePageNum = Number.isInteger(pageNum) && pageNum > 0 ? pageNum : 1;
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/soushu/${encodeURIComponent(event.input.keyword)}.html`,
        method: "GET",
        params: { pageNum: String(safePageNum) },
        headers: requestHeaders(),
      },
      next_state: { stage: "page", requestedPageNum: safePageNum },
    };
  }
  const failure = responseFailure(event.response, "搜索頁不可用");
  if (failure) return failure;
  const page = parseSearchPage(bodyText(event.response));
  if (!page) return FeedError.sourceUnavailable("無法解析起點搜索頁");
  if (
    page.pageNum !== event.state.requestedPageNum &&
    event.state.requestedPageNum > 1
  ) {
    return FeedError.sourceUnavailable(
      `起點搜索分頁異常：請求第 ${event.state.requestedPageNum} 頁，返回第 ${page.pageNum} 頁`,
    );
  }
  return {
    type: "complete",
    result: page.items,
    next_cursor: page.hasNext ? { pageNum: page.pageNum + 1 } : null,
  };
}

function bookInfo(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/book/${event.input.bookId}/`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { stage: "page" },
    };
  }
  const failure = responseFailure(event.response);
  if (failure) return failure;
  const value = parseBookInfo(event.response, event.input.bookId);
  if (!value) return FeedError.contentNotFound("書籍不存在或已下架");
  return { type: "complete", result: value };
}

function chapters(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/book/${event.input.bookId}/catalog/`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { stage: "page" },
    };
  }
  const failure = responseFailure(event.response, "目錄頁不可用");
  if (failure) return failure;
  const items = parseChapterItems(event.response);
  if (!items) return FeedError.sourceUnavailable("起點目錄頁缺少章節數據");
  return { type: "complete", result: items, next_cursor: null };
}

function paragraphs(event) {
  if (event.state == null) {
    return {
      type: "request",
      request: {
        url:
          `${meta.base_url}/chapter/${event.input.bookId}/` +
          `${event.input.chapterId}/`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { stage: "chapter_page" },
    };
  }

  if (event.state.stage === "chapter_page") {
    const failure = responseFailure(event.response);
    if (failure) return failure;
    const context = extractPageContext(bodyText(event.response));
    const chapter = nav(context, "pageProps", "pageData", "chapterInfo");
    const user = nav(context, "pageProps", "pageData", "user");
    const fockUrl = extractFockUrl(bodyText(event.response));
    if (!chapter) return FeedError.contentNotFound("章節不存在或已下架");

    if (chapter.vipStatus === 1) {
      if (user?.isLogin !== true) {
        return FeedError.authRequired("VIP 章節需要登錄起點帳號");
      }
      if (chapter.isBuy === 0) {
        return FeedError.contentNotFound(
          "此 VIP 章節尚未訂閱，請先在起點購買本章",
        );
      }
    }

    if (chapter.content) {
      return completeParagraphs(chapter.chapterName, chapter.content);
    }

    return {
      type: "request",
      request: {
        url: `${meta.base_url}/webcommon/chapter/getMChapterInfo`,
        method: "GET",
        params: {
          bookId: String(event.input.bookId),
          chapterId: String(event.input.chapterId),
        },
        headers: {
          ...requestHeaders(),
          Accept: "application/json, text/plain, */*",
          Referer: event.response.url,
          Cookie: responseCookies(event.response.headers),
        },
      },
      next_state: {
        stage: "chapter_api",
        title: chapter.chapterName,
        userId: user?.id,
        fockUrl,
      },
    };
  }

  if (event.state.stage === "chapter_api") {
    const failure = responseFailure(event.response);
    if (failure) return failure;
    let payload;
    try {
      payload = JSON.parse(bodyText(event.response));
    } catch (_) {
      return FeedError.sourceUnavailable("起點章節 API 返回了無效 JSON");
    }
    const chapter =
      payload?.data?.chapterInfo ?? payload?.data ?? payload?.chapterInfo;
    if (!chapter?.content) return FeedError.contentNotFound("章節內容為空");

    if (!chapter.fkp && chapter.fEnS !== 1) {
      return completeParagraphs(
        chapter.chapterName ?? event.state.title,
        chapter.content,
      );
    }

    if (!event.state.fockUrl) {
      return FeedError.sourceUnavailable("章節頁未提供 Fock 解密程序地址");
    }

    return {
      type: "request",
      request: {
        url: event.state.fockUrl,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: {
        stage: "fock",
        title: chapter.chapterName ?? event.state.title,
        encrypted: chapter.content,
        fkp: chapter.fkp,
        ces: chapter.cES ?? 0,
        userId: event.state.userId,
      },
    };
  }

  if (event.state.stage === "fock") {
    const failure = responseFailure(event.response);
    if (failure) return failure;
    const fuid =
      event.state.userId ??
      event.auth?.fuid ??
      cookieMap(event.auth?.cookie_header).get("ywguid");
    if (!fuid) {
      return FeedError.authRequired("登入資料缺少起點使用者 ID，請重新登入");
    }
    return {
      type: "compute",
      programs: [
        FOCK_ENV_PROGRAM,
        bodyText(event.response),
        FOCK_INITIALIZE_PROGRAM,
        DECODER.decode(Bytes.fromBase64(event.state.fkp)),
        FOCK_UNLOCK_PROGRAM,
      ],
      input: {
        encrypted: event.state.encrypted,
        chapterId: event.input.chapterId,
        fuid,
      },
      next_state: {
        stage: "decrypted",
        title: event.state.title,
        ces: event.state.ces,
      },
    };
  }

  if (event.state.stage === "decrypted") {
    if (event.state.ces === 2) {
      return FeedError.raise(
        "unsupported_content",
        "本章使用起點字體加密，當前版本尚未支持",
      );
    }
    if (typeof event.compute !== "string") {
      return FeedError.sourceUnavailable("VIP 章節解密未返回文字內容");
    }
    return completeParagraphs(event.state.title, event.compute);
  }

  return FeedError.raise("invalid_state", "未知的起點章節解析狀態");
}

// ── 評論（m 站章評/段評，reviewlist4m，登錄限定）─────────────────────────
//
// 章評與段評共用 GET /webcommon/chapterreview/reviewlist4m：paragraphId=-1
// 選章評單元，k 選第 k 個 <p>（與 splitParagraphs 的 1-based 段落 id 對
// 齊）。每頁 12 條，isEnd===1 即末頁，total 爲該單元的評論總數。
//
// 該接口要求 Cookie 與查詢參數攜帶同一 _csrfToken（實測兩者缺一或錯開
// 均 1403，匿名亦然），因此只在登錄後提供評論：未登錄直接要求登錄，
// 登錄後用 login.parse 捕獲的令牌在兩處配對（login.patchRequest 會把
// 帳號 Cookie 疊加進來，腳本設的同名令牌覆蓋舊值，最終仍然一致）。
//
// 章評合並流（commentsMerged，章評按鈕與標題段評入口共用）：作者感言
// 評論（paragraphId=-10）在前、章評（-1）在後。兩單元 reviewId 完全不
// 相交；無感言章節請求 -10 返回 code 0/total 0 空頁，可安全探測。
// cursor 爲 opaque JSON：{note:n} 感言階段、{chapter:m,noteTotal:T} 章評
// 階段（攜帶感言總數，使章評頁 total_count 保持合並值）。單元內不交
// 錯：每個面板頁恰好來自一個單元；感言空頁在當前面板頁內直接鏈章評
// 第 1 頁（不出現空評論頁）。
//
// 回覆不可用：reviewlist4m 每條評論僅內嵌 2 條回覆預覽（replyList）加
// 總數（rootReviewReplyCount），官方 m 站 UI 顯示「剩餘 N 條」並引導
// 去 APP，沒有按評論拉取回覆列表的端點（rootReviewId 參數被忽略），
// 舊版 getchapterendcomments 也只有 2 條熱評且無法翻頁。故 replies 一
// 律爲 null：計數已知也不暴露無法兌現的回覆入口。

function commentsCursorPage(cursor) {
  const page = Number(cursor?.page);
  return Number.isInteger(page) && page > 0 ? page : 1;
}

function toCount(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? Math.floor(number) : null;
}

// createTime 是毫秒字符串；空串會被 Number() 讀成 0，必須按時間語義排除。
function timestampMs(value) {
  const milliseconds = Number(value);
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return null;
  return milliseconds <= 8_640_000_000_000_000 ? milliseconds : null;
}

function commentsAuth(event) {
  if (!event.auth?.cookie_header) {
    return {
      error: FeedError.authRequired("起點章節評論需要登錄起點帳號"),
    };
  }
  const csrfToken =
    event.auth.csrf_token ??
    cookieMap(event.auth.cookie_header).get("_csrfToken");
  if (!csrfToken) {
    return {
      error: FeedError.authRequired("登錄資料缺少起點 CSRF 令牌，請重新登錄"),
    };
  }
  return { csrfToken };
}

function reviewListStep(event, paragraphId, page, state) {
  const auth = commentsAuth(event);
  if (auth.error) return auth.error;
  return {
    type: "request",
    request: {
      url: `${meta.base_url}/webcommon/chapterreview/reviewlist4m`,
      method: "GET",
      params: {
        bookId: String(event.input.bookId),
        chapterId: String(event.input.chapterId),
        paragraphId: String(paragraphId),
        page: String(page),
        _csrfToken: auth.csrfToken,
      },
      headers: {
        ...requestHeaders(),
        Accept: "application/json, text/plain, */*",
        Cookie: `_csrfToken=${auth.csrfToken}`,
      },
    },
    next_state: state,
  };
}

function parseReviewList(event) {
  const failure = responseFailure(event.response, "評論不可用");
  if (failure) return { failure };
  let payload;
  try {
    payload = JSON.parse(bodyText(event.response));
  } catch (_) {
    return {
      failure: FeedError.sourceUnavailable("起點評論 API 返回了無效 JSON"),
    };
  }
  if (payload?.code !== 0) {
    return {
      failure: FeedError.sourceUnavailable(
        `起點評論 API 返回錯誤 ${payload?.code ?? "未知"}：${payload?.msg || "無錯誤消息"}`,
      ),
    };
  }
  const data = payload?.data;
  if (!Array.isArray(data?.list)) {
    return {
      failure: FeedError.sourceUnavailable("起點評論 API 響應缺少列表"),
    };
  }
  const items = [];
  for (const review of data.list) {
    const id = formatId(review?.reviewId);
    if (!id) continue;
    const text = cleanText(review?.content);
    items.push({
      id,
      author: {
        name: cleanText(review?.nickName) || "起點書友",
        avatar_url: absoluteUrl(review?.avatar),
      },
      text: text || (Number(review?.hasImage) === 1 ? "[圖片]" : ""),
      created_at_ms: timestampMs(review?.createTime),
      like_count: toCount(review?.likeCount),
      replies: null,
      source_url: null,
    });
  }
  return {
    items,
    total: toCount(data?.total),
    isEnd: data.isEnd === 1,
  };
}

// 單單元流：真段落 k 的段評，cursor {page:n}。
function commentsList(event, paragraphId) {
  if (event.state == null) {
    const page = commentsCursorPage(event.cursor);
    return reviewListStep(event, paragraphId, page, {
      stage: "list",
      page,
    });
  }

  if (event.state.stage === "list") {
    const parsed = parseReviewList(event);
    if (parsed.failure) return parsed.failure;
    return {
      type: "complete",
      result: { items: parsed.items, total_count: parsed.total },
      next_cursor: parsed.isEnd ? null : { page: event.state.page + 1 },
    };
  }

  return FeedError.raise("invalid_state", "未知的起點評論解析狀態");
}

// 章評合並流（感言在前、章評在後），cursor 語義見區塊註釋。
function commentsMerged(event) {
  if (event.state == null) {
    const cursor = event.cursor;
    const chapterPage = Number(cursor?.chapter);
    if (Number.isInteger(chapterPage) && chapterPage > 0) {
      return reviewListStep(event, -1, chapterPage, {
        stage: "list",
        unit: "chapter",
        page: chapterPage,
        noteTotal: toCount(cursor?.noteTotal) ?? 0,
      });
    }
    const notePage = commentsCursorPage(
      cursor?.note == null ? null : { page: cursor.note },
    );
    return reviewListStep(event, -10, notePage, {
      stage: "list",
      unit: "note",
      page: notePage,
      noteTotal: 0,
    });
  }

  if (event.state.stage === "list") {
    const parsed = parseReviewList(event);
    if (parsed.failure) return parsed.failure;

    if (event.state.unit === "note") {
      if (parsed.items.length > 0) {
        return {
          type: "complete",
          result: { items: parsed.items, total_count: parsed.total },
          next_cursor: parsed.isEnd
            ? { chapter: 1, noteTotal: parsed.total ?? event.state.noteTotal }
            : { note: event.state.page + 1 },
        };
      }
      // 感言空頁（多數章節無作者感言）：在當前面板頁內直接鏈章評第 1 頁。
      return reviewListStep(event, -1, 1, {
        stage: "list",
        unit: "chapter",
        page: 1,
        noteTotal: parsed.total ?? event.state.noteTotal ?? 0,
      });
    }

    return {
      type: "complete",
      result: {
        items: parsed.items,
        total_count: (event.state.noteTotal ?? 0) + (parsed.total ?? 0),
      },
      next_cursor: parsed.isEnd
        ? null
        : {
            chapter: event.state.page + 1,
            noteTotal: event.state.noteTotal,
          },
    };
  }

  return FeedError.raise("invalid_state", "未知的起點評論解析狀態");
}

function chapterComments(event) {
  return commentsMerged(event);
}

function paragraphComments(event) {
  // 段落 id 即 splitParagraphs 賦的 1-based <p> 序號（宿主以字符串傳遞）。
  const paragraphId = Number(event.input.paragraphId);
  if (!Number.isInteger(paragraphId) || paragraphId < 1) {
    return FeedError.contentNotFound("無效的起點段落 ID");
  }
  return commentsList(event, paragraphId);
}

const comments = { chapter: chapterComments, paragraph: paragraphComments };

const login = {
  entry() {
    return {
      url:
        "https://passport.qidian.com/?returnurl=" +
        encodeURIComponent("https://m.qidian.com/"),
      title: "起點中文網登錄",
      user_agent: USER_AGENT,
    };
  },

  parse(page) {
    const pairs = [];
    let hasLoginCookie = false;
    let fuid = null;
    let csrfToken = null;

    for (const cookie of page.cookies ?? []) {
      const name = String(cookie?.name ?? "");
      const value = String(cookie?.value ?? "");
      const domain = String(cookie?.domain ?? "");
      const domainOk = !domain || domain.includes("qidian.com");
      const valueOk = value && !/[;,\x00-\x1f\x7f]/.test(value);
      const excluded = EXCLUDED_COOKIES.has(name) || name.startsWith("Hm_");
      if (!domainOk || !valueOk || excluded) continue;

      pairs.push(`${name}=${value}`);
      if (name === "ywkey" || name === "ywguid") hasLoginCookie = true;
      if (name === "ywguid") fuid = value;
      if (name === "_csrfToken") csrfToken = value;
    }

    if (!hasLoginCookie) {
      return FeedError.authRequired("登錄尚未完成：未檢測到起點登錄 Cookie");
    }
    return {
      cookie_header: pairs.join("; "),
      captured_url: page.current_url,
      fuid,
      csrf_token: csrfToken,
    };
  },

  patchRequest(operation, request, auth) {
    request.headers ??= {};
    const dynamicCookies =
      request.headers.Cookie ?? request.headers.cookie ?? "";
    request.headers.Cookie = mergeCookieHeaders(
      auth.cookie_header,
      dynamicCookies,
    );
    delete request.headers.cookie;

    // Use the same source-selected UA as the login WebView.
    request.headers["User-Agent"] = USER_AGENT;

    const csrfToken =
      auth.csrf_token ?? cookieMap(auth.cookie_header).get("_csrfToken");
    if (
      operation.operation === "paragraphs" &&
      request.url.includes("/webcommon/chapter/getMChapterInfo") &&
      csrfToken
    ) {
      request.params ??= {};
      request.params._csrfToken = csrfToken;
    }
    return request;
  },

  status(event) {
    if (event.state == null) {
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/soushu/langhuanprobe.html`,
          method: "GET",
          headers: requestHeaders(),
        },
        next_state: { stage: "probe" },
      };
    }
    const context = extractPageContext(bodyText(event.response));
    const user = nav(context, "pageProps", "pageData", "user");
    return { type: "complete", result: user?.isLogin === true };
  },
};

export default {
  search,
  bookInfo,
  chapters,
  paragraphs,
  comments,
  login,
};
