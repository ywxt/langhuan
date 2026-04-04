use std::collections::HashSet;

use crate::error::{Error, Result};
use crate::feed::FeedMeta;

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
    version: Option<String>,
    author: Option<String>,
    description: Option<String>,
    base_url: Option<String>,
    allowed_domains: HashSet<String>,
    supports_bookshelf: bool,
}

impl FeedMetaBuilder {
    /// Set a field from a raw header key (e.g. `"name"` or `"name:en"`).
    fn set(&mut self, key: &str, value: String) {
        match key {
            "id" => self.id = Some(value),
            "name" => self.name = Some(value),
            "version" => self.version = Some(value),
            "author" => self.author = Some(value),
            "description" => self.description = Some(value),
            "base_url" => self.base_url = Some(value),
            "allowed_domain" => {
                let domain = value.trim().to_owned();
                if !domain.is_empty() {
                    self.allowed_domains.insert(domain);
                }
            }
            "bookshelf" => {
                self.supports_bookshelf = parse_bool_like(&value).unwrap_or(false);
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
            version: require(self.version, "version")?,
            author: self.author,
            description: self.description,
            base_url: require(self.base_url, "base_url")?,
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
            supports_bookshelf: self.supports_bookshelf,
        })
    }
}

fn parse_bool_like(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Some(true),
        "false" | "0" | "no" | "off" => Some(false),
        _ => None,
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
-- @version      1.0.0
-- @author       someone
-- @description  一個範例書源
-- @base_url     https://example.com
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
        assert_eq!(meta.version, "1.0.0");
        assert_eq!(meta.author.as_deref(), Some("someone"));
        assert_eq!(meta.description.as_deref(), Some("一個範例書源"));
        assert_eq!(meta.base_url, "https://example.com");
        assert!(!meta.supports_bookshelf);
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
        assert!(meta.author.is_none());
        assert!(meta.description.is_none());
    }

    #[test]
    fn allowed_domains_one_per_line() {
        let script = r#"-- ==Feed==
-- @id      test
-- @name    Test
-- @version 1.0
-- @base_url https://example.com
-- @allowed_domain example.com
-- @allowed_domain cdn.example.com
-- ==/Feed==
"#;
        let (meta, _) = parse_meta(script).unwrap();
        assert_eq!(
            meta.allowed_domains,
            HashSet::from(["example.com".to_string(), "cdn.example.com".to_string()])
        );
    }

    #[test]
    fn allowed_domains_empty_when_omitted() {
        let (meta, _) = parse_meta(SAMPLE_SCRIPT).unwrap();
        assert!(meta.allowed_domains.is_empty());
    }

    #[test]
    fn allowed_domains_invalid_hostname() {
        let script = r#"-- ==Feed==
-- @id      test
-- @name    Test
-- @version 1.0
-- @base_url https://example.com
-- @allowed_domain not a valid host
-- ==/Feed==
"#;
        let err = parse_meta(script).unwrap_err();
        assert!(matches!(err, Error::InvalidFeed { .. }));
    }

    #[test]
    fn allowed_domains_blank_value_ignored() {
        let script = "-- ==Feed==\n-- @id test\n-- @name Test\n-- @version 1.0\n-- @base_url https://example.com\n-- @allowed_domain\n-- ==/Feed==\n";
        let (meta, _) = parse_meta(script).unwrap();
        assert!(meta.allowed_domains.is_empty());
    }

    #[test]
    fn bookshelf_capability_defaults_false() {
        let (meta, _) = parse_meta(SAMPLE_SCRIPT).unwrap();
        assert!(!meta.supports_bookshelf);
    }

    #[test]
    fn bookshelf_capability_true_when_declared() {
        let script = r#"-- ==Feed==
-- @id      test
-- @name    Test
-- @version 1.0
-- @base_url https://example.com
-- @bookshelf true
-- ==/Feed==
"#;
        let (meta, _) = parse_meta(script).unwrap();
        assert!(meta.supports_bookshelf);
    }
}
