# Shared by the live lane and hosted recorded-response tests.
def ok: .result.isError == false;
def observation: .result.structuredContent;
def nodes: observation.app | objects | .windows[]?.root | .. | objects;
def named_button($label):
  nodes | select(.role == "AXButton" and .label == $label
    and ((.actions // []) | index("AXPress"))
    and (.name | type == "string" and length > 0));
def full:
  ok and (observation.app.name | type == "string" and length > 0)
  and ([.result.content[]? | select(.type == "image" and .mimeType == "image/png"
    and (.data | type == "string" and length > 0))] | length == 1)
  and ([named_button("All Clear")] | length == 1)
  and ([named_button("1")] | length == 1)
  and ([named_button("All Clear").name, named_button("1").name] | unique | length == 2);
def app_name: observation.app.name | select(type == "string" and length > 0);
def button_name($label):
  [named_button($label)] | select(length == 1) | .[0].name;
def shallow:
  ok and ([.result.content[]? | select(.type == "image")] | length == 0)
  and ([observation.app.windows[]?.root] | length > 0)
  and ([observation.app.windows[].root] | all(.role == "AXWindow"
    and (has("children") | not) and .truncationReason == "depth limit reached"))
  and ([nodes | select(has("frame"))] | length == 0);
# limit is the effective range, clamped to the native child count, not the request.
# All Clear is a leaf: the bounded page must be empty and have no continuation.
def child_page:
  ok and (observation.children |
    .format == "children" and .offset == 0 and .limit == 0 and .total == 0
    and has("nextOffset") and .nextOffset == null and .tree == "[]")
  and ([.result.content[]? | select(.type == "image")] | length == 0);
def invoked:
  ok and observation.dispatch.success == true and observation.resolution.status == "unique";
def retention_missing:
  .result.isError == true and observation.code == -32002 and observation.data.status == "missing";
def display_one:
  ok and ([nodes | select(.role == "AXStaticText"
    and ((.value // "" | gsub("\u200e"; "")) == "1"))] | length == 1);
def since_token: observation.since | select(type == "string" and length > 0);
def unchanged: ok and observation.unchanged == true;
def changed:
  ok and (observation.unchanged // false) == false
  and (observation.diff != null or observation.note == "diff-exceeded-threshold");
def ocr:
  ok and ([observation.screenText[]?.text | strings | select(test("[0-9]"))] | length > 0);
def screen_text: [observation.screenText[]?.text] | .[0:12];
# Safe on both successful observations and structured tool errors.
def diagnostic:
  {isError: .result.isError, error: .error,
   observation: (observation | {app, children, since, unchanged, diff, note,
     screenText, screenTextUnavailable, code, message, data}),
   targets: ([nodes | select(.role == "AXButton" or .role == "AXStaticText")
     | {role, label, value, name, identifier, actions}][0:30])};
