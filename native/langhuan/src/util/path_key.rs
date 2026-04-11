/// Encode an arbitrary string into a filesystem-safe path component.
///
/// The output is prefixed with `h` and then lower-case hex bytes, providing
/// a collision-free mapping for UTF-8 input.
pub fn encode_path_component(raw: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let bytes = raw.as_bytes();
    let mut out = String::with_capacity(1 + bytes.len() * 2);
    out.push('h');
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

/// Decode a hex-encoded path component back to the original string.
///
/// Returns `None` if the input doesn't start with `h` or contains invalid hex.
pub fn decode_path_component(encoded: &str) -> Option<String> {
    let hex = encoded.strip_prefix('h')?;
    if hex.len() % 2 != 0 {
        return None;
    }
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
        .collect::<std::result::Result<_, _>>()
        .ok()?;
    String::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::{decode_path_component, encode_path_component};

    #[test]
    fn encode_component_is_stable_and_non_empty() {
        assert_eq!(encode_path_component(""), "h");
        assert_eq!(encode_path_component("abc"), "h616263");
    }

    #[test]
    fn encode_component_distinguishes_different_inputs() {
        assert_ne!(encode_path_component("a/b"), encode_path_component("a_b"));
    }

    #[test]
    fn decode_roundtrip() {
        for input in ["hello", "a/b", "", "日本語", "feed-123"] {
            let encoded = encode_path_component(input);
            assert_eq!(decode_path_component(&encoded).as_deref(), Some(input));
        }
    }

    #[test]
    fn decode_invalid_returns_none() {
        assert_eq!(decode_path_component("no_prefix"), None);
        assert_eq!(decode_path_component("hzz"), None); // invalid hex
        assert_eq!(decode_path_component("h6"), None); // odd length
    }
}
