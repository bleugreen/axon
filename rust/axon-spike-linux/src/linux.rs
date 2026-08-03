use std::{
    collections::VecDeque,
    error::Error,
    time::{Duration, Instant},
};

use atspi::{
    AccessibilityConnection, CoordType, ObjectRefOwned,
    proxy::{accessible::ObjectRefExt, proxy_ext::ProxyExt},
};

use crate::Options;

#[derive(Clone, Debug, Eq, PartialEq)]
struct Node {
    depth: usize,
    role: String,
    name: String,
    states: String,
    rect: Option<(i32, i32, i32, i32)>,
    text: Option<String>,
    object: ObjectRefOwned,
}

#[tokio::main]
pub async fn run(options: Options) -> Result<(), Box<dyn Error>> {
    let connection = AccessibilityConnection::new().await?;
    let registry = connection.root_accessible_on_registry().await?;
    let applications = registry.get_children().await?;

    if options.application.is_none() {
        println!("applications={}", applications.len());
        for object in applications {
            let proxy = object.as_accessible_proxy(connection.connection()).await?;
            println!(
                "role={:?} name={:?} path={}",
                proxy.get_role_name().await?,
                proxy.name().await?,
                object.path()
            );
        }
        return Ok(());
    }

    let needle = options.application.as_deref().unwrap();
    let root = select_application(connection.connection(), applications, needle).await?;
    let started = Instant::now();
    let before = capture(
        connection.connection(),
        root.clone(),
        options.max_depth,
        options.max_nodes,
    )
    .await;
    let elapsed = started.elapsed();
    print_capture("before", &before, elapsed);

    if options.action {
        let role = options.role.as_deref().unwrap();
        let name = options.name_contains.as_deref().unwrap();
        let target = before
            .iter()
            .find(|node| {
                node.role.eq_ignore_ascii_case(role)
                    && node.name.to_lowercase().contains(&name.to_lowercase())
            })
            .ok_or_else(|| format!("no control matched role={role:?} name contains={name:?}"))?;
        let proxy = target
            .object
            .as_accessible_proxy(connection.connection())
            .await?;
        let action = proxy.proxies().await?.action().await?;
        let actions = action.get_actions().await?;
        println!(
            "matched role={:?} name={:?} actions={actions:?}",
            target.role, target.name
        );
        let (action_index, selected_action) = actions
            .iter()
            .enumerate()
            .find(|(_, candidate)| {
                candidate.name.eq_ignore_ascii_case("click")
                    || candidate.name.eq_ignore_ascii_case("activate")
            })
            .ok_or("matched control exposes no Click or Activate AT-SPI action")?;
        println!(
            "selected_action_index={action_index} selected_action={:?}",
            selected_action.name
        );
+        let dispatch_success = action.do_action(action_index as i32).await?;
+        println!("dispatch_success={dispatch_success}");
+        if !dispatch_success {
+            return Err("AT-SPI Action.DoAction rejected the action".into());
+        }
+        tokio::time::sleep(Duration::from_millis(500)).await;
+
+        let started = Instant::now();
+        let after = capture(
+            connection.connection(),
+            root,
+            options.max_depth,
+            options.max_nodes,
+        )
+        .await;
+        let elapsed = started.elapsed();
+        print_capture("after", &after, elapsed);
+        let text_changes: Vec<_> = before
+            .iter()
+            .zip(&after)
+            .filter_map(|(old, new)| {
+                (old.text != new.text && (old.text.is_some() || new.text.is_some()))
+                    .then(|| (old.text.as_deref(), new.text.as_deref()))
+            })
+            .collect();
+        if text_changes.is_empty() {
+            return Err("action dispatched, but recapture observed no text change".into());
+        }
+        println!(
+            "verified_outcome=true verification=text_changed changes={text_changes:?} before_nodes={} after_nodes={}",
+            before.len(),
+            after.len()
+        );
    }

    Ok(())
}

async fn select_application(
    connection: &atspi::zbus::Connection,
    applications: Vec<ObjectRefOwned>,
    needle: &str,
) -> Result<ObjectRefOwned, Box<dyn Error>> {
    let needle = needle.to_lowercase();
    let mut partial = None;
    for object in applications {
        let proxy = object.as_accessible_proxy(connection).await?;
        let name = proxy.name().await?;
        if name.eq_ignore_ascii_case(&needle) {
            return Ok(object);
        }
        if partial.is_none() && name.to_lowercase().contains(&needle) {
            partial = Some(object);
        }
    }
    partial.ok_or_else(|| format!("no AT-SPI application matched {needle:?}").into())
}

async fn capture(
    connection: &atspi::zbus::Connection,
    root: ObjectRefOwned,
    max_depth: usize,
    max_nodes: usize,
) -> Vec<Node> {
    let mut queue = VecDeque::from([(root, 0)]);
    let mut nodes = Vec::new();
    while let Some((object, depth)) = queue.pop_front() {
        if nodes.len() >= max_nodes {
            break;
        }
        let Ok(proxy) = object.as_accessible_proxy(connection).await else {
            continue;
        };
        let role = proxy
            .get_role_name()
            .await
            .unwrap_or_else(|_| "<error>".to_owned());
        let name = proxy.name().await.unwrap_or_else(|_| "<error>".to_owned());
        let states = proxy
            .get_state()
            .await
            .map(|states| format!("{states:?}"))
            .unwrap_or_else(|_| "<error>".to_owned());
        let (rect, text) = match proxy.proxies().await {
            Ok(proxies) => {
                let rect = match proxies.component().await {
                    Ok(component) => component.get_extents(CoordType::Screen).await.ok(),
                    Err(_) => None,
                };
                let text = match proxies.text().await {
                    Ok(text) => text.get_text(0, -1).await.ok(),
                    Err(_) => None,
                };
                (rect, text)
            }
            Err(_) => (None, None),
        };
        nodes.push(Node {
            depth,
            role,
            name,
            states,
            rect,
            text,
            object: object.clone(),
        });
        if depth < max_depth {
            if let Ok(children) = proxy.get_children().await {
                queue.extend(children.into_iter().map(|child| (child, depth + 1)));
            }
        }
    }
    nodes
}

fn print_capture(label: &str, nodes: &[Node], elapsed: Duration) {
    println!(
        "{label}_nodes={} {label}_capture_ms={:.3}",
        nodes.len(),
        elapsed.as_secs_f64() * 1000.0
    );
    for node in nodes {
        println!(
            "{}role={:?} name={:?} states={} rect={:?} text={:?}",
            "  ".repeat(node.depth),
            node.role,
            node.name,
            node.states,
            node.rect,
            node.text
        );
    }
}
