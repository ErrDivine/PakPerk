import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  workers: 2,
  reporter: "line",
  use: {
    browserName: "chromium",
    headless: true,
    locale: "en-US",
    timezoneId: "UTC",
    serviceWorkers: "block",
  },
});
