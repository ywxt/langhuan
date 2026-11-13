// ==Feed==
// @id           org.eu.ywxt.langhuan.jjwxc
// @name         晉江文學城
// @version      1.2.0
// @author       Langhuan
// @description  適配晉江文學城（www.jjwxc.net）的書源：搜尋、詳情、目錄、正文（含作話與 VIP 章節，支持反爬字體還原），章評、段評及回覆免登入讀取；VIP 章節需登入站方帳號
// @base_url     https://www.jjwxc.net
// @access_domain www.jjwxc.net
// @access_domain my.jjwxc.net
// @access_domain i9-static.jjwxc.net
// @access_domain static.jjwxc.net
// @schema_version 6
// ==/Feed==

import { TextDecoder, TextEncoder, Bytes } from "langhuan:encoding";
import { HTML } from "langhuan:html";
import { Crypto } from "langhuan:crypto";

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

// ── VIP 章節解密 ─────────────────────────────────────────────────────────────
// www/onebook.php 對 VIP 章 302 到 my.jjwxc.net/onebook_vip.php（未登入再 302
// 到 login.php，未購買 302 到 backend/buynovel.php——三種形態都在 my.jjwxc.net
// 上，跟隨重定向後按頁面標記分流）。已購頁面的正文不在 HTML 裏，而是
// #contentvars/#contentlets 隱藏域的一組欄位，由官方 jjcontent.js 在瀏覽器裏
// 解密：
//
// 1. cryptInfo 解出 {key, time}；
// 2. content 用 rotate(md5(key + time + readerid), charSum(accessKey) % 32) 的
//    前 16 / 後 16 字符作 AES-128-CBC 的 key / iv 解密；
// 3. 明文可能是 encodeURIComponent 編碼的 HTML 片段，也可能是原樣 UTF-8。
//
// cryptInfo 的解法按站點腳本版本有三條鏈，全部實現並以明文形狀校驗挑選（错
// 誤金鑰幾乎必在形狀上露餡；三鏈都試是爲了兼容 m 站、舊頁面與版本切換期）：
// a) v20250926（my 站現行，已用真實已購章節離線驗證）：AES-128-CBC，變體按
//    (novelid+chapterid) 奇偶選擇——偶數用 rotate(md5("novel.chapter.reader.
//    access"), sum%32)、奇數用 rotate(md5("access-novel-chapter-reader"),
//    sum%33)——key/iv 取摘要的後 16 / 前 16 字符；明文是 base64(JSON)。
// b) m 站現行：DES-CBC，key/iv 取 rotate(md5("novel.chapter.reader.access"),
//    sum%32) 的第 17–24 / 1–8 字符；明文直接是 JSON。langhuan:crypto 沒有
//    DES，下面附帶純 JS 實現（cryptInfo 只有幾個塊，性能無虞）。
// c) 舊版：AES-128-CBC，key/iv 在 md5 摘要自我串聯後的 32 個 16 字符窗口裏
//    窮舉；明文是 base64(JSON)。
//
// 參考：AnkioTomas/moon（KOReader 插件）、404-novel-project/novel-downloader，
// 以及 2026-11 對真實已購章節（novelid=10620154, chapterid=17）的逐鏈驗證。

const VipEncoder = new TextEncoder();

// 32 字符小寫十六進制 MD5——金鑰材料全部取自這個十六進制串的字符。
function md5Hex(text) {
  return Bytes.toHex(Crypto.md5(VipEncoder.encode(String(text))));
}

// 左旋轉十六進制摘要（offset 爲 0 時原樣返回）。
function rotateHex(hex, offset) {
  const shift = offset % hex.length;
  return shift === 0 ? hex : hex.slice(shift) + hex.slice(0, shift);
}

// accessKey 的碼點和（ASCII 串，與字節和一致）。
function charSum(text) {
  let sum = 0;
  for (let i = 0; i < text.length; i++) sum += text.charCodeAt(i);
  return sum;
}

// AES-128-CBC 解密（PKCS7）。填充或對齊不合法返回 null。
function aesDecrypt(data, key16, iv16) {
  if (data.length === 0 || data.length % 16 !== 0) return null;
  try {
    return Crypto.aes({
      op: "decrypt",
      mode: "cbc",
      key: VipEncoder.encode(key16),
      iv: VipEncoder.encode(iv16),
      data,
      padding: "pkcs7",
    });
  } catch (_) {
    return null;
  }
}

// AES-128-CBC 解密（不去填充）——窮舉鏈的探針用，key/iv 允許原始字節。
function aesDecryptRaw(data, keyBytes, ivBytes) {
  if (data.length === 0 || data.length % 16 !== 0) return null;
  try {
    return Crypto.aes({
      op: "decrypt",
      mode: "cbc",
      key: keyBytes,
      iv: ivBytes,
      data,
      padding: "none",
    });
  } catch (_) {
    return null;
  }
}

// ── DES-CBC（純 JS）──────────────────────────────────────────────────────
// 按 FIPS 46-3 實現的解密（金鑰 8 字節、塊 8 字節、PKCS5 去填充）。以位數組
// 逐位置換實現，正確性優先；測試向量見 tests/jjwxc.rs（openssl des-cbc）。

const DES_IP = [
  58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38,
  30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1,
  59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39,
  31, 23, 15, 7,
];
const DES_FP = [
  40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14,
  54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28,
  35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9,
  49, 17, 57, 25,
];
const DES_E = [
  32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15,
  16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28,
  29, 28, 29, 30, 31, 32, 1,
];
const DES_P = [
  16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14,
  32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
];
const DES_PC1 = [
  57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
  27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38,
  30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
];
const DES_PC2 = [
  14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27,
  20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56,
  34, 53, 46, 42, 50, 36, 29, 32,
];
const DES_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
const DES_SBOX = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2,
    13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7,
    3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2,
    8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6,
    9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6,
    10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5,
    10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15,
    0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14,
    5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7,
    13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5,
    6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12,
    9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1,
    13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9,
    1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8,
    0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3,
    7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13,
    15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
  ],
];

function bytesToBits(bytes) {
  const bits = new Array(bytes.length * 8);
  for (let i = 0; i < bytes.length; i++) {
    for (let j = 0; j < 8; j++) bits[i * 8 + j] = (bytes[i] >> (7 - j)) & 1;
  }
  return bits;
}

function bitsToBytes(bits) {
  const out = new Uint8Array(bits.length / 8);
  for (let i = 0; i < out.length; i++) {
    let value = 0;
    for (let j = 0; j < 8; j++) value = (value << 1) | bits[i * 8 + j];
    out[i] = value;
  }
  return out;
}

function permuteBits(bits, table) {
  const out = new Array(table.length);
  for (let i = 0; i < table.length; i++) out[i] = bits[table[i] - 1];
  return out;
}

function desSubkeys(keyBytes) {
  const bits = permuteBits(bytesToBits(keyBytes), DES_PC1);
  let c = bits.slice(0, 28);
  let d = bits.slice(28);
  const keys = [];
  for (const shift of DES_SHIFTS) {
    c = c.slice(shift).concat(c.slice(0, shift));
    d = d.slice(shift).concat(d.slice(0, shift));
    keys.push(permuteBits(c.concat(d), DES_PC2));
  }
  return keys;
}

// 單塊解密（子密鑰倒序即解密）。
function desDecryptBlock(bits, subkeys) {
  const x = permuteBits(bits, DES_IP);
  let left = x.slice(0, 32);
  let right = x.slice(32);
  for (let round = 15; round >= 0; round--) {
    const expanded = permuteBits(right, DES_E);
    const mixed = new Array(48);
    for (let i = 0; i < 48; i++) mixed[i] = subkeys[round][i] ^ expanded[i];
    const f = new Array(32);
    for (let box = 0; box < 8; box++) {
      const off = box * 6;
      const row = (mixed[off] << 1) | mixed[off + 5];
      const col =
        (mixed[off + 1] << 3) |
        (mixed[off + 2] << 2) |
        (mixed[off + 3] << 1) |
        mixed[off + 4];
      const value = DES_SBOX[box][row * 16 + col];
      for (let j = 0; j < 4; j++) f[box * 4 + j] = (value >> (3 - j)) & 1;
    }
    const fp = permuteBits(f, DES_P);
    const next = new Array(32);
    for (let i = 0; i < 32; i++) next[i] = left[i] ^ fp[i];
    left = right;
    right = next;
  }
  return permuteBits(right.concat(left), DES_FP);
}

// DES-CBC 解密（PKCS5 去填充）。長度或填充不合法返回 null。
function desCbcDecrypt(data, key8, iv8) {
  if (
    data.length === 0 ||
    data.length % 8 !== 0 ||
    key8.length !== 8 ||
    iv8.length !== 8
  ) {
    return null;
  }
  const subkeys = desSubkeys(key8);
  const out = new Uint8Array(data.length);
  let chain = iv8;
  for (let off = 0; off < data.length; off += 8) {
    const block = data.slice(off, off + 8);
    const plain = bitsToBytes(desDecryptBlock(bytesToBits(block), subkeys));
    for (let i = 0; i < 8; i++) out[off + i] = plain[i] ^ chain[i];
    chain = block;
  }
  const pad = out[out.length - 1];
  if (pad < 1 || pad > 8 || out[out.length - pad] !== pad) return null;
  return out.slice(0, out.length - pad);
}

// ── 明文形狀校驗 ─────────────────────────────────────────────────────────

// encodeURIComponent 的字符集（字節級）：字母數字與 % - _ . ! ~ * ' ( )。
function urlEncodedShapeBytes(bytes) {
  for (const b of bytes) {
    const alnum =
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5a) ||
      (b >= 0x61 && b <= 0x7a);
    if (
      !alnum &&
      b !== 0x25 && b !== 0x2d && b !== 0x5f && b !== 0x2e && b !== 0x21 &&
      b !== 0x7e && b !== 0x2a && b !== 0x27 && b !== 0x28 && b !== 0x29
    ) {
      return false;
    }
  }
  return true;
}

// base64 的字符集（字節級）：字母數字與 + / =。
function base64ShapeBytes(bytes) {
  for (const b of bytes) {
    const alnum =
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5a) ||
      (b >= 0x61 && b <= 0x7a);
    if (!alnum && b !== 0x2b && b !== 0x2f && b !== 0x3d) return false;
  }
  return true;
}

// 解密後的明文形狀：URL 編碼串，或含多字節字符的合法 UTF-8（無控制字符，
// 除 \t\n\r）。inner 爲真時允許首尾截斷在多字節字符中間（窮舉探針只解部分
// 塊）。純 ASCII 非編碼串多半是錯誤金鑰的產物，判爲不通過。
function looksLikeTextBytes(bytes, inner) {
  if (urlEncodedShapeBytes(bytes)) return true;
  let i = 0;
  if (inner) {
    while (i < bytes.length && bytes[i] >= 0x80 && bytes[i] < 0xc0) i++;
  }
  let hasMultibyte = false;
  while (i < bytes.length) {
    const c = bytes[i];
    if (c < 0x80) {
      if ((c < 0x20 && c !== 9 && c !== 10 && c !== 13) || c === 0x7f) {
        return false;
      }
      i += 1;
      continue;
    }
    hasMultibyte = true;
    const len =
      c >= 0xc2 && c < 0xe0
        ? 2
        : c >= 0xe0 && c < 0xf0
          ? 3
          : c >= 0xf0 && c < 0xf5
            ? 4
            : 0;
    if (len === 0) return false;
    if (i + len > bytes.length) return inner === true;
    for (let j = 1; j < len; j++) {
      const b = bytes[i + j];
      if (b < 0x80 || b >= 0xc0) return false;
    }
    i += len;
  }
  return hasMultibyte;
}

// cryptInfo 明文 → {key, time}：JSON 或 base64(JSON)。
function parseVipMeta(bytes) {
  let json = null;
  if (base64ShapeBytes(bytes)) {
    try {
      json = Bytes.fromBase64(UTF8.decode(bytes));
    } catch (_) {
      json = null;
    }
  }
  if (json == null) json = bytes;
  try {
    const meta = JSON.parse(UTF8.decode(json));
    const key = String(meta?.key ?? "");
    const time = String(meta?.time ?? "");
    if (!key || !/^\d+$/.test(time)) return null;
    return { key, time };
  } catch (_) {
    return null;
  }
}

// 舊版窮舉鏈：key/iv 各取自 md5 源串摘要自我串聯後的 32 個 16 字符窗口。
// 先用第二塊密文＋首塊密文作 IV 探針 key，命中後再窮舉 iv，最後整體解密。
function bruteForceAes(data, source, shape) {
  if (data.length < 32 || data.length % 16 !== 0) return null;
  const doubled = md5Hex(source) + md5Hex(source);
  const window = (from) => doubled.slice(from, from + 16);
  const probeLen = Math.min(data.length - 16, 48);
  for (let keyOff = 0; keyOff < 32; keyOff++) {
    const key = VipEncoder.encode(window(keyOff));
    const probe = aesDecryptRaw(
      data.slice(16, 16 + probeLen),
      key,
      data.slice(0, 16),
    );
    if (probe == null || !shape(probe, true)) continue;
    for (let ivOff = 0; ivOff < 32; ivOff++) {
      const ivBytes = VipEncoder.encode(window(ivOff));
      const head = aesDecryptRaw(data.slice(0, 16), key, ivBytes);
      if (head == null || !shape(head, true)) continue;
      const plain = aesDecrypt(data, window(keyOff), window(ivOff));
      if (plain != null && shape(plain, false)) return plain;
    }
  }
  return null;
}

// VIP 正文解密：#contentvars 欄位 → HTML 片段。全鏈失敗返回 null。
function vipDecrypt(vars, readerFallback) {
  const novel = String(vars.novelid ?? "");
  const chapter = String(vars.chapterid ?? "");
  const pageReader = String(vars.readerid ?? "");
  const reader = /^\d+$/.test(pageReader)
    ? pageReader
    : String(readerFallback ?? "");
  const access = String(vars.accessKey ?? "");
  if (!novel || !chapter || !reader || !access) return null;
  let info;
  let content;
  try {
    info = Bytes.fromBase64(String(vars.cryptInfo ?? ""));
    content = Bytes.fromBase64(String(vars.content ?? ""));
  } catch (_) {
    return null;
  }
  if (info.length < 16 || content.length < 32) return null;
  const spin = charSum(access);

  // cryptInfo → {key, time}：三條鏈按命中概率排序。
  const meta = (() => {
    // a) v20250926 AES 變體（奇偶選鏈，兩個變體都試）。
    const parity = (Number(novel) + Number(chapter)) % 2;
    if (Number.isInteger(parity)) {
      for (const v of [parity, 1 - parity]) {
        const digest =
          v === 0
            ? rotateHex(md5Hex(`${novel}.${chapter}.${reader}.${access}`), spin % 32)
            : rotateHex(md5Hex(`${access}-${novel}-${chapter}-${reader}`), spin % 33);
        const plain = aesDecrypt(info, digest.slice(16, 32), digest.slice(0, 16));
        if (plain != null) {
          const meta = parseVipMeta(plain);
          if (meta != null) return meta;
        }
      }
    }
    // b) m 站現行 DES。
    const spun = rotateHex(md5Hex(`${novel}.${chapter}.${reader}.${access}`), spin % 32);
    const plain = desCbcDecrypt(
      info,
      VipEncoder.encode(spun.slice(16, 24)),
      VipEncoder.encode(spun.slice(0, 8)),
    );
    if (plain != null) {
      const meta = parseVipMeta(plain);
      if (meta != null) return meta;
    }
    // c) 舊版窗口窮舉。
    const brute = bruteForceAes(
      info,
      `${novel}.${chapter}.${reader}.${access}`,
      (bytes) => base64ShapeBytes(bytes),
    );
    if (brute != null) {
      const meta = parseVipMeta(brute);
      if (meta != null) return meta;
    }
    return null;
  })();
  if (meta == null) return null;

  // content：固定窗口（兩條現行鏈共用）→ 舊版窗口窮舉。
  const textBytes = (() => {
    const t = rotateHex(md5Hex(`${meta.key}${meta.time}${reader}`), spin % 32);
    const plain = aesDecrypt(content, t.slice(0, 16), t.slice(16, 32));
    if (plain != null && looksLikeTextBytes(plain, false)) return plain;
    const brute = bruteForceAes(
      content,
      `${meta.key}${meta.time}${reader}`,
      (bytes, inner) => looksLikeTextBytes(bytes, inner),
    );
    return brute;
  })();
  if (textBytes == null) return null;

  const text = UTF8.decode(textBytes);
  if (/^[A-Za-z0-9%\-_.!~*'()]+$/.test(text)) {
    try {
      return decodeURIComponent(text);
    } catch (_) {
      return text;
    }
  }
  return text;
}

// ── 反爬字體還原 ─────────────────────────────────────────────────────────────
// VIP 明文裏的常用字被替換成私有區（PUA，U+E000–U+F8FF）碼點，頁面附帶一份按
// 章隨機命名的 TTF（noveltext 的 jjwxcfont_<串> 類，字體位於
// static.jjwxc.net/tmp/fonts/<名>.ttf，下載免 Referer/Cookie）。同一個字的字
// 形輪廓在站方所有字體裏恆定：解析 TTF，對每個簡單字形的輪廓點序列做雙哈
// 希，查下方內嵌的「輪廓哈希 → 字」表即可還原。表共 200 條（站方高頻字集），
// 摘自 AnkioTomas/moon 的 font_table；算法已在真實已購章節上驗證 200 個字形
// 全部命中、正文 PUA 碼位全部還原。複合字形（contours ≤ 0，控制點在子字形
// 裏）與未命中的字符原樣保留。

const FONT_HASH_TABLE = {
  "00154a6b1c8b56f4":"看", "003603c812ca6cb9":"因", "0039923416a29944":"着", "00a7c7bf32aedbde":"他",
  "00e5e1da165ae20f":"公", "00ef0dd6285d8477":"之", "01088d012b098b75":"你", "0137f41423653d65":"会",
  "015a34d533889fbf":"二", "015fff502c321d00":"笑", "040233342f1b60df":"行", "0457599a21d8ecb0":"年",
  "048352b4338068c4":"四", "05c743e3058300cd":"现", "062a240d16193a5a":"不", "06b0bf881f9f2226":"多",
  "088e49fa39b6f880":"国", "09ff029326e86634":"几", "0abbfee029445859":"话", "0c7c16ac379a368b":"想",
  "0c8c788935eb4c6d":"法", "0cd499d21adc4075":"三", "0ce7553e341df099":"力", "0d59d79c255b26ae":"起",
  "0eb03ab13b8fecf8":"物", "0ecd20cb29d92a68":"对", "0edb5eb83058c70a":"自", "1087c1a13035f6e7":"但",
  "113677b02151cc54":"下", "115449b02bd79de0":"特", "1172c22d18119f8b":"从", "12356bd2071cd673":"何",
  "124e303120efe23f":"也", "133043da262891ee":"天", "13ef79062ac3d1d1":"论", "149e6780017ee49b":"给",
  "15d4b90832525c96":"并", "169fb4d632f94e0a":"书", "173ff1f031dd13db":"果", "184115df390833fc":"去",
  "188e591e180f8e96":"在", "19b1a58d103eb0c7":"同", "1aa2074a056ddbb5":"身", "1afb25c12fe803a9":"向",
  "1c12c0221b14b585":"使", "1dbd22af181d6e54":"打", "1e7064da2c43a480":"将", "1ec9379119027626":"新",
  "20c73d791f151327":"还", "20e5649a2017aa2a":"而", "2168c86e22945710":"它", "2226e8a417b8e642":"美",
  "222c52fb3869ab22":"口", "22336dd905e33be0":"子", "2235475211e9176e":"手", "2364bc1d28592888":"们",
  "25ca49ae0160dfa2":"然", "26cf0f301be32614":"理", "26e04e9a1cb6bddc":"西", "26f65f171d11692e":"只",
  "27e0e43d1fdbe3fc":"人", "27eda58f10ea029e":"听", "29198b84150e2a02":"种", "2a9a63a208db52cf":"过",
  "2b2043860a42f996":"这", "2b61971b073b5842":"代", "2bd90a330732c715":"里", "2c50307e157d6b0e":"没",
  "2cf2f6d221290a6a":"无", "2d6eed0a2cae9869":"头", "2d9945ea2664a9ab":"主", "2e927429335c13b5":"写",
  "2f1b92e306866f21":"到", "2f9553b9314fe40d":"开", "2fa93dcc26d6e2e8":"了", "307aeb5e186d90a6":"把",
  "31126af32d98854f":"等", "3147482a1e7c2787":"知", "3215d98f2c387b93":"最", "326e4ba02d62949e":"家",
  "3345985812325ce3":"经", "33c74c1218f9ddc3":"出", "33c8c79306682dd7":"于", "340bc8003b70efe1":"先",
  "3657a8c62c1383bb":"面", "36865d7e11f46b78":"为", "36e397e41c9062fb":"分", "380350671201b015":"气",
  "3861b2e329696837":"中", "3a97948e1de6c5f4":"女", "3bf7baa0372f6f00":"便", "3c465aa6245f67f4":"情",
  "3f32aca22ee80a90":"体", "3f428c7b267a61b8":"化", "3f4de79c333d43e7":"由", "4043a2e000c27bf1":"以",
  "4215aa5d2dfe3341":"此", "427dcf4e2b4c0dac":"好", "435b44cb3a093136":"明", "45da937f3a4e04f7":"作",
  "46769d630a62cf6a":"感", "47941d4e008bfb51":"儿", "47d3037514209c17":"社", "486f0fb3116323da":"道",
  "48b7ebab3a7ecdcb":"要", "48f21ae23593414c":"可", "491c37fd21375960":"上", "4a69b7772c51271f":"心",
  "4ace7a71004fcb43":"我", "4bafd6742e9d28c5":"老", "4bde746b27d2f440":"却", "4c19e7c931a5393a":"实",
  "4c826b1b0add86da":"来", "4c9cddcc0edaa3bf":"是", "4d2ef4e001dac785":"回", "4dc52058297c6c6e":"才",
  "4dfe3f8121f151f5":"前", "4e150e77022d1731":"关", "4efece4528ac825c":"点", "4f0d414f3a26189c":"本",
  "50b74008151f8779":"全", "512158f705f1102a":"有", "51dac53805488378":"第", "523e43b61eb81625":"再",
  "524908dd0c504da7":"动", "525b224b2a3c5e69":"史", "53b91871313c87e1":"就", "53e80c372daf792e":"教",
  "54036c4225c63550":"外", "54e5d3e3210f2947":"十", "55d667553b8b0db3":"她", "570f11d93b5fd870":"问",
  "587ee7c900891797":"很", "589d00c32229f925":"者", "58f1d0741752f362":"重", "59953abf2074ea93":"定",
  "59fff24c062dd782":"长", "5a3fd71d01325a3b":"部", "5b8b98991621a6df":"时", "5c86bc9512db5989":"高",
  "5cf629802f52c1f5":"个", "5de9b25d05bc443b":"己", "5e1dfe0b227c69fd":"方", "5e6b7a602017121a":"什",
  "5ee6421a0baf6b20":"名", "613c7379144fe701":"被", "619ce4cd35bc2fc2":"民", "6216c2a915612b9f":"间",
  "62954e2c04a4d150":"见", "62b118e130dcf3dc":"太", "636c1f752941d91f":"都", "64062c9918cfa2ca":"生",
  "6431c0db0ad501ed":"用", "64377b5e39f49e3b":"文", "64cced2918ddb31d":"性", "658ae6f72b4148e4":"成",
  "65bb8b7929460bf7":"后", "65c3321c336aaaef":"少", "6697e0633447ae33":"能", "6702b2d62ffb33a8":"别",
  "6745daf7157df3dc":"日", "6818cbd437787b67":"与", "6929e5aa35ba6c65":"神", "6b647f3025ad6d8c":"那",
  "6bb372693661ed92":"声", "6d1b497b0fd9f084":"相", "6d62ebca25d4273c":"其", "6d8e39fc07cba1dc":"意",
  "6ee59f3022d4e801":"走", "7051be711e796a0a":"更", "716b00b914b4238d":"两", "7212492d07c7dd75":"正",
  "7320c02800fa0624":"些", "7343928136b90bde":"的", "7381bd5e1c5c65ff":"已", "73cb101a00871bb6":"说",
  "73ddd1652fe5784b":"和", "74078d122ceebd69":"门", "742de861183233e2":"如", "750e9cb21d272023":"真",
  "75903fbb1fe83156":"眼", "765295db254176ca":"所", "785ade33150e9065":"白", "78aeb52e1d87f596":"样",
  "7909ea5514a95263":"义", "7a0fd8a116a67df3":"学", "7a175d2128e8e5a2":"世", "7a9596e00300969e":"进",
  "7ae8534201b24360":"地", "7b64232013109594":"又", "7c1c5ee00c1772a7":"发", "7d5d5dc904dee8cf":"得",
  "7db4216c2727791d":"一", "7dfe8d472d0c0519":"么", "7e5289903b3da004":"小", "7eabd922010f6142":"事",
  "7f1f75bc15a2138e":"大", "7f28bafd08237204":"思", "7fe2038424c0128e":"当", "7fe8dc93015ef26a":"死",
};

// 雙哈希的模數。
const FONT_H1_MOD = 2147483647;
const FONT_H2_MOD = 1000000007;

function fontUint16(ttf, at) {
  return (ttf[at] << 8) | ttf[at + 1];
}

function fontInt16(ttf, at) {
  const value = fontUint16(ttf, at);
  return value >= 0x8000 ? value - 0x10000 : value;
}

function fontUint32(ttf, at) {
  return (fontUint16(ttf, at) << 16) | fontUint16(ttf, at + 2);
}

// sfnt 表目錄 → { 表名 → 偏移 }。
function fontTables(ttf) {
  const dir = {};
  const count = fontUint16(ttf, 4);
  for (let i = 0; i < count; i++) {
    const rec = 12 + i * 16;
    dir[String.fromCharCode(ttf[rec], ttf[rec + 1], ttf[rec + 2], ttf[rec + 3])] =
      fontUint32(ttf, rec + 8);
  }
  return dir;
}

// cmap 的 format 4 子表（BMP）→ Map(碼點 → 字形號)。
function fontCmap4(ttf, base) {
  let sub = null;
  const encodings = fontUint16(ttf, base + 2);
  for (let i = 0; i < encodings; i++) {
    const rec = base + 4 + i * 8;
    const pos = base + fontUint32(ttf, rec + 4);
    if (fontUint16(ttf, pos) === 4) sub = pos;
  }
  if (sub == null) return null;
  const segs = Math.floor(fontUint16(ttf, sub + 6) / 2);
  const ends = sub + 14;
  const starts = sub + 16 + segs * 2;
  const deltas = sub + 16 + segs * 4;
  const rangeOffsets = sub + 16 + segs * 6;
  const map = new Map();
  for (let i = 0; i < segs; i++) {
    const first = fontUint16(ttf, starts + i * 2);
    const last = Math.min(fontUint16(ttf, ends + i * 2), 0xfffe);
    const delta = fontInt16(ttf, deltas + i * 2);
    const off = fontUint16(ttf, rangeOffsets + i * 2);
    for (let code = first; code <= last; code++) {
      let gid;
      if (off === 0) {
        gid = (code + delta) & 0xffff;
      } else {
        const at = rangeOffsets + i * 2 + off + (code - first) * 2;
        gid = fontUint16(ttf, at);
        if (gid !== 0) gid = (gid + delta) & 0xffff;
      }
      if (gid !== 0) map.set(code, gid);
    }
  }
  return map;
}

// 簡單字形的輪廓哈希（與生成表的工具同一算法）：對輪廓數、各段端點索引與
// 各點的標誌位、縮放到 1000upm 的座標做兩條多項式哈希。複合或空字形 → null。
function fontGlyphHash(ttf, glyf, start, stop, upm) {
  if (stop <= start) return null;
  let pos = glyf + start;
  const contours = fontInt16(ttf, pos);
  if (contours <= 0) return null;
  let h1 = 7;
  let h2 = 7;
  const feed = (value) => {
    const v = value + 100000;
    h1 = (h1 * 131 + v) % FONT_H1_MOD;
    h2 = (h2 * 137 + v) % FONT_H2_MOD;
  };
  feed(contours);
  pos += 10;
  let count = 0;
  for (let i = 0; i < contours; i++) {
    count = fontUint16(ttf, pos + i * 2) + 1;
    feed(count - 1);
  }
  pos += contours * 2;
  pos += 2 + fontUint16(ttf, pos);
  const flags = [];
  while (flags.length < count) {
    const flag = ttf[pos];
    pos += 1;
    flags.push(flag);
    if (flag % 16 >= 8) {
      const repeat = ttf[pos];
      pos += 1;
      for (let i = 0; i < repeat; i++) flags.push(flag);
    }
  }
  // 各點座標按標誌位解壓：短向量 +1/-1 字節，長向量 int16，同值沿用當前值。
  const axis = (shortBit, sameBit) => {
    const out = [];
    let current = 0;
    for (const flag of flags) {
      if (((flag >> shortBit) & 1) === 1) {
        const delta = ttf[pos];
        pos += 1;
        current += ((flag >> sameBit) & 1) === 1 ? delta : -delta;
      } else if (((flag >> sameBit) & 1) === 0) {
        current += fontInt16(ttf, pos);
        pos += 2;
      }
      out.push(current);
    }
    return out;
  };
  const xs = axis(1, 4);
  const ys = axis(2, 5);
  for (let i = 0; i < count; i++) {
    feed(flags[i] % 2);
    feed(Math.floor((xs[i] * 1000) / upm + 0.5));
    feed(Math.floor((ys[i] * 1000) / upm + 0.5));
  }
  return h1.toString(16).padStart(8, "0") + h2.toString(16).padStart(8, "0");
}

// TTF → Map(碼點 → 真字)。解析失敗返回 null（字符將保持 PUA 原樣）。
function fontMapping(ttf) {
  try {
    if (
      ttf?.length < 12 ||
      ttf[0] !== 0 ||
      ttf[1] !== 1 ||
      ttf[2] !== 0 ||
      ttf[3] !== 0
    ) {
      return null;
    }
    const dir = fontTables(ttf);
    const head = dir["head"];
    const cmapBase = dir["cmap"];
    const glyf = dir["glyf"];
    const loca = dir["loca"];
    if (head == null || cmapBase == null || glyf == null || loca == null) {
      return null;
    }
    const upm = fontUint16(ttf, head + 18);
    const longLoca = fontInt16(ttf, head + 50) === 1;
    if (upm <= 0) return null;
    const codes = fontCmap4(ttf, cmapBase);
    if (codes == null) return null;
    const map = new Map();
    for (const [code, gid] of codes) {
      const at = loca + gid * (longLoca ? 4 : 2);
      const from = longLoca
        ? fontUint32(ttf, at)
        : fontUint16(ttf, at) * 2;
      const to = longLoca
        ? fontUint32(ttf, at + 4)
        : fontUint16(ttf, at + 2) * 2;
      const key = fontGlyphHash(ttf, glyf, from, to, upm);
      const char = key == null ? undefined : FONT_HASH_TABLE[key];
      if (char) map.set(code, char);
    }
    return map;
  } catch (_) {
    return null;
  }
}

// PUA 字符按映射還原（未命中原樣保留），並剔去除去字體佔位用的零寬字符。
function decodeFontText(text, mapping) {
  return String(text ?? "")
    .replace(/[\uE000-\uF8FF]/g, (ch) => mapping.get(ch.charCodeAt(0)) ?? ch)
    .replace(/[\u200B-\u200D\uFEFF]/g, "");
}

// ── VIP 段縫拼接 ──────────────────────────────────────────────────────────────
// VIP 明文被站方切成 <span class="c_xxx">…</span> 片段，被抽走的字掛在同頁
// <style> 規則的 .c_xxx:before/:after content 上，瀏覽器靠 CSS 拼回全文。收
// 成 Map(類名 → {before, after})，再按 span 出現順序配對替換（片段裏 span 不
// 嵌套）。content 字符串要處理 \' \" \\ 與 \XXXXXX 十六進制轉義。

function cssContentValue(rule) {
  const text = String(rule ?? "");
  const match = text.match(/content\s*:\s*/);
  if (!match) return null;
  const stop = match.index + match[0].length;
  const quote = text[stop];
  if (quote !== "'" && quote !== '"') return null;
  let out = "";
  let i = stop + 1;
  while (i < text.length) {
    const c = text[i];
    if (c === quote) return out;
    if (c === "\\") {
      const hex = text.slice(i + 1).match(/^[0-9a-fA-F]{1,6}\s?/);
      if (hex) {
        const code = Number.parseInt(hex[0].trim(), 16);
        out += code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : "";
        i += 1 + hex[0].length;
      } else {
        out += text[i + 1] ?? "";
        i += 2;
      }
    } else {
      out += c;
      i += 1;
    }
  }
  return null;
}

function seamTexts(html) {
  const seams = new Map();
  const text = String(html ?? "");
  for (const style of text.match(/<style\b[^>]*>[\s\S]*?<\/style>/gi) ?? []) {
    for (const rule of style.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const value = cssContentValue(rule[2]);
      if (value == null) continue;
      for (const sel of rule[1].matchAll(/\.(c_\w+)\s*::?\s*(\w+)/g)) {
        if (sel[2] === "before" || sel[2] === "after") {
          const seam = seams.get(sel[1]) ?? {};
          seam[sel[2]] = value;
          seams.set(sel[1], seam);
        }
      }
    }
  }
  return seams;
}

function spliceSeams(html, seams) {
  const opens = [];
  let closed = 0;
  const spliced = String(html ?? "").replace(
    /<[Ss][Pp][Aa][Nn][^>]*>/g,
    (tag) => {
      const cls = tag.match(/class\s*=\s*["'](c_\w+)["']/)?.[1] ?? null;
      opens.push(cls);
      return seams.get(cls)?.before ?? "";
    },
  );
  return spliced.replace(/<\/[Ss][Pp][Aa][Nn]\s*>/g, () => {
    closed += 1;
    return seams.get(opens[closed - 1])?.after ?? "";
  });
}

// ── 正文 ─────────────────────────────────────────────────────────────────────
// onebook.php?novelid=N&chapterid=M。免費章正文在 #paragraph_comment_content，
// 只有文本與 <br>（插圖章節可能含 <img>）；章節標題在 div.noveltext h2。
// VIP 章由 www 入口 302 到 my.jjwxc.net/onebook_vip.php：已購買的頁面帶
// #contentvars/#contentlets 密文欄位（見上節），未登入落在 login.php、未購
// 買落在 backend/buynovel.php（#buy_content）——重定向由宿主跟隨，按最終
// 頁的標記分流。VIP 頁同樣渲染 #paragraph_comment_content，但只是「vip內
// 容加載中」佔位容器，必須先探測 #contentvars。
//
// 段落編號對齊站點規則（onebook.paragraph.comment.js 的
// buildParagraphAnchors，其 isVipContentPending 對 VIP 頁等解密注入後同樣
// 建錨）：按 <br> 拆段、僅非空段遞增、1 起始。站點以該編號作段評地址
// （data-paragraphid），空段（含全角空格）不佔號。

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

// #contentvars / #contentlets 的隱藏域欄位。容器攜帶 cryptInfo 與 content
// 兩個密文欄位才視爲 VIP 頁（免費章兩個容器都不存在）。
function vipVars(document) {
  for (const id of ["contentvars", "contentlets"]) {
    const block = document.find(`#${id}`).first();
    if (block == null) continue;
    const vars = {};
    for (const input of block.find("input")) {
      const name = input.attr("name");
      if (name) vars[name] = input.attr("value") ?? "";
    }
    if (vars.cryptInfo && vars.content) return vars;
  }
  return null;
}

// 讀者 ID 的後備來源：VIP 頁欄位缺 readerid 時從登入憑證推。readerid 直
// 取；現代登入沒有 readerid Cookie，只有 token（base64 的
// 「readerid|hash|…」，值可能被 URL 編碼過），取 | 前綴。
function readerIdFromAuth(auth) {
  const cookies = cookieMap(auth?.cookie_header);
  const readerid = cookies.get("readerid");
  if (readerid != null && /^\d+$/.test(readerid)) return readerid;
  let token = cookies.get("token");
  if (token == null) return null;
  try {
    token = decodeURIComponent(token);
  } catch (_) {
    // 非 URL 編碼形式，按原值重試。
  }
  try {
    const prefix = UTF8.decode(Bytes.fromBase64(token)).split("|")[0];
    if (/^\d+$/.test(prefix)) return prefix;
  } catch (_) {
    // 非法 base64 忽略。
  }
  return null;
}

// VIP 明文的通用清洗：PUA 字符以無分號的十六進制實體出現（&#xe69b 緊跟
// &zwnj;），先解實體，再去 zwnj、站方水印與零寬字符。十進制與其他具名實
// 體留給 richText 的通用解碼。
function vipCleanText(html) {
  return String(html ?? "")
    .replace(/&#x([0-9a-fA-F]+);?/g, (_, hex) => {
      const code = Number(`0x${hex}`);
      return Number.isInteger(code) && code > 0 && code <= 0x10ffff
        ? String.fromCodePoint(code)
        : "";
    })
    .replaceAll("&zwnj;", "")
    .replaceAll("@无限好文，尽在晋江文学城", "")
    .replace(/[\u200B-\u200D\uFEFF]/g, "");
}

// VIP 章節組裝：解密 → 段縫拼接 → 清洗 → 與免費路徑相同的拆段編號與作
// 話，之後視 PUA 情況進字體還原階段，否則直接請求段評數。
function vipAssemble(event, state, document, body, vars) {
  const html = vipDecrypt(vars, readerIdFromAuth(event.auth));
  if (html == null) {
    return FeedError.sourceUnavailable(
      "VIP 章節解密失敗（站點腳本可能已改版）",
    );
  }
  const cleaned = vipCleanText(spliceSeams(html, seamTexts(body)));
  const title = cleanLine(
    document.find("div.noveltext h2").first()?.text() ??
      document.find("h2").first()?.text(),
  );
  const items = [];
  if (title) items.push({ type: "title", text: title });
  let counter = 0;
  for (const item of splitSegments(cleaned)) {
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
  const fontName =
    document
      .find("div.noveltext")
      .first()
      ?.attr("class")
      ?.match(/jjwxcfont_\w+/)?.[0] ?? null;
  const needsFont = items.some(
    (item) => item.type === "text" && /[\uE000-\uF8FF]/.test(item.content),
  );
  if (fontName != null && needsFont) {
    // 字體在 static.jjwxc.net/tmp/fonts/，免 Referer/Cookie。解析失敗或未
    // 命中的字符保持 PUA 原樣（正文仍可讀，個別字顯示爲替換符）。
    return {
      type: "request",
      request: {
        url: `https://static.jjwxc.net/tmp/fonts/${fontName}.ttf`,
        method: "GET",
        headers: requestHeaders(),
      },
      next_state: {
        stage: "font",
        items,
        bookId: state.bookId,
        chapterId: state.chapterId,
      },
    };
  }
  return countsRequest(state, items);
}

// 段評數角標請求（getNovelParagraphCommentNum）。免費章免登入；VIP 站方按
// 閱讀權限門控（匿名 1004、未購爲空），能讀到正文的會話自然拿到數據，失
// 敗時 counts 階段靜默省略角標。
function countsRequest(state, items) {
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
    // VIP 頁先探密文欄位：其 #paragraph_comment_content 只是「vip內容加載
    // 中」佔位容器，走免費路徑會把佔位文字當正文。
    const vars = vipVars(document);
    if (vars != null) {
      return vipAssemble(event, state, document, body, vars);
    }
    const content = document.find("#paragraph_comment_content").first();
    if (content == null) {
      // www 入口對 VIP 章重定向，宿主跟隨後 response.url 是最終頁：未登入
      // 落在 login.php，未購買落在 backend/buynovel.php（頁內也有支付密碼
      // 框，故先探購買頁再探登入）。
      const url = String(event.response?.url ?? "");
      if (document.find("#buy_content").length > 0 || url.includes("buynovel.php")) {
        return FeedError.contentNotFound("VIP 章節尚未購買");
      }
      if (
        document.find('input[type="password"]').length > 0 ||
        url.includes("login.php")
      ) {
        return FeedError.authRequired("VIP 章節需要登入晉江文學城");
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
    return countsRequest(state, items);
  }
  if (state.stage === "font") {
    // 字體是還原增強：拉取或解析失敗時字符保持 PUA 原樣，正文照常返回。
    const mapping =
      event.response?.status === 200 ? fontMapping(event.response?.body) : null;
    const items = state.items ?? [];
    if (mapping != null) {
      for (const item of items) {
        if (item.type === "text") {
          item.content = decodeFontText(item.content, mapping);
        }
      }
    }
    return countsRequest(state, items);
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
// 斷是否還有下一頁，短頁即終止。兩個 API 均免登入（VIP 章亦然）。
// 書級作者公告（div.author_bulletin，站點渲染在每個章節頁的評論區頂部）
// 刻意不顯示：每章重複且需額外抓頁。

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

// ── 登入 ──────────────────────────────────────────────────────────────────────
// 晉江帳號體系在 my.jjwxc.net：登入頁與「我的晉江」是桌面站，WebView 用桌面
// UA 才能拿到正常表單。會話由 .jjwxc.net 域的 Cookie 承載（token 爲
// base64 的「readerid|hash|…」，舊會話則是 readerid），www/my/static 共用，
// 之後的內容請求照常用腳本自己的移動 UA——Cookie 與 UA 無關。

// 登入 WebView 用桌面 Chrome；內容請求仍用上面的移動 UA。
const LOGIN_USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

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

const login = {
  entry() {
    return {
      url: "https://my.jjwxc.net/login.php?referer=%2F%2Fmy.jjwxc.net%2F",
      title: "晉江文學城登入",
      user_agent: LOGIN_USER_AGENT,
    };
  },

  // 登入完成後從 WebView 收 Cookie：保留 jjwxc 域（token/readerid 等會話
  // 憑證都在 .jjwxc.net），排除 Hm_* 統計與含分隔符的髒值。標記是 token
  // 或 readerid——湊齊才視爲登入成功。
  parse(page) {
    const pairs = [];
    let hasLoginCookie = false;
    for (const cookie of page.cookies ?? []) {
      const name = String(cookie?.name ?? "");
      const value = String(cookie?.value ?? "");
      const domain = String(cookie?.domain ?? "");
      const domainOk = !domain || domain.includes("jjwxc.net") || domain.includes("jjwxc.com");
      const valueOk = value && !/[;,\x00-\x1f\x7f]/.test(value);
      const excluded = name.startsWith("Hm_");
      if (!domainOk || !valueOk || excluded) continue;
      pairs.push(`${name}=${value}`);
      if (name === "token" || name === "readerid") hasLoginCookie = true;
    }
    if (!hasLoginCookie) {
      return FeedError.authRequired("登錄尚未完成：未檢測到晉江登入 Cookie");
    }
    return {
      cookie_header: pairs.join("; "),
      captured_url: page.current_url,
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
    return request;
  },

  // 探測「我的晉江」設置頁：未登入 302 到 login.php（最終頁含登入表單），
  // 已登入停在 user_setting.php。
  status(event) {
    if (event.state == null) {
      return {
        type: "request",
        request: {
          url: "https://my.jjwxc.net/backend/user_setting.php",
          method: "GET",
          headers: requestHeaders(),
        },
        next_state: { stage: "probe" },
      };
    }
    return {
      type: "complete",
      result:
        event.response?.status === 200 &&
        !String(event.response?.url ?? "").includes("login.php"),
    };
  },
};

export default {
  search,
  bookInfo,
  chapters,
  paragraphs,
  comments: { chapter: chapterComments, paragraph: paragraphComments },
  login,
};
