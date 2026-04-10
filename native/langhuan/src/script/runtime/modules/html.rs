//! `@langhuan/html` — HTML parsing/querying for Lua scripts.
//!
//! Exposes document-object API with jQuery-like node list methods:
//! - `local html = require("@langhuan/html")`
//! - `local doc = html.parse("<html>...</html>")`
//! - `local nodes = doc:select("div.item > a")`
//! - `nodes:text()` / `nodes:attr("href")` / `nodes:select("span")`

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use ego_tree::NodeId;
use mlua::{Lua, MetaMethod, Result, UserData, UserDataMethods, Value};
use scraper::{ElementRef, Html, Selector};

#[derive(Debug)]
struct DocInner {
    dom: Mutex<Html>,
}

#[derive(Clone, Debug)]
struct DocHandle {
    inner: Arc<DocInner>,
}

#[derive(Clone, Debug)]
struct ElementHandle {
    inner: Arc<DocInner>,
    node_id: NodeId,
}

#[derive(Clone, Debug)]
struct NodeListHandle {
    nodes: Vec<ElementHandle>,
}

fn normalize_whitespace(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn runtime_error(message: impl Into<String>) -> mlua::Error {
    mlua::Error::RuntimeError(message.into())
}

impl DocInner {
    fn new(input: &str) -> Self {
        Self {
            dom: Mutex::new(Html::parse_document(input)),
        }
    }

    fn selector(selector_str: &str) -> Result<Selector> {
        Selector::parse(selector_str).map_err(|e| {
            runtime_error(format!(
                "html.select: invalid selector '{selector_str}': {e}"
            ))
        })
    }

    fn select_from_doc(&self, selector_str: &str) -> Result<Vec<NodeId>> {
        let selector = Self::selector(selector_str)?;
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        Ok(dom.select(&selector).map(|el| el.id()).collect())
    }

    fn select_from_node(&self, node_id: NodeId, selector_str: &str) -> Result<Vec<NodeId>> {
        let selector = Self::selector(selector_str)?;
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        let element = Self::element_ref_from_dom(&dom, node_id)?;
        Ok(element.select(&selector).map(|el| el.id()).collect())
    }

    fn element_ref_from_dom<'a>(dom: &'a Html, node_id: NodeId) -> Result<ElementRef<'a>> {
        let node = dom
            .tree
            .get(node_id)
            .ok_or_else(|| runtime_error("html.node: node not found"))?;
        ElementRef::wrap(node).ok_or_else(|| runtime_error("html.node: node is not an element"))
    }

    fn node_text(&self, node_id: NodeId) -> Result<String> {
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        let element = Self::element_ref_from_dom(&dom, node_id)?;
        Ok(normalize_whitespace(
            &element.text().collect::<Vec<_>>().join(" "),
        ))
    }

    fn node_attr(&self, node_id: NodeId, name: &str) -> Result<Option<String>> {
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        let element = Self::element_ref_from_dom(&dom, node_id)?;
        Ok(element.attr(name).map(str::to_owned))
    }

    fn node_attrs(&self, node_id: NodeId) -> Result<Vec<(String, String)>> {
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        let element = Self::element_ref_from_dom(&dom, node_id)?;
        Ok(element
            .value()
            .attrs()
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect())
    }

    fn node_html(&self, node_id: NodeId) -> Result<String> {
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        let element = Self::element_ref_from_dom(&dom, node_id)?;
        Ok(element.inner_html())
    }

    fn node_outer_html(&self, node_id: NodeId) -> Result<String> {
        let dom = self
            .dom
            .lock()
            .map_err(|_| runtime_error("html.select: document lock poisoned"))?;
        let element = Self::element_ref_from_dom(&dom, node_id)?;
        Ok(element.html())
    }
}

impl NodeListHandle {
    fn len_i64(&self) -> i64 {
        self.nodes.len() as i64
    }

    fn first_node(&self) -> Option<ElementHandle> {
        self.nodes.first().cloned()
    }

    fn eq_one_based(&self, index: i64) -> Option<ElementHandle> {
        if index < 1 {
            return None;
        }
        self.nodes.get((index - 1) as usize).cloned()
    }
}

fn unique_descendants(nodes: &[ElementHandle], selector: &str) -> Result<Vec<ElementHandle>> {
    let mut seen: HashSet<(usize, NodeId)> = HashSet::new();
    let mut out = Vec::new();

    for node in nodes {
        for child_id in node.inner.select_from_node(node.node_id, selector)? {
            let key = (Arc::as_ptr(&node.inner) as usize, child_id);
            if seen.insert(key) {
                out.push(ElementHandle {
                    inner: node.inner.clone(),
                    node_id: child_id,
                });
            }
        }
    }

    Ok(out)
}

fn create_node_list(nodes: Vec<ElementHandle>) -> NodeListHandle {
    NodeListHandle { nodes }
}

impl UserData for NodeListHandle {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_meta_method(MetaMethod::Len, |_, this, ()| Ok(this.len_i64()));
        methods.add_meta_method(MetaMethod::Index, |_, this, key: Value| match key {
            Value::Integer(index) => Ok(this.eq_one_based(index)),
            _ => Ok(None::<ElementHandle>),
        });

        methods.add_method("first", |_, this, ()| Ok(this.first_node()));

        methods.add_method("text", |_, this, ()| {
            let mut acc = String::new();
            for node in &this.nodes {
                let text = node.inner.node_text(node.node_id)?;
                if !text.is_empty() {
                    acc.push_str(&text);
                }
            }
            Ok(acc)
        });

        methods.add_method("attr", |_, this, name: String| {
            if let Some(node) = this.first_node() {
                node.inner.node_attr(node.node_id, &name)
            } else {
                Ok(None)
            }
        });

        methods.add_method("attrs", |lua, this, ()| {
            let attrs_table = lua.create_table()?;
            if let Some(node) = this.first_node() {
                for (k, v) in node.inner.node_attrs(node.node_id)? {
                    attrs_table.set(k, v)?;
                }
            }
            Ok(attrs_table)
        });

        methods.add_method("html", |_, this, ()| {
            if let Some(node) = this.first_node() {
                Ok(Some(node.inner.node_html(node.node_id)?))
            } else {
                Ok(None)
            }
        });

        methods.add_method("outer_html", |_, this, ()| {
            if let Some(node) = this.first_node() {
                Ok(Some(node.inner.node_outer_html(node.node_id)?))
            } else {
                Ok(None)
            }
        });

        methods.add_method("select", |_, this, selector: String| {
            let descendants = unique_descendants(&this.nodes, &selector)?;
            Ok(create_node_list(descendants))
        });
    }
}

impl UserData for DocHandle {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("select", |_, this, selector: String| {
            let node_ids = this.inner.select_from_doc(&selector)?;
            let nodes = node_ids
                .into_iter()
                .map(|node_id| ElementHandle {
                    inner: this.inner.clone(),
                    node_id,
                })
                .collect();
            Ok(create_node_list(nodes))
        });
    }
}

impl UserData for ElementHandle {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("text", |_, this, ()| this.inner.node_text(this.node_id));

        methods.add_method("html", |_, this, ()| this.inner.node_html(this.node_id));

        methods.add_method("outer_html", |_, this, ()| {
            this.inner.node_outer_html(this.node_id)
        });

        methods.add_method("select", |_, this, selector: String| {
            let node_ids = this.inner.select_from_node(this.node_id, &selector)?;
            let nodes = node_ids
                .into_iter()
                .map(|node_id| ElementHandle {
                    inner: this.inner.clone(),
                    node_id,
                })
                .collect();
            Ok(create_node_list(nodes))
        });

        methods.add_method("attrs", |lua, this, ()| {
            let t = lua.create_table()?;
            for (k, v) in this.inner.node_attrs(this.node_id)? {
                t.set(k, v)?;
            }
            Ok(t)
        });

        methods.add_method("attr", |_, this, name: String| {
            this.inner.node_attr(this.node_id, &name)
        });
    }
}

/// Build and return the `@langhuan/html` module table.
pub fn module(lua: &Lua) -> Result<Value> {
    let parse = lua.create_function(|_, input: String| {
        if input.trim().is_empty() {
            return Err(runtime_error("html.parse: input HTML is empty"));
        }

        Ok(DocHandle {
            inner: Arc::new(DocInner::new(&input)),
        })
    })?;

    let table = lua.create_table()?;
    table.set("parse", parse)?;

    Ok(Value::Table(table))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install_html_module(lua: &Lua) -> Result<()> {
        let module_value = module(lua)?;
        lua.globals().set("html", module_value)?;
        Ok(())
    }

    #[test]
    fn parse_and_select_happy_path() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let res: mlua::Table = lua
            .load(
                r#"
                local doc = html.parse([[<div class="item"><a href="/book/42.html"><b> Hello </b> World </a></div>]])
                local nodes = doc:select("div.item > a")
                return {
                    count = #nodes,
                    text = nodes:text(),
                    href = nodes:attr("href"),
                    inner = nodes:html(),
                    outer = nodes:outer_html(),
                }
                "#,
            )
            .eval()
            .expect("lua script should succeed");

        let count: i64 = res.get("count").expect("count");
        let text: String = res.get("text").expect("text");
        let href: String = res.get("href").expect("href");
        let inner: String = res.get("inner").expect("inner");
        let outer: String = res.get("outer").expect("outer");

        assert_eq!(count, 1);
        assert_eq!(text, "Hello World");
        assert_eq!(href, "/book/42.html");
        assert!(inner.contains("Hello"));
        assert!(outer.starts_with("<a "));
    }

    #[test]
    fn invalid_selector_returns_runtime_error() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let err = lua
            .load(
                r#"
                local doc = html.parse("<div></div>")
                doc:select("div[")
                "#,
            )
            .exec()
            .expect_err("selector should fail");

        let msg = err.to_string();
        assert!(msg.contains("html.select:"), "unexpected error: {msg}");
    }

    #[test]
    fn empty_selection_returns_empty_table() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let count: i64 = lua
            .load(
                r#"
                local doc = html.parse("<div><span>x</span></div>")
                local nodes = doc:select("a.missing")
                return #nodes
                "#,
            )
            .eval()
            .expect("lua script should succeed");

        assert_eq!(count, 0);
    }

    #[test]
    fn attrs_and_attr_methods_work() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let res: mlua::Table = lua
            .load(
                r#"
                local doc = html.parse([[<input id="x" disabled data-empty="" data-k="v">]])
                local nodes = doc:select("input")
                local n = nodes:first()
                local attrs = nodes:attrs()
                return {
                    id = nodes:attr("id"),
                    disabled = attrs["disabled"],
                    empty = attrs["data-empty"],
                    k = n:attr("data-k"),
                    missing = n:attr("missing"),
                }
                "#,
            )
            .eval()
            .expect("lua script should succeed");

        let id: String = res.get("id").expect("id");
        let disabled: String = res.get("disabled").expect("disabled");
        let empty: String = res.get("empty").expect("empty");
        let k: String = res.get("k").expect("k");
        let missing: Option<String> = res.get("missing").expect("missing");

        assert_eq!(id, "x");
        assert_eq!(disabled, "");
        assert_eq!(empty, "");
        assert_eq!(k, "v");
        assert_eq!(missing, None);
    }

    #[test]
    fn element_handle_can_select_descendants() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let res: mlua::Table = lua
            .load(
                r#"
                local doc = html.parse([[<div class="root"><ul><li><a href="/1">One</a></li><li><a href="/2">Two</a></li></ul></div>]])
                local root = doc:select("div.root"):first()
                local links = root:select("a")
                return {
                    count = #links,
                    first = links[1]:text(),
                    second = links[2]:text(),
                    second_href = links[2]:attr("href"),
                }
                "#,
            )
            .eval()
            .expect("lua script should succeed");

        let count: i64 = res.get("count").expect("count");
        let first: String = res.get("first").expect("first");
        let second: String = res.get("second").expect("second");
        let second_href: String = res.get("second_href").expect("second_href");

        assert_eq!(count, 2);
        assert_eq!(first, "One");
        assert_eq!(second, "Two");
        assert_eq!(second_href, "/2");
    }

    #[test]
    fn list_can_chain_without_indexing() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let res: mlua::Table = lua
            .load(
                r#"
                local doc = html.parse([[<div class="a"><span data-k="x"> A </span><span data-k="y"> B </span></div>]])
                local spans = doc:select("div.a"):select("span")
                return {
                    count = #spans,
                    text = spans:text(),
                    first_attr = spans:attr("data-k"),
                }
                "#,
            )
            .eval()
            .expect("lua script should succeed");

        let count: i64 = res.get("count").expect("count");
        let text: String = res.get("text").expect("text");
        let first_attr: String = res.get("first_attr").expect("first_attr");

        assert_eq!(count, 2);
        assert_eq!(text, "AB");
        assert_eq!(first_attr, "x");
    }

    #[test]
    fn parse_empty_input_returns_runtime_error() {
        let lua = Lua::new();
        install_html_module(&lua).expect("install html module");

        let err = lua
            .load("html.parse('   ')")
            .exec()
            .expect_err("empty input should fail");

        let msg = err.to_string();
        assert!(msg.contains("html.parse:"), "unexpected error: {msg}");
    }
}
