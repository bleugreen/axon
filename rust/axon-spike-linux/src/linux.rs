use std::{
    collections::VecDeque,
    error::Error,
    time::{Duration, Instant},
};

use atspi::{
    AccessibilityConnection, CoordType, ObjectRef, ObjectRefOwned,
    proxy::{
        accessible::{AccessibleProxy, ObjectRefExt},
        proxy_ext::ProxyExt,
    },
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

async fn same_bus_children(
    connection: &atspi::zbus::Connection,
    object: &ObjectRefOwned,
) -> Result<Vec<ObjectRefOwned>, Box<dyn Error>> {
    use atspi::zbus::{
        fdo::DBusProxy,
        names::BusName,
        zvariant::OwnedObjectPath,
    };

    let destination = object
        .name()
        .ok_or("AT-SPI object reference has no bus destination")?
        .clone();
    let reply = connection
        .call_method(
            Some(destination),
            object.path(),
            Some("org.a11y.atspi.Accessible"),
            "GetChildren",
            &(),
        )
        .await?;
    let children: Vec<(String, OwnedObjectPath)> = reply.body().deserialize()?;
    let dbus = DBusProxy::new(connection).await?;
    let mut resolved = Vec::with_capacity(children.len());
    for (name, path) in children {
        let bus_name = BusName::try_from(name)?;
        let unique_name = match bus_name {
            BusName::Unique(name) => name.into(),
            BusName::WellKnown(_) => dbus.get_name_owner(bus_name).await?,
        };
        resolved.push(ObjectRef::new_owned(unique_name, path));
    }
    Ok(resolved)
}

async fn accessible_proxy<'a>(
    connection: &'a atspi::zbus::Connection,
    object: &'a ObjectRefOwned,
    same_bus: bool,
) -> Result<AccessibleProxy<'a>, Box<dyn Error>> {
    if !same_bus {
        return Ok(object.as_accessible_proxy(connection).await?);
    }

    let destination = object
        .name()
        .ok_or("AT-SPI object reference has no bus destination")?
        .clone();
    Ok(AccessibleProxy::builder(connection)
        .destination(destination)?
        .path(object.path().clone())?
        .build()
        .await?)
}

#[tokio::main]
pub async fn run(options: Options) -> Result<(), Box<dyn Error>> {
    let connection = AccessibilityConnection::new().await?;
    let registry = connection.root_accessible_on_registry().await?;
    let applications = registry.get_children().await?;

    if options.application.is_none() {
        println!("applications={}", applications.len());
        for object in applications {
            let proxy = accessible_proxy(
                connection.connection(),
                &object,
                options.same_bus,
            )
            .await?;
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
    let root = select_application(
        connection.connection(),
        applications,
        needle,
        options.same_bus,
    )
    .await?;
    let started = Instant::now();
    let before = capture(
        connection.connection(),
        root.clone(),
        options.max_depth,
        options.max_nodes,
        options.same_bus,
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
        let proxy = accessible_proxy(
            connection.connection(),
            &target.object,
            options.same_bus,
        )
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
        let dispatch_success = action.do_action(action_index as i32).await?;
        println!("dispatch_success={dispatch_success}");
        if !dispatch_success {
            return Err("AT-SPI Action.DoAction rejected the action".into());
        }
        tokio::time::sleep(Duration::from_millis(500)).await;

        let started = Instant::now();
        let after = capture(
            connection.connection(),
            root,
            options.max_depth,
            options.max_nodes,
            options.same_bus,
        )
        .await;
        let elapsed = started.elapsed();
        print_capture("after", &after, elapsed);
        let expected_before = options.expect_text_before.as_deref().unwrap();
        let expected_after = options.expect_text_after.as_deref().unwrap();
        let text_object = before
            .iter()
            .find(|node| node.text.as_deref() == Some(expected_before))
            .ok_or_else(|| {
                format!("no text object contained expected before value {expected_before:?}")
            })?;
        let observed_after = after
            .iter()
            .find(|node| node.object == text_object.object)
            .and_then(|node| node.text.as_deref());
        if observed_after != Some(expected_after) {
            return Err(format!(
                "action dispatched, but text object changed from {expected_before:?} to {observed_after:?}, expected {expected_after:?}"
            )
            .into());
        }
        println!(
            "verified_outcome=true verification=same_object_text_transition before={expected_before:?} after={expected_after:?} object={:?} before_nodes={} after_nodes={}",
            text_object.object,
            before.len(),
            after.len()
        );
    }

    Ok(())
}

async fn select_application(
    connection: &atspi::zbus::Connection,
    applications: Vec<ObjectRefOwned>,
    needle: &str,
    same_bus: bool,
) -> Result<ObjectRefOwned, Box<dyn Error>> {
    let needle = needle.to_lowercase();
    let mut partial = None;
    for object in applications {
        let proxy = accessible_proxy(connection, &object, same_bus).await?;
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
    same_bus: bool,
) -> Vec<Node> {
    let mut queue = VecDeque::from([(root, 0)]);
    let mut nodes = Vec::new();
    while let Some((object, depth)) = queue.pop_front() {
        if nodes.len() >= max_nodes {
            break;
        }
        let proxy = match accessible_proxy(connection, &object, same_bus).await {
            Ok(proxy) => proxy,
            Err(error) => {
                eprintln!(
                    "accessible_proxy_error destination={:?} path={} error={error}",
                    object.name_as_str(),
                    object.path()
                );
                continue;
            }
        };
        let role = match proxy.get_role_name().await {
            Ok(role) => role,
            Err(_) => proxy
                .get_role()
                .await
                .map(|role| format!("{role:?}"))
                .unwrap_or_else(|_| "<error>".to_owned()),
        };
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
            let children = if same_bus {
                same_bus_children(connection, &object).await
            } else {
                proxy.get_children().await.map_err(Into::into)
            };
            if let Ok(children) = children {
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
            "{}role={:?} name={:?} destination={:?} path={} states={} rect={:?} text={:?}",
            "  ".repeat(node.depth),
            node.role,
            node.name,
            node.object.name_as_str(),
            node.object.path(),
            node.states,
            node.rect,
            node.text
        );
    }
}
