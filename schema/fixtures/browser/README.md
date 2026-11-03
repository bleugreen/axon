# Browser verb fixtures: a frozen corpus

Each file is the Swift daemon's answer to one `navigate`, `windows`, or `tabs` request (or a URL
case Foundation decided), written by the Swift conformance test that existed until 0.4.0. The Swift
daemon is gone, so **these are never regenerated**. They pin the wire shapes the Rust daemon took
over: `rust/axon-core/tests/browser_contract.rs` holds the contract types to these bytes, and the
`axon-mac` router test produces the same bodies end to end from a scripted browser.

A deliberate change to a browser verb's wire shape is a contract change: edit the fixture by hand,
say why in the commit, and update the shared docs.
