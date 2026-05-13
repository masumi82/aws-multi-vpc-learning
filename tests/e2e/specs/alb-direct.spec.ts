import { test, expect } from "@playwright/test";

// E6: ALB を CloudFront を経由せず直接叩くと SG で弾かれる
//     (CloudFront managed prefix list 制限の証跡)
test("E6: Direct ALB access is blocked by SG (timeout or connection refused)", async ({
  request,
}) => {
  const albDns = process.env.ALB_DNS_NAME;
  test.skip(!albDns, "ALB_DNS_NAME not provided");

  try {
    const res = await request.get(`http://${albDns}/`, {
      timeout: 8_000,
      failOnStatusCode: false,
    });
    // ここに来てしまったら SG が緩い疑い
    // ただし 504/403 ならまだ妥当
    expect([403, 504]).toContain(res.status());
  } catch (e: any) {
    // タイムアウト or ECONNREFUSED → SG ブロック正常
    const msg = String(e?.message ?? e);
    expect(/timeout|ECONNREFUSED|ECONNRESET|ETIMEDOUT/i.test(msg)).toBeTruthy();
  }
});
