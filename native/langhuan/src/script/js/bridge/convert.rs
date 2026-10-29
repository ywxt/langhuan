//! Value conversion between JavaScript, host data, and JSON.
//!
//! [`JsData`] is the realm-independent materialization used to copy the
//! compute input and result between the feed realm and the disposable
//! compute realm; unlike JSON it preserves `undefined` and raw bytes. The
//! rquickjs trait implementations turn host data into live JavaScript
//! values, and [`js_to_json`] renders results back the way `JSON.stringify`
//! would.

use bytes::Bytes;
use rquickjs::{Array, Ctx, IntoJs, Object, TypedArray, Value as JsValue};
use serde_json::Value;

use crate::error::{Error, Result};

use super::MAX_BRIDGE_BYTES;

// ---------------------------------------------------------------------------
// JsData: realm-independent materialization
// ---------------------------------------------------------------------------

/// A deep-copied, realm-independent JavaScript value.
///
/// Used where a value must cross between the feed realm and the disposable
/// compute realm (compute input and results). Unlike JSON it preserves
/// `undefined` and raw bytes; functions and symbols are rejected because
/// they cannot be copied.
#[derive(Debug, Clone, PartialEq)]
pub enum JsData {
    Undefined,
    Null,
    Bool(bool),
    Int(i32),
    Num(f64),
    Str(String),
    Bytes(Bytes),
    Arr(Vec<JsData>),
    Obj(Vec<(String, JsData)>),
}

impl JsData {
    /// Materialize JSON-shaped host data (operation input, cursor, auth).
    pub fn from_json(value: &Value) -> Self {
        match value {
            Value::Null => Self::Null,
            Value::Bool(flag) => Self::Bool(*flag),
            Value::Number(number) => {
                if let Some(int) = number.as_i64() {
                    i32::try_from(int)
                        .map(Self::Int)
                        .unwrap_or_else(|_| Self::Num(int as f64))
                } else if let Some(uint) = number.as_u64() {
                    Self::Num(uint as f64)
                } else {
                    Self::Num(number.as_f64().unwrap_or(f64::NAN))
                }
            }
            Value::String(text) => Self::Str(text.clone()),
            Value::Array(items) => Self::Arr(items.iter().map(Self::from_json).collect()),
            Value::Object(entries) => Self::Obj(
                entries
                    .iter()
                    .map(|(key, value)| (key.clone(), Self::from_json(value)))
                    .collect(),
            ),
        }
    }

    /// Render back to JSON (test helpers and diagnostics).
    #[cfg(test)]
    pub fn into_json(self) -> Value {
        match self {
            Self::Undefined | Self::Null => Value::Null,
            Self::Bool(flag) => Value::Bool(flag),
            Self::Int(int) => Value::Number(serde_json::Number::from(i64::from(int))),
            Self::Num(number) => {
                serde_json::Number::from_f64(number).map_or(Value::Null, Value::Number)
            }
            Self::Str(text) => Value::String(text),
            Self::Bytes(_) => Value::Null,
            Self::Arr(items) => Value::Array(items.into_iter().map(Self::into_json).collect()),
            Self::Obj(entries) => Value::Object(
                entries
                    .into_iter()
                    .map(|(key, value)| (key, Self::into_json(value)))
                    .collect(),
            ),
        }
    }

    /// Approximate materialized size, used to keep bridge payloads bounded.
    pub fn measure(&self) -> usize {
        match self {
            Self::Undefined | Self::Null | Self::Bool(_) => 8,
            Self::Int(_) | Self::Num(_) => 16,
            Self::Str(text) => text.len(),
            Self::Bytes(bytes) => bytes.len(),
            Self::Arr(items) => items.len() + items.iter().map(Self::measure).sum::<usize>(),
            Self::Obj(entries) => entries
                .iter()
                .map(|(key, value)| key.len() + 8 + value.measure())
                .sum(),
        }
    }
}

/// Build a live JavaScript value from [`JsData`].
impl<'js> IntoJs<'js> for &JsData {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        Ok(match self {
            JsData::Undefined => JsValue::new_undefined(ctx.clone()),
            JsData::Null => JsValue::new_null(ctx.clone()),
            JsData::Bool(flag) => JsValue::new_bool(ctx.clone(), *flag),
            JsData::Int(int) => JsValue::new_int(ctx.clone(), *int),
            JsData::Num(number) => JsValue::new_float(ctx.clone(), *number),
            JsData::Str(text) => rquickjs::String::from_str(ctx.clone(), text)?.into_value(),
            JsData::Bytes(bytes) => bytes_to_u8array(ctx, bytes)?,
            JsData::Arr(items) => {
                let array = Array::new(ctx.clone())?;
                for (index, item) in items.iter().enumerate() {
                    array.set(index, item)?;
                }
                array.into_value()
            }
            JsData::Obj(entries) => {
                let object = Object::new(ctx.clone())?;
                for (key, value) in entries {
                    object.set(key.as_str(), value)?;
                }
                object.into_value()
            }
        })
    }
}

/// Owned counterpart to the borrow above: freshly materialized values
/// (`JsData::from_json`) go straight into `Object::set` and work through
/// rquickjs's native `Option` conversion.
impl<'js> IntoJs<'js> for JsData {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<JsValue<'js>> {
        (&self).into_js(ctx)
    }
}

/// Materialize a live JavaScript value as [`JsData`].
///
/// Rejects functions, symbols, and BigInt because they cannot be copied
/// across realms. Function-valued object properties are skipped, matching
/// how `JSON.stringify` drops them.
pub fn js_to_jsdata(value: &JsValue<'_>) -> Result<JsData> {
    let data = js_to_jsdata_inner(value)?;
    if data.measure() > MAX_BRIDGE_BYTES {
        return Err(Error::javascript("JavaScript value exceeds the size limit"));
    }
    Ok(data)
}

fn js_to_jsdata_inner(value: &JsValue<'_>) -> Result<JsData> {
    if value.is_undefined() {
        return Ok(JsData::Undefined);
    }
    if value.is_null() {
        return Ok(JsData::Null);
    }
    if value.is_bool() {
        return Ok(JsData::Bool(value.as_bool().unwrap_or(false)));
    }
    if value.is_int() {
        return Ok(JsData::Int(value.as_int().unwrap_or(0)));
    }
    if value.is_float() {
        return Ok(JsData::Num(value.as_float().unwrap_or(f64::NAN)));
    }
    if value.is_string() {
        let text = value
            .get::<String>()
            .map_err(|_| Error::javascript("a string value could not be read"))?;
        return Ok(JsData::Str(text));
    }
    if value.is_big_int() {
        return Err(Error::javascript(
            "BigInt values are not supported; convert them with String() first",
        ));
    }
    if let Some(bytes) = u8_to_bytes(value) {
        return Ok(JsData::Bytes(bytes));
    }
    if value.is_array() {
        let array = value
            .clone()
            .into_array()
            .ok_or_else(|| Error::javascript("an array value could not be materialized"))?;
        let mut items = Vec::with_capacity(array.len());
        for element in array.iter::<JsValue>() {
            let element = element
                .map_err(|error| Error::javascript(format!("array iteration failed: {error}")))?;
            items.push(js_to_jsdata_inner(&element)?);
        }
        return Ok(JsData::Arr(items));
    }
    if value.is_function() {
        return Err(Error::javascript(
            "functions cannot be copied across realms",
        ));
    }
    if let Some(object) = value.clone().into_object() {
        let mut entries = Vec::new();
        for entry in object.props::<String, JsValue>() {
            let (key, prop) = entry
                .map_err(|error| Error::javascript(format!("object iteration failed: {error}")))?;
            // Function-valued properties are dropped, like JSON.stringify.
            if prop.is_function() {
                continue;
            }
            entries.push((key, js_to_jsdata_inner(&prop)?));
        }
        return Ok(JsData::Obj(entries));
    }
    Err(Error::javascript("symbols cannot be copied across realms"))
}

// ---------------------------------------------------------------------------
// JSON conversion
// ---------------------------------------------------------------------------

/// Convert a JavaScript value to JSON the way `JSON.stringify` would:
/// `undefined` and functions are dropped (or rendered `null` inside arrays),
/// objects with a `toJSON` method are converted through it, and non-finite
/// numbers become `null`.
///
/// Returns `None` when the value would be dropped entirely. Typed arrays are
/// rejected with guidance instead of being mangled.
pub fn js_to_json<'js>(ctx: &Ctx<'js>, value: &JsValue<'js>) -> Result<Option<Value>> {
    if value.is_function() {
        return Err(Error::javascript(
            "functions cannot be returned to the host; return plain data instead",
        ));
    }
    if value.is_symbol() {
        return Err(Error::javascript("symbols cannot be returned to the host"));
    }
    let mut size = 0usize;
    convert_to_json(ctx, value, &mut size)
}

fn convert_to_json<'js>(
    ctx: &Ctx<'js>,
    value: &JsValue<'js>,
    size: &mut usize,
) -> Result<Option<Value>> {
    if value.is_undefined() {
        return Ok(None);
    }
    if value.is_null() {
        return Ok(Some(Value::Null));
    }
    if value.is_bool() {
        bump_json_size(size, 5)?;
        return Ok(Some(Value::Bool(value.as_bool().unwrap_or(false))));
    }
    if value.is_int() {
        bump_json_size(size, 8)?;
        let int = value.as_int().unwrap_or(0);
        return Ok(Some(Value::Number(serde_json::Number::from(i64::from(
            int,
        )))));
    }
    if value.is_float() {
        bump_json_size(size, 8)?;
        let number = value.as_float().unwrap_or(f64::NAN);
        // JSON renders non-finite numbers as null.
        return Ok(Some(
            serde_json::Number::from_f64(number).map_or(Value::Null, Value::Number),
        ));
    }
    if value.is_string() {
        let text = value
            .get::<String>()
            .map_err(|_| Error::javascript("a string value could not be read"))?;
        bump_json_size(size, text.len())?;
        return Ok(Some(Value::String(text)));
    }
    if value.is_big_int() {
        return Err(Error::javascript(
            "BigInt values cannot be converted to JSON; use .toString() first",
        ));
    }
    if u8_to_bytes(value).is_some() {
        return Err(Error::javascript(
            "Uint8Array values cannot be returned to the host; decode them with \
             TextDecoder or encode them with Bytes.toBase64/Bytes.toHex first",
        ));
    }
    if value.is_array() {
        let array = value
            .clone()
            .into_array()
            .ok_or_else(|| Error::javascript("an array value could not be read"))?;
        let mut items = Vec::with_capacity(array.len());
        for element in array.iter::<JsValue>() {
            let element = element
                .map_err(|error| Error::javascript(format!("array iteration failed: {error}")))?;
            // Undefined slots and functions become null, like JSON.stringify.
            let converted = convert_to_json(ctx, &element, size)?.unwrap_or(Value::Null);
            bump_json_size(size, 1)?;
            items.push(converted);
        }
        return Ok(Some(Value::Array(items)));
    }
    if let Some(object) = value.clone().into_object() {
        // Honor toJSON like JSON.stringify does (this covers Date).
        if let Ok(to_json) = object.get::<_, rquickjs::Function>("toJSON") {
            let mut arguments = rquickjs::function::Args::new(ctx.clone(), 0);
            arguments.this(object.clone()).map_err(js_call_error)?;
            let converted = to_json.call_arg(arguments).map_err(js_call_error)?;
            return convert_to_json(ctx, &converted, size);
        }
        let mut entries = Vec::new();
        for entry in object.props::<String, JsValue>() {
            let (key, prop) = entry
                .map_err(|error| Error::javascript(format!("object iteration failed: {error}")))?;
            // Function-valued properties are dropped, like JSON.stringify.
            if let Some(converted) = convert_to_json(ctx, &prop, size)? {
                bump_json_size(size, key.len() + 16)?;
                entries.push((key, converted));
            }
        }
        return Ok(Some(Value::Object(entries.into_iter().collect())));
    }
    Ok(None)
}

fn bump_json_size(size: &mut usize, addition: usize) -> Result<()> {
    *size = size
        .checked_add(addition)
        .ok_or_else(|| Error::javascript("JavaScript result exceeds the size limit"))?;
    if *size > MAX_BRIDGE_BYTES {
        return Err(Error::javascript(
            "JavaScript result exceeds the size limit",
        ));
    }
    Ok(())
}

fn js_call_error(error: rquickjs::Error) -> Error {
    Error::javascript(format!("calling toJSON failed: {error}"))
}

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

/// Copy the bytes of a `Uint8Array` value, or `None` if the value is not a
/// byte array (detached buffers included).
pub fn u8_to_bytes(value: &JsValue<'_>) -> Option<Bytes> {
    let typed = TypedArray::<u8>::from_value(value.clone()).ok()?;
    // SAFETY: no JavaScript runs while the slice is borrowed; the bytes are
    // copied immediately.
    let slice = unsafe { typed.as_bytes()? };
    Some(Bytes::copy_from_slice(slice))
}

/// Create a `Uint8Array` value from raw bytes.
pub fn bytes_to_u8array<'js>(ctx: &Ctx<'js>, bytes: &[u8]) -> rquickjs::Result<JsValue<'js>> {
    Ok(TypedArray::<u8>::new_copy(ctx.clone(), bytes)?.into_value())
}

/// Copy the bytes of a typed array argument, rejecting detached buffers.
pub fn typed_bytes<'js>(ctx: &Ctx<'js>, data: &TypedArray<'js, u8>) -> rquickjs::Result<Vec<u8>> {
    // SAFETY: no JavaScript runs while the slice is borrowed.
    match unsafe { data.as_bytes() } {
        Some(slice) => Ok(slice.to_vec()),
        None => Err(rquickjs::Exception::throw_message(
            ctx,
            "expected a Uint8Array, got a detached buffer",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn js_data_json_round_trip_preserves_shapes() {
        let json = serde_json::json!({
            "name": "番茄",
            "count": 3,
            "ratio": 0.5,
            "flag": true,
            "empty": null,
            "list": [1, "two", null],
        });
        let data = JsData::from_json(&json);
        assert_eq!(data.into_json(), json);
    }

    #[test]
    fn js_data_measure_counts_payloads() {
        let data = JsData::Obj(vec![(
            "payload".to_owned(),
            JsData::Bytes(Bytes::from_static(&[7; 100])),
        )]);
        assert!(data.measure() >= 100);
    }
}
