// The Electron target: one window, one page, no chrome of its own.
//
// Kept as close to a default packaged application as possible, because the row
// it produces speaks for what a packaged Chromium application does with a
// posted event, not for what this file configures.
const { app, BrowserWindow } = require("electron");

const address = process.argv[process.argv.length - 1];

app.whenReady().then(() => {
  const window = new BrowserWindow({
    width: 640,
    height: 480,
    x: 120,
    y: 120,
    show: true,
  });
  window.loadURL(address);
});

app.on("window-all-closed", () => app.quit());
