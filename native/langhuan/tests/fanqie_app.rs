//! Integration tests for the fanqie-app feed script (APP gateway route).
//!
//! Mocked tests serve the whole device-registration and reading flow from a
//! local mockito server: device register (ttencrypt body), privilege
//! activation, key registration, and the reading endpoints. The mock's
//! `registerkey` and `reader/full` responses are encrypted with the same
//! static keys the script uses (`shared_key`, the registered content key),
//! so a green test proves the script's decryption path, its multi-step
//! state machine, and the presence of the signing headers.
//!
//! Signing itself (`x-argus`/`x-ladon` correctness) can only be validated by
//! the real gateway — see the ignored live smoke test at the bottom.
//!
//! Network-facing URLs in the script are rewritten to the mock server and
//! the allowlist is restricted to localhost, mirroring `tests/fanqie.rs`.

use aes::cipher::{BlockEncryptMut, KeyIvInit, block_padding::Pkcs7};
use langhuan::error::Result;
use langhuan::feed::{Feed, SharedStorageHandler, StorageHandler};
use langhuan::script::runtime::ScriptEngine;
use mockito::ServerGuard;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Write as _;
use std::sync::{Arc, Mutex};
use tokio_stream::StreamExt as _;

type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;

const SHARED_KEY: [u8; 16] = [
    172, 37, 198, 125, 221, 143, 56, 193, 179, 122, 35, 72, 130, 142, 34, 46,
];
const DEVICE_ID: &str = "7345647812359704062";
const INSTALL_ID: &str = "7400000000000000001";
const BOOK_ID: &str = "7146230612570047006";
const CHAPTER_ID: &str = "1111111111111111111";
const KEYVER: u64 = 5;
/// Content key handed out by the mock `registerkey` endpoint.
const CONTENT_KEY: [u8; 16] = [
    0x51, 0x8f, 0x13, 0xa7, 0x22, 0x0c, 0x97, 0x4e, 0xd3, 0x66, 0x80, 0x19, 0xab, 0xf4, 0x2d, 0xc8,
];
/// Content key after a key refresh (registerkey returns this on retry).
const REFRESHED_CONTENT_KEY: [u8; 16] = [
    0x0a, 0xbb, 0x47, 0x91, 0xe2, 0x55, 0x3c, 0xfe, 0x18, 0x76, 0xd9, 0x04, 0x63, 0x8a, 0x21, 0xb7,
];

// ── Helpers ─────────────────────────────────────────────────────────────────

/// In-memory storage backend; tests inspect it to assert what the script
/// persisted.
#[derive(Default)]
struct MemoryStorage(Mutex<HashMap<(String, String), Value>>);

impl StorageHandler for MemoryStorage {
    fn get(&self, feed_id: &str, key: &str) -> Result<Option<Value>> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .get(&(feed_id.to_owned(), key.to_owned()))
            .cloned())
    }

    fn set(&self, feed_id: &str, key: &str, value: Value) -> Result<()> {
        self.0
            .lock()
            .unwrap()
            .insert((feed_id.to_owned(), key.to_owned()), value);
        Ok(())
    }

    fn delete(&self, feed_id: &str, key: &str) -> Result<()> {
        self.0
            .lock()
            .unwrap()
            .remove(&(feed_id.to_owned(), key.to_owned()));
        Ok(())
    }
}

/// Rewrite every network-facing URL in the script to the mock server and
/// restrict the domain allowlist to localhost.
fn load_script_for_server(server: &ServerGuard) -> String {
    let base = server.url();
    include_str!("../../../docs/book-sources/fanqie-app.js")
        .replace(
            "https://reading.snssdk.com/reading",
            &format!("{base}/reading"),
        )
        .replace(
            "https://i.snssdk.com/service/2/device_register/?tt_data=a",
            &format!("{base}/service/2/device_register/?tt_data=a"),
        )
        .replace(
            "https://fanqienovel.com/api/reader/directory/detail",
            &format!("{base}/api/reader/directory/detail"),
        )
        .replace(
            "// @base_url     https://reading.snssdk.com",
            &format!("// @base_url     {base}"),
        )
        .replace(
            "// @access_domain reading.snssdk.com",
            "// @access_domain 127.0.0.1",
        )
        .replace("// @access_domain i.snssdk.com", "")
        .replace("// @access_domain fanqienovel.com", "")
}

fn aes_cbc_encrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Vec<u8> {
    Aes128CbcEnc::new(key.into(), iv.into()).encrypt_padded_vec_mut::<Pkcs7>(data)
}

fn gzip(data: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(data).unwrap();
    encoder.finish().unwrap()
}

fn b64(data: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let triple = ((chunk[0] as u32) << 16)
            | ((chunk.get(1).copied().unwrap_or(0) as u32) << 8)
            | chunk.get(2).copied().unwrap_or(0) as u32;
        out.push(CHARS[(triple >> 18 & 0x3f) as usize] as char);
        out.push(CHARS[(triple >> 12 & 0x3f) as usize] as char);
        out.push(if chunk.len() > 1 {
            CHARS[(triple >> 6 & 0x3f) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            CHARS[(triple & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// The `registerkey` response body: `data.key` is
/// `base64(iv || AES-CBC(shared_key)(content_key))`.
fn registerkey_body(content_key: &[u8; 16], keyver: u64) -> String {
    let iv = [0x33u8; 16];
    let encrypted = aes_cbc_encrypt(&SHARED_KEY, &iv, content_key);
    let mut iv_and_ct = iv.to_vec();
    iv_and_ct.extend_from_slice(&encrypted);
    json!({
        "code": 0,
        "data": { "key": b64(&iv_and_ct), "keyver": keyver },
    })
    .to_string()
}

/// The `reader/full` response body: `data.content` is
/// `base64(iv || AES-CBC(content_key)(gzip(xhtml)))` with
/// `compress_status = 1`, matching how the real gateway serves chapters.
fn chapter_body(content_key: &[u8; 16], key_version: u64) -> String {
    let xhtml = "<h1>第1章 殞命</h1><p>第一段。</p><p>第二段。</p>".as_bytes();
    let gzipped = gzip(xhtml);
    let iv = [0x77u8; 16];
    let encrypted = aes_cbc_encrypt(content_key, &iv, &gzipped);
    let mut iv_and_ct = iv.to_vec();
    iv_and_ct.extend_from_slice(&encrypted);
    json!({
        "code": 0,
        "data": {
            "content": b64(&iv_and_ct),
            "key_version": key_version,
            "compress_status": 1,
        },
    })
    .to_string()
}

fn device_register_json() -> String {
    json!({
        "device_id": 123,
        "device_id_str": DEVICE_ID,
        "install_id_str": INSTALL_ID,
    })
    .to_string()
}

/// Assert that every mock received its expected calls (and, through the
/// header matchers below, that requests carried the signing headers).
macro_rules! assert_all {
    ($($mock:expr),* $(,)?) => {
        $(
            $mock.assert_async().await;
        )*
    };
}

// ── Device registration flow ────────────────────────────────────────────────

#[tokio::test]
async fn app_flow_registers_device_signs_and_reads_chapter() {
    let mut server = mockito::Server::new_async().await;

    let register = server
        .mock("POST", "/service/2/device_register/?tt_data=a")
        .match_header("content-type", "application/octet-stream; tt-data=a")
        .match_header("user-agent", "okhttp/4.10.0")
        .with_status(200)
        .with_body(device_register_json())
        .expect(1)
        .create_async()
        .await;
    let activate = server
        .mock("POST", "/reading/user/privilege/add/v")
        .match_query(mockito::Matcher::Any)
        .match_header("x-argus", mockito::Matcher::Regex(".+".into()))
        .match_header("x-ladon", mockito::Matcher::Regex(".+".into()))
        .match_header("x-khronos", mockito::Matcher::Regex(r"^\d+$".into()))
        .match_header(
            "x-ss-stub",
            mockito::Matcher::Regex(r"^[0-9a-f]{32}$".into()),
        )
        .with_status(200)
        .with_body(json!({ "code": 0, "data": { "expire_time": "2027-01-01" } }).to_string())
        .expect(1)
        .create_async()
        .await;
    let registerkey = server
        .mock("POST", "/reading/crypt/registerkey")
        .match_query(mockito::Matcher::Any)
        .match_header("content-encoding", "gzip")
        .match_header("x-argus", mockito::Matcher::Regex(".+".into()))
        .with_status(200)
        .with_body(registerkey_body(&CONTENT_KEY, KEYVER))
        .expect(1)
        .create_async()
        .await;
    let full = server
        .mock("GET", "/reading/reader/full/v")
        .match_query(mockito::Matcher::Any)
        .match_header("x-argus", mockito::Matcher::Regex(".+".into()))
        .match_header("user-agent", "com.dragon.read")
        .with_status(200)
        .with_body(chapter_body(&CONTENT_KEY, KEYVER))
        .expect(1)
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let storage = Arc::new(MemoryStorage::default());
    let engine = ScriptEngine::new().with_storage(storage.clone() as SharedStorageHandler);
    let feed = engine.load_script(&script).await.expect("load failed");

    let items: Vec<_> = feed.paragraphs(BOOK_ID, CHAPTER_ID).collect().await;

    assert_all!(register, activate, registerkey, full);

    let texts: Vec<String> = items
        .iter()
        .map(|item| {
            let item = item.as_ref().expect("paragraph item");
            let value = serde_json::to_value(item).unwrap();
            let object = value.as_object().unwrap();
            format!(
                "{}:{}",
                object.get("type").unwrap().as_str().unwrap(),
                object
                    .get("text")
                    .or_else(|| object.get("content"))
                    .unwrap()
                    .as_str()
                    .unwrap()
            )
        })
        .collect();
    assert_eq!(
        texts,
        vec![
            "title:第1章 殞命".to_owned(),
            "text:第一段。".to_owned(),
            "text:第二段。".to_owned(),
        ],
        "decrypted paragraphs"
    );

    // The registered device and content key are persisted for later
    // operations. `device_type` is a random model from the registration
    // body; assert its presence rather than its value.
    let device = storage
        .get("org.eu.ywxt.langhuan.fanqie_app", "device")
        .unwrap();
    let device = device.expect("device persisted");
    assert_eq!(device["device_id"], json!(DEVICE_ID));
    assert_eq!(device["install_id"], json!(INSTALL_ID));
    assert!(
        device["device_type"]
            .as_str()
            .is_some_and(|m| !m.is_empty()),
        "device_type is a random model: {device}"
    );
    let keyinfo = storage
        .get("org.eu.ywxt.langhuan.fanqie_app", "keyinfo")
        .unwrap();
    let keyinfo = keyinfo.expect("keyinfo persisted");
    assert_eq!(keyinfo["keyver"].as_f64(), Some(KEYVER as f64));
    assert_eq!(keyinfo["key"].as_str().map(str::len), Some(24));
}

// ── Empty-body device invalidation recovery ────────────────────────────────

#[tokio::test]
async fn app_flow_recovers_from_empty_response_by_reregistering() {
    let mut server = mockito::Server::new_async().await;

    // The reading endpoint first answers with 200 + empty body (device
    // invalidated). Mockito matches the most recently created mock first,
    // so the empty-body mock shadows the real one for the first call.
    let full = server
        .mock("GET", "/reading/reader/full/v")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body("")
        .expect(1)
        .create_async()
        .await;
    let full_retry = server
        .mock("GET", "/reading/reader/full/v")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(chapter_body(&CONTENT_KEY, KEYVER))
        .expect(1)
        .create_async()
        .await;
    let register = server
        .mock("POST", "/service/2/device_register/?tt_data=a")
        .with_status(200)
        .with_body(device_register_json())
        .expect(2)
        .create_async()
        .await;
    let activate = server
        .mock("POST", "/reading/user/privilege/add/v")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(json!({ "code": 0 }).to_string())
        .expect(2)
        .create_async()
        .await;
    let registerkey = server
        .mock("POST", "/reading/crypt/registerkey")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(registerkey_body(&CONTENT_KEY, KEYVER))
        .expect(2)
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let engine = ScriptEngine::new()
        .with_storage(Arc::new(MemoryStorage::default()) as SharedStorageHandler);
    let feed = engine.load_script(&script).await.expect("load failed");

    let items: Vec<_> = feed.paragraphs(BOOK_ID, CHAPTER_ID).collect().await;

    assert_all!(register, activate, registerkey, full, full_retry);
    assert_eq!(
        items.len(),
        3,
        "expected title + two paragraphs after device replacement"
    );
}

// ── Content key invalidation ('Invalid') triggers re-registration ──────────

#[tokio::test]
async fn app_flow_rekeys_when_content_is_invalid() {
    let mut server = mockito::Server::new_async().await;

    let register = server
        .mock("POST", "/service/2/device_register/?tt_data=a")
        .with_status(200)
        .with_body(device_register_json())
        .expect(1)
        .create_async()
        .await;
    let activate = server
        .mock("POST", "/reading/user/privilege/add/v")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(json!({ "code": 0 }).to_string())
        .expect(1)
        .create_async()
        .await;
    // Mockito serves the first (in creation order) matching mock that has
    // not yet reached its expect() count, so mocks are created in the order
    // the flow is expected to hit them: the initial registration gets
    // keyver 5, the refresh after 'Invalid' gets the rotated keyver 6.
    let registerkey_initial = server
        .mock("POST", "/reading/crypt/registerkey")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(registerkey_body(&CONTENT_KEY, KEYVER))
        .expect(1)
        .create_async()
        .await;
    let registerkey_refreshed = server
        .mock("POST", "/reading/crypt/registerkey")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(registerkey_body(&REFRESHED_CONTENT_KEY, KEYVER + 1))
        .expect(1)
        .create_async()
        .await;
    // First chapter answer reports 'Invalid' (key registration expired on
    // the server); the retry returns content under the rotated key.
    let full_invalid = server
        .mock("GET", "/reading/reader/full/v")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(json!({ "code": 0, "data": { "content": "Invalid" } }).to_string())
        .expect(1)
        .create_async()
        .await;
    let full = server
        .mock("GET", "/reading/reader/full/v")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(chapter_body(&REFRESHED_CONTENT_KEY, KEYVER + 1))
        .expect(1)
        .create_async()
        .await;

    let script = load_script_for_server(&server);
    let storage = Arc::new(MemoryStorage::default());
    let engine = ScriptEngine::new().with_storage(storage.clone() as SharedStorageHandler);
    let feed = engine.load_script(&script).await.expect("load failed");

    let items: Vec<_> = feed.paragraphs(BOOK_ID, CHAPTER_ID).collect().await;

    assert_all!(
        register,
        activate,
        registerkey_initial,
        registerkey_refreshed,
        full_invalid,
        full
    );
    assert_eq!(items.len(), 3, "expected paragraphs after rekey");

    let keyinfo = storage
        .get("org.eu.ywxt.langhuan.fanqie_app", "keyinfo")
        .unwrap();
    let keyinfo = keyinfo.expect("keyinfo persisted");
    assert_eq!(keyinfo["keyver"].as_f64(), Some((KEYVER + 1) as f64));
}

// ── Live gateway smoke ──────────────────────────────────────────────────────

/// Real-gateway smoke test against reading.snssdk.com / i.snssdk.com.
///
/// Ignored by default: it depends on external network, gateway availability,
/// and the target's willingness to register a device from the caller's
/// network. It is the only check that the x-argus/x-ladon signatures are
/// accepted as correct (mocked tests cannot validate that).
#[tokio::test]
#[ignore = "hits real app gateway"]
async fn live_gateway_smoke() {
    let script = include_str!("../../../docs/book-sources/fanqie-app.js");
    let engine = ScriptEngine::new()
        .with_storage(Arc::new(MemoryStorage::default()) as SharedStorageHandler);
    let feed = engine.load_script(script).await.expect("load failed");

    let search_future = feed.search("深空").take(10).collect::<Vec<_>>();
    let results = tokio::time::timeout(std::time::Duration::from_secs(60), search_future)
        .await
        .expect("live search timed out after 60s");
    let keyword_items: Vec<_> = results
        .into_iter()
        .collect::<std::result::Result<Vec<_>, _>>()
        .expect("live keyword search yielded an error");
    assert!(
        !keyword_items.is_empty(),
        "keyword search returned no items"
    );

    let book = feed
        .book_info(&keyword_items[0].id)
        .await
        .expect("book_info");
    let chapters: Vec<_> = feed.chapters(&book.id).collect().await;
    let chapters: Vec<_> = chapters
        .into_iter()
        .collect::<std::result::Result<Vec<_>, _>>()
        .expect("live chapters yielded an error");
    assert!(!chapters.is_empty(), "no chapters");

    let first_chapter = &chapters[0];
    let paragraphs: Vec<_> = feed.paragraphs(&book.id, &first_chapter.id).collect().await;
    let paragraphs: Vec<_> = paragraphs
        .into_iter()
        .collect::<std::result::Result<Vec<_>, _>>()
        .expect("live paragraphs yielded an error");
    assert!(!paragraphs.is_empty(), "no paragraphs");
}

/// Real-gateway VIP verification: reads a web-gated chapter anonymously.
///
/// Ignored like `live_gateway_smoke`. The public, unsigned web directory
/// API marks most chapters of a book `isChapterLock: true` — everything
/// past the ~10-chapter free preview, exactly the chapters the web route
/// renders as the SVIP login wall. This test confirms the wall on the web
/// reader page, then reads the same chapter through the app gateway —
/// verifying first-hand the route's core claim: web-gated chapters decrypt
/// to full text with no account.
#[tokio::test]
#[ignore = "hits real website"]
async fn live_vip_chapter_decrypts_anonymously() {
    const BROWSER_UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
                              (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
    let script = include_str!("../../../docs/book-sources/fanqie-app.js");
    let engine = ScriptEngine::new()
        .with_storage(Arc::new(MemoryStorage::default()) as SharedStorageHandler);
    let feed = engine.load_script(script).await.expect("load failed");

    let search_future = feed.search("深空").take(10).collect::<Vec<_>>();
    let results = tokio::time::timeout(std::time::Duration::from_secs(60), search_future)
        .await
        .expect("live search timed out after 60s");
    let books: Vec<_> = results
        .into_iter()
        .collect::<std::result::Result<Vec<_>, _>>()
        .expect("live search yielded an error");
    assert!(!books.is_empty(), "no search results to probe");

    let client = langhuan::http::shared_client();
    for book in books.iter().take(5) {
        let response = client
            .get(format!(
                "https://fanqienovel.com/api/reader/directory/detail?bookId={}",
                book.id
            ))
            .header("User-Agent", BROWSER_UA)
            .send()
            .await
            .expect("web directory request");
        let text = response.text().await.expect("web directory text");
        let directory: Value = serde_json::from_str(&text).expect("web directory json");
        let volumes = directory["data"]["chapterListWithVolume"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let mut total = 0usize;
        let mut locked = 0usize;
        let mut gated_chapter = None;
        for volume in &volumes {
            for chapter in volume.as_array().into_iter().flatten() {
                total += 1;
                let chapter_locked = chapter["isChapterLock"].as_bool().unwrap_or(false);
                locked += usize::from(chapter_locked);
                if chapter_locked && gated_chapter.is_none() {
                    gated_chapter = Some(
                        chapter["itemId"]
                            .as_str()
                            .expect("locked chapter itemId")
                            .to_owned(),
                    );
                }
            }
        }
        let Some(chapter_id) = gated_chapter else {
            eprintln!("book {} has no locked chapters, trying next", book.id);
            continue;
        };
        eprintln!(
            "book {} ({}): {total} chapters, isChapterLock={locked}; first locked is {chapter_id}",
            book.id, book.title
        );

        // Confirm the web route really gates this chapter (SVIP wall marker
        // in the server-rendered reader page).
        let page = client
            .get(format!("https://fanqienovel.com/reader/{chapter_id}"))
            .header("User-Agent", BROWSER_UA)
            .send()
            .await
            .expect("web reader page request")
            .text()
            .await
            .expect("web reader page text");
        let web_gated = page.contains("muye-to-vip-login");
        eprintln!("web reader page gates this chapter: {web_gated}");
        assert!(web_gated, "expected the web route to gate this chapter");

        // The app gateway should hand over the full chapter anonymously.
        let paragraphs: Vec<_> = feed.paragraphs(&book.id, &chapter_id).collect().await;
        let paragraphs: Vec<_> = paragraphs
            .into_iter()
            .collect::<std::result::Result<Vec<_>, _>>()
            .expect("live gated chapter yielded an error");
        assert!(
            !paragraphs.is_empty(),
            "web-gated chapter decrypted to zero paragraphs"
        );
        return;
    }
    panic!("no locked chapter found among the first search results");
}
