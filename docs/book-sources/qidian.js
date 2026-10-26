// ==Feed==
// @id           qidian
// @name         起點中文網
// @version      3.1.0
// @author       Langhuan
// @description  起點中文網書源（m 站），支持登入及已購 VIP 章節
// @base_url     https://m.qidian.com
// @access_domain m.qidian.com
// @access_domain *.image.myqcloud.com
// @schema_version 3
// ==/Feed==

(() => {
"use strict";

const PAGE_CONTEXT_MARKER = 'id="vite-plugin-ssr_pageContext"';

function requestHeaders() {
  return {
    "User-Agent":
      "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
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
  if (isWafChallenge(response.body)) {
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

function parseSearchItems(body) {
  const context = extractPageContext(body);
  if (!context) return null;
  const records = nav(
    context,
    "pageProps",
    "pageData",
    "bookInfo",
    "records",
  );
  if (!Array.isArray(records)) return [];
  return records
    .map((record) => ({
      id: formatId(record?.bid),
      title: cleanText(record?.bName),
      author: cleanText(record?.bAuth),
      cover_url: absoluteUrl(record?.imgUrl),
      description: cleanText(record?.desc),
    }))
    .filter((book) => book.id && book.title);
}

function parseBookInfo(response, fallbackId) {
  const context = extractPageContext(response.body);
  const info = nav(context, "pageProps", "pageData", "bookInfo");
  if (!info?.bookName) return null;

  const coverMatch = response.body.match(
    /(?:data-src|src)="(\/\/bookcover\.yuewen\.com\/[^"]+)"/,
  );
  const idMatch = response.url.match(/\/book\/(\d+)/);
  return {
    id: idMatch?.[1] ?? formatId(info.bookId) ?? fallbackId,
    title: cleanText(info.bookName),
    author: cleanText(info.authorName),
    cover_url: absoluteUrl(coverMatch?.[1]),
    description: cleanText(info.desc),
  };
}

function parseChapterItems(response) {
  const context = extractPageContext(response.body);
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

function splitParagraphs(content) {
  const normalized = String(content ?? "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n")
    .replace(/<p(?:\s[^>]*)?>/gi, "\n");
  const items = [];
  for (const line of normalized.split("\n")) {
    if (!line.trim()) continue;
    if (/<img\b/i.test(line)) {
      const match = line.match(/<img[^>]*\bsrc=(?:"([^"]+)"|'([^']+)'|([^\s>]+))/i);
      const url = absoluteUrl(match?.[1] ?? match?.[2] ?? match?.[3]);
      if (url) items.push({ type: "image", url });
      continue;
    }
    const text = cleanText(line);
    if (text) items.push({ type: "text", content: text });
  }
  return items;
}

function completeParagraphs(title, content) {
  const items = [];
  const cleanTitle = cleanText(title);
  if (cleanTitle) items.push({ type: "title", text: cleanTitle });
  items.push(...splitParagraphs(content));
  return { type: "complete", items, next_cursor: null };
}

function responseCookies(headers) {
  const cookies = [];
  for (const pair of Array.isArray(headers) ? headers : []) {
    if (String(pair?.[0] ?? "").toLowerCase() !== "set-cookie") continue;
    const first = String(pair?.[1] ?? "").split(";", 1)[0].trim();
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
(() => {
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
    return {
      type: "request",
      request: {
        url: `${meta.base_url}/soushu/${encodeURIComponent(event.input.keyword)}.html`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: { stage: "page" },
    };
  }
  const failure = responseFailure(event.response, "搜索頁不可用");
  if (failure) return failure;
  const items = parseSearchItems(event.response.body);
  if (!items) return FeedError.sourceUnavailable("無法解析起點搜索頁");
  return { type: "complete", items, next_cursor: null };
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
  return { type: "complete", value };
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
  return { type: "complete", items, next_cursor: null };
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
    const context = extractPageContext(event.response.body);
    const chapter = nav(context, "pageProps", "pageData", "chapterInfo");
    const user = nav(context, "pageProps", "pageData", "user");
    const fockUrl = extractFockUrl(event.response.body);
    if (!chapter) return FeedError.contentNotFound("章節不存在或已下架");

    if (chapter.vipStatus === 1) {
      if (user?.isLogin !== true) {
        return FeedError.authRequired("VIP 章節需要登錄起點帳號");
      }
      if (chapter.isBuy === 0) {
        return FeedError.contentNotFound("此 VIP 章節尚未訂閱，請先在起點購買本章");
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
      payload = JSON.parse(event.response.body);
    } catch (_) {
      return FeedError.sourceUnavailable("起點章節 API 返回了無效 JSON");
    }
    const chapter = payload?.data?.chapterInfo ?? payload?.data ?? payload?.chapterInfo;
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
        event.response.body,
        FOCK_INITIALIZE_PROGRAM,
        atob(event.state.fkp),
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

const login = {
  entry() {
    return {
      url:
        "https://passport.qidian.com/?returnurl=" +
        encodeURIComponent("https://m.qidian.com/"),
      title: "起點中文網登錄",
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
    const dynamicCookies = request.headers.Cookie ?? request.headers.cookie ?? "";
    request.headers.Cookie = mergeCookieHeaders(auth.cookie_header, dynamicCookies);
    delete request.headers.cookie;

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
    const context = extractPageContext(event.response?.body ?? "");
    const user = nav(context, "pageProps", "pageData", "user");
    return { type: "complete", value: user?.isLogin === true };
  },
};

return {
  search,
  bookInfo,
  chapters,
  paragraphs,
  login,
};
})()
