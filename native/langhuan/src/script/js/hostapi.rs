//! Host-provided globals installed into every sandbox realm.
//!
//! QuickJS intentionally ships no browser APIs, so the host supplies the
//! encoding and byte utilities book sources need. Everything here is a pure
//! function over its arguments — no network, filesystem, clock, or random
//! side channels — so installing the same set in the feed realm and the
//! capability-free compute realm leaks nothing.

use encoding_rs::Encoding;
use rquickjs::function::Opt;
use rquickjs::{Ctx, Exception, Object, Result as JsResult, TypedArray};

use super::bridge::typed_bytes;
use super::module::{Namespace, constructor, set_function};

/// Install `TextDecoder`, `TextEncoder`, and the `Bytes` namespace.
pub(super) fn install<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    install_text_decoder(ctx)?;
    install_text_encoder(ctx)?;
    install_bytes(ctx)?;
    Ok(())
}

fn install_text_decoder<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    constructor(
        ctx,
        "TextDecoder",
        |ctx: Ctx<'js>, label: Opt<String>, options: Opt<Object<'js>>| -> JsResult<Object<'js>> {
            build_text_decoder(&ctx, label.0, options.0)
        },
    )
}

fn build_text_decoder<'js>(
    ctx: &Ctx<'js>,
    label: Option<String>,
    options: Option<Object<'js>>,
) -> JsResult<Object<'js>> {
    let label = label.unwrap_or_else(|| "utf-8".to_owned());
    let Some(encoding) = Encoding::for_label(label.as_bytes()) else {
        return Err(Exception::throw_message(
            ctx,
            &format!("TextDecoder: unknown encoding label {label:?}"),
        ));
    };
    let fatal = flag(ctx, options.as_ref(), "TextDecoder", "fatal", false)?;
    let ignore_bom = flag(ctx, options.as_ref(), "TextDecoder", "ignoreBOM", false)?;

    let decoder = Object::new(ctx.clone())?;
    decoder.set("encoding", encoding.name())?;
    decoder.set("fatal", fatal)?;
    decoder.set("ignoreBOM", ignore_bom)?;
    set_function(
        ctx,
        &decoder,
        "decode",
        move |ctx: Ctx<'js>,
              data: Opt<TypedArray<'js, u8>>,
              options: Opt<Object<'js>>|
              -> JsResult<String> {
            let options = options.0;
            if flag(
                &ctx,
                options.as_ref(),
                "TextDecoder.decode",
                "stream",
                false,
            )? {
                return Err(Exception::throw_message(
                    &ctx,
                    "TextDecoder.decode: streaming decode is not supported",
                ));
            }
            let bytes = match &data.0 {
                Some(data) => typed_bytes(&ctx, data)?,
                None => Vec::new(),
            };
            // Unlike the WHATWG decoder we do not re-sniff the encoding
            // from a BOM; a leading BOM of the requested encoding is
            // removed unless `ignoreBOM` is set.
            let (text, had_errors) = if ignore_bom {
                encoding.decode_without_bom_handling(&bytes)
            } else {
                encoding.decode_with_bom_removal(&bytes)
            };
            if had_errors && fatal {
                return Err(Exception::throw_message(
                    &ctx,
                    "TextDecoder.decode: invalid byte sequence for the encoding",
                ));
            }
            Ok(text.into_owned())
        },
    )?;
    Ok(decoder)
}

fn install_text_encoder<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    constructor(
        ctx,
        "TextEncoder",
        |ctx: Ctx<'js>| -> JsResult<Object<'js>> {
            let encoder = Object::new(ctx.clone())?;
            encoder.set("encoding", "utf-8")?;
            set_function(
                &ctx,
                &encoder,
                "encode",
                |ctx: Ctx<'js>, input: Opt<String>| -> JsResult<TypedArray<'js, u8>> {
                    let bytes = input.0.unwrap_or_default().into_bytes();
                    TypedArray::<u8>::new_copy(ctx.clone(), &bytes)
                },
            )?;
            Ok(encoder)
        },
    )
}

fn install_bytes<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    Namespace::new(ctx, "Bytes")?
        .function(
            "toBase64",
            |ctx: Ctx<'js>,
             data: TypedArray<'js, u8>,
             options: Opt<Object<'js>>|
             -> JsResult<String> {
                let url_safe = flag(&ctx, options.0.as_ref(), "Bytes.toBase64", "urlSafe", false)?;
                let bytes = typed_bytes(&ctx, &data)?;
                Ok(to_base64(&bytes, url_safe))
            },
        )?
        .function(
            "fromBase64",
            |ctx: Ctx<'js>,
             input: String,
             options: Opt<Object<'js>>|
             -> JsResult<TypedArray<'js, u8>> {
                let url_safe = flag(
                    &ctx,
                    options.0.as_ref(),
                    "Bytes.fromBase64",
                    "urlSafe",
                    false,
                )?;
                let bytes = from_base64(&input, url_safe).ok_or_else(|| {
                    Exception::throw_message(&ctx, "Bytes.fromBase64: invalid base64 input")
                })?;
                TypedArray::<u8>::new_copy(ctx.clone(), &bytes)
            },
        )?
        .function(
            "toHex",
            |ctx: Ctx<'js>, data: TypedArray<'js, u8>| -> JsResult<String> {
                let bytes = typed_bytes(&ctx, &data)?;
                Ok(to_hex(&bytes))
            },
        )?
        .function(
            "fromHex",
            |ctx: Ctx<'js>, input: String| -> JsResult<TypedArray<'js, u8>> {
                let bytes = from_hex(&input).ok_or_else(|| {
                    Exception::throw_message(&ctx, "Bytes.fromHex: invalid hex input")
                })?;
                TypedArray::<u8>::new_copy(ctx.clone(), &bytes)
            },
        )?
        .install()
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

/// Read an optional boolean property from an options object.
fn flag<'js>(
    ctx: &Ctx<'js>,
    options: Option<&Object<'js>>,
    label: &str,
    name: &str,
    fallback: bool,
) -> JsResult<bool> {
    let Some(options) = options else {
        return Ok(fallback);
    };
    let value: rquickjs::Value = options.get(name)?;
    if value.is_undefined() || value.is_null() {
        return Ok(fallback);
    }
    match value.as_bool() {
        Some(flag) => Ok(flag),
        None => Err(Exception::throw_message(
            ctx,
            &format!("{label}: `{name}` must be a boolean"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Base64 and hex
// ---------------------------------------------------------------------------

const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const BASE64_URL_SAFE_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn to_base64(input: &[u8], url_safe: bool) -> String {
    let alphabet = if url_safe {
        BASE64_URL_SAFE_ALPHABET
    } else {
        BASE64_ALPHABET
    };
    let mut output = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        output.push(alphabet[(triple >> 18) as usize & 0x3F] as char);
        output.push(alphabet[(triple >> 12) as usize & 0x3F] as char);
        output.push(if chunk.len() > 1 {
            alphabet[(triple >> 6) as usize & 0x3F] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            alphabet[triple as usize & 0x3F] as char
        } else {
            '='
        });
    }
    output
}

fn from_base64(input: &str, url_safe: bool) -> Option<Vec<u8>> {
    // ASCII whitespace is skipped so PEM-style payloads decode unchanged.
    let compact: Vec<u8> = input
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect();
    let value_of = |byte: u8| -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some(u32::from(byte - b'A')),
            b'a'..=b'z' => Some(u32::from(byte - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(byte - b'0') + 52),
            b'+' if !url_safe => Some(62),
            b'/' if !url_safe => Some(63),
            b'-' if url_safe => Some(62),
            b'_' if url_safe => Some(63),
            _ => None,
        }
    };
    // Strip trailing padding, then require a valid remainder length and no
    // padding in the middle.
    let padding = compact
        .iter()
        .rev()
        .take_while(|&&byte| byte == b'=')
        .count();
    if padding > 2
        || padding == compact.len() && !compact.is_empty()
        || compact[..compact.len() - padding].contains(&b'=')
    {
        return None;
    }
    let digits = &compact[..compact.len() - padding];
    if digits.len() % 4 == 1 {
        return None;
    }
    let mut output = Vec::with_capacity(digits.len() * 3 / 4);
    for chunk in digits.chunks(4) {
        let mut triple: u32 = 0;
        for (index, &byte) in chunk.iter().enumerate() {
            triple |= value_of(byte)? << (18 - 6 * index);
        }
        output.push((triple >> 16) as u8);
        if chunk.len() > 2 {
            output.push((triple >> 8) as u8);
        }
        if chunk.len() > 3 {
            output.push(triple as u8);
        }
    }
    Some(output)
}

fn to_hex(input: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(input.len() * 2);
    for byte in input {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0F) as usize] as char);
    }
    output
}

fn from_hex(input: &str) -> Option<Vec<u8>> {
    if !input.len().is_multiple_of(2) {
        return None;
    }
    let digit = |byte: u8| -> Option<u8> {
        match byte {
            b'0'..=b'9' => Some(byte - b'0'),
            b'a'..=b'f' => Some(byte - b'a' + 10),
            b'A'..=b'F' => Some(byte - b'A' + 10),
            _ => None,
        }
    };
    let mut output = Vec::with_capacity(input.len() / 2);
    for pair in input.as_bytes().chunks(2) {
        output.push((digit(pair[0])? << 4) | digit(pair[1])?);
    }
    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::script::js::sandbox::Sandbox;
    use std::time::Duration;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(to_base64(b"", false), "");
        assert_eq!(to_base64(b"f", false), "Zg==");
        assert_eq!(to_base64(b"fo", false), "Zm8=");
        assert_eq!(to_base64(b"foo", false), "Zm9v");
        assert_eq!(to_base64(b"foob", false), "Zm9vYg==");
        assert_eq!(to_base64(b"fooba", false), "Zm9vYmE=");
        assert_eq!(to_base64(b"foobar", false), "Zm9vYmFy");
    }

    #[test]
    fn base64_round_trips_including_255_bytes() {
        let bytes: Vec<u8> = (0..=255u8).chain([7, 8, 9]).collect();
        assert_eq!(
            from_base64(&to_base64(&bytes, false), false).unwrap(),
            bytes
        );
        assert_eq!(from_base64(&to_base64(&bytes, true), true).unwrap(), bytes);
    }

    #[test]
    fn base64_skips_whitespace_and_accepts_missing_padding() {
        assert_eq!(
            from_base64("Zm9v\n  YmFy", false).unwrap(),
            b"foobar".to_vec()
        );
        assert_eq!(from_base64("Zm9vYmFy", false).unwrap(), b"foobar".to_vec());
    }

    #[test]
    fn base64_rejects_bad_input() {
        assert!(from_base64("A", false).is_none());
        assert!(from_base64("Zm9v*", false).is_none());
        assert!(from_base64("Z=g==", false).is_none());
        assert!(from_base64("==", false).is_none());
        // Standard alphabet must be rejected in url-safe mode and back.
        assert!(from_base64("+w==", true).is_none());
        assert!(from_base64("-w==", false).is_none());
    }

    #[test]
    fn hex_round_trips() {
        let bytes = [0x00, 0x0F, 0xA5, 0xFF];
        assert_eq!(to_hex(&bytes), "000fa5ff");
        assert_eq!(from_hex("000fa5ff").unwrap(), bytes);
        assert_eq!(from_hex("000FA5FF").unwrap(), bytes);
        assert!(from_hex("000fa5f").is_none());
        assert!(from_hex("000fa5fg").is_none());
    }

    #[test]
    fn option_flags_report_their_namespace() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_json("new TextDecoder('utf-8', { fatal: 5 })")
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("TextDecoder: `fatal` must be a boolean"),
            "{error}"
        );
        let error = sandbox
            .eval_json("Bytes.toBase64(new Uint8Array(1), { urlSafe: 1 })")
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("Bytes.toBase64: `urlSafe` must be a boolean"),
            "{error}"
        );
    }
}
