import { test, expect } from "@playwright/test";

// E2: /api/* は ALB → Fargate (nginx) に到達
test("E2: GET /api/ returns ALB origin (Nginx welcome)", async ({ request }) => {
  const res = await request.get("/api/");
  expect(res.status()).toBe(200);
  const body = await res.text();
  // public.ecr.aws/nginx/nginx:stable のデフォルトページ
  expect(body.toLowerCase()).toContain("nginx");
});

// E5: HEAD / OPTIONS の対応
test("E5a: HEAD /api/ returns 200", async ({ request }) => {
  const res = await request.head("/api/");
  expect(res.status()).toBe(200);
});

test("E5b: OPTIONS /api/ returns 200/204", async ({ request }) => {
  const res = await request.fetch("/api/", { method: "OPTIONS" });
  expect([200, 204, 405]).toContain(res.status());
  // 405 だと CloudFront/ALB のメソッド扱いに齟齬があるサイン
});
