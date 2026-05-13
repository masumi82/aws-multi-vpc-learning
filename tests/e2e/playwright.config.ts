import { defineConfig, devices } from "@playwright/test";

// CLOUDFRONT_DOMAIN は run.sh が terraform output から注入する
const baseURL = process.env.CLOUDFRONT_DOMAIN
  ? `https://${process.env.CLOUDFRONT_DOMAIN}`
  : "https://example.com"; // フォールバック (実テスト時は必ず注入)

export default defineConfig({
  testDir: "./specs",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: true,
  reporter: [
    ["list"],
    ["html", { outputFolder: "playwright-report", open: "never" }],
  ],
  use: {
    baseURL,
    ignoreHTTPSErrors: false,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
