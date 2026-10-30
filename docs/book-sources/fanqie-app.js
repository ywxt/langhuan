// ==Feed==
// @id           org.eu.ywxt.langhuan.fanqie_app
// @name         番茄小說（APP 直連）
// @version      1.0.0
// @author       Langhuan
// @description  番茄小說 APP 網關書源（reading.snssdk.com）：匿名設備註冊後經 x-argus/x-ladon 簽名直連閱讀 API，VIP 章節全文解密，無需帳號。需要宿主提供存儲後端（langhuan:storage）
// @base_url     https://reading.snssdk.com
// @access_domain reading.snssdk.com
// @access_domain i.snssdk.com
// @access_domain fanqienovel.com
// @schema_version 4
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
const REGISTER_URL = "https://i.snssdk.com/service/2/device_register/?tt_data=a";
const APP_USER_AGENT = "com.dragon.read";
const OKHTTP_UA = "okhttp/4.10.0";
// 目錄回退走番茄網頁站的免簽名 API，用瀏覽器 UA（上游經頁面 fetch 訪問）。
const WEB_USER_AGENT =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

const LOW_RAND = new Uint8Array([0xf2, 0x81]);
const HIGH_RAND = new Uint8Array([0x61, 0x6f]); // 'a', 'o'
const XOR_PREFIX = new Uint8Array([0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff]);
const ARGUS_HEADER = new Uint8Array([0xa6, 0x6e, 0xad, 0x9f, 0x77, 0x01, 0xd0, 0x0c, 0x18]);

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
  "RMX1931", "MI8", "Honor10", "P30", "V1921A",
  "Redmi Note 7", "Redmi K20 Pro", "MI 9", "Mi 10 Pro",
  "SM-G9750", "Pixel 6", "HD1910", "M2011K2C",
  "LIO-AN00", "VOG-TL00", "PCLM10", "GM1900",
  "Pixel 7 Pro", "Pixel 6a", "SM-N9760", "POCO F1",
];
const DEVICE_BRANDS = [
  "realme", "Xiaomi", "Huawei", "OPPO", "vivo",
  "samsung", "OnePlus", "google", "Redmi", "HONOR", "motorola", "POCO",
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
  return Bytes.toHex(Crypto.md5(typeof input === "string" ? utf8(input) : input));
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
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
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
// 由同一字符串構造，故不用宿主的 params 拼接。
function formEncode(value) {
  return encodeURIComponent(String(value)).replace(/%20/g, "+");
}

function encodeQuery(params) {
  return params.map(([key, value]) => `${key}=${formEncode(value)}`).join("&");
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

  const bodyHash = sm3Prefix6(xssStub === "" ? new Uint8Array(16) : decodeStub(xssStub));
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
    "." + String(randomInt(1_000_000)).padStart(6, "0") +
    "." + String(randomInt(100_000_000)).padStart(8, "0") +
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
  storage.set("keyinfo", { key: Bytes.toBase64(keyinfo.key), keyver: keyinfo.keyver });
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
    next_state: { pipeline: "register", deviceType: body.header.device_model, launch },
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
    request: { url, method: "POST", headers, body },
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
  const body = JSON.stringify({ content: Bytes.toBase64(concat(iv, encrypted)) });
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
  const body = JSON.stringify({ content: Bytes.toBase64(concat(iv, encrypted)) });
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
    : cells.filter((cell) => Array.isArray(cell?.book_data) && cell.book_data.length);

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
  if (json?.code !== 0 || !Array.isArray(items) || items.length === 0) return null;
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
  const title = document.select("h1, h2").first()?.text().trim();
  if (title) items.push({ type: "title", text: title });
  for (const paragraph of document.select("p")) {
    const content = paragraph.text().trim();
    if (content) items.push({ type: "text", content });
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
  if (!keyword) return { type: "complete", items: [] };
  const passback = event.cursor == null ? 0 : Number(event.cursor);
  const direct = bookIdFromKeyword(keyword);
  return ensureDeviceStep(() =>
    direct
      ? appGetStep("/bookapi/detail/v", [["book_id", direct]], { search: { direct } })
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
    appGetStep("/bookapi/detail/v", [["book_id", bookId]], { bookInfo: { bookId } }),
  );
}

function chaptersStart(event) {
  const bookId = bookIdFromKeyword(String(event.input.bookId ?? ""));
  if (!bookId) return FeedError.contentNotFound("無效的書籍 ID");
  return ensureDeviceStep(() =>
    appGetStep(
      "/bookapi/directory/all_items/v",
      [["book_id", bookId]],
      { chapters: { bookId, webFallback: false } },
    ),
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
    return FeedError.raise("search_failed", json.message || `搜索失敗（code=${json.code}）`);
  }

  if (state.direct) {
    const book = bookInfoFromDetail(json.data, state.direct);
    if (book.type === "fail") return book;
    return { type: "complete", items: [book] };
  }

  const { tab, items } = searchBooks(json);
  const passback = state.passback ?? 0;
  const hasMore = Boolean(tab?.has_more) && items.length > 0;
  // 回填服務端游標；未給時按已取回數量前推，至少不會原地打轉。
  const next = Number(tab?.passback) || passback + Math.max(items.length, 1);
  return hasMore
    ? { type: "complete", items, next_cursor: next }
    : { type: "complete", items };
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
  return { type: "complete", value: book };
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
  if (items) return { type: "complete", items };

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
      if (chapter?.itemId) titleById.set(String(chapter.itemId), String(chapter.title ?? ""));
    }
  }
  for (const itemId of allItems) {
    const id = String(itemId);
    items2.push({ id, title: titleById.get(id) ?? "" });
  }
  return items2.length
    ? { type: "complete", items: items2 }
    : FeedError.contentNotFound("無法取得書籍目錄");
}

function paragraphs(event) {
  if (event.state == null) return paragraphsStart(event);

  const pipelined = pipelineResponse(event);
  if (pipelined) return pipelined;

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
    (data.key_version !== undefined && Number(data.key_version) !== keyinfo?.keyver);
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
        { paragraphs: { bookId: state.bookId, chapterId: state.chapterId, attempt: state.attempt + 1 } },
      ),
    );
  }
  if (!data.content || data.content === "Invalid") {
    return FeedError.contentNotFound("章節正文不可用（密鑰重註冊後仍為 Invalid）");
  }

  const plain = decryptChapter(data.content, data.compress_status);
  const items = contentParagraphs(plain);
  if (!items.length) {
    return FeedError.contentNotFound("章節正文解密後為空");
  }
  return { type: "complete", items };
}

// 密鑰未就緒（或緩存不可用）時的公共入口：先重註冊密鑰再發正文請求。
function ensureKeyinfoStep(launch) {
  if (currentKeyinfo()) return launch();
  return refreshKeyStep(launch);
}

export default { search, bookInfo, chapters, paragraphs };
