// This worker belongs only to the separate distribution build. It serves the
// existing runtime's /thief2-assets requests from the user's local import.
const base = new URL('.', self.location.href);
const prefix = 'thief2-vr:' + base.pathname;
const stateUrl = new URL('import-state.json', base).href;

self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('message', event => {
    if (event.data === 'claim-client') event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', event => {
    const url = new URL(event.request.url);
    if (url.origin !== base.origin || !['GET', 'HEAD'].includes(event.request.method)) return;
    if (url.pathname.startsWith('/thief2-assets/')) {
        event.respondWith(importedFile(event.request, url));
    } else if (url.pathname.startsWith('/vis/') && base.pathname !== '/') {
        // Resolve our generated visibility cache under the GitHub project path.
        event.respondWith(fetch(new URL(url.pathname.slice(1), base)));
    }
});

async function importedFile(request, url) {
    let path;
    try {
        path = decodeURIComponent(url.pathname.slice('/thief2-assets/'.length)).replace(/\\/g, '/').toLowerCase();
        if (!path || /[\x00-\x1f:#?]/.test(path) || path.split('/').some(p => !p || p === '.' || p === '..')) throw new Error('Invalid path');
    } catch { return new Response('Invalid game file path.', { status: 400 }); }
    const metadata = await caches.open(prefix + ':metadata-v1');
    const record = await metadata.match(stateUrl);
    if (!record) return new Response('Import your Thief II files first.', { status: 404 });
    const state = await record.json();
    if (!state.cacheName?.startsWith(prefix + ':files-v1-')) return new Response('Invalid saved import.', { status: 404 });
    const cache = await caches.open(state.cacheName);
    const key = new URL('/thief2-assets/' + path.split('/').map(encodeURIComponent).join('/'), base.origin);
    const response = await cache.match(key.href);
    if (!response) return new Response('Game file not found in the import: ' + path, { status: 404 });
    if (request.method === 'HEAD') return new Response(null, { status: 200, headers: response.headers });
    return response;
}
