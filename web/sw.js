// Deliberately does almost nothing -- this is a live chat app (WebSocket +
// dynamic history), so caching index.html or any request would risk
// serving stale app code or stale conversation state. A `fetch` handler
// existing at all (even a pure pass-through) is what Android's install
// criteria actually check for; it doesn't need to *do* anything with the
// request for that box to be ticked.
self.addEventListener("install", (event) => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  event.respondWith(fetch(event.request));
});
