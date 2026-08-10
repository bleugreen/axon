const { app, BrowserWindow } = require("electron");
const http = require("http");

app.commandLine.appendSwitch("force-renderer-accessibility");

// Written against `http` rather than `fetch`: the older Electron majors measured here ship a Node
// without a global fetch, and this file has to run identically on every one of them for their rows
// to be comparable.
function post(payload) {
  const body = JSON.stringify(payload);
  const url = new URL(process.env.AXON_HARNESS_REPORT);
  const request = http.request(
    {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    },
    (response) => response.resume(),
  );
  request.on("error", () => {});
  request.end(body);
}

app.whenReady().then(async () => {
  const window = new BrowserWindow({
    width: 480,
    height: 360,
    frame: false,
    show: true,
    webPreferences: { sandbox: false },
  });
  await window.loadURL(process.env.AXON_HARNESS_PAGE);
  setTimeout(() => {
    post({
      kind: "ready",
      pid: process.pid,
      signature: `Electron ${process.versions.electron} (Chromium ${process.versions.chrome})`,
      viewportOffset: [0, 0],
    });
  }, 600);
});

app.on("window-all-closed", () => app.quit());
