//! The `langhuan:crypto` module: cryptography and compression.
//!
//! Book sources need to run the same algorithms sites use — digests, HMAC,
//! AES, Simon/Speck signing ciphers, and gzip — but the sandbox must never
//! hand them a native code loader. Everything here is a pure function over
//! explicit arguments, so it is safe to declare in the feed realm and in
//! every disposable compute realm.

use aes::cipher::block_padding::{NoPadding, Pkcs7};
use aes::cipher::{BlockDecryptMut, BlockEncryptMut, KeyInit, KeyIvInit, StreamCipher};
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::{DeflateEncoder, GzEncoder};
use hmac::Mac;
use rquickjs::module::{Declarations, Exports, ModuleDef};
use rquickjs::{Ctx, Exception, FromJs, Object, Result as JsResult, TypedArray, Value as JsValue};
use sha2::Digest;

use super::bridge::{Fields, conversion_detail, typed_bytes};
use super::module::{Namespace, declare_module};

/// Upper bound for decompressed output, matching the QuickJS heap limit.
const MAX_EXPANSION_BYTES: usize = 32 * 1024 * 1024;
/// Upper bound for `Crypto.randomBytes`.
const MAX_RANDOM_BYTES: usize = 1024 * 1024;

/// The `langhuan:crypto` module: `Crypto` and `Compression`.
struct CryptoModule;

impl ModuleDef for CryptoModule {
    fn declare<'js>(declarations: &Declarations<'js>) -> JsResult<()> {
        declarations.declare("Crypto")?.declare("Compression")?;
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> JsResult<()> {
        exports.export("Crypto", crypto(ctx)?)?;
        exports.export("Compression", compression(ctx)?)?;
        Ok(())
    }
}

/// Declare the `langhuan:crypto` module in the realm.
pub(super) fn declare<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    declare_module::<CryptoModule>(ctx, "langhuan:crypto")
}

fn crypto<'js>(ctx: &Ctx<'js>) -> JsResult<Object<'js>> {
    Ok(Namespace::new(ctx)?
        .function("md5", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<md5::Md5>(&ctx, &data)
        })?
        .function("sha1", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sha1::Sha1>(&ctx, &data)
        })?
        .function("sha256", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sha2::Sha256>(&ctx, &data)
        })?
        .function("sha512", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sha2::Sha512>(&ctx, &data)
        })?
        .function("sm3", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sm3::Sm3>(&ctx, &data)
        })?
        .function(
            "hmac",
            |ctx: Ctx<'js>,
             algorithm: String,
             key: TypedArray<'js, u8>,
             data: TypedArray<'js, u8>| {
                let key = typed_bytes(&ctx, &key)?;
                let data = typed_bytes(&ctx, &data)?;
                let mac = hmac_digest(&algorithm, &key, &data).ok_or_else(|| {
                    Exception::throw_message(
                        &ctx,
                        &format!("Crypto.hmac: unknown algorithm {algorithm:?}"),
                    )
                })?;
                bytes_out(&ctx, mac)
            },
        )?
        .function(
            "aes",
            |ctx: Ctx<'js>, options: JsValue<'js>| -> JsResult<TypedArray<'js, u8>> {
                let request = AesRequest::from_js(&ctx, options).map_err(|error| {
                    Exception::throw_message(
                        &ctx,
                        &format!("Crypto.aes: {}", conversion_detail(error)),
                    )
                })?;
                let output = aes_run(&ctx, &request)?;
                bytes_out(&ctx, output)
            },
        )?
        .function(
            "simon",
            |ctx: Ctx<'js>, key: TypedArray<'js, u8>, data: TypedArray<'js, u8>| {
                let key = typed_bytes(&ctx, &key)?;
                let data = typed_bytes(&ctx, &data)?;
                let output = simon_run(&key, &data).map_err(|message| {
                    Exception::throw_message(&ctx, &format!("Crypto.simon: {message}"))
                })?;
                bytes_out(&ctx, output)
            },
        )?
        .function(
            "speck",
            |ctx: Ctx<'js>, key: TypedArray<'js, u8>, data: TypedArray<'js, u8>| {
                let key = typed_bytes(&ctx, &key)?;
                let data = typed_bytes(&ctx, &data)?;
                let output = speck_run(&key, &data).map_err(|message| {
                    Exception::throw_message(&ctx, &format!("Crypto.speck: {message}"))
                })?;
                bytes_out(&ctx, output)
            },
        )?
        .function(
            "randomBytes",
            |ctx: Ctx<'js>, length: usize| -> JsResult<TypedArray<'js, u8>> {
                if length == 0 || length > MAX_RANDOM_BYTES {
                    return Err(Exception::throw_message(
                        &ctx,
                        &format!(
                            "Crypto.randomBytes: length must be between 1 and {MAX_RANDOM_BYTES}"
                        ),
                    ));
                }
                let mut buffer = vec![0u8; length];
                getrandom::fill(&mut buffer).map_err(|_| {
                    Exception::throw_message(&ctx, "Crypto.randomBytes: system RNG failed")
                })?;
                bytes_out(&ctx, buffer)
            },
        )?
        .object())
}

fn compression<'js>(ctx: &Ctx<'js>) -> JsResult<Object<'js>> {
    Ok(Namespace::new(ctx)?
        .function("gzip", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = gzip_encode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.gzip: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?
        .function("gunzip", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = gzip_decode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.gunzip: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?
        .function("deflateRaw", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = deflate_raw_encode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.deflateRaw: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?
        .function("inflateRaw", |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = inflate_raw_decode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.inflateRaw: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?
        .object())
}

// ---------------------------------------------------------------------------
// Digests and HMAC
// ---------------------------------------------------------------------------

fn digest_call<'js, D>(ctx: &Ctx<'js>, data: &TypedArray<'js, u8>) -> JsResult<TypedArray<'js, u8>>
where
    D: Digest,
{
    let bytes = typed_bytes(ctx, data)?;
    let mut hasher = D::new();
    hasher.update(&bytes);
    bytes_out(ctx, hasher.finalize().to_vec())
}

/// HMAC over the supported digest algorithms.
fn hmac_digest(algorithm: &str, key: &[u8], data: &[u8]) -> Option<Vec<u8>> {
    type HmacMd5 = hmac::Hmac<md5::Md5>;
    type HmacSha1 = hmac::Hmac<sha1::Sha1>;
    type HmacSha256 = hmac::Hmac<sha2::Sha256>;
    type HmacSha512 = hmac::Hmac<sha2::Sha512>;
    type HmacSm3 = hmac::Hmac<sm3::Sm3>;
    match algorithm {
        "md5" => Some(hmac_of::<HmacMd5>(key, data)),
        "sha1" => Some(hmac_of::<HmacSha1>(key, data)),
        "sha256" => Some(hmac_of::<HmacSha256>(key, data)),
        "sha512" => Some(hmac_of::<HmacSha512>(key, data)),
        "sm3" => Some(hmac_of::<HmacSm3>(key, data)),
        _ => None,
    }
}

fn hmac_of<M>(key: &[u8], data: &[u8]) -> Vec<u8>
where
    M: Mac + KeyInit,
{
    let mut mac = <M as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

// ---------------------------------------------------------------------------
// AES
// ---------------------------------------------------------------------------

/// The `Crypto.aes` options, extracted from the options object.
struct AesRequest {
    op: String,
    mode: String,
    key: Vec<u8>,
    iv: Option<Vec<u8>>,
    data: Vec<u8>,
    padding: Option<String>,
    aad: Option<Vec<u8>>,
}

impl<'js> FromJs<'js> for AesRequest {
    fn from_js(ctx: &Ctx<'js>, value: JsValue<'js>) -> JsResult<Self> {
        let fields = Fields::new(value, "AesRequest")?;
        Ok(Self {
            op: fields.required_string("op")?,
            mode: fields.required_string("mode")?,
            key: fields.required_bytes(ctx, "key")?,
            iv: fields.optional_bytes(ctx, "iv")?,
            data: fields.required_bytes(ctx, "data")?,
            padding: fields.optional_string("padding")?,
            aad: fields.optional_bytes(ctx, "aad")?,
        })
    }
}

#[derive(Clone, Copy)]
enum Op {
    Encrypt,
    Decrypt,
}

#[derive(Clone, Copy)]
enum Mode {
    Cbc,
    Ecb,
    Ctr,
    Gcm,
}

impl Mode {
    /// Whether the mode applies block padding at all.
    const fn padded(self) -> bool {
        matches!(self, Mode::Cbc | Mode::Ecb)
    }

    fn from_label(label: &str) -> Option<Self> {
        match label {
            "cbc" => Some(Mode::Cbc),
            "ecb" => Some(Mode::Ecb),
            "ctr" => Some(Mode::Ctr),
            "gcm" => Some(Mode::Gcm),
            _ => None,
        }
    }
}

#[derive(Clone, Copy)]
enum Padding {
    Pkcs7,
    None,
}

fn aes_run<'js>(ctx: &Ctx<'js>, request: &AesRequest) -> JsResult<Vec<u8>> {
    let fail = |message: String| Exception::throw_message(ctx, &format!("Crypto.aes: {message}"));
    let op = match request.op.as_str() {
        "encrypt" => Op::Encrypt,
        "decrypt" => Op::Decrypt,
        other => {
            return Err(fail(format!(
                "`op` must be \"encrypt\" or \"decrypt\", got {other:?}"
            )));
        }
    };
    let Some(mode) = Mode::from_label(&request.mode) else {
        return Err(fail(format!("unknown mode {:?}", request.mode)));
    };
    let padding = parse_padding(mode.padded(), request.padding.as_deref()).map_err(fail)?;
    let iv = match (mode, request.iv.as_deref()) {
        (Mode::Ecb, Some(_)) => return Err(fail("`iv` must be omitted for ecb".to_owned())),
        (Mode::Ecb, None) => &[][..],
        (Mode::Cbc, None) => return Err(fail("`iv` is required for cbc".to_owned())),
        (Mode::Ctr, None) => return Err(fail("`iv` is required for ctr".to_owned())),
        (Mode::Gcm, None) => return Err(fail("`iv` (the nonce) is required for gcm".to_owned())),
        (_, Some(iv)) => iv,
    };
    match mode {
        Mode::Cbc => cbc_run(op, &request.key, iv, &request.data, padding),
        Mode::Ecb => ecb_run(op, &request.key, &request.data, padding),
        Mode::Ctr => ctr_run(&request.key, iv, &request.data),
        Mode::Gcm => gcm_run(
            op,
            &request.key,
            iv,
            &request.data,
            request.aad.as_deref().unwrap_or_default(),
        ),
    }
    .map_err(fail)
}

/// Resolve the `padding` option: block modes default to PKCS#7, stream modes
/// reject any label but an explicit `"none"`.
fn parse_padding(padded: bool, label: Option<&str>) -> Result<Padding, String> {
    match (padded, label) {
        (false, None | Some("none")) | (true, Some("none")) => Ok(Padding::None),
        (true, None | Some("pkcs7")) => Ok(Padding::Pkcs7),
        (_, Some(other)) => Err(format!(
            "`padding` must be \"pkcs7\" or \"none\", got {other:?}"
        )),
    }
}

fn cbc_run(
    op: Op,
    key: &[u8],
    iv: &[u8],
    data: &[u8],
    padding: Padding,
) -> Result<Vec<u8>, String> {
    macro_rules! enc {
        ($ctor:ty, $pad:ty) => {{
            let cipher = <$ctor as KeyIvInit>::new_from_slices(key, iv)
                .map_err(|_| "invalid key or iv length".to_owned())?;
            Ok(cipher.encrypt_padded_vec_mut::<$pad>(data))
        }};
    }
    macro_rules! dec {
        ($ctor:ty, $pad:ty) => {{
            let cipher = <$ctor as KeyIvInit>::new_from_slices(key, iv)
                .map_err(|_| "invalid key or iv length".to_owned())?;
            cipher.decrypt_padded_vec_mut::<$pad>(data).map_err(|_| {
                "decryption failed (wrong key/iv, corrupted data, or bad padding)".to_owned()
            })
        }};
    }
    match (op, key.len(), padding) {
        (Op::Encrypt, 16, Padding::Pkcs7) => enc!(cbc::Encryptor<aes::Aes128>, Pkcs7),
        (Op::Encrypt, 16, Padding::None) => enc!(cbc::Encryptor<aes::Aes128>, NoPadding),
        (Op::Encrypt, 24, Padding::Pkcs7) => enc!(cbc::Encryptor<aes::Aes192>, Pkcs7),
        (Op::Encrypt, 24, Padding::None) => enc!(cbc::Encryptor<aes::Aes192>, NoPadding),
        (Op::Encrypt, 32, Padding::Pkcs7) => enc!(cbc::Encryptor<aes::Aes256>, Pkcs7),
        (Op::Encrypt, 32, Padding::None) => enc!(cbc::Encryptor<aes::Aes256>, NoPadding),
        (Op::Decrypt, 16, Padding::Pkcs7) => dec!(cbc::Decryptor<aes::Aes128>, Pkcs7),
        (Op::Decrypt, 16, Padding::None) => dec!(cbc::Decryptor<aes::Aes128>, NoPadding),
        (Op::Decrypt, 24, Padding::Pkcs7) => dec!(cbc::Decryptor<aes::Aes192>, Pkcs7),
        (Op::Decrypt, 24, Padding::None) => dec!(cbc::Decryptor<aes::Aes192>, NoPadding),
        (Op::Decrypt, 32, Padding::Pkcs7) => dec!(cbc::Decryptor<aes::Aes256>, Pkcs7),
        (Op::Decrypt, 32, Padding::None) => dec!(cbc::Decryptor<aes::Aes256>, NoPadding),
        _ => Err("key must be 16, 24, or 32 bytes".to_owned()),
    }
}

fn ecb_run(op: Op, key: &[u8], data: &[u8], padding: Padding) -> Result<Vec<u8>, String> {
    macro_rules! enc {
        ($ctor:ty, $pad:ty) => {{
            let cipher = <$ctor as KeyInit>::new_from_slice(key)
                .map_err(|_| "invalid key length".to_owned())?;
            Ok(cipher.encrypt_padded_vec_mut::<$pad>(data))
        }};
    }
    macro_rules! dec {
        ($ctor:ty, $pad:ty) => {{
            let cipher = <$ctor as KeyInit>::new_from_slice(key)
                .map_err(|_| "invalid key length".to_owned())?;
            cipher.decrypt_padded_vec_mut::<$pad>(data).map_err(|_| {
                "decryption failed (wrong key, corrupted data, or bad padding)".to_owned()
            })
        }};
    }
    match (op, key.len(), padding) {
        (Op::Encrypt, 16, Padding::Pkcs7) => enc!(ecb::Encryptor<aes::Aes128>, Pkcs7),
        (Op::Encrypt, 16, Padding::None) => enc!(ecb::Encryptor<aes::Aes128>, NoPadding),
        (Op::Encrypt, 24, Padding::Pkcs7) => enc!(ecb::Encryptor<aes::Aes192>, Pkcs7),
        (Op::Encrypt, 24, Padding::None) => enc!(ecb::Encryptor<aes::Aes192>, NoPadding),
        (Op::Encrypt, 32, Padding::Pkcs7) => enc!(ecb::Encryptor<aes::Aes256>, Pkcs7),
        (Op::Encrypt, 32, Padding::None) => enc!(ecb::Encryptor<aes::Aes256>, NoPadding),
        (Op::Decrypt, 16, Padding::Pkcs7) => dec!(ecb::Decryptor<aes::Aes128>, Pkcs7),
        (Op::Decrypt, 16, Padding::None) => dec!(ecb::Decryptor<aes::Aes128>, NoPadding),
        (Op::Decrypt, 24, Padding::Pkcs7) => dec!(ecb::Decryptor<aes::Aes192>, Pkcs7),
        (Op::Decrypt, 24, Padding::None) => dec!(ecb::Decryptor<aes::Aes192>, NoPadding),
        (Op::Decrypt, 32, Padding::Pkcs7) => dec!(ecb::Decryptor<aes::Aes256>, Pkcs7),
        (Op::Decrypt, 32, Padding::None) => dec!(ecb::Decryptor<aes::Aes256>, NoPadding),
        _ => Err("key must be 16, 24, or 32 bytes".to_owned()),
    }
}

fn ctr_run(key: &[u8], iv: &[u8], data: &[u8]) -> Result<Vec<u8>, String> {
    macro_rules! run {
        ($ctor:ty) => {{
            let mut cipher = <$ctor as KeyIvInit>::new_from_slices(key, iv)
                .map_err(|_| "invalid key or iv length (iv must be 16 bytes)".to_owned())?;
            let mut buffer = data.to_vec();
            cipher.apply_keystream(&mut buffer);
            buffer
        }};
    }
    match key.len() {
        16 => Ok(run!(ctr::Ctr128BE<aes::Aes128>)),
        24 => Ok(run!(ctr::Ctr128BE<aes::Aes192>)),
        32 => Ok(run!(ctr::Ctr128BE<aes::Aes256>)),
        _ => Err("key must be 16, 24, or 32 bytes".to_owned()),
    }
}

fn gcm_run(op: Op, key: &[u8], iv: &[u8], data: &[u8], aad: &[u8]) -> Result<Vec<u8>, String> {
    use aes_gcm::aead::{Aead, Payload};
    macro_rules! run {
        ($ctor:ty) => {{
            let cipher = <$ctor as KeyInit>::new_from_slice(key)
                .map_err(|_| "invalid key length".to_owned())?;
            let nonce = aes_gcm::aead::generic_array::GenericArray::from_slice(iv);
            let payload = Payload { msg: data, aad };
            match op {
                Op::Encrypt => cipher
                    .encrypt(nonce, payload)
                    .map_err(|_| "encryption failed".to_owned()),
                Op::Decrypt => cipher.decrypt(nonce, payload).map_err(|_| {
                    "decryption failed (wrong key/iv/tag or corrupted data)".to_owned()
                }),
            }
        }};
    }
    match key.len() {
        16 => run!(aes_gcm::Aes128Gcm),
        24 => run!(aes_gcm::AesGcm<aes::Aes192, aes_gcm::aead::consts::U12>),
        32 => run!(aes_gcm::Aes256Gcm),
        _ => Err("key must be 16, 24, or 32 bytes".to_owned()),
    }
}

// ---------------------------------------------------------------------------
// Simon and Speck
// ---------------------------------------------------------------------------

// Simon128/256 and Speck128/256 from the NSA's Simon and Speck paper: the
// lightweight block ciphers behind ByteDance's x-argus / x-ladon request
// signing, which book sources must reproduce byte for byte. Signing uses them
// in ECB mode with PKCS#7 padding over a 32-byte key; only encryption is
// exposed because signing never decrypts.

/// Simon128/256 round count (Simon and Speck paper, table 1).
const SIMON_ROUNDS: usize = 72;
/// The 62-bit z4 sequence that whitens the Simon128/256 key schedule.
const SIMON_Z4: u64 = 0x3dc94c3a046d678b;
/// Speck128/256 round count (Simon and Speck paper, table 1).
const SPECK_ROUNDS: usize = 34;

/// Read the four little-endian 64-bit words of a 32-byte cipher key.
fn cipher_key_words(key: &[u8]) -> Result<[u64; 4], String> {
    if key.len() != 32 {
        return Err(format!("key must be 32 bytes, got {}", key.len()));
    }
    let word = |index: usize| {
        u64::from_le_bytes(
            key[index * 8..index * 8 + 8]
                .try_into()
                .expect("8-byte chunk"),
        )
    };
    Ok([word(0), word(1), word(2), word(3)])
}

/// PKCS#7-pad `data` to a multiple of `block` bytes (RFC 5652 §6.3);
/// aligned data gains a full padding block.
fn pkcs7_pad(data: &[u8], block: usize) -> Vec<u8> {
    let pad = block - data.len() % block;
    let mut padded = Vec::with_capacity(data.len() + pad);
    padded.extend_from_slice(data);
    padded.resize(data.len() + pad, pad as u8);
    padded
}

fn simon_key_schedule(key: &[u64; 4]) -> [u64; SIMON_ROUNDS] {
    let mut keys = [0u64; SIMON_ROUNDS];
    keys[..4].copy_from_slice(key);
    for index in 4..SIMON_ROUNDS {
        let mixed = keys[index - 1].rotate_right(3) ^ keys[index - 3];
        let mixed = mixed ^ mixed.rotate_right(1);
        let z_bit = (SIMON_Z4 >> ((index - 4) % 62)) & 1;
        keys[index] = !keys[index - 4] ^ mixed ^ z_bit ^ 3;
    }
    keys
}

/// One Simon round: `y' = x ^ (S¹y & S⁸y) ^ S²y ^ k`, `x' = y`.
fn simon_encrypt_block(keys: &[u64; SIMON_ROUNDS], x: u64, y: u64) -> (u64, u64) {
    let (mut x, mut y) = (x, y);
    for &key in keys {
        let f = y.rotate_left(1) & y.rotate_left(8);
        let next = x ^ f ^ y.rotate_left(2) ^ key;
        x = y;
        y = next;
    }
    (x, y)
}

fn simon_run(key: &[u8], data: &[u8]) -> Result<Vec<u8>, String> {
    let schedule = simon_key_schedule(&cipher_key_words(key)?);
    let padded = pkcs7_pad(data, 16);
    let mut out = vec![0u8; padded.len()];
    let (blocks, _) = padded.as_chunks::<16>();
    let (outputs, _) = out.as_chunks_mut::<16>();
    for (block, output) in blocks.iter().zip(outputs.iter_mut()) {
        let x = u64::from_le_bytes(block[..8].try_into().expect("8-byte half"));
        let y = u64::from_le_bytes(block[8..].try_into().expect("8-byte half"));
        let (low, high) = simon_encrypt_block(&schedule, x, y);
        output[..8].copy_from_slice(&low.to_le_bytes());
        output[8..].copy_from_slice(&high.to_le_bytes());
    }
    Ok(out)
}

fn speck_key_schedule(key: &[u64; 4]) -> [u64; SPECK_ROUNDS] {
    let [k0, l1, l2, l3] = *key;
    let mut keys = [0u64; SPECK_ROUNDS];
    keys[0] = k0;
    let mut window = [l1, l2, l3];
    for index in 0..SPECK_ROUNDS - 1 {
        let next = window[0].rotate_right(8).wrapping_add(keys[index]) ^ index as u64;
        let rotated = keys[index].rotate_left(3);
        window = [window[1], window[2], next];
        keys[index + 1] = next ^ rotated;
    }
    keys
}

/// One Speck round: `x' = k ^ (S⁻⁸x + y)`, `y' = x' ^ S³y`.
fn speck_encrypt_block(keys: &[u64; SPECK_ROUNDS], y: u64, x: u64) -> (u64, u64) {
    let (mut y, mut x) = (y, x);
    for &key in keys {
        x = key ^ x.rotate_right(8).wrapping_add(y);
        y = x ^ y.rotate_left(3);
    }
    (y, x)
}

fn speck_run(key: &[u8], data: &[u8]) -> Result<Vec<u8>, String> {
    let schedule = speck_key_schedule(&cipher_key_words(key)?);
    let padded = pkcs7_pad(data, 16);
    let mut out = vec![0u8; padded.len()];
    let (blocks, _) = padded.as_chunks::<16>();
    let (outputs, _) = out.as_chunks_mut::<16>();
    for (block, output) in blocks.iter().zip(outputs.iter_mut()) {
        let y = u64::from_le_bytes(block[..8].try_into().expect("8-byte half"));
        let x = u64::from_le_bytes(block[8..].try_into().expect("8-byte half"));
        let (first, second) = speck_encrypt_block(&schedule, y, x);
        output[..8].copy_from_slice(&first.to_le_bytes());
        output[8..].copy_from_slice(&second.to_le_bytes());
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

fn gzip_encode(data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Write as _;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(data)
        .and_then(|_| encoder.finish())
        .map_err(|_| "compression failed".to_owned())
}

fn gzip_decode(data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read as _;
    let mut output = Vec::new();
    GzDecoder::new(data)
        .take(MAX_EXPANSION_BYTES as u64 + 1)
        .read_to_end(&mut output)
        .map_err(|_| "invalid gzip data".to_owned())?;
    if output.len() > MAX_EXPANSION_BYTES {
        return Err(format!(
            "decompressed data exceeds {MAX_EXPANSION_BYTES} bytes"
        ));
    }
    Ok(output)
}

fn deflate_raw_encode(data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Write as _;
    let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(data)
        .and_then(|_| encoder.finish())
        .map_err(|_| "compression failed".to_owned())
}

fn inflate_raw_decode(data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read as _;
    let mut output = Vec::new();
    flate2::read::DeflateDecoder::new(data)
        .take(MAX_EXPANSION_BYTES as u64 + 1)
        .read_to_end(&mut output)
        .map_err(|_| "invalid deflate data".to_owned())?;
    if output.len() > MAX_EXPANSION_BYTES {
        return Err(format!(
            "decompressed data exceeds {MAX_EXPANSION_BYTES} bytes"
        ));
    }
    Ok(output)
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

fn bytes_out<'js>(ctx: &Ctx<'js>, bytes: Vec<u8>) -> JsResult<TypedArray<'js, u8>> {
    TypedArray::<u8>::new_copy(ctx.clone(), &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::script::js::sandbox::Sandbox;
    use std::time::Duration;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    fn unhex(text: &str) -> Vec<u8> {
        text.as_bytes()
            .chunks(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    #[test]
    fn digests_match_known_vectors() {
        let data = b"abc";
        let mut md5 = md5::Md5::new();
        md5.update(data);
        assert_eq!(hex(&md5.finalize()), "900150983cd24fb0d6963f7d28e17f72");
        let mut sha1 = sha1::Sha1::new();
        sha1.update(data);
        assert_eq!(
            hex(&sha1.finalize()),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        let mut sha256 = sha2::Sha256::new();
        sha256.update(data);
        assert_eq!(
            hex(&sha256.finalize()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let mut sha512 = sha2::Sha512::new();
        sha512.update(data);
        assert_eq!(
            hex(&sha512.finalize()),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a\
             2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        );
    }

    #[test]
    fn hmac_matches_rfc4231_case2() {
        // HMAC-SHA256 with key "Jefe".
        let mac = hmac_digest("sha256", b"Jefe", b"what do ya want for nothing?").unwrap();
        assert_eq!(
            hex(&mac),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        assert!(hmac_digest("sha3", b"k", b"d").is_none());
    }

    #[test]
    fn sm3_matches_the_standard_vector_and_hmac_follows() {
        // sm3("abc") is the worked example in GB/T 32905 itself.
        let mut digest = sm3::Sm3::new();
        digest.update(b"abc");
        assert_eq!(
            hex(&digest.finalize()),
            "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
        );
        let mut digest = sm3::Sm3::new();
        digest.update("langhuan-番茄测试".as_bytes());
        assert_eq!(
            hex(&digest.finalize()),
            "fc3d6414499926ff7562eaddff0cd1203e3359ee82c6795277076d8f8521be57"
        );
        let data: Vec<u8> = (0..100).collect();
        let mut digest = sm3::Sm3::new();
        digest.update(&data);
        assert_eq!(
            hex(&digest.finalize()),
            "4b2833c158dd41614b76e37f18889243bd6b4a744e36de60920a2f89e409c64e"
        );
        let mac = hmac_digest("sm3", b"Jefe", b"what do ya want for nothing?").unwrap();
        assert_eq!(
            hex(&mac),
            "2e87f1d16862e6d964b50a5200bf2b10b764faa9680a296a2405f24bec39f882"
        );
        let key: Vec<u8> = (0..100).map(|index| index + 7).collect();
        let mac = hmac_digest("sm3", &key, b"second").unwrap();
        assert_eq!(
            hex(&mac),
            "d5be25eca79dc9c10ea8976a191654196474f03d10331944029e334ee552c32e"
        );
    }

    #[test]
    fn simon_matches_the_signing_stack_vectors() {
        let key: Vec<u8> = (0..=31).collect();
        // One input block: the plaintext block plus a full padding block.
        let one_block: Vec<u8> = (0..=15).collect();
        assert_eq!(
            hex(&simon_run(&key, &one_block).unwrap()),
            "708c031e1d44519f5d235198757c23940f1b843de8b876190ebefc6e5be42113"
        );
        // 23 bytes: 9 bytes of padding over two blocks.
        let partial: Vec<u8> = (3..=25).collect();
        assert_eq!(
            hex(&simon_run(&key, &partial).unwrap()),
            "6a079365a83dbc1eb8df54d58a2f874a8897e81466b8471d72b5a0138e07f558"
        );
        // 100 bytes across seven blocks.
        let multi: Vec<u8> = (11..=110).collect();
        assert_eq!(
            hex(&simon_run(&key, &multi).unwrap()),
            "980b5b84ab8750bbbc8cbe611667b359d379df95371f8fe255696d3055c003aa\
             cd3539c32ac2a2fb31ff05cf38a4aa4172c8868ec125a1dd39fb3657b667ee77\
             606f289b59e9b6d2ff1603c75c045da74849d6e3d6bde0813aedba0854339907\
             bc655256066954f2f48a81c7675c97da"
        );
        assert_eq!(
            simon_run(&key[..16], &one_block).unwrap_err(),
            "key must be 32 bytes, got 16"
        );
    }

    #[test]
    fn speck_matches_the_signing_stack_vectors() {
        let key: Vec<u8> = (0..=31).collect();
        // A single byte still encrypts to a full padded block.
        assert_eq!(
            hex(&speck_run(&key, &[9]).unwrap()),
            "3aa52de3780437b60def656294c8c3f7"
        );
        let partial: Vec<u8> = (5..=19).collect();
        assert_eq!(
            hex(&speck_run(&key, &partial).unwrap()),
            "a7b07cf02374992b886d9fb7ba0fd412"
        );
        // Aligned input gains a full padding block.
        let aligned: Vec<u8> = (0..=15).collect();
        assert_eq!(
            hex(&speck_run(&key, &aligned).unwrap()),
            "ff3a8de8800e57794bda791b326d035f5cc41d1af28ab6b39cef907bb0a7ec0d"
        );
        let multi: Vec<u8> = (13..=112).collect();
        assert_eq!(
            hex(&speck_run(&key, &multi).unwrap()),
            "4f821507d18764c8288823fef7d573c6aff1b9036340ffef0147f13b857a1833\
             766f24b319ee8970ac0a2ec0e5a8f1b109492243ad56592e10909f367674deb5a\
             ad54af3f4b6e78deca5816f66e6a15d60a05167930ac3172d108f1d9d5b277c9\
             64d2af1442bccc5d6d82116b333ed1b"
        );
        assert_eq!(
            speck_run(&[7; 16], &aligned).unwrap_err(),
            "key must be 32 bytes, got 16"
        );
    }

    #[test]
    fn sm3_and_signing_ciphers_round_trip_through_the_realm() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let result = sandbox
            .eval_module_json(
                r#"import { Crypto } from "langhuan:crypto";
                   import { TextEncoder, Bytes } from "langhuan:encoding";
                   const key = Bytes.fromHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
                   const enc = new TextEncoder();
                   export default [
                       Bytes.toHex(Crypto.sm3(enc.encode("abc"))),
                       Bytes.toHex(Crypto.hmac("sm3", enc.encode("Jefe"),
                                               enc.encode("what do ya want for nothing?"))),
                       Bytes.toHex(Crypto.simon(key, Bytes.fromHex("000102030405060708090a0b0c0d0e0f"))),
                       Bytes.toHex(Crypto.speck(key, Bytes.fromHex("000102030405060708090a0b0c0d0e0f"))),
                   ].join("\n");"#,
            )
            .unwrap();
        let lines: Vec<&str> = result.split('\n').collect();
        assert_eq!(
            lines[0],
            "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
        );
        assert_eq!(
            lines[1],
            "2e87f1d16862e6d964b50a5200bf2b10b764faa9680a296a2405f24bec39f882"
        );
        assert_eq!(
            lines[2],
            "708c031e1d44519f5d235198757c23940f1b843de8b876190ebefc6e5be42113"
        );
        assert_eq!(
            lines[3],
            "ff3a8de8800e57794bda791b326d035f5cc41d1af28ab6b39cef907bb0a7ec0d"
        );
    }

    #[test]
    fn aes128_cbc_matches_nist_sp800_38a_f21() {
        let key = unhex("2b7e151628aed2a6abf7158809cf4f3c");
        let iv = unhex("000102030405060708090a0b0c0d0e0f");
        let plaintext = unhex("6bc1bee22e409f96e93d7e117393172a");
        let ciphertext = cbc_run(Op::Encrypt, &key, &iv, &plaintext, Padding::None).unwrap();
        assert_eq!(hex(&ciphertext), "7649abac8119b246cee98e9b12e9197d");
        let decrypted = cbc_run(Op::Decrypt, &key, &iv, &ciphertext, Padding::None).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn aes128_ecb_matches_nist_sp800_38a_f11() {
        let key = unhex("2b7e151628aed2a6abf7158809cf4f3c");
        let plaintext = unhex("6bc1bee22e409f96e93d7e117393172a");
        let ciphertext = ecb_run(Op::Encrypt, &key, &plaintext, Padding::None).unwrap();
        assert_eq!(hex(&ciphertext), "3ad77bb40d7a3660a89ecaf32466ef97");
        assert_eq!(
            ecb_run(Op::Decrypt, &key, &ciphertext, Padding::None).unwrap(),
            plaintext
        );
    }

    #[test]
    fn aes128_ctr_matches_nist_sp800_38a_f51() {
        let key = unhex("2b7e151628aed2a6abf7158809cf4f3c");
        let iv = unhex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
        let plaintext = unhex("6bc1bee22e409f96e93d7e117393172a");
        let ciphertext = ctr_run(&key, &iv, &plaintext).unwrap();
        assert_eq!(hex(&ciphertext), "874d6191b620e3261bef6864990db6ce");
        assert_eq!(ctr_run(&key, &iv, &ciphertext).unwrap(), plaintext);
    }

    #[test]
    fn aes128_gcm_matches_the_nist_cavp_vector() {
        // gcmEncryptExtIV128.rsp: 16-byte plaintext, empty AAD.
        let key = unhex("7fddb57453c241d03efbed3ac44e371c");
        let iv = unhex("ee283a3fc75575e33efd4887");
        let plaintext = unhex("d5de42b461646c255c87bd2962d3b9a2");
        let sealed = gcm_run(Op::Encrypt, &key, &iv, &plaintext, b"").unwrap();
        // Output is ciphertext || tag.
        assert_eq!(
            hex(&sealed),
            "2ccda4a5415cb91e135c2a0f78c9b2fdb36d1df9b9d5e596f83e8b7f52971cb3"
        );
        assert_eq!(
            gcm_run(Op::Decrypt, &key, &iv, &sealed, b"").unwrap(),
            plaintext
        );
        // Wrong AAD must fail authentication.
        assert!(gcm_run(Op::Decrypt, &key, &iv, &sealed, b"x").is_err());
    }

    #[test]
    fn aes_cbc_pkcs7_round_trips_all_key_sizes() {
        for length in [16u8, 24, 32] {
            let key = vec![0x42u8; usize::from(length)];
            let iv = [0x11u8; 16];
            let data = b"arbitrary length payload!";
            let sealed = cbc_run(Op::Encrypt, &key, &iv, data, Padding::Pkcs7).unwrap();
            assert_eq!(sealed.len() % 16, 0);
            assert_ne!(sealed, data.to_vec());
            let opened = cbc_run(Op::Decrypt, &key, &iv, &sealed, Padding::Pkcs7).unwrap();
            assert_eq!(opened, data);
        }
        // A wrong key must fail padding validation.
        let key = vec![0x42u8; 16];
        let iv = [0x11u8; 16];
        let sealed = cbc_run(Op::Encrypt, &key, &iv, b"secret", Padding::Pkcs7).unwrap();
        let wrong = vec![0x43u8; 16];
        assert!(cbc_run(Op::Decrypt, &wrong, &iv, &sealed, Padding::Pkcs7).is_err());
    }

    #[test]
    fn compression_round_trips_and_flags_broken_input() {
        let data = b"hello hello hello hello hello hello world".to_vec();
        let gz = gzip_encode(&data).unwrap();
        assert_eq!(&gz[..3], &[0x1f, 0x8b, 0x08]);
        assert_eq!(gzip_decode(&gz).unwrap(), data);
        let raw = deflate_raw_encode(&data).unwrap();
        assert_eq!(inflate_raw_decode(&raw).unwrap(), data);
        assert!(gzip_decode(b"not gzip").is_err());
        assert!(inflate_raw_decode(b"not deflate").is_err());
        // A gzip bomb must be capped rather than exhaust memory.
        let bomb = gzip_encode(&vec![0u8; 1024]).unwrap();
        // 1 KiB of zeros compresses tiny; decode is fine and small.
        assert_eq!(gzip_decode(&bomb).unwrap().len(), 1024);
    }

    #[test]
    fn aes_rejects_malformed_options_with_field_names() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let cases = [
            ("Crypto.aes(5)", "Crypto.aes: expected an object"),
            ("Crypto.aes({})", "Crypto.aes: missing field `op`"),
            (
                "Crypto.aes({ op: 5, mode: 'cbc', key: [], iv: [], data: [] })",
                "Crypto.aes: `op` must be a string",
            ),
            (
                "Crypto.aes({ op: 'encrypt', mode: 'cbc', key: 5, iv: [], data: [] })",
                "Crypto.aes: `key` must be a Uint8Array",
            ),
        ];
        for (code, expected) in cases {
            let module = format!(r#"import {{ Crypto }} from "langhuan:crypto"; {code}"#);
            let error = sandbox.eval_module_json(&module).unwrap_err().to_string();
            assert!(error.contains(expected), "{code} -> {error}");
        }
    }

    #[test]
    fn aes_round_trips_options_through_the_realm() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let sealed = sandbox
            .eval_module_json(
                r#"import { Crypto } from "langhuan:crypto";
                   import { TextEncoder, Bytes } from "langhuan:encoding";
                   export default Bytes.toHex(Crypto.aes({
                       op: "encrypt",
                       mode: "cbc",
                       key: new Uint8Array(16),
                       iv: new Uint8Array(16),
                       data: new TextEncoder().encode("secret"),
                   }));"#,
            )
            .unwrap();
        let opened = sandbox
            .eval_module_json(&format!(
                r#"import {{ Crypto }} from "langhuan:crypto";
                   import {{ TextDecoder, Bytes }} from "langhuan:encoding";
                   export default new TextDecoder().decode(Crypto.aes({{
                       op: "decrypt",
                       mode: "cbc",
                       key: new Uint8Array(16),
                       iv: new Uint8Array(16),
                       data: Bytes.fromHex("{sealed}"),
                   }}));"#
            ))
            .unwrap();
        assert_eq!(opened, "secret");
    }
}
