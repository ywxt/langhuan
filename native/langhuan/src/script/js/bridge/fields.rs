//! Field readers over live JavaScript objects.
//!
//! [`Fields`] reads an object field by field and reports every failure as a
//! conversion error whose message slot names the offending field. Boundary
//! functions extract that detail with [`conversion_detail`] and prefix their
//! own context label — a host error for script results, a thrown exception
//! for host API arguments — so the same reader works under any caller.

use rquickjs::{
    Ctx, Error as JsError, FromJs, Object, Result as JsResult, TypedArray, Value as JsValue,
};
use serde_json::Value;

use super::convert::{JsData, js_to_jsdata, js_to_json};
use crate::error::Error;

/// The detail message of a conversion error, for boundaries that prefix a
/// context label instead of formatting the generic conversion framing.
pub fn conversion_detail(error: JsError) -> String {
    match error {
        JsError::FromJs {
            message: Some(detail),
            ..
        } => detail,
        other => other.to_string(),
    }
}

/// Field readers over a live object, so extraction errors name the offending
/// field. The detail travels in the conversion error's message slot; the
/// boundary functions prefix the context label.
pub struct Fields<'js> {
    object: Object<'js>,
    /// The Rust type being read, named if an error escapes a boundary raw.
    type_name: &'static str,
}

impl<'js> Fields<'js> {
    /// Read `value` as an object for conversion into `type_name`.
    pub fn new(value: JsValue<'js>, type_name: &'static str) -> JsResult<Self> {
        let js_type = value.type_name();
        let object = value.into_object().ok_or_else(|| {
            JsError::new_from_js_message(js_type, type_name, "expected an object")
        })?;
        Ok(Self { object, type_name })
    }

    /// A conversion failure with an arbitrary detail.
    pub fn invalid(&self, detail: impl Into<String>) -> JsError {
        JsError::new_from_js_message("object", self.type_name, detail.into())
    }

    /// Fetch a field's live value.
    pub fn value(&self, field: &str) -> JsResult<JsValue<'js>> {
        self.object
            .get::<_, JsValue>(field)
            .map_err(|error| self.invalid(format!("reading `{field}` failed: {error}")))
    }

    /// A required field that is absent.
    pub fn missing(&self, field: &str) -> JsError {
        self.invalid(format!("missing field `{field}`"))
    }

    /// A field with the wrong shape.
    pub fn error(&self, field: &str, problem: &str) -> JsError {
        self.invalid(format!("`{field}` {problem}"))
    }

    /// A host-side conversion failure for a field.
    pub fn conversion_error(&self, field: &str, error: Error) -> JsError {
        self.invalid(format!("`{field}`: {error}"))
    }

    pub fn required_string(&self, field: &str) -> JsResult<String> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        value
            .get::<String>()
            .map_err(|_| self.error(field, "must be a string"))
    }

    pub fn optional_string(&self, field: &str) -> JsResult<Option<String>> {
        let value = self.value(field)?;
        if value.is_undefined() || value.is_null() {
            return Ok(None);
        }
        value
            .get::<String>()
            .map(Some)
            .map_err(|_| self.error(field, "must be a string"))
    }

    pub fn required_object(&self, field: &str) -> JsResult<Object<'js>> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        value
            .into_object()
            .ok_or_else(|| self.error(field, "must be an object"))
    }

    pub fn string_array(&self, field: &str) -> JsResult<Vec<String>> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        if !value.is_array() {
            return Err(self.error(field, "must be an array of strings"));
        }
        let array = value
            .into_array()
            .ok_or_else(|| self.error(field, "must be an array of strings"))?;
        let mut items = Vec::with_capacity(array.len());
        for entry in array.iter::<JsValue>() {
            let entry = entry
                .map_err(|error| self.invalid(format!("reading `{field}` failed: {error}")))?;
            let text = entry
                .get::<String>()
                .map_err(|_| self.error(field, "must contain only strings"))?;
            items.push(text);
        }
        Ok(items)
    }

    /// A field that must be a `Uint8Array`.
    pub fn required_bytes(&self, ctx: &Ctx<'js>, field: &str) -> JsResult<Vec<u8>> {
        let value = self.value(field)?;
        if value.is_undefined() {
            return Err(self.missing(field));
        }
        self.byte_field(ctx, field, value)
    }

    /// An optional field that must be a `Uint8Array` when present.
    pub fn optional_bytes(&self, ctx: &Ctx<'js>, field: &str) -> JsResult<Option<Vec<u8>>> {
        let value = self.value(field)?;
        if value.is_undefined() || value.is_null() {
            return Ok(None);
        }
        Ok(Some(self.byte_field(ctx, field, value)?))
    }

    /// A field value that must be a `Uint8Array` with an attached buffer.
    fn byte_field(&self, ctx: &Ctx<'js>, field: &str, value: JsValue<'js>) -> JsResult<Vec<u8>> {
        let typed = TypedArray::<u8>::from_js(ctx, value)
            .map_err(|_| self.error(field, "must be a Uint8Array"))?;
        // SAFETY: no JavaScript runs while the slice is borrowed; the bytes
        // are copied immediately.
        match unsafe { typed.as_bytes() } {
            Some(slice) => Ok(slice.to_vec()),
            None => Err(self.error(field, "must not be a detached buffer")),
        }
    }

    /// Read a field as realm-independent data, for values that travel back
    /// into the realm untouched (unlike JSON fields, which the host
    /// materializes for serde).
    pub fn data_field(&self, field: &str) -> JsResult<Option<JsData>> {
        let value = self.value(field)?;
        if value.is_undefined() || value.is_null() {
            return Ok(None);
        }
        js_to_jsdata(&value)
            .map(Some)
            .map_err(|error| self.conversion_error(field, error))
    }

    /// Convert a field to JSON, rejecting bytes and other non-JSON values.
    pub fn json_field(&self, ctx: &Ctx<'js>, field: &str) -> JsResult<Option<Value>> {
        let value = self.value(field)?;
        if value.is_undefined() || value.is_null() {
            return Ok(None);
        }
        js_to_json(ctx, &value).map_err(|error| self.conversion_error(field, error))
    }
}
