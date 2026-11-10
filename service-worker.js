/* == fq-move-v1 : 前の住所の「控えの仕組み」を片づける ==
   ★アプリは https://festa.lifeplusllc.com/ に引っ越した。
   ★前に一度開いたスマホは、ここ（前の住所）の古い service worker を持っている。
     ブラウザが新しい版を取りに来たら、この版に入れかわり、
       1) 古い画面の控え（キャッシュ）を全部消す
       2) 自分自身を外す（登録を解除する）
       3) 開いている画面を、同じページのまま新しい住所へ移す
   ★fetch は横取りしない（素通し）。転送ページ（index.html / 404.html）がそのまま届く。 */
self.addEventListener('install', function(e){ self.skipWaiting(); });
self.addEventListener('activate', function(e){
  e.waitUntil((async function(){
    try{ var ks = await caches.keys(); await Promise.all(ks.map(function(k){ return caches.delete(k); })); }catch(err){}
    try{ await self.clients.claim(); }catch(err){}
    var cs = [];
    try{ cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true }); }catch(err){}
    try{ await self.registration.unregister(); }catch(err){}
    cs.forEach(function(c){
      try{
        var u = new URL(c.url);
        var p = u.pathname.replace(/^\/fukushi-quest\/?/, '');
        c.navigate('https://festa.lifeplusllc.com/' + p + u.search + u.hash);
      }catch(err){}
    });
  })());
});
