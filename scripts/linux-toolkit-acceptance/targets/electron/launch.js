// Electron target. Chromium filters synthetic X11 events; this measures that claim rather than
// repeating it. The window is frameless so the page's own coordinates are the window's coordinates,
// and renderer accessibility is forced on so the AT-SPI half of the measurement has a tree to read.
const { spawn } = require("node:child_process");
const path = require("node:path");

const electron = require(path.join(__dirname, "node_modules", "electron"));

const child = spawn(
  electron,
  [path.join(__dirname, "main.js"), "--force-renderer-accessibility", "--no-sandbox"],
  { stdio: "inherit", env: process.env },
);
child.on("exit", (code) => process.exit(code ?? 0));
