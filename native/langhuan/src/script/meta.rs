use std::collections::HashMap;

use serde::Serialize;

use crate::error::{Error, Result};

/// Metadata extracted from the `==Feed==` header block of a Lua feed script.
///
/// # Header format
///
/// ```lua
/// -- ==Feed==
/// -- @id           example-feed
/// -- @name         範例書源
/// -- @name:en      Example Feed
/// -- @version      1.0.0
/// -- @author       someone
/// -- @description  一個範例書源
/// -- @base_url     https://example.com
/// -- @charset      utf-8
/// -- @content_type html
/// -- @allowed_domains example.com, cdn.example.com
/// -- ==/Feed==
/// ```
#[derive(Debug, Clone, Serialize)]
pub struct FeedMeta {
    /// Unique identifier for this feed.
    pub id: String,
    /// Display name of the feed (default locale).
    pub name: String,
    /// Localised names keyed by locale code (e.g. `"en"`, `"zh"`).
    pub name_i18n: HashMap<String, String>,
    /// Version string (e.g. `"1.0.0"`).
    pub version: String,
    /// Author of the feed script.
    pub author: Option<String>,
    /// Short description (default locale).
    pub description: Option<String>,
    /// Localised descriptions keyed by locale code.
    pub description_i18n: HashMap<String, String>,
    /// Base URL used by the feed. Available in Lua as `meta.base_url`.
    pub base_url: String,
    /// Character encoding of HTTP responses (e.g. `"utf-8"`, `"gbk"`).
    /// Defaults to `"utf-8"` if omitted.
    pub charset: String,
    /// Expected response content type hint (`"html"` or `"json"`).
    /// Defaults to `"html"` if omitted.
    pub content_type: String,
    /// Allowed domain patterns for HTTP requests made by this feed.
    ///
    /// An empty list means **no restriction** (all domains are allowed).
    /// Each pattern is either an exact hostname (`example.com`) or a wildcard
    /// subdomain pattern (`*.example.com`).
    pub allowed_domains: Vec<String>,
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const HEADER_START: &str = "==Feed==";
const HEADER_END: &str = "==/Feed==";

/// Parse the `==Feed==` metadata header from a Lua feed script.
///
/// Returns the parsed [`FeedMeta`] and the **byte offset** where the header
/// block ends (i.e. the start of the script body).
pub fn parse_meta(script: &str) -> Result<(FeedMeta, usize)> {
    let (header_lines, body_offset) = extract_header_lines(script)?;
    let meta = build_meta(&header_lines)?;
    Ok((meta, body_offset))
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// A raw key-value pair from a header line.
struct HeaderEntry {
    /// The key without the leading `@`, e.g. `"name"` or `"name:en"`.
    key: String,
    /// The value after the key, trimmed.
    value: String,
    /// 1-based line number in the original script (kept for diagnostics).
    #[allow(dead_code)]
    line: usize,
}

/// Extract header lines between `==Feed==` and `==/Feed==`.
///
/// Returns the list of parsed entries and the byte offset of the first byte
/// after the closing `==/Feed==` line.
fn extract_header_lines(script: &str) -> Result<(Vec<HeaderEntry>, usize)> {
    let mut entries = Vec::new();
    let mut in_header = false;
    let mut body_offset: Option<usize> = None;

    for (line_idx, line) in script.lines().enumerate() {
        let line_num = line_idx + 1;
        let trimmed = line.trim();

        // Strip leading `--` (Lua comment prefix).
        let content = if let Some(rest) = trimmed.strip_prefix("--") {
            rest.trim()
        } else {
            trimmed
        };

        if !in_header {
            if content == HEADER_START {
                in_header = true;
            }
            continue;
        }

        // Inside the header block.
        if content == HEADER_END {
            // Calculate byte offset: position after this line (including newline).
            let line_start = script.len() - script[script_offset_of_line(script, line_idx)..].len();
            let line_end_offset = line_start + line.len();
            // Skip the trailing newline if present.
            body_offset = Some(if script.as_bytes().get(line_end_offset) == Some(&b'\n') {
                line_end_offset + 1
            } else {
                line_end_offset
            });
            break;
        }

        // Parse `@key value`.
        if let Some(rest) = content.strip_prefix('@') {
            let (key, value) = match rest.split_once(char::is_whitespace) {
                Some((k, v)) => (k.trim().to_owned(), v.trim().to_owned()),
                None => (rest.trim().to_owned(), String::new()),
            };
            entries.push(HeaderEntry {
                key,
                value,
                line: line_num,
            });
        }
        // Lines without `@` inside the header are ignored (comments, blank).
    }

    if !in_header {
        return Err(Error::ScriptParse {
            line: 1,
            message: "missing ==Feed== header".to_owned(),
        });
    }

    if body_offset.is_none() {
        return Err(Error::ScriptParse {
            line: 1,
            message: "missing ==/Feed== closing tag".to_owned(),
        });
    }

    Ok((entries, body_offset.unwrap_or(0)))
}

/// Return the byte offset of the `n`-th line (0-indexed) in `s`.
fn script_offset_of_line(s: &str, n: usize) -> usize {
    s.lines()
        .take(n)
        .map(|l| l.len() + 1) // +1 for '\n'
        .sum()
}

/// Intermediate builder for [`FeedMeta`].
///
/// All fields start as `None` / empty. Call [`set`](Self::set) for each
/// `@key value` entry, then [`build`](Self::build) to validate required
/// fields and produce the final [`FeedMeta`].
#[derive(Default)]
struct FeedMetaBuilder {
    id: Option<String>,
    name: Option<String>,
    name_i18n: HashMap<String, String>,
    version: Option<String>,
    author: Option<String>,
    description: Option<String>,
    description_i18n: HashMap<String, String>,
    base_url: Option<String>,
    charset: Option<String>,
    content_type: Option<String>,
    allowed_domains: Vec<String>,
}

impl FeedMetaBuilder {
    /// Set a field from a raw header key (e.g. `"name"` or `"name:en"`).
    fn set(&mut self, key: &str, value: String) {
        // Split key into base and optional locale, e.g. "name:en" → ("name", Some("en")).
        let (base_key, locale) = match key.split_once(':') {
            Some((base, loc)) => (base, Some(loc)),
            None => (key, None),
        };

        match (base_key, locale) {
            ("id", None) => self.id = Some(value),
            ("name", None) => self.name = Some(value),
            ("name", Some(loc)) => {
                self.name_i18n.insert(loc.to_owned(), value);
            }
            ("version", None) => self.version = Some(value),
            ("author", None) => self.author = Some(value),
            ("description", None) => self.description = Some(value),
            ("description", Some(loc)) => {
                self.description_i18n.insert(loc.to_owned(), value);
            }
            ("base_url", None) => self.base_url = Some(value),
            ("charset", None) => self.charset = Some(value),
            ("content_type", None) => self.content_type = Some(value),
            ("allowed_domains", None) => {
                self.allowed_domains = value
                    .split(',')
                    .map(|s| s.trim().to_owned())
                    .filter(|s| !s.is_empty())
                    .collect();
            }
            _ => {
                // Unknown keys are silently ignored for forward compatibility.
            }
        }
    }

    /// Validate required fields and produce the final [`FeedMeta`].
    fn build(self) -> Result<FeedMeta> {
        /// Helper: ensure a required field is `Some` and non-empty.
        fn require(field: Option<String>, name: &str) -> Result<String> {
            match field {
                Some(v) if !v.is_empty() => Ok(v),
                _ => Err(Error::InvalidFeed {
                    message: format!("missing required field: @{name}"),
                }),
            }
        }

        Ok(FeedMeta {
            id: require(self.id, "id")?,
            name: require(self.name, "name")?,
            name_i18n: self.name_i18n,
            version: require(self.version, "version")?,
            author: self.author,
            description: self.description,
            description_i18n: self.description_i18n,
            base_url: require(self.base_url, "base_url")?,
            charset: self.charset.unwrap_or_else(|| "utf-8".to_owned()),
            content_type: self.content_type.unwrap_or_else(|| "html".to_owned()),
            allowed_domains: {
                for entry in &self.allowed_domains {
                    if !is_valid_hostname(entry) {
                        return Err(Error::InvalidFeed {
                            message: format!("invalid domain in allowed_domains: '{entry}'"),
                        });
                    }
                }
                self.allowed_domains
            },
        })
    }
}

/// Return `true` if `s` is a valid hostname accepted by the URL parser.
///
/// Delegates to `reqwest::Url` so the same rules applied to actual HTTP
/// requests are used here.
fn is_valid_hostname(s: &str) -> bool {
    reqwest::Url::parse(&format!("http://{s}/"))
        .map(|u| u.host_str().is_some_and(|h| h.eq_ignore_ascii_case(s)))
        .unwrap_or(false)
}

/// Build a [`FeedMeta`] from raw header entries.
fn build_meta(entries: &[HeaderEntry]) -> Result<FeedMeta> {
    let mut builder = FeedMetaBuilder::default();
    for entry in entries {
        builder.set(&entry.key, entry.value.clone());
    }
    builder.build()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_SCRIPT: &str = r#"-- ==Feed==
-- @id           example-feed
-- @name         範例書源
-- @name:en      Example Feed
-- @version      1.0.0
-- @author       someone
-- @description  一個範例書源
-- @base_url     https://example.com
-- @charset      utf-8
-- @content_type html
-- ==/Feed==

function search_request(keyword, cursor)
    return {}
end
"#;

    #[test]
    fn parse_valid_header() {
        let (meta, offset) = parse_meta(SAMPLE_SCRIPT).unwrap();
        assert_eq!(meta.id, "example-feed");
        assert_eq!(meta.name, "範例書源");
        assert_eq!(
            meta.name_i18n.get("en").map(String::as_str),
            Some("Example Feed")
        );
        assert_eq!(meta.version, "1.0.0");
        assert_eq!(meta.author.as_deref(), Some("someone"));
        assert_eq!(meta.description.as_deref(), Some("一個範例書源"));
        assert_eq!(meta.base_url, "https://example.com");
        assert_eq!(meta.charset, "utf-8");
        assert_eq!(meta.content_type, "html");
        // Body should start after the header.
        assert!(offset > 0);
        assert!(SAMPLE_SCRIPT[offset..].contains("function search_request"));
    }

    #[test]
    fn missing_header_start() {
        let script = "-- just a comment\nfunction foo() end";
        let err = parse_meta(script).unwrap_err();
        assert!(matches!(err, Error::ScriptParse { .. }));
    }

    #[test]
    fn missing_header_end() {
        let script = "-- ==Feed==\n-- @id test\n-- @name test\n";
        let err = parse_meta(script).unwrap_err();
        assert!(matches!(err, Error::ScriptParse { .. }));
    }

    #[test]
    fn missing_required_field() {
        let script = "-- ==Feed==\n-- @id test\n-- ==/Feed==\n";
        let err = parse_meta(script).unwrap_err();
        assert!(matches!(err, Error::InvalidFeed { .. }));
    }

    #[test]
    fn defaults_for_optional_fields() {
        let script = r#"-- ==Feed==
-- @id      test
-- @name    Test
-- @version 1.0
-- @base_url https://example.com
-- ==/Feed==
"#;
        let (meta, _) = parse_meta(script).unwrap();
        assert_eq!(meta.charset, "utf-8");
        assert_eq!(meta.content_type, "html");
        assert!(meta.author.is_none());
        assert!(meta.description.is_none());
    }
}
