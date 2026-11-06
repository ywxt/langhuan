// ==Feed==
// @id           org.eu.ywxt.langhuan.fanqie_app
// @name         番茄小說（APP 直連）
// @version      2.2.3
// @author       Langhuan
// @description  番茄小說 APP 網關書源（reading.snssdk.com）：匿名設備註冊後經 x-argus/x-ladon 簽名直連閱讀 API，VIP 章節全文解密，無需帳號；支持正文段落評論，章節段落附帶評論數角標。需要宿主提供存儲後端（langhuan:storage）
// @base_url     https://reading.snssdk.com
// @access_domain reading.snssdk.com
// @access_domain i.snssdk.com
// @access_domain fanqienovel.com
// @access_domain api5-normal-sinfonlineb.fqnovel.com
// @schema_version 6
// ==/Feed==
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本書源的協議編排（簽名棧、設備註冊流、密鑰註冊與正文解密的字節級佈
// 局）衍生自 naiyQAQ/fanqie-assistant（GPL-3.0，https://github.com/naiyQAQ/
// fanqie-assistant），其協議知識又來自 fq-go-api 與 unidbg 社區的逆向工
// 作。密碼學原語本身（SM3/MD5/SHA-512/Simon/Speck/AES/PKCS7/protobuf/
// gzip）由 langhuan 的 Rust 宿主模塊提供（langhuan:crypto / langhuan:
// protobuf），本文件只保留協議編排。與 MIT 授權的 fanqie.js（網頁路線）
// 是並存的兩個書源：本源不登錄、不解字體混淆，解密即乾淨文本。
//
// ── 路線說明 ─────────────────────────────────────────────────────────────
//
// 番茄網頁端（fanqie.js 所走）對 VIP 章節是 SSR 權益牆：未登入只渲染試
// 讀段落，登入而無 SVIP 權益仍是同一頁。APP 端不同：閱讀網關
// （reading.snssdk.com/reading/*）按「設備」而非「帳號」放行——註冊一
// 台匿名設備、激活設備級會員（privilege/add，設備維度的權益），即可讀
// 全文。此主張已實測：tests/fanqie_app.rs 的 live_vip_chapter_decrypts_
// anonymously（#[ignore]）先以網頁目錄 API 的 isChapterLock 標記選出網
// 頁端被牆章節、確認其閱讀頁確為 SVIP 牆（muye-to-vip-login），再經本
// 源匿名讀出全文。
//
// ── 協議棧（全部為請求側編排，記錄自 fanqie-assistant）────────────────
//
// 設備註冊  POST i.snssdk.com/service/2/device_register/?tt_data=a
//           請求體是 ttencrypt 算法：gzip(JSON) 前置 sha512 校驗，再以
//           sha512(sha512(random32) ‖ FIXED_STRING) 的前 32 字節做
//           AES-128-CBC，輸出 "tc\x05\x10\x00\x00" ‖ random ‖ 密文。
//           該接口不簽名，UA 是 okhttp/4.10.0。
//
// 會員激活  POST /reading/user/privilege/add/v
//           privilege_id 7210376203117531962 超出 Number.MAX_SAFE_
//           INTEGER，JSON 必須手工拼接。失敗可容忍（fanqie-assistant 同
//           樣吞掉此步失敗，正文仍可解，僅權益時長受影響）。
//
// 密鑰註冊  POST /reading/crypt/registerkey
//           請求體：device_id 十進制 → 16 字節大端 → 整體反轉（= 小端）
//           → shared_key AES-CBC 加密 → IV‖密文 base64 → {content:…}
//           → gzip → 帶簽名與 Content-Encoding: gzip 發送。密鑰續期
//           （refresh）走同一端點但 body 只取 device_id 小端的前 8 字節
//           （i64 截斷），IV 也改為 16 個字母數字字符的 UTF-8——兩條路
//           徑的字節佈局不同，均按上游實現保真移植。響應 data.key 是
//           base64(IV‖AES-CBC(shared_key)(內容密鑰))，解出 16 字節密鑰
//           與 keyver 一併持久化。
//
// 正文      GET /reading/reader/full/v?item_id=&req_type=1
//           data.content 為 base64(IV‖AES-128-CBC(內容密鑰)(正文))，
//           compress_status===1 時解密後還要 gunzip。content==='Invalid'
//           或 key_version 與本地不符表示密鑰註冊失效，重註冊後重試。
//
// 段評      POST api5-normal-sinfonlineb.fqnovel.com/novel/commentapi/
//           comment/list/{chapterId}/v1 與 reply/list/{commentId}/v1。
//           body 為 JSON 且參與簽名（X-SS-STUB），配方見下方「段評與回
//           覆」註釋塊；不需要內容密鑰，僅需已註冊的設備。
//
// 請求簽名  x-argus / x-ladon / x-khronos / x-ss-req-ticket（X-SS-STUB
//           僅帶體請求）。argus：protobuf 字段表（見 buildArgusProtobuf）
//           → Simon128/256-ECB（密鑰 = SM3(signKey‖LOW_RAND‖HIGH_RAND‖
//           signKey) 的 32 字節，低 64 位在前）→ 前置 8 字節 XOR 前綴後
//           data[i] ^= data[i%8]（i≥8）→ 整體反轉 → 9 字節頭‖data‖
//           HIGH_RAND → AES-128-CBC（key=md5(signKey[0..16]),
//           iv=md5(signKey[16..32])）→ LOW_RAND‖密文 base64。
//           ladon：Speck128/256-ECB，密鑰 = utf8(md5hex(random4‖aid))，
//           明文 "ts-licenseId-aid"，輸出 random‖密文 base64。簽名對
//           gzip 後的請求體字節計算（X-SS-STUB 為其 md5 hex）。
//
// ── 閘道語義 ─────────────────────────────────────────────────────────────
//
// /reading/* 對未認可的設備回 HTTP 200 + 空體（content-length: 0，一個
// 字節都沒有），無錯誤碼。這是設備被作廢的靜默拒絕，不是 IP 封鎖——重
// 新註冊設備即刻恢復。與 fanqie.js 檔頭早先「機房 IP 一律空體」的舊歸
// 因不同：空體按設備處理即可。本源的恢復策略照搬 fanqie-assistant：
// 業務響應為空 → 清除本地設備重走註冊流（每個操作至多換一次設備，且
// 兩次替換之間必須有過一次成功請求，避免惡性註冊循環）。
//
// 設備與密鑰經 langhuan:storage 持久化（鍵 "device" / "keyinfo"），跨操
// 作、跨重載複用；同一存儲後端下不同書源互不可見。

import { TextDecoder, TextEncoder, Bytes } from "langhuan:encoding";
import { Crypto, Compression } from "langhuan:crypto";
import { Protobuf } from "langhuan:protobuf";
import { storage } from "langhuan:storage";
import { HTML } from "langhuan:html";

const DECODER = new TextDecoder("utf-8");
const ENCODER = new TextEncoder();

// ── 協議常量（源自 fanqie-assistant 的 unidbgconfig/config）──────────────

const AID = "1967";
const LICENSE_ID = "1611921764";
const SDK_VERSION = "v04.04.05-ov-android";
const SDK_VERSION_INT = 134744640;
const CALL_TYPE = 738;
const SIGN_KEY = Bytes.fromHex(
  "ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c",
);
const SHARED_KEY = new Uint8Array([
  172, 37, 198, 125, 221, 143, 56, 193, 179, 122, 35, 72, 130, 142, 34, 46,
]);

const READING_BASE = "https://reading.snssdk.com/reading";
// 評論中台（commentapi）與閱讀網關是不同的 host： fqapp/mtongle 的驗證
// 配方都指向 api5-normal-sinfonlineb。
const COMMENT_BASE = "https://api5-normal-sinfonlineb.fqnovel.com";
const REGISTER_URL =
  "https://i.snssdk.com/service/2/device_register/?tt_data=a";
const APP_USER_AGENT = "com.dragon.read";
const OKHTTP_UA = "okhttp/4.10.0";
// 目錄回退走番茄網頁站的免簽名 API，用瀏覽器 UA（上游經頁面 fetch 訪問）。
const WEB_USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

const LOW_RAND = new Uint8Array([0xf2, 0x81]);
const HIGH_RAND = new Uint8Array([0x61, 0x6f]); // 'a', 'o'
const XOR_PREFIX = new Uint8Array([
  0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff,
]);
const ARGUS_HEADER = new Uint8Array([
  0xa6, 0x6e, 0xad, 0x9f, 0x77, 0x01, 0xd0, 0x0c, 0x18,
]);

const TT_FIXED_STRING = Bytes.fromBase64(
  "TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA==",
);

// 設備註冊體的隨機素材池（fanqie-assistant 的 devicebody 表）。
const ANDROID_VERSIONS = [
  { version: "9", api: 29 },
  { version: "10", api: 30 },
  { version: "11", api: 31 },
  { version: "12", api: 32 },
  { version: "13", api: 33 },
  { version: "14", api: 34 },
];
const DEVICE_MODELS = [
  "RMX1931",
  "MI8",
  "Honor10",
  "P30",
  "V1921A",
  "Redmi Note 7",
  "Redmi K20 Pro",
  "MI 9",
  "Mi 10 Pro",
  "SM-G9750",
  "Pixel 6",
  "HD1910",
  "M2011K2C",
  "LIO-AN00",
  "VOG-TL00",
  "PCLM10",
  "GM1900",
  "Pixel 7 Pro",
  "Pixel 6a",
  "SM-N9760",
  "POCO F1",
];
const DEVICE_BRANDS = [
  "realme",
  "Xiaomi",
  "Huawei",
  "OPPO",
  "vivo",
  "samsung",
  "OnePlus",
  "google",
  "Redmi",
  "HONOR",
  "motorola",
  "POCO",
];
const HEX_LOW = "0123456789abcdef";

// ── 字節工具 ──────────────────────────────────────────────────────────────

function utf8(text) {
  return ENCODER.encode(text);
}

function concat(...parts) {
  let length = 0;
  for (const part of parts) length += part.length;
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function md5Hex(input) {
  return Bytes.toHex(
    Crypto.md5(typeof input === "string" ? utf8(input) : input),
  );
}

function randomUint32() {
  return new DataView(Crypto.randomBytes(4).buffer).getUint32(0);
}

function randomInt(max) {
  return randomUint32() % max;
}

function randomItem(list) {
  return list[randomInt(list.length)];
}

// 長度為 k 的隨機小寫十六進制字符串（每字符一個隨機字節取模）。
function randomHex(k) {
  const bytes = Crypto.randomBytes(k);
  let out = "";
  for (let i = 0; i < k; i++) out += HEX_LOW[bytes[i] % 16];
  return out;
}

function randomString(length) {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = Crypto.randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i++) out += chars.charAt(bytes[i] % chars.length);
  return out;
}

function uuid() {
  const bytes = Crypto.randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Bytes.toHex(bytes);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// URLSearchParams 風格的查詢編碼（空格 → +）。請求 URL 與簽名輸入必須
// 由同一字符串構造：兩者共用這一個編碼函數。
function encodeQuery(params) {
  return HTML.encodeURIComponents(
    params.map(([key, value]) => [key, String(value)]),
  ).replaceAll("%20", "+");
}

function parseQuery(query) {
  const map = new Map();
  for (const pair of query.split("&")) {
    if (!pair) continue;
    const eq = pair.indexOf("=");
    if (eq < 0) continue;
    map.set(pair.slice(0, eq), pair.slice(eq + 1));
  }
  return map;
}

function bodyText(response) {
  return DECODER.decode(response?.body ?? new Uint8Array(0));
}

function bodyJson(response) {
  try {
    return JSON.parse(bodyText(response));
  } catch {
    return null;
  }
}

// ── 請求簽名（x-argus / x-ladon）─────────────────────────────────────────

function sm3Prefix6(data) {
  return Crypto.sm3(data).slice(0, 6);
}

// X-SS-STUB 是 32 字符 hex；空/缺體視為 16 字節全零。
function decodeStub(stub) {
  const bytes = new Uint8Array(16);
  if (stub.length >= 32) {
    for (let i = 0; i < 16; i++) {
      bytes[i] = parseInt(stub.slice(i * 2, i * 2 + 2), 16) & 0xff;
    }
  }
  return bytes;
}

function buildArgusProtobuf(query, xssStub, timestamp) {
  const params = parseQuery(query);
  const deviceId = params.get("device_id") ?? "";
  const versionName = params.get("version_name") ?? "";

  const bodyHash = sm3Prefix6(
    xssStub === "" ? new Uint8Array(16) : decodeStub(xssStub),
  );
  const queryHash = sm3Prefix6(query === "" ? new Uint8Array(16) : utf8(query));
  const rand = randomUint32() % 0x7fffffff;

  const writer = new Protobuf();
  writer.varint(1, 0x20200929 * 2); // magic
  writer.varint(2, 2); // version
  writer.varint(3, rand);
  writer.string(4, AID);
  writer.string(5, deviceId);
  writer.string(6, LICENSE_ID);
  writer.string(7, versionName);
  writer.string(8, SDK_VERSION);
  writer.varint(9, SDK_VERSION_INT);
  writer.bytes(10, new Uint8Array(8)); // envcode
  writer.varint(11, 0); // platform
  writer.varint(12, timestamp * 2); // createTime
  writer.bytes(13, bodyHash);
  writer.bytes(14, queryHash);

  const extra = new Protobuf();
  extra.varint(1, 1);
  extra.varint(2, 1);
  extra.varint(3, 1);
  extra.varint(7, 3348294860);
  writer.bytes(15, extra.finish());

  writer.string(16, ""); // sec_device_id
  writer.string(20, "none"); // pskVersion
  writer.varint(21, CALL_TYPE);

  const device = new Protobuf();
  device.string(1, "NX551J");
  device.varint(2, 8196);
  device.varint(4, 2162219008);
  writer.bytes(23, device.finish());

  writer.varint(25, 2);
  return writer.finish();
}

function argus(query, xssStub, timestamp) {
  const protobuf = buildArgusProtobuf(query, xssStub, timestamp);

  // Simon 密鑰 = SM3(signKey ‖ LOW ‖ HIGH ‖ signKey) 的 32 字節，小端
  // u64 序即其內存佈局，直接整體作為 key。
  const simonKey = Crypto.sm3(concat(SIGN_KEY, LOW_RAND, HIGH_RAND, SIGN_KEY));
  const encrypted = Crypto.simon(simonKey, protobuf);

  const data = concat(XOR_PREFIX, encrypted);
  for (let i = XOR_PREFIX.length; i < data.length; i++) {
    data[i] ^= data[i % 8];
  }
  data.reverse();

  const plaintext = concat(ARGUS_HEADER, data, HIGH_RAND);
  const ciphertext = Crypto.aes({
    op: "encrypt",
    mode: "cbc",
    key: Crypto.md5(SIGN_KEY.slice(0, 16)),
    iv: Crypto.md5(SIGN_KEY.slice(16)),
    data: plaintext,
  });
  return Bytes.toBase64(concat(LOW_RAND, ciphertext));
}

function ladon(timestamp) {
  const random = Crypto.randomBytes(4);
  const plaintext = utf8(`${timestamp}-${LICENSE_ID}-${AID}`);
  const key = utf8(md5Hex(concat(random, utf8(AID))));
  const encrypted = Crypto.speck(key, plaintext);
  return Bytes.toBase64(concat(random, encrypted));
}

// 簽名針對 URL 的查詢串與請求體字節（gzip 之後）。
function signHeaders(url, body) {
  const query = url.slice(url.indexOf("?") + 1);
  const hasBody = body != null && body.length > 0;
  const stub = hasBody ? md5Hex(body) : "";
  const now = Date.now();
  const timestamp = Math.floor(now / 1000);
  const headers = {
    "x-argus": argus(query, stub, timestamp),
    "x-ladon": ladon(timestamp),
    "x-khronos": String(timestamp),
    "x-ss-req-ticket": String(now),
  };
  if (hasBody) headers["X-SS-STUB"] = stub;
  return headers;
}

// ── 設備註冊體（devicebody 的 generateRequestBody）───────────────────────

function generateRequestBody() {
  const osInfo = randomItem(ANDROID_VERSIONS);
  const deviceBrand = randomItem(DEVICE_BRANDS);
  const deviceModel = randomItem(DEVICE_MODELS);
  const genTime = Date.now();

  const romVersion =
    "coloros__" +
    randomHex(4).toUpperCase() +
    "." +
    String(randomInt(1_000_000)).padStart(6, "0") +
    "." +
    String(randomInt(100_000_000)).padStart(8, "0") +
    " release-keys";

  return {
    magic_tag: "ss_app_log",
    header: {
      display_name: "番茄免费小说",
      aid: 1967,
      channel: "43536163a",
      package: "com.dragon.read",
      sdk_version: "3.7.0-rc.25-fanqie-xiaoshuo",
      sdk_target_version: 29,
      git_hash: "711d1a7",
      density_dpi: 240,
      display_density: "hdpi",
      resolution: "720x1280",
      language: "zh",
      timezone: 8,
      access: "wifi",
      not_request_sender: 0,
      carrier: "CHINA MOBILE",
      mcc_mnc: "46000",
      region: "CN",
      tz_name: "Asia/Shanghai",
      tz_offset: 28800,
      sim_region: "cn",
      sim_serial_number: [],
      oaid_may_support: false,
      device_platform: "android",
      custom: { host_bit: 32, dragon_device_type: 0 },
      pre_installed_channel: "",
      is_system_app: 0,
      sdk_flavor: "china",
      guest_mode: 0,

      os: "Android",
      os_version: osInfo.version,
      os_api: osInfo.api,
      device_model: deviceModel,
      device_brand: deviceBrand,
      device_manufacturer: deviceBrand,
      cpu_abi: "arm64-v8a",
      release_build: randomHex(7),
      cdid: uuid(),
      sig_hash: "a4a27c2633195374c15651ffc3c4a497",
      openudid: randomHex(20),
      clientudid: uuid(),
      req_id: uuid(),

      rom: randomHex(14).toUpperCase(),
      rom_version: romVersion,
      apk_first_install_time: genTime - randomInt(365) * 86_400_000,

      ipv6_list: [
        { type: "client_anpi", value: "::1" },
        { type: "client_anpi", value: ipv6UniqueLocal() },
        { type: "client_anpi", value: ipv6UniqueLocal() },
      ],
    },
    _gen_time: genTime,
  };
}

function ipv6UniqueLocal() {
  const x = randomInt(1 << 8);
  let address = `fd${HEX_LOW[x >> 4]}${HEX_LOW[x & 0x0f]}`;
  for (let i = 0; i < 7; i++) {
    const v = randomInt(1 << 16);
    address +=
      ":" +
      HEX_LOW[(v >> 12) & 0x0f] +
      HEX_LOW[(v >> 8) & 0x0f] +
      HEX_LOW[(v >> 4) & 0x0f] +
      HEX_LOW[v & 0x0f];
  }
  return address;
}

// ttencrypt：設備註冊體的加密層。
function ttEncrypt(data) {
  const random = Crypto.randomBytes(32);
  const digest = Crypto.sha512(concat(Crypto.sha512(random), TT_FIXED_STRING));
  const compressed = Compression.gzip(data);
  const hashed = concat(Crypto.sha512(compressed), compressed);
  const encrypted = Crypto.aes({
    op: "encrypt",
    mode: "cbc",
    key: digest.slice(0, 16),
    iv: digest.slice(16, 32),
    data: hashed,
  });
  return concat(new Uint8Array([116, 99, 5, 16, 0, 0]), random, encrypted);
}

// device_id 十進制 → 16 字節大端 → 整體反轉（小端）。初始註冊用完整
// 16 字節，密鑰續期只取前 8 字節（i64 截斷）。
function deviceIdBytesLE(deviceId, take) {
  const bytes = new Uint8Array(16);
  let id = BigInt(deviceId);
  for (let i = 15; i >= 0; i--) {
    bytes[i] = Number(id & 0xffn);
    id >>= 8n;
  }
  bytes.reverse();
  return bytes.slice(0, take);
}

// ── 設備會話（storage 持久化 + 空體恢復）────────────────────────────────

// 唯一的模塊級可變狀態：剛換過設備且此後還沒有任何業務響應非空過。
// 空體是「設備被服端作廢」的唯一信號（無錯誤碼可判），但「閘道整體
// 拒絕」（出口 IP 被限、接口故障、代理攔截）症狀相同、正確動作相反：
// 前者換設備立刻恢復，後者換了也白換。區分兩者的唯一證據是「新設備
// 是否也被空體」——這個實驗跨操作，載體就得跨操作存活。所以是會話
// 級運行時守衛而非持久數據（feed 重載即重置，新會話允許再試一次），
// 不進 storage；同一 feed 的操作在 realm 鎖下串行執行，無並發問題。
// 上游實測作廢不按閒置時間發生，故不設時間窗，只認「兩次替換之間有
// 一次非空響應」。與 fanqie.js 的風控攔截會話鎖同一模式。
let deviceUnverified = false;

// 持久狀態的事實來源就是 storage：每次按需讀取，不做模塊內緩存——一次
// 橋接調用比維護緩存一致性的代價低。
function currentDevice() {
  const stored = storage.get("device");
  return stored && stored.device_id && stored.install_id ? stored : null;
}

function saveDevice(device) {
  storage.set("device", device);
}

function dropDevice() {
  storage.delete("device");
  storage.delete("keyinfo");
}

function currentKeyinfo() {
  const stored = storage.get("keyinfo");
  if (!stored || !stored.key) return null;
  return { key: Bytes.fromBase64(stored.key), keyver: stored.keyver };
}

function saveKeyinfo(keyinfo) {
  storage.set("keyinfo", {
    key: Bytes.toBase64(keyinfo.key),
    keyver: keyinfo.keyver,
  });
}

function dropKeyinfo() {
  storage.delete("keyinfo");
}

function emptyResponse(response) {
  return response.status === 200 && response.body.length === 0;
}

// ── 註冊流：多步狀態機，結束後調用 launch() 回到業務首步 ──────────────────

function registerStep(launch) {
  const body = generateRequestBody();
  const request = {
    url: REGISTER_URL,
    method: "POST",
    headers: {
      "User-Agent": OKHTTP_UA,
      "Content-Type": "application/octet-stream; tt-data=a",
    },
    body: ttEncrypt(utf8(JSON.stringify(body))),
  };
  return {
    type: "request",
    request,
    next_state: {
      pipeline: "register",
      deviceType: body.header.device_model,
      launch,
    },
  };
}

// 註冊流的查詢串（與閱讀流不同：channel=0、os_version=0、無 ssmix 等）。
function deviceQuery(device, versionCode, extra) {
  return encodeQuery([
    ["device_id", device.device_id],
    ["iid", device.install_id],
    ["device_type", device.device_type],
    ["aid", AID],
    ["app_name", "novelapp"],
    ["channel", "0"],
    ["device_platform", "android"],
    ["os_version", "0"],
    ["version_code", versionCode],
    ...(extra ?? []),
  ]);
}

function activateStep(device, launch) {
  const query = deviceQuery(device, "63932", [
    ["manifest_version_code", "63932"],
    ["update_version_code", "63932"],
  ]);
  const url = `https://reading.snssdk.com/reading/user/privilege/add/v?${query}`;
  // privilege_id 超出安全整數範圍，必須手工拼接 JSON。
  const body =
    '{"add_count_daily":0,"amount":2592000,' +
    '"privilege_id":7210376203117531962,"from":8,' +
    `"unique_key":"${Date.now()}"}`;
  const headers = signHeaders(url, body);
  headers["User-Agent"] = APP_USER_AGENT;
  headers["Content-Type"] = "application/json; charset=utf-8";
  return {
    type: "request",
    request: { url, method: "POST", headers, body: utf8(body) },
    next_state: { pipeline: "activate", device, launch },
  };
}

function registerKeyStep(device, launch) {
  const query = deviceQuery(device, "6.3.9.32");
  const url = `https://reading.snssdk.com/reading/crypt/registerkey?${query}`;
  const iv = Crypto.randomBytes(16);
  const encrypted = Crypto.aes({
    op: "encrypt",
    mode: "cbc",
    key: SHARED_KEY,
    iv,
    data: deviceIdBytesLE(device.device_id, 16),
  });
  const body = JSON.stringify({
    content: Bytes.toBase64(concat(iv, encrypted)),
  });
  const gzipped = Compression.gzip(utf8(body));
  const headers = signHeaders(url, gzipped);
  headers["User-Agent"] = APP_USER_AGENT;
  headers["Content-Type"] = "application/json; charset=utf-8";
  headers["Content-Encoding"] = "gzip";
  return {
    type: "request",
    request: { url, method: "POST", headers, body: gzipped },
    next_state: { pipeline: "registerkey", device, launch },
  };
}

// 密鑰續期：body 是 device_id 小端的前 8 字節，IV 是 16 字符隨機字母數
// 字的 UTF-8 字節——與初始註冊的佈局不同，按上游保真。
function refreshKeyStep(launch) {
  const device = currentDevice();
  const query = deviceQuery(device, "6.3.9.32");
  const url = `https://reading.snssdk.com/reading/crypt/registerkey?${query}`;
  const iv = utf8(randomString(16));
  const encrypted = Crypto.aes({
    op: "encrypt",
    mode: "cbc",
    key: SHARED_KEY,
    iv,
    data: deviceIdBytesLE(device.device_id, 8),
  });
  const body = JSON.stringify({
    content: Bytes.toBase64(concat(iv, encrypted)),
  });
  const gzipped = Compression.gzip(utf8(body));
  const headers = signHeaders(url, gzipped);
  headers["User-Agent"] = APP_USER_AGENT;
  headers["Content-Type"] = "application/json; charset=utf-8";
  headers["Content-Encoding"] = "gzip";
  return {
    type: "request",
    request: { url, method: "POST", headers, body: gzipped },
    next_state: { pipeline: "refreshkey", launch },
  };
}

function readKeyinfoResponse(json) {
  const encryptedKey = json?.data?.key;
  if (!encryptedKey) {
    return FeedError.sourceUnavailable(
      `密鑰註冊失敗：響應缺少 key（code=${json?.code ?? "無"}, message=${json?.message ?? "無"}）`,
    );
  }
  const buf = Bytes.fromBase64(encryptedKey);
  const key = Crypto.aes({
    op: "decrypt",
    mode: "cbc",
    key: SHARED_KEY,
    iv: buf.slice(0, 16),
    data: buf.slice(16),
  });
  return { key, keyver: json?.data?.keyver };
}

// 註冊流的響應分派。返回 null 表示不屬於註冊流，交回業務 reducer。
function pipelineResponse(event) {
  const state = event.state;
  if (state.pipeline == null) return null;
  switch (state.pipeline) {
    case "register": {
      const json = bodyJson(event.response);
      if (!json?.device_id_str || !json?.install_id_str) {
        return FeedError.sourceUnavailable(
          `設備註冊失敗：響應缺少 device_id（HTTP ${event.response.status}）`,
        );
      }
      const device = {
        device_id: String(json.device_id_str),
        install_id: String(json.install_id_str),
        device_type: state.deviceType,
      };
      return activateStep(device, state.launch);
    }
    case "activate": {
      // 激活失敗可容忍（與 fanqie-assistant 一致）：權益時長受影響，
      // 但正文解密不依賴它。
      return registerKeyStep(state.device, state.launch);
    }
    case "registerkey": {
      const keyinfo = readKeyinfoResponse(bodyJson(event.response));
      if (keyinfo.type === "fail") return keyinfo;
      saveDevice(state.device);
      saveKeyinfo(keyinfo);
      return state.launch();
    }
    case "refreshkey": {
      const keyinfo = readKeyinfoResponse(bodyJson(event.response));
      if (keyinfo.type === "fail") return keyinfo;
      saveKeyinfo(keyinfo);
      return state.launch();
    }
    default:
      return null;
  }
}

// 設備未就緒時的公共入口：先走註冊流，完成後調 launch()。
function ensureDeviceStep(launch) {
  if (currentDevice()) return launch();
  return registerStep(launch);
}

// 業務響應為空體（設備被作廢）：清設備重註冊，註冊完成後調 retryStep
// 重發本次操作的首步。
function recoverDeviceStep(retryStep) {
  if (deviceUnverified) {
    return FeedError.sourceUnavailable(
      "番茄閘道持續返回空回應（剛更換的設備也不被認可），請稍後再試",
    );
  }
  dropDevice();
  deviceUnverified = true;
  return registerStep(retryStep);
}

// 業務響應正常到達即視為設備健康（哪怕業務碼出錯）。
function markDeviceHealthy() {
  deviceUnverified = false;
}

// ── 閱讀流請求步 ──────────────────────────────────────────────────────────

function buildAppQuery(extra) {
  const device = currentDevice();
  return encodeQuery([
    ["iid", device.install_id],
    ["device_id", device.device_id],
    ["ac", "wifi"],
    ["channel", "43536163a"],
    ["aid", AID],
    ["app_name", "novelapp"],
    ["version_code", "70132"],
    ["version_name", "7.0.1.32"],
    ["device_platform", "android"],
    ["os", "android"],
    ["ssmix", "a"],
    ["os_version", "10"],
    ["device_type", device.device_type || "P30"],
    ["device_brand", device.device_brand || "realme"],
    ["update_version_code", "70132"],
    ["manifest_version_code", "70132"],
    ["pv_player", "70132"],
    ...(extra ?? []),
  ]);
}

function appGetStep(path, extra, businessState) {
  const url = `${READING_BASE}${path}?${buildAppQuery(extra)}`;
  const headers = signHeaders(url);
  headers["User-Agent"] = APP_USER_AGENT;
  return {
    type: "request",
    request: { url, method: "GET", headers },
    next_state: businessState,
  };
}

// ── 響應解析 ──────────────────────────────────────────────────────────────

function bookIdFromKeyword(keyword) {
  const text = keyword.trim();
  if (/^\d{6,}$/.test(text)) return text;
  const match = text.match(/(?:page|book)\/(\d{6,})/);
  return match ? match[1] : null;
}

function searchBooks(json) {
  const tabs = Array.isArray(json?.search_tabs) ? json.search_tabs : [];
  const tab = tabs.find((entry) => Number(entry?.tab_type) === 1);
  const cells = Array.isArray(tab?.data) ? tab.data : [];
  // show_type=110 是真正的搜索結果；未命中時退化為「帶 book_data 的都要」
  // （聽書/漫畫 tab 的 cell 編號不同）。
  const resultCells = cells.filter((cell) => Number(cell?.show_type) === 110);
  const pool = resultCells.length
    ? resultCells
    : cells.filter(
        (cell) => Array.isArray(cell?.book_data) && cell.book_data.length,
      );

  const items = [];
  const seen = new Set();
  for (const cell of pool) {
    for (const raw of cell?.book_data ?? []) {
      const id = String(raw?.book_id ?? "");
      if (!id || id === "0" || seen.has(id)) continue;
      seen.add(id);
      items.push({
        id,
        title: raw.book_name || raw.original_book_name || "",
        author: raw.author || "",
        cover_url: raw.thumb_url || raw.audio_thumb_url_hd || "",
        description: raw.abstract || "",
      });
    }
  }
  return { tab, items };
}

function bookInfoFromDetail(data, bookId) {
  if (!data) return FeedError.contentNotFound("書籍不存在");
  return {
    id: String(data.book_id ?? bookId),
    title: data.book_name || data.original_book_name || "",
    author: data.author || "",
    cover_url: data.thumb_url || "",
    description: data.abstract || "",
  };
}

function chapterItems(json) {
  const items = json?.data?.item_data_list;
  if (json?.code !== 0 || !Array.isArray(items) || items.length === 0)
    return null;
  const chapters = [];
  for (const item of items) {
    const id = String(item.item_id ?? "");
    if (!id) continue;
    chapters.push({ id, title: String(item.title ?? "") });
  }
  return chapters.length ? chapters : null;
}

function contentParagraphs(plain) {
  const text = plain.trim();
  if (!text) return [];
  if (!text.startsWith("<")) {
    // 少數章節解密後是 JSON；正文在 content 字段（仍可能是 HTML 片段）。
    try {
      const json = JSON.parse(text);
      const inner = typeof json?.content === "string" ? json.content : null;
      if (inner != null && inner.trim().startsWith("<")) {
        return paragraphsFromHtml(inner);
      }
    } catch {
      // 非 JSON：按純文本整體返回。
    }
    return [{ type: "text", content: text }];
  }
  return paragraphsFromHtml(text);
}

function paragraphsFromHtml(htmlText) {
  const document = HTML.parse(htmlText);
  const items = [];
  const title = document.find("h1, h2").first()?.text().trim();
  if (title) items.push({ type: "title", text: title });
  // 服務端段評的 para_index 從正文第一個 <p> 起算（0-based，標題不佔
  // 索引，空段照常遞增——與 commentapi 實況對齊），因此計數跟隨 <p> 的
  // 遍歷而非實際輸出。
  let paraIndex = 0;
  for (const paragraph of document.find("p")) {
    const content = paragraph.text().trim();
    if (content) {
      items.push({ type: "text", content, id: String(paraIndex) });
    }
    paraIndex += 1;
  }
  return items;
}

function decryptChapter(encrypted, compressStatus) {
  const keyinfo = currentKeyinfo();
  if (!keyinfo) throw new Error("正文解密前未取得內容密鑰");
  const buf = Bytes.fromBase64(encrypted);
  let plain = Crypto.aes({
    op: "decrypt",
    mode: "cbc",
    key: keyinfo.key,
    iv: buf.slice(0, 16),
    data: buf.slice(16),
  });
  if (compressStatus === 1) plain = Compression.gunzip(plain);
  return DECODER.decode(plain);
}

// ── Reducers ──────────────────────────────────────────────────────────────

function searchStart(event) {
  const keyword = String(event.input.keyword ?? "").trim();
  if (!keyword) return { type: "complete", result: [] };
  const passback = event.cursor == null ? 0 : Number(event.cursor);
  const direct = bookIdFromKeyword(keyword);
  return ensureDeviceStep(() =>
    direct
      ? appGetStep("/bookapi/detail/v", [["book_id", direct]], {
          search: { direct },
        })
      : appGetStep(
          "/bookapi/search/tab/v",
          [
            ["query", keyword],
            ["passback", String(passback)],
            ["selected_items", ""],
            ["tab_type", "1"],
          ],
          { search: { keyword, passback } },
        ),
  );
}

function bookInfoStart(event) {
  const bookId = bookIdFromKeyword(String(event.input.bookId ?? ""));
  if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
  return ensureDeviceStep(() =>
    appGetStep("/bookapi/detail/v", [["book_id", bookId]], {
      bookInfo: { bookId },
    }),
  );
}

function chaptersStart(event) {
  const bookId = bookIdFromKeyword(String(event.input.bookId ?? ""));
  if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
  return ensureDeviceStep(() =>
    appGetStep("/bookapi/directory/all_items/v", [["book_id", bookId]], {
      chapters: { bookId, webFallback: false },
    }),
  );
}

function paragraphsStart(event) {
  const bookId = bookIdFromKeyword(String(event.input.bookId ?? ""));
  const chapterId = bookIdFromKeyword(String(event.input.chapterId ?? ""));
  if (!chapterId) return FeedError.contentNotFound("無效的章節 ID");
  return ensureDeviceStep(() =>
    ensureKeyinfoStep(() =>
      appGetStep(
        "/reader/full/v",
        [
          ["item_id", chapterId],
          ["req_type", "1"],
        ],
        { paragraphs: { bookId, chapterId, attempt: 0 } },
      ),
    ),
  );
}

function search(event) {
  if (event.state == null) return searchStart(event);

  const pipelined = pipelineResponse(event);
  if (pipelined) return pipelined;

  const state = event.state.search;
  const response = event.response;
  if (emptyResponse(response)) {
    return recoverDeviceStep(() => searchStart(event));
  }
  markDeviceHealthy();
  const json = bodyJson(response);
  if (json == null) {
    return FeedError.raise("search_failed", "番茄搜索回應不是有效的 JSON");
  }
  if (json.code !== undefined && json.code !== 0) {
    return FeedError.raise(
      "search_failed",
      json.message || `搜索失敗（code=${json.code}）`,
    );
  }

  if (state.direct) {
    const book = bookInfoFromDetail(json.data, state.direct);
    if (book.type === "fail") return book;
    return { type: "complete", result: [book] };
  }

  const { tab, items } = searchBooks(json);
  const passback = state.passback ?? 0;
  const hasMore = Boolean(tab?.has_more) && items.length > 0;
  // 回填服務端游標；未給時按已取回數量前推，至少不會原地打轉。
  const next = Number(tab?.passback) || passback + Math.max(items.length, 1);
  return hasMore
    ? { type: "complete", result: items, next_cursor: next }
    : { type: "complete", result: items };
}

function bookInfo(event) {
  if (event.state == null) return bookInfoStart(event);

  const pipelined = pipelineResponse(event);
  if (pipelined) return pipelined;

  const response = event.response;
  if (emptyResponse(response)) {
    return recoverDeviceStep(() => bookInfoStart(event));
  }
  markDeviceHealthy();
  const json = bodyJson(response);
  const book = bookInfoFromDetail(json?.data, event.state.bookInfo.bookId);
  if (book.type === "fail") return book;
  return { type: "complete", result: book };
}

function chapters(event) {
  if (event.state == null) return chaptersStart(event);

  const pipelined = pipelineResponse(event);
  if (pipelined) return pipelined;

  const state = event.state.chapters;
  const response = event.response;
  if (emptyResponse(response)) {
    return recoverDeviceStep(() => chaptersStart(event));
  }
  markDeviceHealthy();
  const json = bodyJson(response);
  const items = chapterItems(json);
  if (items) return { type: "complete", result: items };

  // APP 目錄端點數據不全時回落到番茄網頁站的免簽名目錄 API。
  if (!state.webFallback) {
    return {
      type: "request",
      request: {
        url: `https://fanqienovel.com/api/reader/directory/detail?bookId=${state.bookId}`,
        method: "GET",
        headers: { "User-Agent": WEB_USER_AGENT },
      },
      next_state: { chapters: { bookId: state.bookId, webFallback: true } },
    };
  }

  const allItems = json?.data?.allItemIds;
  const chaptersByVolume = json?.data?.chapterListWithVolume;
  if (!Array.isArray(allItems) || !Array.isArray(chaptersByVolume)) {
    return FeedError.contentNotFound("無法取得書籍目錄");
  }
  const items2 = [];
  const titleById = new Map();
  for (const volume of chaptersByVolume) {
    if (!Array.isArray(volume)) continue;
    for (const chapter of volume) {
      if (chapter?.itemId)
        titleById.set(String(chapter.itemId), String(chapter.title ?? ""));
    }
  }
  for (const itemId of allItems) {
    const id = String(itemId);
    items2.push({ id, title: titleById.get(id) ?? "" });
  }
  return items2.length
    ? { type: "complete", result: items2 }
    : FeedError.contentNotFound("無法取得書籍目錄");
}

function paragraphs(event) {
  if (event.state == null) return paragraphsStart(event);

  const pipelined = pipelineResponse(event);
  if (pipelined) return pipelined;

  // 段評計數（idea/list）響應：任何失敗均非致命——無計數照常完成
  // （角標是裝飾層，正文已到手，不值得爲計數報錯）。
  if (event.state.ideaCounts) {
    const items = event.state.ideaCounts.items;
    applyIdeaCounts(items, parseIdeaCounts(event.response));
    return { type: "complete", result: items };
  }

  const state = event.state.paragraphs;
  const response = event.response;
  if (emptyResponse(response)) {
    return recoverDeviceStep(() => paragraphsStart(event));
  }
  markDeviceHealthy();
  const json = bodyJson(response);
  const data = json?.data;
  if (!data) {
    return FeedError.contentNotFound(
      `無法取得章節正文（HTTP ${response.status}，回應非 JSON 或缺少 data）`,
    );
  }

  const keyinfo = currentKeyinfo();
  const expired =
    data.content === "Invalid" ||
    (data.key_version !== undefined &&
      Number(data.key_version) !== keyinfo?.keyver);
  if (expired && state.attempt < 2) {
    // 密鑰註冊失效：'Invalid' 時 keyver 可能仍與本地一致，必須強制重註冊
    // 而不是走緩存。
    dropKeyinfo();
    return refreshKeyStep(() =>
      appGetStep(
        "/reader/full/v",
        [
          ["item_id", state.chapterId],
          ["req_type", "1"],
        ],
        {
          paragraphs: {
            bookId: state.bookId,
            chapterId: state.chapterId,
            attempt: state.attempt + 1,
          },
        },
      ),
    );
  }
  if (!data.content || data.content === "Invalid") {
    return FeedError.contentNotFound(
      "章節正文不可用（密鑰重註冊後仍為 Invalid）",
    );
  }

  const plain = decryptChapter(data.content, data.compress_status);
  const items = contentParagraphs(plain);
  if (!items.length) {
    return FeedError.contentNotFound("章節正文解密後為空");
  }
  // 段評計數（角標）：idea/list 給出全章有評論段落的評論數 map（鍵爲
  // 0-based para_index，與 paragraphsFromHtml 賦的段落 id 對齊），配方
  // 移植自 mtongle 生產實現並經實測交叉驗證（idea/list count 與
  // comment/list total 一致）。設備已在流內注冊，直接設備籤名即可。
  return commentPostStep(
    `/novel/commentapi/idea/list/${state.chapterId}/v1`,
    {
      chapter_id: state.chapterId,
      item_version: "1",
      comment_source: 2,
      group_type: 15,
      business_param: { book_id: state.bookId },
    },
    { ideaCounts: { items } },
  );
}

// idea/list 響應：data.data 是「para_index 字符串 → {count,...}」的 map，
// 只有有評論的段落出現；code 非 0、結構缺失、JSON 壞損一律視爲無計數。
function parseIdeaCounts(response) {
  try {
    const payload = bodyJson(response);
    if (payload?.code !== 0) return null;
    const data = payload?.data?.data;
    if (data == null || typeof data !== "object") return null;
    return data;
  } catch (_) {
    return null;
  }
}

function applyIdeaCounts(items, data) {
  if (!data) return;
  for (const item of items) {
    if (item.type === "title" || item.id == null) continue;
    // 成功的 idea/list 覆蓋全章：不在 map 中的段落即零評論（已知），
    // 與「未知/不支持」區分開——契約語義與起點 summary 的補 0 一致。
    item.comment_count = toCount(data[item.id]?.count) ?? 0;
  }
}

// ── 段評與回覆（commentapi 中台，配方移植自 fqapp / mtongle 驗證實現）──
//
// POST {COMMENT_BASE}/novel/commentapi/comment/list/{chapterId}/v1
//      段評列表：comment_source=2、comment_type=1、group_type=15、
//      server_channel=38（38 是實測可用值，官方 presenter 的 43 恒返回
//      空，39 只對部分書有效）、group_id=章節 ID、business_param 內
//      book_id/item_version/para_index 缺一報 103001（item_version 可
//      硬編碼 "1"）。para_index 從正文第一個 <p> 起算（0-based，標題
//      不佔索引，空段照常遞增），與 paragraphsFromHtml 賦的段落 id 對
//      齊。
// POST {COMMENT_BASE}/novel/commentapi/reply/list/{commentId}/v1
//      回覆列表：comment_source=502，group_id 仍是章節 ID。
// 兩者 body 均爲 JSON，簽名復用 signHeaders(url, body)（X-SS-STUB 爲
// body 的 md5）。段評響應的條目在 data.data_list[i].comment（內容在
// .common、計數在 .stat 內部），回覆響應在 data.reply_list[i]（外層
// 鍵爲大寫 Common，reply_id 爲主鍵）；分頁統一在 data.common_list_info
// （cursor 是純數字字符串 offset，has_more 決定是否有下一頁）。

const COMMENT_COUNT = 20;
const REPLY_COUNT = 10;

// 評論請求的設備參數袋（fqapp 的 reading724Params，7.2.4.32 版本）。
// 型號字段是官方客戶端的硬編碼值，與註冊設備不同型號亦可用：簽名輸入
// 只有查詢串與請求體字節，不含這些字段。
function commentQuery() {
  const device = currentDevice();
  return encodeQuery([
    ["iid", device.install_id],
    ["device_id", device.device_id],
    ["ac", "wifi"],
    ["channel", "xiaomi_1967_64"],
    ["aid", AID],
    ["app_name", "novelapp"],
    ["version_code", "72432"],
    ["version_name", "7.2.4.32"],
    ["device_platform", "android"],
    ["os", "android"],
    ["ssmix", "a"],
    ["device_type", "25053RT47C"],
    ["device_brand", "Redmi"],
    ["language", "zh"],
    ["os_api", "36"],
    ["os_version", "16"],
    ["manifest_version_code", "72432"],
    ["resolution", "1280*2620"],
    ["dpi", "520"],
    ["update_version_code", "72432"],
    ["host_abi", "arm64-v8a"],
    ["dragon_device_type", "phone"],
    ["pv_player", "72432"],
    ["compliance_status", "0"],
    ["need_personal_recommend", "1"],
    ["player_so_load", "1"],
    ["is_android_pad_screen", "0"],
    ["rom_version", "miui_V816_OS3.0.9.0.WOLCNXM"],
  ]);
}

function commentPostStep(path, body, businessState) {
  const url = `${COMMENT_BASE}${path}?${commentQuery()}`;
  const bodyBytes = utf8(JSON.stringify(body));
  const headers = signHeaders(url, bodyBytes);
  headers["User-Agent"] = APP_USER_AGENT;
  headers["Content-Type"] = "application/json; charset=utf-8";
  return {
    type: "request",
    request: { url, method: "POST", headers, body: bodyBytes },
    next_state: businessState,
  };
}

function commentListStart(state) {
  const body = {
    business_param: {
      book_id: state.bookId,
      comment_sort_debug: false,
      end_offset_time: 0,
      fold_type: 1,
      item_count: 0,
      item_version: "1",
      max_item_count: 0,
      need_danmaku_occlusion_face_data: false,
      para_index: state.paraIndex,
      playlet_item_duration: 0,
      read_item_count: 0,
      req_type: 0,
      start_offset_time: 0,
      // need_count 只在首页（cursor 为空）为 true，与官方一致。
      need_count: !state.cursor,
    },
    comment_source: 2,
    comment_type: 1,
    count: COMMENT_COUNT,
    group_id: state.chapterId,
    group_type: 15,
    server_channel: 38,
    sort: 1,
  };
  if (state.cursor) body.cursor = state.cursor;
  return commentPostStep(
    `/novel/commentapi/comment/list/${state.chapterId}/v1`,
    body,
    { comments: state },
  );
}

function replyListStart(state) {
  const body = {
    aid: Number(AID),
    business_param: {
      book_id: state.bookId,
      client_ab_params: '{"comment_dislike_filter":"0"}',
      need_count: false,
    },
    comment_id: state.parentId,
    comment_source: 502,
    comment_type: 1,
    compliance_status: 0,
    count: REPLY_COUNT,
    cursor: state.cursor || "",
    group_id: state.chapterId,
    group_type: 15,
  };
  return commentPostStep(
    `/novel/commentapi/reply/list/${state.parentId}/v1`,
    body,
    { comments: state },
  );
}

function commentsStart(event) {
  const bookId = bookIdFromKeyword(String(event.input.bookId ?? ""));
  const chapterId = bookIdFromKeyword(String(event.input.chapterId ?? ""));
  if (!bookId || !chapterId) {
    return FeedError.contentNotFound("無效的書籍或章節 ID");
  }
  const paragraphId = String(event.input.paragraphId ?? "");
  const paraIndex = Number(paragraphId);
  if (!/^\d+$/.test(paragraphId) || !Number.isInteger(paraIndex)) {
    return FeedError.contentNotFound("無效的段落 ID");
  }
  const parentId = String(event.input.parentId ?? "");
  const state = {
    bookId,
    chapterId,
    paraIndex,
    parentId,
    cursor: event.cursor == null ? "" : String(event.cursor),
  };
  return ensureDeviceStep(() =>
    parentId ? replyListStart(state) : commentListStart(state),
  );
}

// 評論項的公共解析：common 承載內容與作者，stat 承載計數。
function toCount(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? Math.floor(number) : null;
}

function timestampMs(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  const milliseconds = seconds > 100_000_000_000 ? seconds : seconds * 1000;
  return milliseconds <= 8_640_000_000_000_000 ? milliseconds : null;
}

function commentText(content) {
  const text = String(content?.text ?? "").trim();
  if (text) return text;
  // 純圖片評論：content.image_data_list.image_data 存在即代表有圖。
  const images = content?.image_data_list?.image_data;
  return Array.isArray(images) && images.length ? "[圖片]" : "";
}

// ── 頭像 URL 改寫 ────────────────────────────────────────────────────────────
// commentapi 下發的頭像字節是 HEIC——官方 App 用系統解碼器渲染，本應用的
// UI 在 Android/Linux 上不解碼 HEIC；其主要形態還是 http 時效籤名 URL
// （明文流量被 Android 拒絕，x-expires 過期後整體失效）。同一對象在
// byteimg 公共 CDN 上以 ~tplv-{service}-expand:200:0:0.webp 形態無籤名
// 供應（https、全平臺可解碼、不過期），統一改寫成該形態。對象不支持該
// 模板時 CDN 返回 404，UI 落回默認頭像。
const AVATAR_SIGNED_RE =
  /^https?:\/\/p\d+-reading-sign\.fqnovelpic\.com\/(tos-cn-i-[a-z0-9-]+)\/([a-z0-9]+)~tplv-/i;
const AVATAR_CDN_RE = /^https?:\/\/p\d+-novel\.byteimg\.com\//i;

function avatarUrl(raw) {
  const url = String(raw ?? "").trim();
  if (!url) return null;
  const signed = AVATAR_SIGNED_RE.exec(url);
  if (signed) {
    // tos-cn-i-{service}/{object} 的籤名形態 → {service} 的 expand 模板。
    const [, bucket, objectId] = signed;
    const service = bucket.replace(/^tos-cn-i-/, "");
    return `https://p3-novel.byteimg.com/${bucket}/${objectId}~tplv-${service}-expand:200:0:0.webp`;
  }
  if (AVATAR_CDN_RE.test(url)) {
    // 無籤名形態：同一對象、同一模板，僅把擴展名換成 WebP 並升級 https。
    return url.replace(/^http:\/\//i, "https://").replace(/\.heic(\?|$)/i, ".webp$1");
  }
  return url;
}

function commentAuthor(common) {
  const base = common?.user_info?.base_info ?? {};
  return {
    name: String(base.user_name ?? "").trim() || "番茄書友",
    avatar_url: avatarUrl(base.user_avatar),
  };
}

function commentIdText(value) {
  if (value == null) return "";
  return typeof value === "number" ? value.toFixed(0) : String(value).trim();
}

function parseCommentItems(json) {
  const data = json?.data;
  if (data == null) return null;
  const items = [];
  // 段評條目在 data_list[i].comment（內容再嵌一層 common，計數在
  // comment.stat 內部）；回覆條目在 reply_list[i]，common 直接在外層
  // （官方序列化的鍵是大寫 Common，兩種都收）。歸一成 {common, stat, id}
  // 再解析。
  const entries = Array.isArray(data?.data_list)
    ? data.data_list.map((entry) => {
        const comment = entry?.comment;
        return {
          common: comment?.common,
          stat: comment?.stat ?? entry?.stat,
          id: comment?.comment_id,
        };
      })
    : Array.isArray(data?.reply_list)
      ? data.reply_list.map((entry) => ({
          common: entry?.Common ?? entry?.common,
          stat: entry?.stat,
          id: entry?.reply_id,
        }))
      : [];
  for (const entry of entries) {
    const id = commentIdText(entry.id);
    if (!id) continue;
    const text = commentText(entry.common?.content);
    if (!text) continue;
    const replyCount = toCount(entry.stat?.reply_count);
    items.push({
      id,
      author: commentAuthor(entry.common),
      text,
      created_at_ms: timestampMs(entry.common?.create_timestamp),
      like_count: toCount(entry.stat?.digg_count),
      // 回覆的回覆不再展開：段評條目帶回覆計數，回覆條目不帶。
      replies: replyCount == null ? null : { total_count: replyCount },
    });
  }
  const info = data.common_list_info ?? data.comment_list_info ?? {};
  const cursor = String(info?.cursor ?? "");
  const hasMore = info?.has_more === true && cursor !== "";
  return {
    items,
    total_count: toCount(info?.total),
    next_cursor: hasMore ? cursor : null,
  };
}

function comments(event) {
  if (event.state == null) return commentsStart(event);

  const pipelined = pipelineResponse(event);
  if (pipelined) return pipelined;

  const response = event.response;
  if (emptyResponse(response)) {
    return recoverDeviceStep(() => commentsStart(event));
  }
  markDeviceHealthy();
  const json = bodyJson(response);
  if (json == null) {
    return FeedError.sourceUnavailable("番茄評論回應不是有效的 JSON");
  }
  if (json.code !== undefined && json.code !== 0 && json.code !== 200) {
    return FeedError.sourceUnavailable(
      `番茄評論 API 返回錯誤（code=${json.code}，${json.message || "無錯誤消息"}）`,
    );
  }
  const page = parseCommentItems(json);
  if (page == null) {
    return FeedError.sourceUnavailable("番茄評論回應缺少數據");
  }
  return {
    type: "complete",
    result: { items: page.items, total_count: page.total_count },
    next_cursor: page.next_cursor,
  };
}

// 密鑰未就緒（或緩存不可用）時的公共入口：先重註冊密鑰再發正文請求。
function ensureKeyinfoStep(launch) {
  if (currentKeyinfo()) return launch();
  return refreshKeyStep(launch);
}

// 章評（group_id 對應的章評單元配方）官方客戶端未在 m 站/網頁暴露，
// 社區逆向也未驗證可用組合，故不導出 comments.chapter；宿主對缺失的
// 導出自動隱藏章評入口。段評與其回覆已完整支持。
export default {
  search,
  bookInfo,
  chapters,
  paragraphs,
  comments: { paragraph: comments },
};
