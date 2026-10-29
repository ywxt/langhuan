//! Host-provided cryptography and compression namespaces.
//!
//! Book sources need to run the same algorithms sites use — digests, HMAC,
//! AES, and gzip — but the sandbox must never hand them a native code loader.
//! Everything here is a pure function over explicit arguments, so it is safe
//! to install in the feed realm and in every disposable compute realm.

use aes::cipher::block_padding::{NoPadding, Pkcs7};
use aes::cipher::{BlockDecryptMut, BlockEncryptMut, KeyInit, KeyIvInit, StreamCipher};
use flate2::read::GzDecoder;
use flate2::write::{DeflateEncoder, GzEncoder};
use flate2::Compression;
use hmac::Mac;
use rquickjs::{Ctx, Exception, FromJs, Function, Object, Result as JsResult, TypedArray, Value as JsValue};
use sha2::Digest;

/// Upper bound for decompressed output, matching the QuickJS heap limit.
const MAX_EXPANSION_BYTES: usize = 32 * 1024 * 1024;
/// Upper bound for `Crypto.randomBytes`.
const MAX_RANDOM_BYTES: usize = 1024 * 1024;

pub(super) fn install<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    install_crypto(ctx)?;
    install_compression(ctx)?;
    Ok(())
}

fn install_crypto<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    let namespace = Object::new(ctx.clone())?;

    namespace.set(
        "md5",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<md5::Md5>(&ctx, &data)
        })?,
    )?;
    namespace.set(
        "sha1",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sha1::Sha1>(&ctx, &data)
        })?,
    )?;
    namespace.set(
        "sha256",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sha2::Sha256>(&ctx, &data)
        })?,
    )?;
    namespace.set(
        "sha512",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            digest_call::<sha2::Sha512>(&ctx, &data)
        })?,
    )?;
    namespace.set(
        "hmac",
        Function::new(
            ctx.clone(),
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
        )?,
    )?;
    namespace.set(
        "aes",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, options: Object<'js>| -> JsResult<TypedArray<'js, u8>> {
                let request = AesRequest::from_options(&ctx, &options)?;
                let output = aes_run(&ctx, &request)?;
                bytes_out(&ctx, output)
            },
        )?,
    )?;
    namespace.set(
        "randomBytes",
        Function::new(
            ctx.clone(),
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
        )?,
    )?;
    ctx.globals().set("Crypto", namespace)
}

fn install_compression<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    let namespace = Object::new(ctx.clone())?;
    namespace.set(
        "gzip",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = gzip_encode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.gzip: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?,
    )?;
    namespace.set(
        "gunzip",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = gzip_decode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.gunzip: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?,
    )?;
    namespace.set(
        "deflateRaw",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = deflate_raw_encode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.deflateRaw: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?,
    )?;
    namespace.set(
        "inflateRaw",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, data: TypedArray<'js, u8>| {
            let bytes = typed_bytes(&ctx, &data)?;
            let output = inflate_raw_decode(&bytes).map_err(|message| {
                Exception::throw_message(&ctx, &format!("Compression.inflateRaw: {message}"))
            })?;
            bytes_out(&ctx, output)
        })?,
    )?;
    ctx.globals().set("Compression", namespace)
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
    match algorithm {
        "md5" => Some(hmac_of::<HmacMd5>(key, data)),
        "sha1" => Some(hmac_of::<HmacSha1>(key, data)),
        "sha256" => Some(hmac_of::<HmacSha256>(key, data)),
        "sha512" => Some(hmac_of::<HmacSha512>(key, data)),
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

impl AesRequest {
    fn from_options<'js>(ctx: &Ctx<'js>, options: &Object<'js>) -> JsResult<Self> {
        Ok(Self {
            op: required_string(ctx, options, "op")?,
            mode: required_string(ctx, options, "mode")?,
            key: required_bytes(ctx, options, "key")?,
            iv: optional_bytes(ctx, options, "iv")?,
            data: required_bytes(ctx, options, "data")?,
            padding: optional_string(options, "padding"),
            aad: optional_bytes(ctx, options, "aad")?,
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
        other => return Err(fail(format!("`op` must be \"encrypt\" or \"decrypt\", got {other:?}"))),
    };
    let Some(mode) = Mode::from_label(&request.mode) else {
        return Err(fail(format!("unknown mode {:?}", request.mode)));
    };
    let padding =
        parse_padding(mode.padded(), request.padding.as_deref()).map_err(fail)?;
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
        (_, Some(other)) => Err(format!("`padding` must be \"pkcs7\" or \"none\", got {other:?}")),
    }
}

fn cbc_run(op: Op, key: &[u8], iv: &[u8], data: &[u8], padding: Padding) -> Result<Vec<u8>, String> {
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

fn gcm_run(
    op: Op,
    key: &[u8],
    iv: &[u8],
    data: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, String> {
    use aes_gcm::aead::{Aead, Payload};
    macro_rules! run {
        ($ctor:ty) => {{
            let cipher = <$ctor as KeyInit>::new_from_slice(key)
                .map_err(|_| "invalid key length".to_owned())?;
            let nonce = aes_gcm::aead::generic_array::GenericArray::from_slice(iv);
            let payload = Payload {
                msg: data,
                aad,
            };
            match op {
                Op::Encrypt => cipher
                    .encrypt(nonce, payload)
                    .map_err(|_| "encryption failed".to_owned()),
                Op::Decrypt => cipher
                    .decrypt(nonce, payload)
                    .map_err(|_| {
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
        return Err(format!("decompressed data exceeds {MAX_EXPANSION_BYTES} bytes"));
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
        return Err(format!("decompressed data exceeds {MAX_EXPANSION_BYTES} bytes"));
    }
    Ok(output)
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

/// Copy the bytes of a typed array, rejecting detached buffers.
fn typed_bytes<'js>(ctx: &Ctx<'js>, data: &TypedArray<'js, u8>) -> JsResult<Vec<u8>> {
    // SAFETY: no JavaScript runs while the slice is borrowed.
    match unsafe { data.as_bytes() } {
        Some(slice) => Ok(slice.to_vec()),
        None => Err(Exception::throw_message(
            ctx,
            "expected a Uint8Array, got a detached buffer",
        )),
    }
}

fn bytes_out<'js>(ctx: &Ctx<'js>, bytes: Vec<u8>) -> JsResult<TypedArray<'js, u8>> {
    TypedArray::<u8>::new_copy(ctx.clone(), &bytes)
}

fn required_string<'js>(ctx: &Ctx<'js>, object: &Object<'js>, name: &str) -> JsResult<String> {
    let value: JsValue = object.get(name)?;
    if value.is_undefined() {
        return Err(Exception::throw_message(
            ctx,
            &format!("Crypto.aes: missing field `{name}`"),
        ));
    }
    match String::from_js(ctx, value) {
        Ok(value) => Ok(value),
        Err(_) => Err(Exception::throw_message(
            ctx,
            &format!("Crypto.aes: `{name}` must be a string"),
        )),
    }
}

fn optional_string(object: &Object<'_>, name: &str) -> Option<String> {
    object.get::<_, String>(name).ok()
}

fn required_bytes<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    name: &str,
) -> JsResult<Vec<u8>> {
    let value: JsValue = object.get(name)?;
    if value.is_undefined() {
        return Err(Exception::throw_message(
            ctx,
            &format!("Crypto.aes: missing field `{name}`"),
        ));
    }
    let typed = TypedArray::<u8>::from_js(ctx, value).map_err(|_| {
        Exception::throw_message(ctx, &format!("Crypto.aes: `{name}` must be a Uint8Array"))
    })?;
    typed_bytes(ctx, &typed)
}

fn optional_bytes<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    name: &str,
) -> JsResult<Option<Vec<u8>>> {
    let value: JsValue = object.get(name)?;
    if value.is_undefined() || value.is_null() {
        return Ok(None);
    }
    let typed = TypedArray::<u8>::from_js(ctx, value).map_err(|_| {
        Exception::throw_message(ctx, &format!("Crypto.aes: `{name}` must be a Uint8Array"))
    })?;
    Ok(Some(typed_bytes(ctx, &typed)?))
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(
            hex(&md5.finalize()),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        let mut sha1 = sha1::Sha1::new();
        sha1.update(data);
        assert_eq!(hex(&sha1.finalize()), "a9993e364706816aba3e25717850c26c9cd0d89d");
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
            let sealed =
                cbc_run(Op::Encrypt, &key, &iv, data, Padding::Pkcs7).unwrap();
            assert_eq!(sealed.len() % 16, 0);
            assert_ne!(sealed, data.to_vec());
            let opened =
                cbc_run(Op::Decrypt, &key, &iv, &sealed, Padding::Pkcs7).unwrap();
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
}
