/* FUKUSHI QUEST PWA service worker
   fq-sw-v3 (2026-08-24)
   ------------------------------------------------------------------
   ★v2までの問題：すべての GET を「キャッシュ優先」で返していたため、
     1) Supabase の ranking / prizes 取得（GET）が最初の1回で固定され、
        ランキングも在庫連動も二度と更新されなかった。
     2) index.html も更新が届かず、当日の朝に直しても前日に開いた人には
        古い画面が出続けた。
   ★v3 の方針：
     - 別ドメイン（Supabase / CDN / Google Fonts）は一切さわらない＝素通し。
     - 同一オリジンの HTML と config.js は「ネットワーク優先」。
       つながらない時だけキャッシュを出す（＝オフラインでも開ける）。
     - アイコン・manifest だけ「キャッシュ優先」（変わらないので速さ優先）。
   ------------------------------------------------------------------ */
const CACHE = 'fq326-v5';   // fq-logo-daku-v2: ロゴの絵（lg_ga/lg_ru）を差し替えたので版を上げる
// ★画像は下で「キャッシュ優先」にしている。版を上げないと、
//   一度端末に取り込まれた古い絵がいつまでも出続ける。
//   ★img/ の絵を差し替えたら、必ずここの数字を上げること。
const ASSETS = ['./', './index.html', './quest.html', './config.js', './manifest.webmanifest',  // fq-swap-home-v1: quest.html も先に保存する
  './icons/icon-192.png', './icons/icon-512.png', './icons/icon-512-maskable.png'];

self.addEventListener('install', e => {
  // 1つでも落ちると全部入らないので、個別に入れて失敗は無視する
  e.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.all(ASSETS.map(u => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (_) { return; }

  // ★別ドメインは素通し（Supabase API・supabase-js CDN・Google Fonts）
  if (url.origin !== self.location.origin) return;

  const isShell =
    req.mode === 'navigate' ||
    url.pathname.endsWith('/') ||
    url.pathname.endsWith('.html') ||
    url.pathname.endsWith('config.js');

  if (isShell) {
    // ネットワーク優先：新しいのが取れたらそれを出し、控えも更新する
    e.respondWith(
      fetch(req)
        .then(res => {
          if (res && res.ok) {
            const cp = res.clone();
            caches.open(CACHE).then(c => c.put(req, cp)).catch(() => {});
          }
          return res;
        })
        .catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
    );
    return;
  }

  // アイコン等：キャッシュ優先
  e.respondWith(
    caches.match(req).then(r => r || fetch(req).then(res => {
      if (res && res.ok) {
        const cp = res.clone();
        caches.open(CACHE).then(c => c.put(req, cp)).catch(() => {});
      }
      return res;
    }))
  );
});

// 「今すぐ新しい版に切り替える」用（ページ側から postMessage で呼べる）
self.addEventListener('message', e => {
  if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting();
});
