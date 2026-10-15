# Android native redirect client

Continue the approved native-client design with a Java API usable directly from
Kotlin/Java Android apps. A second policy engine is rejected; resolve the same
canonical HTTPS URLs and validate the same six-field JSON protocol as Swift.
java.net.HttpURLConnection would use process-global cookie/auth configuration;
use a dedicated OkHttp client with no cookies/cache/authenticator/interceptors,
redirects disabled, retryOnConnectionFailure disabled, a ten-second call deadline
and cancellable calls. A larger app framework would not add protocol capability.

Official OkHttp README and Maven Central metadata agree on5.5.0 and support for
Android21+/Java8+. Use its Android variant in host apps; the local JVM build uses
okhttp-jvm. Android supplies org.json; a provided JSON dependency supports isolated
JVM tests without bundling another Android JSON implementation. Keep the SDK API
independent of Activity/Context, UI frameworks and server credentials. Return a
browser/app navigation decision for the host rather than launch activities itself.

Only allowlisted public HTTPS short hosts may be requested. Keep passwords in
bounded form POSTs, reject password query fields, omit fragments, set an Android
user agent for existing device targeting, and default attribution consent to
denied. Stream at most64KiB, reject unexpected HTTP/MIME/shape/source/URL/UUID
responses, enforce matching click ID/query values, and strip unexpected consent-
denied attribution. App navigation requires an owned HTTPS content host and normal
TLS port; other valid destinations and web mode require explicit browser fallback.

One execute/enqueue per call; cancellation and ambiguous delivery do not trigger
SDK retries. Caller errors contain only stable reason/status/retry metadata.
Tests must exercise actual OkHttp HTTP/TLS behavior, request forms/headers,
password/rate responses, malformed payloads, unsafe URLs, default-denied/granted
consent, expiry/browser mode, bounded bodies, cancellation, no automatic redirects,
no retries and no global cookie use. Compile library against Java8 API; Android
manifest/assetlinks/Play signing/installed-device proof and deterministic deferred
attribution remain separate requirements, not claims made by JVM fixtures.
