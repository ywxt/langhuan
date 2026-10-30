//! The `langhuan:protobuf` module: protobuf wire-format encoding.
//!
//! Book sources that talk to app APIs sign their requests with payloads
//! encoded in protobuf's wire format. `Protobuf` is a writer covering the
//! field shapes those payloads use — varints and length-delimited strings,
//! bytes, and submessages; a submessage is just nested bytes, so build the
//! inner writer and pass `inner.finish()` to `bytes`. The buffer lives in
//! Rust, behind plain `varint`/`string`/`bytes`/`finish` methods; like every
//! host module this is a pure transformation over explicit arguments.

use std::cell::RefCell;
use std::rc::Rc;

use rquickjs::module::{Declarations, Exports, ModuleDef};
use rquickjs::{Ctx, Exception, Function, Object, Result as JsResult, TypedArray};

use super::bridge::typed_bytes;
use super::module::{constructor, declare_module, set_function};

/// Upper bound on one encoded message, matching the QuickJS heap limit.
const MAX_MESSAGE_BYTES: usize = 32 * 1024 * 1024;
/// Largest protobuf field number (2^29 - 1 per the wire-format spec).
const MAX_FIELD: u32 = (1 << 29) - 1;
/// Largest value accepted for a varint field: every integer up to 2^53 is
/// exactly representable as a JavaScript number.
const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_992.0;
/// Wire type 0: base-128 varints.
const WIRE_VARINT: u64 = 0;
/// Wire type 2: length-delimited payloads (strings, bytes, submessages).
const WIRE_LEN: u64 = 2;

/// The `langhuan:protobuf` module: `Protobuf`.
struct ProtobufModule;

impl ModuleDef for ProtobufModule {
    fn declare<'js>(declarations: &Declarations<'js>) -> JsResult<()> {
        declarations.declare("Protobuf")?;
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> JsResult<()> {
        exports.export("Protobuf", protobuf(ctx)?)?;
        Ok(())
    }
}

/// Declare the `langhuan:protobuf` module in the realm.
pub(super) fn declare<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    declare_module::<ProtobufModule>(ctx, "langhuan:protobuf")
}

fn protobuf<'js>(ctx: &Ctx<'js>) -> JsResult<Function<'js>> {
    constructor(ctx, |ctx: Ctx<'js>| -> JsResult<Object<'js>> {
        let state = Rc::new(RefCell::new(Vec::new()));
        let writer = Object::new(ctx.clone())?;

        let varint_state = Rc::clone(&state);
        set_function(
            &ctx,
            &writer,
            "varint",
            move |ctx: Ctx<'js>, field: u32, value: f64| -> JsResult<()> {
                let label = "Protobuf.varint";
                let field = validate_field(&ctx, field, label)?;
                let value = validate_varint(&ctx, value, label)?;
                let mut buffer = varint_state.borrow_mut();
                write_varint(&mut buffer, u64::from(field) << 3 | WIRE_VARINT);
                write_varint(&mut buffer, value);
                check_limit(&ctx, buffer.len(), label)
            },
        )?;

        let string_state = Rc::clone(&state);
        set_function(
            &ctx,
            &writer,
            "string",
            move |ctx: Ctx<'js>, field: u32, value: String| -> JsResult<()> {
                let label = "Protobuf.string";
                let field = validate_field(&ctx, field, label)?;
                let value = value.into_bytes();
                let mut buffer = string_state.borrow_mut();
                write_varint(&mut buffer, u64::from(field) << 3 | WIRE_LEN);
                write_varint(&mut buffer, value.len() as u64);
                extend(&ctx, &mut buffer, &value, label)
            },
        )?;

        let bytes_state = Rc::clone(&state);
        set_function(
            &ctx,
            &writer,
            "bytes",
            move |ctx: Ctx<'js>, field: u32, value: TypedArray<'js, u8>| -> JsResult<()> {
                let label = "Protobuf.bytes";
                let field = validate_field(&ctx, field, label)?;
                let value = typed_bytes(&ctx, &value)?;
                let mut buffer = bytes_state.borrow_mut();
                write_varint(&mut buffer, u64::from(field) << 3 | WIRE_LEN);
                write_varint(&mut buffer, value.len() as u64);
                extend(&ctx, &mut buffer, &value, label)
            },
        )?;

        set_function(
            &ctx,
            &writer,
            "finish",
            move |ctx: Ctx<'js>| -> JsResult<TypedArray<'js, u8>> {
                let buffer = state.borrow();
                TypedArray::<u8>::new_copy(ctx.clone(), &*buffer)
            },
        )?;
        Ok(writer)
    })
}

/// Reject field numbers protobuf cannot carry on the wire.
fn validate_field<'js>(ctx: &Ctx<'js>, field: u32, label: &str) -> JsResult<u32> {
    if (1..=MAX_FIELD).contains(&field) {
        return Ok(field);
    }
    Err(Exception::throw_message(
        ctx,
        &format!("{label}: `field` must be between 1 and {MAX_FIELD}"),
    ))
}

/// Reject values a JavaScript number cannot carry exactly.
fn validate_varint<'js>(ctx: &Ctx<'js>, value: f64, label: &str) -> JsResult<u64> {
    if value.fract() == 0.0 && (0.0..=MAX_SAFE_INTEGER).contains(&value) {
        return Ok(value as u64);
    }
    Err(Exception::throw_message(
        ctx,
        &format!("{label}: `value` must be a non-negative safe integer"),
    ))
}

/// Write a base-128 varint: seven bits per byte, most significant last.
fn write_varint(buffer: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            buffer.push(byte);
            return;
        }
        buffer.push(byte | 0x80);
    }
}

/// Append a payload, refusing messages past the size limit.
fn extend<'js>(ctx: &Ctx<'js>, buffer: &mut Vec<u8>, payload: &[u8], label: &str) -> JsResult<()> {
    if buffer.len() + payload.len() > MAX_MESSAGE_BYTES {
        return Err(Exception::throw_message(
            ctx,
            &format!("{label}: message exceeds {MAX_MESSAGE_BYTES} bytes"),
        ));
    }
    buffer.extend_from_slice(payload);
    Ok(())
}

fn check_limit<'js>(ctx: &Ctx<'js>, length: usize, label: &str) -> JsResult<()> {
    if length > MAX_MESSAGE_BYTES {
        return Err(Exception::throw_message(
            ctx,
            &format!("{label}: message exceeds {MAX_MESSAGE_BYTES} bytes"),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::script::js::sandbox::Sandbox;
    use std::time::Duration;

    /// Evaluate `body` (a statement using `writer`) and return the message
    /// hex, or the failure message.
    fn run(body: &str) -> Result<String, String> {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let module = format!(
            r#"import {{ Protobuf }} from "langhuan:protobuf";
               import {{ Bytes }} from "langhuan:encoding";
               const writer = new Protobuf();
               {body}
               export default Bytes.toHex(writer.finish());"#
        );
        match sandbox.eval_module_json(&module) {
            Ok(hex) => Ok(hex),
            Err(error) => Err(error.to_string()),
        }
    }

    #[test]
    fn varint_and_string_match_the_wire_examples() {
        // The encoding examples from the protobuf documentation: field 1
        // carries 150, field 2 carries "testing".
        assert_eq!(
            run(r#"writer.varint(1, 150); writer.string(2, "testing");"#).unwrap(),
            "089601120774657374696e67"
        );
        // 300 needs a two-byte varint: 0xac 0x02.
        assert_eq!(run("writer.varint(1, 300);").unwrap(), "08ac02");
        // Empty strings keep their length prefix.
        assert_eq!(run(r#"writer.string(4, "");"#).unwrap(), "2200");
    }

    #[test]
    fn submessages_encode_as_nested_bytes() {
        assert_eq!(
            run(r#"const inner = new Protobuf();
                   inner.varint(1, 150);
                   writer.bytes(3, inner.finish());"#)
            .unwrap(),
            "1a03089601"
        );
    }

    #[test]
    fn invalid_fields_and_values_name_their_method() {
        for (code, expected) in [
            (
                "writer.varint(0, 1);",
                "Protobuf.varint: `field` must be between 1 and 536870911",
            ),
            (
                "writer.varint(536870912, 1);",
                "Protobuf.varint: `field` must be between 1 and 536870911",
            ),
            (
                "writer.varint(1, -1);",
                "Protobuf.varint: `value` must be a non-negative safe integer",
            ),
            (
                "writer.varint(1, 1.5);",
                "Protobuf.varint: `value` must be a non-negative safe integer",
            ),
            // 2^53 + 2 is the smallest literal past the safe range.
            (
                "writer.varint(1, 9007199254740994);",
                "Protobuf.varint: `value` must be a non-negative safe integer",
            ),
            (
                "writer.string(0, \"x\");",
                "Protobuf.string: `field` must be between 1 and 536870911",
            ),
        ] {
            let error = run(code).unwrap_err();
            assert!(error.contains(expected), "{code} -> {error}");
        }
    }
}
