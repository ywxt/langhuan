// ==Feed==
// @id           fanqie
// @name         番茄小說
// @version      1.2.0
// @author       Langhuan
// @description  番茄小說官網書源（fanqienovel.com）：支持關鍵詞搜尋（也可直接貼書籍連結或 ID），正文採用字體混淆，內置字形映射表解碼；搜索被風控攔截時可經內嵌驗證頁完成人機驗證後重試
// @base_url     https://fanqienovel.com
// @access_domain fanqienovel.com
// @access_domain *.byteimg.com
// @access_domain *.fqnovelpic.com
// @schema_version 3
// ==/Feed==

// 官網正文反爬採用字體混淆：HTML 內約 360 個高頻字以私用區（PUA）碼位存儲，
// 由自訂字體繪製真正的字形。目前線上字體是 Source Han Sans SC Normal v2.002
// 的子集，因此下方的映射表是用上游正式 release 逐字形輪廓精確比對解出的（非
// OCR 猜測）。番茄偶爾會輪換字體：FONT_HASH 固定本表對應的字體版本，輪換後
// 會明確報錯而不是解出亂碼。更新字體時兩者必須一起更新。
//
// 官網搜尋 API（/api/author/search/search_book/v1）位於字節 BDMS 簽名保護的
// /api 命名空間下，且參數必須以 POST 查詢串發送：未簽名的 GET 會被風控以空
// 響應加 bdturing 滑塊挑戰攔截，而同樣參數的 POST（無 body、無簽名、無
// cookie）可以直接到達端點並返回明文 JSON。
//
// 若番茄日後封堵此通路，搜索會返回 webview 步驟：host 彈出內嵌驗證頁（打開
// /library 觸發滑塊），用戶完成後頁面快照（URL、HTML、cookies）以
// event.webview 回到本 reducer，腳本把採集到的 fanqienovel.com cookie（剔除
// Hm_* 統計項）附加到重試請求上。驗證後的 cookie 串在本會話內快取，後續搜索
// 直接帶上；若驗證後仍被攔截則標記本會話為風控攔截狀態，之後的搜索直接報
// search_failed 而不再重複彈出驗證頁，直到某次搜索成功才解除。

(() => {
  "use strict";

  const USER_AGENT =
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

  const FONT_HASH = "dc027189e0ba4cd";

  // PUA 碼位 → 真實字元。按碼位升序排列。
  const FONT_MAP = {
    "\ue3e8": "D", "\ue3e9": "在", "\ue3ea": "主", "\ue3eb": "特",
    "\ue3ec": "家", "\ue3ed": "军", "\ue3ee": "然", "\ue3ef": "表",
    "\ue3f0": "场", "\ue3f1": "4", "\ue3f2": "要", "\ue3f3": "只",
    "\ue3f4": "v", "\ue3f5": "和", "\ue3f7": "6", "\ue3f8": "别",
    "\ue3f9": "还", "\ue3fa": "g", "\ue3fb": "现", "\ue3fc": "儿",
    "\ue3fd": "岁", "\ue400": "此", "\ue401": "象", "\ue402": "月",
    "\ue403": "3", "\ue404": "出", "\ue405": "战", "\ue406": "工",
    "\ue407": "相", "\ue408": "o", "\ue409": "男", "\ue40a": "直",
    "\ue40b": "失", "\ue40c": "世", "\ue40d": "F", "\ue40e": "都",
    "\ue40f": "平", "\ue410": "文", "\ue411": "什", "\ue412": "V",
    "\ue413": "O", "\ue414": "将", "\ue415": "真", "\ue416": "T",
    "\ue417": "那", "\ue418": "当", "\ue41a": "会", "\ue41b": "立",
    "\ue41c": "些", "\ue41d": "u", "\ue41e": "是", "\ue41f": "十",
    "\ue420": "张", "\ue421": "学", "\ue422": "气", "\ue423": "大",
    "\ue424": "爱", "\ue425": "两", "\ue426": "命", "\ue427": "全",
    "\ue428": "后", "\ue429": "东", "\ue42a": "性", "\ue42b": "通",
    "\ue42c": "被", "\ue42d": "1", "\ue42e": "它", "\ue42f": "乐",
    "\ue430": "接", "\ue431": "而", "\ue432": "感", "\ue433": "车",
    "\ue434": "山", "\ue435": "公", "\ue436": "了", "\ue437": "常",
    "\ue438": "以", "\ue439": "何", "\ue43a": "可", "\ue43b": "话",
    "\ue43c": "先", "\ue43d": "p", "\ue43e": "i", "\ue43f": "叫",
    "\ue440": "轻", "\ue441": "M", "\ue442": "士", "\ue443": "w",
    "\ue444": "着", "\ue445": "变", "\ue446": "尔", "\ue447": "快",
    "\ue448": "l", "\ue449": "个", "\ue44a": "说", "\ue44b": "少",
    "\ue44c": "色", "\ue44d": "里", "\ue44e": "安", "\ue44f": "花",
    "\ue450": "远", "\ue451": "7", "\ue452": "难", "\ue453": "师",
    "\ue454": "放", "\ue455": "t", "\ue456": "报", "\ue457": "认",
    "\ue458": "面", "\ue459": "道", "\ue45a": "S", "\ue45c": "克",
    "\ue45d": "地", "\ue45e": "度", "\ue45f": "I", "\ue460": "好",
    "\ue461": "机", "\ue462": "U", "\ue463": "民", "\ue464": "写",
    "\ue465": "把", "\ue466": "万", "\ue467": "同", "\ue468": "水",
    "\ue469": "新", "\ue46a": "没", "\ue46b": "书", "\ue46c": "电",
    "\ue46d": "吃", "\ue46e": "像", "\ue46f": "斯", "\ue470": "5",
    "\ue471": "为", "\ue472": "y", "\ue473": "白", "\ue474": "几",
    "\ue475": "日", "\ue476": "教", "\ue477": "看", "\ue478": "但",
    "\ue479": "第", "\ue47a": "加", "\ue47b": "候", "\ue47c": "作",
    "\ue47d": "上", "\ue47e": "拉", "\ue47f": "住", "\ue480": "有",
    "\ue481": "法", "\ue482": "r", "\ue483": "事", "\ue484": "应",
    "\ue485": "位", "\ue486": "利", "\ue487": "你", "\ue488": "声",
    "\ue489": "身", "\ue48a": "国", "\ue48b": "问", "\ue48c": "马",
    "\ue48d": "女", "\ue48e": "他", "\ue48f": "Y", "\ue490": "比",
    "\ue491": "父", "\ue492": "x", "\ue493": "A", "\ue494": "H",
    "\ue495": "N", "\ue496": "s", "\ue497": "X", "\ue498": "边",
    "\ue499": "美", "\ue49a": "对", "\ue49b": "所", "\ue49c": "金",
    "\ue49d": "活", "\ue49e": "回", "\ue49f": "意", "\ue4a0": "到",
    "\ue4a1": "z", "\ue4a2": "从", "\ue4a3": "j", "\ue4a4": "知",
    "\ue4a5": "又", "\ue4a6": "内", "\ue4a7": "因", "\ue4a8": "点",
    "\ue4a9": "Q", "\ue4aa": "三", "\ue4ab": "定", "\ue4ac": "8",
    "\ue4ad": "R", "\ue4ae": "b", "\ue4af": "正", "\ue4b0": "或",
    "\ue4b1": "夫", "\ue4b2": "向", "\ue4b3": "德", "\ue4b4": "听",
    "\ue4b5": "更", "\ue4b7": "得", "\ue4b8": "告", "\ue4b9": "并",
    "\ue4ba": "本", "\ue4bb": "q", "\ue4bc": "过", "\ue4bd": "记",
    "\ue4be": "L", "\ue4bf": "让", "\ue4c0": "打", "\ue4c1": "f",
    "\ue4c2": "人", "\ue4c3": "就", "\ue4c4": "者", "\ue4c5": "去",
    "\ue4c6": "原", "\ue4c7": "满", "\ue4c8": "体", "\ue4c9": "做",
    "\ue4ca": "经", "\ue4cb": "K", "\ue4cc": "走", "\ue4cd": "如",
    "\ue4ce": "孩", "\ue4cf": "c", "\ue4d0": "G", "\ue4d1": "给",
    "\ue4d2": "使", "\ue4d3": "物", "\ue4d5": "最", "\ue4d6": "笑",
    "\ue4d7": "部", "\ue4d9": "员", "\ue4da": "等", "\ue4db": "受",
    "\ue4dc": "k", "\ue4dd": "行", "\ue4de": "一", "\ue4df": "条",
    "\ue4e0": "果", "\ue4e1": "动", "\ue4e2": "光", "\ue4e3": "门",
    "\ue4e4": "头", "\ue4e5": "见", "\ue4e6": "往", "\ue4e7": "自",
    "\ue4e8": "解", "\ue4e9": "成", "\ue4ea": "处", "\ue4eb": "天",
    "\ue4ec": "能", "\ue4ed": "于", "\ue4ee": "名", "\ue4ef": "其",
    "\ue4f0": "发", "\ue4f1": "总", "\ue4f2": "母", "\ue4f3": "的",
    "\ue4f4": "死", "\ue4f5": "手", "\ue4f6": "入", "\ue4f7": "路",
    "\ue4f8": "进", "\ue4f9": "心", "\ue4fa": "来", "\ue4fb": "h",
    "\ue4fc": "时", "\ue4fd": "力", "\ue4fe": "多", "\ue4ff": "开",
    "\ue500": "已", "\ue501": "许", "\ue502": "d", "\ue503": "至",
    "\ue504": "由", "\ue505": "很", "\ue506": "界", "\ue507": "n",
    "\ue508": "小", "\ue509": "与", "\ue50a": "Z", "\ue50b": "想",
    "\ue50c": "代", "\ue50d": "么", "\ue50e": "分", "\ue50f": "生",
    "\ue510": "口", "\ue511": "再", "\ue512": "妈", "\ue513": "望",
    "\ue514": "次", "\ue515": "西", "\ue516": "风", "\ue517": "种",
    "\ue518": "带", "\ue519": "J", "\ue51b": "实", "\ue51c": "情",
    "\ue51d": "才", "\ue51e": "这", "\ue520": "E", "\ue521": "我",
    "\ue522": "神", "\ue523": "格", "\ue524": "长", "\ue525": "觉",
    "\ue526": "间", "\ue527": "年", "\ue528": "眼", "\ue529": "无",
    "\ue52a": "不", "\ue52b": "亲", "\ue52c": "关", "\ue52d": "结",
    "\ue52e": "0", "\ue52f": "友", "\ue530": "信", "\ue531": "下",
    "\ue532": "却", "\ue533": "重", "\ue534": "己", "\ue535": "老",
    "\ue536": "2", "\ue537": "音", "\ue538": "字", "\ue539": "m",
    "\ue53a": "呢", "\ue53b": "明", "\ue53c": "之", "\ue53d": "前",
    "\ue53e": "高", "\ue53f": "P", "\ue540": "B", "\ue541": "目",
    "\ue542": "太", "\ue543": "e", "\ue544": "9", "\ue545": "起",
    "\ue546": "稜", "\ue547": "她", "\ue548": "也", "\ue549": "W",
    "\ue54a": "用", "\ue54b": "方", "\ue54c": "子", "\ue54d": "英",
    "\ue54e": "每", "\ue54f": "理", "\ue550": "便", "\ue551": "四",
    "\ue552": "数", "\ue553": "期", "\ue554": "中", "\ue555": "C",
    "\ue556": "外", "\ue557": "样", "\ue558": "a", "\ue559": "海",
    "\ue55a": "们", "\ue55b": "任",
  };

  function headers() {
    return {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "zh-CN,zh;q=0.9",
    };
  }

  // ── 搜索會話狀態（模組級，隨 Feed 物件存活於本次應用會話）─────────────────
  //
  // 驗證後的 cookie 串與風控攔截標記：cookie 串讓後續搜索直接帶上憑證；
  // 標記避免「驗證也救不了」時每次搜索都重複彈出驗證頁，直到某次搜索
  // 成功才自動解除。

  let sessionCookieHeader = null;
  let sessionRiskBlocked = false;

  function isFanqieDomain(domain) {
    const host = String(domain ?? "").replace(/^\./, "").toLowerCase();
    return host === "fanqienovel.com" || host.endsWith(".fanqienovel.com");
  }

  // 從驗證頁快照採集 cookie：僅保留 fanqienovel.com 域、剔除百度統計
  // （Hm_*）等與風控無關的項。
  function cookieHeaderFromSnapshot(cookies) {
    const parts = [];
    for (const cookie of Array.isArray(cookies) ? cookies : []) {
      const name = String(cookie?.name ?? "").trim();
      if (!name || name.startsWith("Hm_")) continue;
      const domain = String(cookie?.domain ?? "");
      if (domain && !isFanqieDomain(domain)) continue;
      parts.push(`${name}=${cookie.value ?? ""}`);
    }
    return parts.length > 0 ? parts.join("; ") : null;
  }

  function searchRequest(keyword, pageIndex) {
    const request = {
      url: `${meta.base_url}/api/author/search/search_book/v1`,
      method: "POST",
      params: {
        filter: "127,127,127,127",
        page_count: "10",
        page_index: String(pageIndex),
        query_type: "0",
        query_word: keyword,
      },
      headers: headers(),
    };
    if (sessionCookieHeader != null) {
      request.headers.Cookie = sessionCookieHeader;
    }
    return request;
  }

  function decode(value) {
    let out = "";
    for (const ch of String(value ?? "")) out += FONT_MAP[ch] ?? ch;
    return out;
  }

  function hasPrivateUse(value) {
    return /[\ue000-\uf8ff]/.test(String(value ?? ""));
  }

  function absoluteUrl(value) {
    const url = String(value ?? "").trim();
    if (!url) return null;
    return url.startsWith("//") ? `https:${url}` : url;
  }

  function ensureAvailable(response) {
    const status = response?.status ?? 0;
    const body = response?.body ?? "";
    if (status === 404) {
      return FeedError.contentNotFound("書籍或章節不存在或已下架");
    }
    if (status === 429) {
      return FeedError.rateLimited("番茄限流，請稍後重試");
    }
    if (status !== 200) {
      return FeedError.sourceUnavailable(`番茄返回 HTTP ${status}`);
    }
    // 風控攔截頁難以從 body 字串可靠識別（正常頁面也內嵌字節 captcha
    // SDK），交由結構檢測：缺少目錄/正文容器時由各自的解析路徑報錯。
    return null;
  }

  function normalizeBookId(value) {
    const id = String(value ?? "").trim();
    return /^\d{6,21}$/.test(id) ? id : null;
  }

  // 使用者可能在搜尋框貼入完整連結或純 ID：直接解析該書；否則按關鍵詞搜尋。
  function bookIdFromKeyword(keyword) {
    const text = String(keyword ?? "").trim();
    const fromUrl = text.match(/fanqienovel\.com\/page\/(\d{6,})/i);
    if (fromUrl) return fromUrl[1];
    const bare = text.match(/^(\d{15,21})$/);
    if (bare) return bare[1];
    return null;
  }

  // ── 頁面解析 ────────────────────────────────────────────────────────────────

  function parseBook(response, bookId) {
    const document = HTML.parse(response.body);
    const title = decode(document.select("h1").first()?.text()).trim();
    const author = decode(
      document.select(".author-name-text").first()?.text(),
    ).trim();
    const cover = document.select("img.book-cover-img").first();
    const description = decode(
      document.select(".page-abstract-content p").first()?.text(),
    ).trim();
    return {
      id: bookId,
      title: title || "未知書名",
      author: author || "未知",
      cover_url: absoluteUrl(cover?.attr("src")),
      description: description || null,
    };
  }

  function parseSearchResults(body, pageIndex) {
    const payload = JSON.parse(body);
    if (payload.code !== 0) {
      return FeedError.raise(
        "search_failed",
        `番茄搜索返回錯誤 ${payload.code}：${payload.message ?? "未知錯誤"}`,
      );
    }
    const data = payload.data ?? {};
    const books = Array.isArray(data.search_book_data_list)
      ? data.search_book_data_list
      : [];
    const items = [];
    for (const book of books) {
      const id = String(book?.book_id ?? "");
      const title = decode(book?.book_name ?? "").trim();
      if (!id || !title) continue;
      items.push({
        id,
        title,
        author: decode(book?.author ?? "").trim() || "未知",
        cover_url: book?.thumb_url ?? null,
        description: decode(book?.book_abstract ?? "").trim() || null,
      });
    }
    const total = Number(data.total_count ?? 0);
    const nextCursor = (pageIndex + 1) * 10 < total ? pageIndex + 1 : null;
    return { type: "complete", items, next_cursor: nextCursor };
  }

  function parseChapters(response) {
    const document = HTML.parse(response.body);
    const items = [];
    const seen = new Set();
    // 目錄在 .page-directory-content 內完整 SSR；頁首的「最近更新」橫幅也帶
    // chapter-item-title class，但位於該容器之外，作用域選擇器天然排除它。
    for (const anchor of document.select(
      ".page-directory-content a.chapter-item-title",
    )) {
      const id = (anchor.attr("href") ?? "").match(/^\/reader\/(\d+)$/)?.[1];
      if (!id || seen.has(id)) continue;
      const title = decode(anchor.text()).trim();
      if (!title) continue;
      items.push({ id, title });
      seen.add(id);
    }
    return items;
  }

  function parseParagraphs(response) {
    const body = response.body ?? "";
    const document = HTML.parse(body);

    // 字體哈希釘住映射表版本；輪換後明確報錯。
    const hash = body.match(/awesome-font\/c\/([a-z0-9]+)(?:-\d+)?\.woff2/)?.[1];
    if (hash != null && hash !== FONT_HASH) {
      return FeedError.raise(
        "font_mapping_outdated",
        `番茄更換了混淆字體（${hash}），本書源的映射表需要更新`,
      );
    }

    const title = decode(
      document.select(".muye-reader-title").first()?.text(),
    ).trim();

    const lines = [];
    for (const node of document.select(".muye-reader-content p")) {
      const line = decode(node.text()).trim();
      if (line) lines.push(line);
    }
    if (lines.length === 0) {
      return FeedError.contentNotFound(
        "章節內容不存在（可能遭遇風控、需要登入、付費或已下架）",
      );
    }

    const items = [];
    if (title && !hasPrivateUse(title)) items.push({ type: "title", text: title });
    for (const line of lines) {
      if (hasPrivateUse(line)) {
        return FeedError.raise(
          "font_mapping_outdated",
          "正文包含無法解碼的字元，本書源的映射表可能需要更新",
        );
      }
      items.push({ type: "text", content: line });
    }
    return { type: "complete", items };
  }

  // ── Reducers ────────────────────────────────────────────────────────────────

  function search(event) {
    if (event.state == null) {
      const keyword = String(event.input.keyword ?? "").trim();
      if (!keyword) return { type: "complete", items: [] };
      const direct = bookIdFromKeyword(keyword);
      if (direct) {
        return {
          type: "request",
          request: {
            url: `${meta.base_url}/page/${direct}`,
            method: "GET",
            headers: headers(),
          },
          next_state: { direct: true, bookId: direct },
        };
      }
      // 參見檔頭注釋：搜尋 API 只接受 POST 查詢串，GET 會被風控挑戰攔截。
      const pageIndex = event.cursor == null ? 0 : Number(event.cursor);
      return {
        type: "request",
        request: searchRequest(keyword, pageIndex),
        next_state: { pageIndex },
      };
    }
    if (event.state.direct) {
      const failure = ensureAvailable(event.response);
      if (failure) return failure;
      return {
        type: "complete",
        items: [parseBook(event.response, event.state.bookId)],
      };
    }
    if (event.webview != null) {
      // 用戶剛在驗證頁完成人機驗證：採集 cookie 並帶著重試本次搜索。
      const header = cookieHeaderFromSnapshot(event.webview.cookies);
      if (header == null) {
        return FeedError.authRequired(
          "驗證後未採集到 fanqienovel.com 的有效 cookie",
        );
      }
      sessionCookieHeader = header;
      const pageIndex = event.state.pageIndex ?? 0;
      return {
        type: "request",
        request: searchRequest(event.input.keyword, pageIndex),
        next_state: { pageIndex, retried: true },
      };
    }
    const failure = ensureAvailable(event.response);
    if (failure) return failure;
    const body = String(event.response?.body ?? "").trim();
    if (!body || body.startsWith("<")) {
      // 風控攔截：200 但 body 為空或為挑戰頁 HTML。
      if (event.state.retried) {
        sessionRiskBlocked = true;
        sessionCookieHeader = null;
        return FeedError.raise(
          "search_failed",
          "完成驗證後仍被番茄風控攔截，請稍後再試",
        );
      }
      if (sessionRiskBlocked) {
        return FeedError.raise(
          "search_failed",
          "番茄風控持續攔截（本會話內驗證已無效），請稍後再試",
        );
      }
      return {
        type: "webview",
        url: `${meta.base_url}/library`,
        title: "番茄小說驗證",
        user_agent: USER_AGENT,
        next_state: { pageIndex: event.state.pageIndex ?? 0 },
      };
    }
    const result = parseSearchResults(body, event.state.pageIndex ?? 0);
    if (result.type === "complete") sessionRiskBlocked = false;
    return result;
  }

  function bookInfo(event) {
    if (event.state == null) {
      const bookId = normalizeBookId(event.input.bookId);
      if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/page/${bookId}`,
          method: "GET",
          headers: headers(),
        },
        next_state: { bookId },
      };
    }
    const failure = ensureAvailable(event.response);
    if (failure) return failure;
    return {
      type: "complete",
      value: parseBook(event.response, event.state.bookId),
    };
  }

  function chapters(event) {
    if (event.state == null) {
      const bookId = normalizeBookId(event.input.bookId);
      if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/page/${bookId}`,
          method: "GET",
          headers: headers(),
        },
        next_state: { requested: true },
      };
    }
    const failure = ensureAvailable(event.response);
    if (failure) return failure;
    return { type: "complete", items: parseChapters(event.response) };
  }

  function paragraphs(event) {
    if (event.state == null) {
      const chapterId = normalizeBookId(event.input.chapterId);
      if (!chapterId) return FeedError.contentNotFound("無效的章節 ID");
      return {
        type: "request",
        request: {
          url: `${meta.base_url}/reader/${chapterId}`,
          method: "GET",
          headers: headers(),
        },
        next_state: { requested: true },
      };
    }
    const failure = ensureAvailable(event.response);
    if (failure) return failure;
    return parseParagraphs(event.response);
  }

  return { search, bookInfo, chapters, paragraphs };
})()
