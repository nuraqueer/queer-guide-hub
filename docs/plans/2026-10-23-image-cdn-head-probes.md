# Image CDN HEAD responses

The image auditor sends HEAD before requesting image bytes. The CDN accepted GET but rejected HEAD with HTTP 405, so valid mirrored images were recorded as unreachable. A live control returned HEAD 405 and GET 200 with a 433,360-byte, 1280×960 JPEG.

The Gaycities observation history contains 2,681 CDN method failures. A current-image join finds 1,375 event records still carrying a failed CDN observation (1,374 active), with 662 exact open `IMAGE_UNREACHABLE` findings. These are recheck candidates, not verified repairs: a fresh audit can still discover genuine size, decode or reuse problems.

Original-image HEAD now reads R2 metadata without opening the object body. GET and HEAD share content type, real byte length, quoted ETag, cache and CORS headers. Cached thumbnail HEAD also reads metadata only; an uncached thumbnail uses the GET representation and cancels its response body. Missing assets return bodyless 404, while upload authorization and unsupported methods retain their existing guards. No image quality thresholds or stored observations are changed by the Worker fix.

Validation: five Worker regressions, Worker TypeScript check, scoped ESLint and Wrangler build dry run pass. The Worker now owns a small standalone Vitest suite picked up by the existing worker-tests CI job. API behavior was checked against the current [R2 Workers reference](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/). Deployment and subsequent native-auditor receipts will be recorded separately; no pending reduction is credited before rechecks.
