const { app, BrowserWindow } = require("electron");

app.commandLine.appendSwitch("force-renderer-accessibility");

function post(payload) {
  return fetch(process.env.AXON_HARNESS_REPORT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  }).catch(() => {});
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
