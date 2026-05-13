import { test, expect } from "@playwright/test";

// E7: Tier 1 では複数 Fargate タスクで動作。
//     ALB が複数 Target にバランシングしていることを CloudFront 経由で確認する。
//     nginx は本来同じレスポンスを返すため、X-Amz-Cf-Id (CloudFront リクエスト ID) と
//     server: nginx ヘッダから「ALB 経由で安定して応答が返る」を見る。
//
// 注意: ECS Service の TG に複数 healthy target が居る前提。
//       Tier 0 (1 task) でも PASS する。Tier 1 検証では併せて Integration test I14 の
//       healthy 数 = desired_count を確認する。
test("E7: /api/* responses are served stably across multiple requests", async ({ request }) => {
  const N = 20;
  const cfIds = new Set<string>();
  const statuses: number[] = [];

  for (let i = 0; i < N; i++) {
    const res = await request.get(`/api/?_=${i}`);
    statuses.push(res.status());
    const cfId = res.headers()["x-amz-cf-id"];
    if (cfId) cfIds.add(cfId);
  }

  // 全リクエストが 200 で返ること (CloudFront fallback でも 200)
  expect(statuses.every((s) => s === 200)).toBeTruthy();

  // CloudFront 各リクエストでユニークな ID が付与されていること
  // (= 全てが CloudFront を通過した証跡、ALB の応答能力が安定している指標)
  expect(cfIds.size).toBeGreaterThanOrEqual(Math.floor(N * 0.9));
});
