use std::collections::HashSet;
use std::sync::{Arc, Mutex, MutexGuard};

use ego_tree::{NodeId, NodeRef};
use rquickjs::function::This;
use rquickjs::object::Accessor;
use rquickjs::{Array, Ctx, Exception, Function, Object, Result as JsResult, Value};
use scraper::{ElementRef, Html, Node, Selector};

const MAX_HTML_INPUT_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug)]
struct Document {
    dom: Mutex<Html>,
}

type SharedDocument = Arc<Document>;

fn js_error<'js, T>(ctx: &Ctx<'js>, message: impl AsRef<str>) -> JsResult<T> {
    Err(Exception::throw_message(ctx, message.as_ref()))
}

fn lock_document<'a, 'js>(
    ctx: &Ctx<'js>,
    document: &'a SharedDocument,
) -> JsResult<MutexGuard<'a, Html>> {
    document
        .dom
        .lock()
        .map_err(|_| Exception::throw_internal(ctx, "HTML document lock poisoned"))
}

fn parse_selector<'js>(ctx: &Ctx<'js>, selector: &str) -> JsResult<Selector> {
    Selector::parse(selector).map_err(|error| {
        Exception::throw_message(
            ctx,
            &format!("HTML.select: invalid selector '{selector}': {error}"),
        )
    })
}

fn element<'a>(dom: &'a Html, node_id: NodeId) -> Option<ElementRef<'a>> {
    dom.tree.get(node_id).and_then(ElementRef::wrap)
}

fn select_ids<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    root: Option<NodeId>,
    selector: &str,
) -> JsResult<Vec<NodeId>> {
    let selector = parse_selector(ctx, selector)?;
    let dom = lock_document(ctx, document)?;
    Ok(match root {
        Some(node_id) => element(&dom, node_id)
            .into_iter()
            .flat_map(|node| node.select(&selector))
            .map(|node| node.id())
            .collect(),
        None => dom.select(&selector).map(|node| node.id()).collect(),
    })
}

fn select_descendants<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    roots: &[NodeId],
    selector: &str,
) -> JsResult<Vec<NodeId>> {
    let selector = parse_selector(ctx, selector)?;
    let dom = lock_document(ctx, document)?;
    let mut seen = HashSet::new();
    let mut selected = Vec::new();
    for root in roots {
        let Some(root) = element(&dom, *root) else {
            continue;
        };
        for node in root.select(&selector) {
            if seen.insert(node.id()) {
                selected.push(node.id());
            }
        }
    }
    Ok(selected)
}

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

fn node_text<'js>(ctx: &Ctx<'js>, document: &SharedDocument, node_id: NodeId) -> JsResult<String> {
    let dom = lock_document(ctx, document)?;
    let Some(node) = dom.tree.get(node_id) else {
        return js_error(ctx, "HTML node no longer exists");
    };
    let mut output = String::new();
    append_text(node, &mut output);
    Ok(output)
}

fn node_attr<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    node_id: NodeId,
    name: &str,
) -> JsResult<Option<String>> {
    let dom = lock_document(ctx, document)?;
    Ok(element(&dom, node_id).and_then(|node| node.attr(name).map(str::to_owned)))
}

fn node_attrs<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    node_id: NodeId,
) -> JsResult<Vec<(String, String)>> {
    let dom = lock_document(ctx, document)?;
    Ok(element(&dom, node_id)
        .map(|node| {
            node.value()
                .attrs()
                .map(|(name, value)| (name.to_owned(), value.to_owned()))
                .collect()
        })
        .unwrap_or_default())
}

fn node_html<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    node_id: NodeId,
    outer: bool,
) -> JsResult<Option<String>> {
    let dom = lock_document(ctx, document)?;
    Ok(element(&dom, node_id).map(|node| {
        if outer {
            node.html()
        } else {
            node.inner_html()
        }
    }))
}

fn node_parent<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    node_id: NodeId,
) -> JsResult<Option<NodeId>> {
    let dom = lock_document(ctx, document)?;
    let Some(node) = dom.tree.get(node_id) else {
        return Ok(None);
    };
    Ok(node
        .ancestors()
        .find_map(|parent| ElementRef::wrap(parent).map(|element| element.id())))
}

fn node_children<'js>(
    ctx: &Ctx<'js>,
    document: &SharedDocument,
    node_id: NodeId,
) -> JsResult<Vec<NodeId>> {
    let dom = lock_document(ctx, document)?;
    Ok(dom
        .tree
        .get(node_id)
        .into_iter()
        .flat_map(|node| node.children())
        .filter_map(ElementRef::wrap)
        .map(|child| child.id())
        .collect())
}

fn build_selection<'js>(
    ctx: &Ctx<'js>,
    document: SharedDocument,
    nodes: Vec<NodeId>,
) -> JsResult<Array<'js>> {
    let selection = Array::new(ctx.clone())?;
    for (index, node_id) in nodes.iter().copied().enumerate() {
        selection.set(index, build_node(ctx, document.clone(), node_id)?)?;
    }

    selection.as_object().set(
        "first",
        Function::new(ctx.clone(), |this: This<Array<'js>>| this.0.get::<Value>(0))?,
    )?;

    let text_document = document.clone();
    let text_nodes = nodes.clone();
    selection.as_object().set(
        "text",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> JsResult<String> {
            let mut output = String::new();
            for node_id in &text_nodes {
                output.push_str(&node_text(&ctx, &text_document, *node_id)?);
            }
            Ok(output)
        })?,
    )?;

    let attr_document = document.clone();
    let attr_node = nodes.first().copied();
    selection.as_object().set(
        "attr",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, name: String| {
            attr_node
                .map(|node_id| node_attr(&ctx, &attr_document, node_id, &name))
                .transpose()
                .map(Option::flatten)
        })?,
    )?;

    let attrs_document = document.clone();
    let attrs_node = nodes.first().copied();
    selection.as_object().set(
        "attrs",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> JsResult<Object<'js>> {
            let attributes = Object::new(ctx.clone())?;
            if let Some(node_id) = attrs_node {
                for (name, value) in node_attrs(&ctx, &attrs_document, node_id)? {
                    attributes.set(name, value)?;
                }
            }
            Ok(attributes)
        })?,
    )?;

    for (name, outer) in [("html", false), ("outer_html", true)] {
        let html_document = document.clone();
        let html_node = nodes.first().copied();
        selection.as_object().set(
            name,
            Function::new(ctx.clone(), move |ctx: Ctx<'js>| {
                html_node
                    .map(|node_id| node_html(&ctx, &html_document, node_id, outer))
                    .transpose()
                    .map(Option::flatten)
            })?,
        )?;
    }

    let select_document = document;
    selection.as_object().set(
        "select",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, selector: String| {
            let selected = select_descendants(&ctx, &select_document, &nodes, &selector)?;
            build_selection(&ctx, select_document.clone(), selected)
        })?,
    )?;
    Ok(selection)
}

fn build_node<'js>(
    ctx: &Ctx<'js>,
    document: SharedDocument,
    node_id: NodeId,
) -> JsResult<Object<'js>> {
    let node = Object::new(ctx.clone())?;
    let tag_name = {
        let dom = lock_document(ctx, &document)?;
        element(&dom, node_id)
            .map(|element| element.value().name().to_owned())
            .unwrap_or_default()
    };
    node.set("tagName", tag_name)?;

    let text_document = document.clone();
    node.set(
        "text",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> JsResult<String> {
            node_text(&ctx, &text_document, node_id)
        })?,
    )?;
    node.set("textContent", node_text(ctx, &document, node_id)?)?;

    let attr_document = document.clone();
    let attr = Function::new(ctx.clone(), move |ctx: Ctx<'js>, name: String| {
        node_attr(&ctx, &attr_document, node_id, &name)
    })?;
    node.set("attr", attr.clone())?;
    node.set("getAttribute", attr)?;

    let attrs_document = document.clone();
    node.set(
        "attrs",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> JsResult<Object<'js>> {
            let attributes = Object::new(ctx.clone())?;
            for (name, value) in node_attrs(&ctx, &attrs_document, node_id)? {
                attributes.set(name, value)?;
            }
            Ok(attributes)
        })?,
    )?;

    for (name, outer) in [("html", false), ("outer_html", true)] {
        let html_document = document.clone();
        node.set(
            name,
            Function::new(ctx.clone(), move |ctx: Ctx<'js>| {
                node_html(&ctx, &html_document, node_id, outer)
            })?,
        )?;
    }

    let select_document = document.clone();
    let select = Function::new(ctx.clone(), move |ctx: Ctx<'js>, selector: String| {
        let selected = select_ids(&ctx, &select_document, Some(node_id), &selector)?;
        build_selection(&ctx, select_document.clone(), selected)
    })?;
    node.set("select", select.clone())?;
    node.set("querySelectorAll", select)?;

    let query_document = document.clone();
    node.set(
        "querySelector",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, selector: String| {
            let selected = select_ids(&ctx, &query_document, Some(node_id), &selector)?;
            selected
                .first()
                .copied()
                .map(|id| build_node(&ctx, query_document.clone(), id))
                .transpose()
        })?,
    )?;

    // Relations are getters so walking `parent.parent` remains possible
    // without eagerly constructing a cyclic object graph.
    let parent_document = document.clone();
    node.prop(
        "parent",
        Accessor::from(move |ctx: Ctx<'js>| {
            node_parent(&ctx, &parent_document, node_id)?
                .map(|id| build_node(&ctx, parent_document.clone(), id))
                .transpose()
        }),
    )?;
    let children_document = document;
    node.prop(
        "children",
        Accessor::from(move |ctx: Ctx<'js>| {
            let children = node_children(&ctx, &children_document, node_id)?;
            build_selection(&ctx, children_document.clone(), children)
        }),
    )?;
    Ok(node)
}

fn build_document<'js>(ctx: &Ctx<'js>, document: SharedDocument) -> JsResult<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    let select_document = document.clone();
    let select = Function::new(ctx.clone(), move |ctx: Ctx<'js>, selector: String| {
        let selected = select_ids(&ctx, &select_document, None, &selector)?;
        build_selection(&ctx, select_document.clone(), selected)
    })?;
    object.set("select", select.clone())?;
    object.set("querySelectorAll", select)?;

    object.set(
        "querySelector",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, selector: String| {
            let selected = select_ids(&ctx, &document, None, &selector)?;
            selected
                .first()
                .copied()
                .map(|id| build_node(&ctx, document.clone(), id))
                .transpose()
        })?,
    )?;
    Ok(object)
}

pub(super) fn install<'js>(ctx: &Ctx<'js>) -> JsResult<()> {
    let html = Object::new(ctx.clone())?;
    html.set(
        "parse",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, input: String| {
            if input.trim().is_empty() {
                return js_error(&ctx, "HTML.parse: input is empty");
            }
            if input.len() > MAX_HTML_INPUT_BYTES {
                return js_error(&ctx, "HTML.parse: input exceeds the 4 MiB limit");
            }
            build_document(
                &ctx,
                Arc::new(Document {
                    dom: Mutex::new(Html::parse_document(&input)),
                }),
            )
        })?,
    )?;
    html.set(
        "decodeEntities",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, input: String| {
            if input.len() > MAX_HTML_INPUT_BYTES {
                return js_error(&ctx, "HTML.decodeEntities: input exceeds the 4 MiB limit");
            }
            let document = Html::parse_fragment(&input);
            let mut output = String::new();
            append_text(document.tree.root(), &mut output);
            Ok(output)
        })?,
    )?;
    ctx.globals().set("HTML", html)
}
