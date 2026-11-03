//! Point targets: a caller-supplied coordinate, the space it was measured in, and the application
//! it belongs to.
//!
//! The accepted shapes are the ones the public schema documents for every backend:
//! `{point:{x,y,coordinateSpace,app}}`, `{app,coordinateSpace,point:{x,y}}`, and
//! `{x,y,coordinateSpace}`, with the same precedence the Swift daemon used until 0.4.0, so a
//! `{app, point}` fallback recorded by either daemon means the same thing.

use serde_json::{Map, Value};

/// Which coordinate system a point's `x` and `y` are in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointSpace {
    /// Logical screen points in the platform accessibility coordinate system.
    Screen,
    /// Logical points relative to the origin of the application's focused window.
    Window,
    /// Pixels in an encoded screenshot of the application's window.
    Screenshot,
}

impl PointSpace {
    pub fn key(self) -> &'static str {
        match self {
            PointSpace::Screen => "screen",
            PointSpace::Window => "window",
            PointSpace::Screenshot => "screenshot",
        }
    }
}

/// One parsed point target.
#[derive(Clone, Debug, PartialEq)]
pub struct PointTarget {
    pub x: f64,
    pub y: f64,
    pub space: PointSpace,
    /// The application the point names, from the most specific place that named one.
    pub app: Option<String>,
}

/// Whether a target value is shaped like a point rather than a semantic name or a text location.
pub fn pointer_target_is_point(target: &Value) -> bool {
    target.get("point").is_some() || (target.get("x").is_some() && target.get("y").is_some())
}

impl PointTarget {
    /// Parses `target`, falling back to `top_level_app` for the application.
    ///
    /// The point is the most specific statement of what it means, so what it declares wins and the
    /// target object around it only fills in what the point left unsaid; the top-level `app`
    /// parameter is the last resort. `window` and `screenshot` points are relative to a window, so
    /// they require an application from one of those three places.
    pub fn parse(target: &Value, top_level_app: Option<&str>) -> Result<PointTarget, String> {
        let wrapper = target
            .as_object()
            .ok_or_else(|| "point target must be an object".to_string())?;
        let (point, wrapper) = match wrapper.get("point") {
            Some(point) => (
                point
                    .as_object()
                    .ok_or_else(|| "point must be an object".to_string())?,
                Some(wrapper),
            ),
            None => (wrapper, None),
        };
        let number = |key: &str| point.get(key).and_then(Value::as_f64);
        let (Some(x), Some(y)) = (number("x"), number("y")) else {
            return Err("point requires numeric x and y".into());
        };
        let space = match declared_space(point)? {
            Some(space) => space,
            None => match wrapper {
                Some(wrapper) => declared_space(wrapper)?.unwrap_or(PointSpace::Screen),
                None => PointSpace::Screen,
            },
        };
        let app = non_empty(point, "app")
            .or_else(|| wrapper.and_then(|wrapper| non_empty(wrapper, "app")))
            .or_else(|| {
                top_level_app
                    .filter(|app| !app.is_empty())
                    .map(str::to_owned)
            });
        if space != PointSpace::Screen && app.is_none() {
            return Err(format!(
                "point coordinateSpace {} requires app",
                space.key()
            ));
        }
        Ok(PointTarget { x, y, space, app })
    }
}

fn non_empty(object: &Map<String, Value>, key: &str) -> Option<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

/// The space an object states, or `None` when it states none. `space` is the legacy spelling.
fn declared_space(object: &Map<String, Value>) -> Result<Option<PointSpace>, String> {
    let Some(raw) = object
        .get("coordinateSpace")
        .or_else(|| object.get("space"))
        .and_then(Value::as_str)
    else {
        return Ok(None);
    };
    match raw {
        "screen" => Ok(Some(PointSpace::Screen)),
        "window" => Ok(Some(PointSpace::Window)),
        "screenshot" => Ok(Some(PointSpace::Screenshot)),
        _ => Err("point coordinateSpace must be screen, window, or screenshot".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(target: Value, app: Option<&str>) -> Result<PointTarget, String> {
        PointTarget::parse(&target, app)
    }

    #[test]
    fn all_three_shapes_parse_to_the_same_point() {
        let expected = PointTarget {
            x: 10.0,
            y: 20.0,
            space: PointSpace::Window,
            app: Some("TextEdit".into()),
        };
        for target in [
            json!({"point":{"x":10,"y":20,"coordinateSpace":"window","app":"TextEdit"}}),
            json!({"app":"TextEdit","coordinateSpace":"window","point":{"x":10,"y":20}}),
            json!({"x":10,"y":20,"coordinateSpace":"window","app":"TextEdit"}),
        ] {
            assert_eq!(parse(target.clone(), None).unwrap(), expected, "{target}");
        }
    }

    #[test]
    fn the_point_outranks_the_wrapper_which_outranks_the_top_level_app() {
        let point = parse(
            json!({"app":"Wrapper","coordinateSpace":"screen",
                   "point":{"x":1,"y":2,"app":"Point","coordinateSpace":"window"}}),
            Some("TopLevel"),
        )
        .unwrap();
        assert_eq!(point.app.as_deref(), Some("Point"));
        assert_eq!(point.space, PointSpace::Window);

        let wrapper = parse(
            json!({"app":"Wrapper","point":{"x":1,"y":2}}),
            Some("TopLevel"),
        )
        .unwrap();
        assert_eq!(wrapper.app.as_deref(), Some("Wrapper"));

        let top = parse(json!({"point":{"x":1,"y":2}}), Some("TopLevel")).unwrap();
        assert_eq!(top.app.as_deref(), Some("TopLevel"));
        assert_eq!(top.space, PointSpace::Screen);
    }

    #[test]
    fn the_legacy_space_key_is_read_and_an_empty_app_is_absent() {
        let point = parse(
            json!({"x":1,"y":2,"space":"screenshot","app":"Safari"}),
            None,
        )
        .unwrap();
        assert_eq!(point.space, PointSpace::Screenshot);
        let bare = parse(json!({"x":1,"y":2,"app":""}), Some("")).unwrap();
        assert_eq!(bare.app, None);
    }

    #[test]
    fn window_relative_points_require_an_app_and_malformed_points_are_refused() {
        assert!(
            parse(json!({"x":1,"y":2,"coordinateSpace":"window"}), None)
                .unwrap_err()
                .contains("requires app")
        );
        assert!(
            parse(json!({"x":1,"y":2,"coordinateSpace":"pixels"}), None)
                .unwrap_err()
                .contains("screen, window, or screenshot")
        );
        assert!(
            parse(json!({"point":{"x":"1","y":2}}), None)
                .unwrap_err()
                .contains("numeric")
        );
        assert!(parse(json!({"point":5}), None).is_err());
    }

    #[test]
    fn recorded_point_fallbacks_are_points() {
        assert!(pointer_target_is_point(
            &json!({"app":"com.apple.TextEdit","point":{"x":1,"y":2}})
        ));
        assert!(pointer_target_is_point(&json!({"x":1,"y":2})));
        assert!(!pointer_target_is_point(&json!({"app":"A","name":"B"})));
    }
}
