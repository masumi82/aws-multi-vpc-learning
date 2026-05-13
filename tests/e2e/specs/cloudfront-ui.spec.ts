import { test, expect } from "@playwright/test";

// E1: CloudFront → S3 UI 配信
test("E1: GET / returns S3 index.html (200)", async ({ page }) => {
  const res = await page.goto("/");
  expect(res?.status()).toBe(200);
  await expect(page.locator('[data-testid="marker"]')).toHaveText("deployed");
});

// E3: SPA フォールバック (存在しないパス → index.html を 200 で返す)
test("E3: GET /this-path-does-not-exist returns index.html (200, SPA fallback)", async ({
  page,
}) => {
  const res = await page.goto("/this-path-does-not-exist");
  expect(res?.status()).toBe(200);
  await expect(page.locator('[data-testid="marker"]')).toHaveText("deployed");
});

// E4: HTTP → HTTPS リダイレクト
test("E4: HTTP request is redirected to HTTPS", async ({ request }) => {
  const domain = process.env.CLOUDFRONT_DOMAIN!;
  const res = await request.get(`http://${domain}/`, {
    maxRedirects: 0,
    failOnStatusCode: false,
  });
  expect([301, 302, 308]).toContain(res.status());
  const location = res.headers()["location"];
  expect(location?.startsWith("https://")).toBeTruthy();
});
