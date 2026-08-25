
---

## `fq-swap-home-v1` — 来場者が最初に見る画面を案内画面にした（2026-08-25）

### 何を変えたか

| 前 | 後 |
|---|---|
| `index.html` … クエスト本体（トップを開くといきなりこれ） | `quest.html` |
| `home.html` … チラシと同じ見た目の案内画面 | `index.html`（新しいトップ） |

**トップを開くと、まず案内画面（開催日・ステージ・みどころ・会場・協賛）が出る。**
クエストはタブの「🎁 クエスト」から入る。

### ★調べて分かったこと — 印刷済みQRはファイル名を含んでいなかった

READMEには「印刷済みのQRが `index.html` を指しているので `?q=` で転送する形にする」と
書いていたが、**`qr/qr_print_A4.pdf` から実際にQRを読み取って確かめたところ、違った。**

```
アプリ用    → https://cocokaraplus-max.github.io/fukushi-quest/
本部モニター → https://cocokaraplus-max.github.io/fukushi-quest/honbu.html
```

**どちらもファイル名を含んでいない。** アプリ用はフォルダのトップを指している。
だから **home を index.html にするだけで、印刷済みのQRはそのまま案内画面に着く。**

**How to apply:** 「印刷済みだから触れない」と思ったら、**実物のQRを読んで確かめる。**
PDFからでも読める（`pdftoppm` で画像にして `cv2.QRCodeDetector`）。

### 転送 — QRの形が3通りとも動く

新しい `index.html` の head の早い位置に、`?q=` `?dev=1` `?admin=1` が付いていたら
`quest.html` へ渡す処理を入れた。

```
.../fukushi-quest/?q=talk_A            今後作るQR。★ファイル名が入らないので永久に壊れない
.../fukushi-quest/index.html?q=talk_A  アプリ内の説明どおりに作ったQR
.../fukushi-quest/quest.html?q=talk_A  直接
```

**すでに印刷したQRがあっても、無くても、どちらでも困らない。**

あわせて `quest.html` の中の説明文を `…/index.html?q=` から `…/?q=` に直した。
**今後QRを作るときは、この「ファイル名なし」の形にすること。**

### そのほか触った場所

- `index.html`（新トップ）… `manifest.webmanifest` の読み込みと Service Worker の登録を追加。
  入口が案内画面になったため（クエスト側にも元から入っている）
- `index.html`（新トップ）… 「クエストをはじめる」のリンク先を `quest.html` に
- `service-worker.js` … `ASSETS` に `./quest.html` を追加。版番号を `fq326-v3` → `fq326-v4`
  （★上げないと、前に開いた人の端末に古い組み合わせが残る）
- `check.html` … クエスト本体の修正確認を `quest.html` に対して行うように

### 触ると壊れる場所

1. **新しい `index.html` の転送を消さないこと。**
   消すと、`?q=` 付きのQRが「案内画面が開くだけ」になり、ポイントが入らない。
2. **転送を head の早い位置から動かさないこと。** 描画より前に動く必要がある。
3. **`service-worker.js` の版番号を戻さないこと。**
4. **今後作るQRに `index.html` や `quest.html` を含めないこと。**
   トップ + `?q=…` の形なら、また入れ替えても壊れない。

### 検証したこと（ローカルのサーバーに出して、実際のブラウザで6通り）

| 開いたURL | 結果 |
|---|---|
| `/` | 案内画面 |
| `/?q=talk_A` | クエストへ転送（スキャンも実行された） |
| `/index.html?q=talk_A` | クエストへ転送 |
| `/quest.html?q=talk_A` | 直接クエスト |
| `/?admin=1` | クエストへ転送（`?admin=1` も渡る） |
| `/index.html` | 案内画面 |

足したJSの文法チェックも通っている。

### ★公開したあとに確認すること

1. `https://cocokaraplus-max.github.io/fukushi-quest/` を開いて**案内画面**が出るか
2. `.../fukushi-quest/?q=talk_A` を開いて**クエストに入り、ポイントが入るか**
3. `.../fukushi-quest/check.html` を開いて、**⑤の項目が `quest.html` を見て緑になるか**
4. **前に開いたことのある端末**で、古い画面が残っていないか
   （Service Worker の版を上げてあるので、再読み込みで入れ替わるはず）
