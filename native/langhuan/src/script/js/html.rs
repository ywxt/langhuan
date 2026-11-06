//! The `langhuan:html` module: `HTML`.
//!
//! The interface follows jQuery and the browser's DOM surface: selections
//! carry jQuery traversal methods (`find`, `parent`, `children`, `closest`,
//! `first`, `last`, `eq`, `each`), and nodes follow browser element
//! semantics (`tagName` uppercased, `attr` returning `""` for an empty
//! attribute and `undefined` only when absent, `closest` walking
//! ancestor-or-self). Results merged from several roots are deduplicated
//! and ordered like jQuery's `uniqueSort`. `encodeURIComponent` provides
//! the browser's component encoding with an optional non-UTF-8 charset,
//! and `encodeURIComponents` encodes `[key, value]` pairs into a
//! `key=value&key=value` query string.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use ego_tree::{NodeId, NodeRef};
use encoding_rs::Encoding;
use rquickjs::function::{Args, Opt, This};
use rquickjs::module::{Declarations, Exports, ModuleDef};
use rquickjs::{Array, Ctx, Exception, Function, Object, Result as JsResult, Value};
use scraper::{ElementRef, Html, Node, Selector};

use super::module::{Namespace, declare_module, set_function};

/// The `langhuan:html` module: `HTML`.
struct HtmlModule;

impl ModuleDef for HtmlModule {
    fn declare<'js>(declarations: &Declarations<'js>) -> JsResult<()> {
        declarations.declare("HTML")?;
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> JsResult<()> {
        exports.export("HTML", html(ctx)?)?;
        Ok(())
    }
}

/// Declare the `langhuan:html` module in the realm.
pub(super) fn declare<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    declare_module::<HtmlModule>(ctx, "langhuan:html")
}

const MAX_HTML_INPUT_BYTES: usize = 4 * 1024 * 1024;

fn js_error<'js, T>(ctx: &Ctx<'js>, message: impl AsRef<str>) -> JsResult<T> {
    Err(Exception::throw_message(ctx, message.as_ref()))
}

/// Descendant text of one node: `<br>` reads as `\n` and `script`/`style`
/// content is skipped, like the browser's `innerText`.
fn append_text(node: NodeRef<'_, Node>, output: &mut String) {
    match node.value() {
        Node::Text(text) => output.push_str(text),
        Node::Element(element) if element.name() == "br" => output.push('\n'),
        Node::Element(element) if matches!(element.name(), "script" | "style") => return,
        _ => {}
    }
    for child in node.children() {
        append_text(child, output);
    }
}

/// Percent-encode bytes like the browser's `encodeURIComponent`, leaving
/// the alphanumeric set and `-_.!~*'()` unescaped.
fn percent_encode_component(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut output = String::with_capacity(bytes.len());
    for &byte in bytes {
        if byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')'
            )
        {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(HEX[(byte >> 4) as usize] as char);
            output.push(HEX[(byte & 0x0F) as usize] as char);
        }
    }
    output
}

// ---------------------------------------------------------------------------
// The parsed document
// ---------------------------------------------------------------------------

/// A parsed document shared by every node and selection handed to scripts.
#[derive(Debug)]
struct Document {
    dom: Mutex<Html>,
    /// Pre-order document position of each node, built on first sort. The
    /// tree never changes after parsing, so the index cannot go stale; it
    /// orders results merged from several roots like jQuery's `uniqueSort`.
    positions: OnceLock<HashMap<NodeId, u32>>,
}

type SharedDocument = Arc<Document>;

impl Document {
    fn new(input: &str) -> Self {
        Self {
            dom: Mutex::new(Html::parse_document(input)),
            positions: OnceLock::new(),
        }
    }

    /// Lock the tree for one read.
    fn lock<'a, 'js>(&'a self, ctx: &Ctx<'js>) -> JsResult<MutexGuard<'a, Html>> {
        self.dom
            .lock()
            .map_err(|_| Exception::throw_internal(ctx, "HTML document lock poisoned"))
    }

    /// Parse a CSS selector, throwing with the invalid selector named.
    fn parse_selector<'js>(ctx: &Ctx<'js>, selector: &str) -> JsResult<Selector> {
        Selector::parse(selector).map_err(|error| {
            Exception::throw_message(ctx, &format!("invalid selector '{selector}': {error}"))
        })
    }

    /// The element for a node id.
    fn element(dom: &Html, node_id: NodeId) -> Option<ElementRef<'_>> {
        dom.tree.get(node_id).and_then(ElementRef::wrap)
    }

    /// Whether one element matches `selector`.
    ///
    /// scraper exposes matching only through subtree selects, so the test
    /// runs the selector in the element's scope — its parent element, or
    /// the whole document for the root element — and checks membership.
    /// Combinators stay structural, so membership there equals a plain
    /// match here.
    fn matches(dom: &Html, node_id: NodeId, selector: &Selector) -> bool {
        let Some(node) = dom.tree.get(node_id) else {
            return false;
        };
        let scope = node
            .parent()
            .and_then(|parent| ElementRef::wrap(parent).map(|element| element.id()));
        match scope {
            Some(scope) => Self::element(dom, scope)
                .into_iter()
                .flat_map(|scope| scope.select(selector))
                .any(|found| found.id() == node_id),
            None => dom.select(selector).any(|found| found.id() == node_id),
        }
    }

    /// The nearest ancestor-or-self element matching `selector`, like the
    /// browser's `Element.closest`.
    fn closest_id(dom: &Html, node_id: NodeId, selector: &Selector) -> Option<NodeId> {
        let mut current = dom.tree.get(node_id)?;
        loop {
            if let Some(candidate) = ElementRef::wrap(current)
                && Self::matches(dom, candidate.id(), selector)
            {
                return Some(candidate.id());
            }
            current = current.parent()?;
        }
    }

    // -- Single-node readers ------------------------------------------------

    /// Descendant text of one node, following the `innerText` rules of
    /// [`append_text`].
    fn text<'js>(&self, ctx: &Ctx<'js>, node_id: NodeId) -> JsResult<String> {
        let dom = self.lock(ctx)?;
        let Some(node) = dom.tree.get(node_id) else {
            return js_error(ctx, "HTML node no longer exists");
        };
        let mut output = String::new();
        append_text(node, &mut output);
        Ok(output)
    }

    /// Attribute value of one element: `Some("")` for an empty attribute
    /// and `None` only when absent, matching the browser's `getAttribute`
    /// modulo its use of `null`.
    fn attr<'js>(
        &self,
        ctx: &Ctx<'js>,
        node_id: NodeId,
        name: &str,
    ) -> JsResult<Option<String>> {
        let dom = self.lock(ctx)?;
        Ok(Self::element(&dom, node_id).and_then(|node| node.attr(name).map(str::to_owned)))
    }

    /// Every attribute of one element as name/value pairs.
    fn attrs<'js>(
        &self,
        ctx: &Ctx<'js>,
        node_id: NodeId,
    ) -> JsResult<Vec<(String, String)>> {
        let dom = self.lock(ctx)?;
        Ok(Self::element(&dom, node_id)
            .map(|node| {
                node.value()
                    .attrs()
                    .map(|(name, value)| (name.to_owned(), value.to_owned()))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Serialized HTML of one element: outer when `outer`, inner otherwise.
    fn html<'js>(
        &self,
        ctx: &Ctx<'js>,
        node_id: NodeId,
        outer: bool,
    ) -> JsResult<Option<String>> {
        let dom = self.lock(ctx)?;
        Ok(Self::element(&dom, node_id).map(|node| if outer {
            node.html()
        } else {
            node.inner_html()
        }))
    }

    // -- Traversal merged over roots ----------------------------------------

    /// Deduplicate ids and order them by document position, like jQuery's
    /// `uniqueSort`. Also corrects whole-document selects, which scraper
    /// yields in arena insertion order rather than document order.
    fn unique_sorted(&self, dom: &Html, mut ids: Vec<NodeId>) -> Vec<NodeId> {
        if ids.len() <= 1 {
            return ids;
        }
        let positions = self.positions.get_or_init(|| {
            // Iterative pre-order walk: children are pushed reversed so
            // they pop in document order.
            let mut positions = HashMap::new();
            let mut stack = vec![dom.tree.root()];
            let mut next = 0u32;
            while let Some(node) = stack.pop() {
                positions.insert(node.id(), next);
                next += 1;
                stack.extend(node.children().rev());
            }
            positions
        });
        let mut seen = HashSet::new();
        ids.retain(|id| seen.insert(*id));
        ids.sort_by_key(|id| positions.get(id).copied().unwrap_or(u32::MAX));
        ids
    }

    /// Matching descendants of every root, merged in document order.
    fn find_ids<'js>(
        &self,
        ctx: &Ctx<'js>,
        roots: &[NodeId],
        selector: &str,
    ) -> JsResult<Vec<NodeId>> {
        let selector = Self::parse_selector(ctx, selector)?;
        let dom = self.lock(ctx)?;
        let mut selected = Vec::new();
        for root in roots {
            let Some(root) = Self::element(&dom, *root) else {
                continue;
            };
            for found in root.select(&selector) {
                selected.push(found.id());
            }
        }
        Ok(self.unique_sorted(&dom, selected))
    }

    /// Immediate parent elements of every root, optionally filtered.
    fn parent_ids<'js>(
        &self,
        ctx: &Ctx<'js>,
        roots: &[NodeId],
        filter: Option<&str>,
    ) -> JsResult<Vec<NodeId>> {
        let filter = filter
            .map(|selector| Self::parse_selector(ctx, selector))
            .transpose()?;
        let dom = self.lock(ctx)?;
        let mut selected = Vec::new();
        for root in roots {
            let Some(parent) = dom.tree.get(*root).and_then(|node| {
                node.ancestors()
                    .find_map(|parent| ElementRef::wrap(parent).map(|element| element.id()))
            }) else {
                continue;
            };
            if let Some(filter) = &filter
                && !Self::matches(&dom, parent, filter)
            {
                continue;
            }
            selected.push(parent);
        }
        Ok(self.unique_sorted(&dom, selected))
    }

    /// Direct child elements of every root, optionally filtered.
    fn children_ids<'js>(
        &self,
        ctx: &Ctx<'js>,
        roots: &[NodeId],
        filter: Option<&str>,
    ) -> JsResult<Vec<NodeId>> {
        let filter = filter
            .map(|selector| Self::parse_selector(ctx, selector))
            .transpose()?;
        let dom = self.lock(ctx)?;
        let mut selected = Vec::new();
        for root in roots {
            for child in dom
                .tree
                .get(*root)
                .into_iter()
                .flat_map(|node| node.children())
                .filter_map(ElementRef::wrap)
            {
                if let Some(filter) = &filter
                    && !Self::matches(&dom, child.id(), filter)
                {
                    continue;
                }
                selected.push(child.id());
            }
        }
        Ok(self.unique_sorted(&dom, selected))
    }

    /// Nearest ancestor-or-self match for every root, merged in document
    /// order.
    fn closest_ids<'js>(
        &self,
        ctx: &Ctx<'js>,
        roots: &[NodeId],
        selector: &str,
    ) -> JsResult<Vec<NodeId>> {
        let selector = Self::parse_selector(ctx, selector)?;
        let dom = self.lock(ctx)?;
        let mut selected = Vec::new();
        for root in roots {
            if let Some(closest) = Self::closest_id(&dom, *root, &selector) {
                selected.push(closest);
            }
        }
        Ok(self.unique_sorted(&dom, selected))
    }
}

// ---------------------------------------------------------------------------
// JavaScript object builders
// ---------------------------------------------------------------------------

fn build_selection<'js>(
    ctx: &Ctx<'js>,
    document: SharedDocument,
    nodes: Vec<NodeId>,
) -> JsResult<Array<'js>> {
    let selection = Array::new(ctx.clone())?;
    for (index, node_id) in nodes.iter().copied().enumerate() {
        selection.set(index, build_node(ctx, document.clone(), node_id)?)?;
    }

    let selection_object = selection.as_object();
    set_function(ctx, selection_object, "first", |this: This<Array<'js>>| {
        this.0.get::<Value>(0)
    })?;

    set_function(
        ctx,
        selection_object,
        "last",
        |ctx: Ctx<'js>, this: This<Array<'js>>| {
            let len = this.0.len();
            if len == 0 {
                return Ok(Value::new_undefined(ctx));
            }
            this.0.get::<Value>(len - 1)
        },
    )?;

    set_function(
        ctx,
        selection_object,
        "eq",
        |ctx: Ctx<'js>, this: This<Array<'js>>, index: i32| {
            let len = this.0.len() as i32;
            let index = if index < 0 { index + len } else { index };
            if index < 0 || index >= len {
                return Ok(Value::new_undefined(ctx));
            }
            this.0.get::<Value>(index as usize)
        },
    )?;

    set_function(
        ctx,
        selection_object,
        "each",
        |ctx: Ctx<'js>, this: This<Array<'js>>, callback: Function<'js>| {
            for index in 0..this.0.len() {
                let node = this.0.get::<Object>(index)?;
                let mut arguments = Args::new(ctx.clone(), 2);
                arguments.this(node.clone())?;
                arguments.push_arg(Value::new_number(ctx.clone(), index as f64))?;
                arguments.push_arg(node)?;
                let result: Value = callback.call_arg(arguments)?;
                if result.as_bool() == Some(false) {
                    break;
                }
            }
            Ok::<_, rquickjs::Error>(this.0)
        },
    )?;

    let text_document = document.clone();
    let text_nodes = nodes.clone();
    set_function(
        ctx,
        selection_object,
        "text",
        move |ctx: Ctx<'js>| -> JsResult<String> {
            let mut output = String::new();
            for node_id in &text_nodes {
                output.push_str(&text_document.text(&ctx, *node_id)?);
            }
            Ok(output)
        },
    )?;

    let attr_document = document.clone();
    let attr_node = nodes.first().copied();
    set_function(
        ctx,
        selection_object,
        "attr",
        move |ctx: Ctx<'js>, name: String| {
            attr_node
                .map(|node_id| attr_document.attr(&ctx, node_id, &name))
                .transpose()
                .map(Option::flatten)
        },
    )?;

    let attrs_document = document.clone();
    let attrs_node = nodes.first().copied();
    set_function(
        ctx,
        selection_object,
        "attrs",
        move |ctx: Ctx<'js>| -> JsResult<Object<'js>> {
            let attributes = Object::new(ctx.clone())?;
            if let Some(node_id) = attrs_node {
                for (name, value) in attrs_document.attrs(&ctx, node_id)? {
                    attributes.set(name, value)?;
                }
            }
            Ok(attributes)
        },
    )?;

    for (name, outer) in [("html", false), ("outerHTML", true)] {
        let html_document = document.clone();
        let html_node = nodes.first().copied();
        set_function(ctx, selection_object, name, move |ctx: Ctx<'js>| {
            html_node
                .map(|node_id| html_document.html(&ctx, node_id, outer))
                .transpose()
                .map(Option::flatten)
        })?;
    }

    let find_document = document.clone();
    let find_nodes = nodes.clone();
    set_function(
        ctx,
        selection_object,
        "find",
        move |ctx: Ctx<'js>, selector: String| {
            let selected = find_document.find_ids(&ctx, &find_nodes, &selector)?;
            build_selection(&ctx, find_document.clone(), selected)
        },
    )?;

    let parent_document = document.clone();
    let parent_nodes = nodes.clone();
    set_function(
        ctx,
        selection_object,
        "parent",
        move |ctx: Ctx<'js>, filter: Opt<String>| {
            let selected =
                parent_document.parent_ids(&ctx, &parent_nodes, filter.0.as_deref())?;
            build_selection(&ctx, parent_document.clone(), selected)
        },
    )?;

    let children_document = document.clone();
    let children_nodes = nodes.clone();
    set_function(
        ctx,
        selection_object,
        "children",
        move |ctx: Ctx<'js>, filter: Opt<String>| {
            let selected =
                children_document.children_ids(&ctx, &children_nodes, filter.0.as_deref())?;
            build_selection(&ctx, children_document.clone(), selected)
        },
    )?;

    let closest_document = document;
    let closest_nodes = nodes;
    set_function(
        ctx,
        selection_object,
        "closest",
        move |ctx: Ctx<'js>, selector: String| {
            let selected = closest_document.closest_ids(&ctx, &closest_nodes, &selector)?;
            build_selection(&ctx, closest_document.clone(), selected)
        },
    )?;
    Ok(selection)
}

fn build_node<'js>(
    ctx: &Ctx<'js>,
    document: SharedDocument,
    node_id: NodeId,
) -> JsResult<Object<'js>> {
    let node = Object::new(ctx.clone())?;
    // Browser DOM: element names report uppercased, like `Element.tagName`.
    let tag_name = {
        let dom = document.lock(ctx)?;
        Document::element(&dom, node_id)
            .map(|element| element.value().name().to_uppercase())
            .unwrap_or_default()
    };
    node.set("tagName", tag_name)?;

    let text_document = document.clone();
    set_function(
        ctx,
        &node,
        "text",
        move |ctx: Ctx<'js>| -> JsResult<String> { text_document.text(&ctx, node_id) },
    )?;

    let attr_document = document.clone();
    set_function(ctx, &node, "attr", move |ctx: Ctx<'js>, name: String| {
        attr_document.attr(&ctx, node_id, &name)
    })?;

    let attrs_document = document.clone();
    set_function(
        ctx,
        &node,
        "attrs",
        move |ctx: Ctx<'js>| -> JsResult<Object<'js>> {
            let attributes = Object::new(ctx.clone())?;
            for (name, value) in attrs_document.attrs(&ctx, node_id)? {
                attributes.set(name, value)?;
            }
            Ok(attributes)
        },
    )?;

    for (name, outer) in [("html", false), ("outerHTML", true)] {
        let html_document = document.clone();
        set_function(ctx, &node, name, move |ctx: Ctx<'js>| {
            html_document.html(&ctx, node_id, outer)
        })?;
    }

    let find_document = document.clone();
    set_function(
        ctx,
        &node,
        "find",
        move |ctx: Ctx<'js>, selector: String| {
            let selected = find_document.find_ids(&ctx, &[node_id], &selector)?;
            build_selection(&ctx, find_document.clone(), selected)
        },
    )?;

    // Relations are functions, like jQuery's traversal methods; the browser
    // property names stay available through the return values.
    let parent_document = document.clone();
    set_function(ctx, &node, "parent", move |ctx: Ctx<'js>| {
        let parents = parent_document.parent_ids(&ctx, &[node_id], None)?;
        parents
            .first()
            .map(|id| build_node(&ctx, parent_document.clone(), *id))
            .transpose()
    })?;

    let children_document = document.clone();
    set_function(ctx, &node, "children", move |ctx: Ctx<'js>| {
        let children = children_document.children_ids(&ctx, &[node_id], None)?;
        build_selection(&ctx, children_document.clone(), children)
    })?;

    let closest_document = document;
    set_function(
        ctx,
        &node,
        "closest",
        move |ctx: Ctx<'js>, selector: String| {
            let closest = closest_document.closest_ids(&ctx, &[node_id], &selector)?;
            closest
                .first()
                .map(|id| build_node(&ctx, closest_document.clone(), *id))
                .transpose()
        },
    )?;
    Ok(node)
}

fn build_document<'js>(ctx: &Ctx<'js>, document: SharedDocument) -> JsResult<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    let find_document = document;
    set_function(ctx, &object, "find", move |ctx: Ctx<'js>, selector: String| {
        // The lock must be released before building the selection: nodes
        // lock the document again when they read their `tagName`.
        let selected = {
            let selector = Document::parse_selector(&ctx, &selector)?;
            let dom = find_document.lock(&ctx)?;
            let selected: Vec<NodeId> =
                dom.select(&selector).map(|found| found.id()).collect();
            find_document.unique_sorted(&dom, selected)
        };
        build_selection(&ctx, find_document.clone(), selected)
    })?;

    Ok(object)
}

// ---------------------------------------------------------------------------
// Namespace
// ---------------------------------------------------------------------------

fn html<'js>(ctx: &Ctx<'js>) -> JsResult<Object<'js>> {
    Ok(Namespace::new(ctx)?
        .function("parse", |ctx: Ctx<'js>, input: String| {
            if input.trim().is_empty() {
                return js_error(&ctx, "HTML.parse: input is empty");
            }
            if input.len() > MAX_HTML_INPUT_BYTES {
                return js_error(&ctx, "HTML.parse: input exceeds the 4 MiB limit");
            }
            build_document(&ctx, Arc::new(Document::new(&input)))
        })?
        .function("decodeEntities", |ctx: Ctx<'js>, input: String| {
            if input.len() > MAX_HTML_INPUT_BYTES {
                return js_error(&ctx, "HTML.decodeEntities: input exceeds the 4 MiB limit");
            }
            let document = Html::parse_fragment(&input);
            let mut output = String::new();
            append_text(document.tree.root(), &mut output);
            Ok(output)
        })?
        .function(
            "encodeURIComponent",
            |ctx: Ctx<'js>, value: String, charset: Opt<String>| -> JsResult<String> {
                let label = charset.0.unwrap_or_else(|| "utf-8".to_owned());
                let Some(encoding) = Encoding::for_label(label.as_bytes()) else {
                    return js_error(
                        &ctx,
                        format!("HTML.encodeURIComponent: unknown encoding label {label:?}"),
                    );
                };
                let (bytes, _encoding, _had_errors) = encoding.encode(&value);
                Ok(percent_encode_component(&bytes))
            },
        )?
        .function(
            "encodeURIComponents",
            |ctx: Ctx<'js>, pairs: Array<'js>, charset: Opt<String>| -> JsResult<String> {
                let label = charset.0.unwrap_or_else(|| "utf-8".to_owned());
                let Some(encoding) = Encoding::for_label(label.as_bytes()) else {
                    return js_error(
                        &ctx,
                        format!("HTML.encodeURIComponents: unknown encoding label {label:?}"),
                    );
                };
                let encode = |text: &str| {
                    let (bytes, _encoding, _had_errors) = encoding.encode(text);
                    percent_encode_component(&bytes)
                };
                // Every entry is a [key, value] pair of strings; both sides
                // are encoded as components and the pairs joined with `&`.
                let mut parts = Vec::with_capacity(pairs.len());
                for index in 0..pairs.len() {
                    let entry = pairs.get::<Value>(index)?;
                    let Some(pair) = entry.as_array().filter(|pair| pair.len() == 2) else {
                        return js_error(
                            &ctx,
                            "HTML.encodeURIComponents: each query pair must be a \
                             [key, value] array",
                        );
                    };
                    let key = pair.get::<String>(0)?;
                    let item = pair.get::<String>(1)?;
                    parts.push(format!("{}={}", encode(&key), encode(&item)));
                }
                Ok(parts.join("&"))
            },
        )?
        .object())
}

#[cfg(test)]
mod tests {
    use crate::script::js::sandbox::Sandbox;
    use std::time::Duration;

    /// Evaluate a module importing `langhuan:html` and return its default
    /// export as a string, exercising the real import path.
    fn evaluate(code: &str) -> String {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let module = format!(r#"import {{ HTML }} from "langhuan:html"; {code}"#);
        sandbox.eval_module_json(&module).unwrap()
    }

    #[test]
    fn traversal_matches_the_jquery_surface() {
        let result = evaluate(
            r#"const document = HTML.parse(`
              <section id="results">
                <article class="card featured">
                  <a href="/book/42.html"><span>Book &amp; One</span></a>
                </article>
                <article class="card"><a href="/other">Other</a></article>
                <script>const fake = '<a href="/book/99.html">Fake</a>';</script>
              </section>`);
              const links = document.find('#results > article.card a[href*="/book/"][href$=".html"]');
              const cards = document.find("article.card");
              export default JSON.stringify({
                count: links.length,
                href: links.first().attr("href"),
                text: links.first().text().trim(),
                tag: document.find("article.featured").first().tagName,
                parentTag: links.first().parent().tagName,
                closestTag: links.first().closest("article").tagName,
                children: cards.first().children().length,
                lastText: cards.find("a").last().text(),
                eqMinusOne: cards.find("a").eq(-1).text(),
                eachSum: (() => {
                  let sum = "";
                  cards.each(function (index, node) {
                    sum += index + this.tagName + node.tagName;
                  });
                  return sum;
                })(),
              });"#,
        );
        assert_eq!(
            result,
            r#"{"count":1,"href":"/book/42.html","text":"Book & One","tag":"ARTICLE","parentTag":"ARTICLE","closestTag":"ARTICLE","children":1,"lastText":"Other","eqMinusOne":"Other","eachSum":"0ARTICLEARTICLE1ARTICLEARTICLE"}"#
        );
    }

    #[test]
    fn each_stops_when_the_callback_returns_false() {
        let result = evaluate(
            r#"const document = HTML.parse("<ul><li>a</li><li>b</li><li>c</li></ul>");
              let seen = [];
              document.find("li").each((index, node) => {
                seen.push(index + node.text());
                return index < 1;
              });
              export default JSON.stringify(seen);"#,
        );
        assert_eq!(result, r#"["0a","1b"]"#);
    }

    #[test]
    fn selection_parent_and_children_filter_by_selector() {
        let result = evaluate(
            r##"const document = HTML.parse(`
              <div id="wrap"><p class="keep">one</p><p>two</p><span>three</span></div>
              <div id="other"><p class="keep">four</p></div>`);
              const paragraphs = document.find("p");
              export default JSON.stringify({
                parents: paragraphs.parent().map((n) => n.attr("id")),
                filteredParents: paragraphs.parent("#other").map((n) => n.attr("id")),
                children: document.find("#wrap").children(".keep").map((n) => n.text()),
                allChildren: document.find("#wrap").children().length,
                closestShared: document.find("p").closest("body").length,
              });"##,
        );
        assert_eq!(
            result,
            r#"{"parents":["wrap","other"],"filteredParents":["other"],"children":["one"],"allChildren":3,"closestShared":1}"#
        );
    }

    #[test]
    fn merged_results_are_unique_and_document_ordered() {
        let result = evaluate(
            r#"const nested = HTML.parse(
                "<div id='outer'><i id='one'></i><div id='inner'><i id='two'></i></div></div>");
              // The selection [outer, inner] has overlapping subtrees: inner
              // is a descendant of outer, so `two` matches under both roots
              // and must appear once.
              const merged = nested.find("div").find("i").map((n) => n.attr("id"));
              // [a, b] live in document order, but their parents come back
              // inner-first; sorting restores document order.
              const reordered = HTML.parse(
                "<div id='p1'><div id='p2'><span id='a'></span></div><span id='b'></span></div>");
              const parents = reordered.find("span").parent().map((n) => n.attr("id"));
              export default JSON.stringify({ merged, parents });"#,
        );
        assert_eq!(result, r#"{"merged":["one","two"],"parents":["p1","p2"]}"#);
    }

    #[test]
    fn attr_distinguishes_empty_from_absent() {
        let result = evaluate(
            r#"const document = HTML.parse(`<a href="" data-flag title="t"></a>`);
              const link = document.find("a").first();
              export default JSON.stringify([link.attr("href"), link.attr("data-flag"),
                link.attr("title"), link.attr("missing")]);"#,
        );
        assert_eq!(result, r#"["","","t",null]"#);
    }

    #[test]
    fn html_and_outer_html_follow_the_browser_names() {
        let result = evaluate(
            r##"const document = HTML.parse("<div id='x'>one<br>two</div>");
              const node = document.find("#x").first();
              export default JSON.stringify([node.html(), node.outerHTML(),
                document.find("#x").outerHTML(), document.find("#missing").outerHTML()]);"##,
        );
        assert_eq!(
            result,
            r#"["one<br>two","<div id=\"x\">one<br>two</div>","<div id=\"x\">one<br>two</div>",null]"#
        );
    }

    #[test]
    fn text_preserves_br_as_newline_and_skips_scripts() {
        let result = evaluate(
            r##"const document = HTML.parse(
                "<div id='x'>one<br>two<script>var x = '<br>'</script></div>");
              export default JSON.stringify(document.find("#x").first().text());"##,
        );
        assert_eq!(result, r#""one\ntwo""#);
    }

    #[test]
    fn encode_uri_component_matches_the_browser() {
        let result = evaluate(
            r#"export default JSON.stringify([
                HTML.encodeURIComponent("Book & Author"),
                HTML.encodeURIComponent("-_.!~*'()"),
                HTML.encodeURIComponent("你好"),
              ]);"#,
        );
        assert_eq!(
            result,
            r#"["Book%20%26%20Author","-_.!~*'()","%E4%BD%A0%E5%A5%BD"]"#
        );
    }

    #[test]
    fn encode_uri_component_supports_other_charsets() {
        let result = evaluate(
            r#"export default HTML.encodeURIComponent("你好", "gbk");"#,
        );
        assert_eq!(result, r#"%C4%E3%BA%C3"#);
    }

    #[test]
    fn encode_uri_component_rejects_unknown_charsets() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_module_json(
                r#"import { HTML } from "langhuan:html";
                   export default HTML.encodeURIComponent("x", "no-such-charset");"#,
            )
            .unwrap_err()
            .to_string();
        assert!(error.contains("unknown encoding label"), "{error}");
    }

    #[test]
    fn encode_uri_components_builds_query_strings() {
        let result = evaluate(
            r#"export default JSON.stringify([
                HTML.encodeURIComponents([["q", "a b"], ["page", "2"]]),
                HTML.encodeURIComponents([]),
                HTML.encodeURIComponents([["kw", "你好"]], "gbk"),
                HTML.encodeURIComponents([["empty", ""], ["sym", "-_.!~*'()"]]),
              ]);"#,
        );
        assert_eq!(
            result,
            r#"["q=a%20b&page=2","","kw=%C4%E3%BA%C3","empty=&sym=-_.!~*'()"]"#
        );
    }

    #[test]
    fn encode_uri_component_stays_a_single_string_function() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_module_json(
                r#"import { HTML } from "langhuan:html";
                   export default HTML.encodeURIComponent([["q", "a"]]);"#,
            )
            .unwrap_err()
            .to_string();
        assert!(error.contains("into type 'string'"), "{error}");
    }

    #[test]
    fn encode_uri_components_rejects_malformed_pairs() {
        for argument in [
            r#"[["q", "a"], "page"]"#,
            r#"[["q"]]"#,
            r#"[["q", "a", "extra"]]"#,
            r#"[42]"#,
        ] {
            let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
            let error = sandbox
                .eval_module_json(&format!(
                    r#"import {{ HTML }} from "langhuan:html";
                       export default HTML.encodeURIComponents({argument});"#
                ))
                .unwrap_err()
                .to_string();
            assert!(
                error.contains("each query pair must be a [key, value] array"),
                "{argument}: {error}"
            );
        }
    }

    #[test]
    fn encode_uri_components_rejects_non_array_input() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_module_json(
                r#"import { HTML } from "langhuan:html";
                   export default HTML.encodeURIComponents("page=1");"#,
            )
            .unwrap_err()
            .to_string();
        assert!(error.contains("into type 'array'"), "{error}");
    }

    #[test]
    fn encode_uri_components_keep_keys_and_values_strings() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_module_json(
                r#"import { HTML } from "langhuan:html";
                   export default HTML.encodeURIComponents([["page", 2]]);"#,
            )
            .unwrap_err()
            .to_string();
        assert!(error.contains("into type 'string'"), "{error}");
    }

    #[test]
    fn encode_uri_components_rejects_unknown_charsets() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_module_json(
                r#"import { HTML } from "langhuan:html";
                   export default HTML.encodeURIComponents(
                     [["x", "y"]], "no-such-charset");"#,
            )
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("HTML.encodeURIComponents: unknown encoding label"),
            "{error}"
        );
    }

    #[test]
    fn invalid_selectors_throw() {
        let mut sandbox = Sandbox::new(Duration::from_secs(5)).unwrap();
        let error = sandbox
            .eval_module_json(
                r#"import { HTML } from "langhuan:html";
                   export default HTML.parse("<div></div>").find("a[");"#,
            )
            .unwrap_err()
            .to_string();
        assert!(error.contains("invalid selector"), "{error}");
    }
}
