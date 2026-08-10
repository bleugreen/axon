// Electron target. Chromium filters synthetic X11 events; this measures that claim rather than
// repeating it. The window is frameless so the page's own coordinates are the window's coordinates,
// and renderer accessibility is forced on so the AT-SPI half of the measurement has a tree to read.
const { spawn } = require("node:child_process");
const path = require("node:path");

// Which runtime to launch. Chromium reports itself to AT-SPI as toolkit "Chromium" version "1.0"
// whatever engine it is, so an acceptance table keyed on that signature authorizes the whole family
// — which is only honest if the family has been measured across more than one engine generation.
// Each installed runtime is measured separately for that reason.
const runtime = process.env.AXON_HARNESS_ELECTRON || path.join(__dirname, "node_modules", "electron");
const electron = require(runtime);

const child = spawn(
  electron,
  [path.join(__dirname, "main.js"), "--force-renderer-accessibility", "--no-sandbox"],
  { stdio: "inherit", env: process.env },
);
child.on("exit", (code) => process.exit(code ?? 0));
