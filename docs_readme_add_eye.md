
---

## `fq-pass-eye-v1` と、リセットが弾かれた件（2026-08-26）

### ★Supabase には「うっかり全消し」を防ぐ安全装置がある

本部の画面でリセットを押したら、こう出て止まった。

```
通信エラー: DELETE requires a WHERE clause
```

**原因**：Supabase には `safeupdate` という安全装置が入っていて、
**`where` の付いていない `delete` / `update` を拒否する。**
`fq_reset` の中身がまさにそれだった。

```sql
delete from draws;                       -- ← 弾かれた
delete from participants;                -- ← 弾かれた
update prizes set stock = initial_stock; -- ← 弾かれた
```

**直し方**：全部に `where` を付ける。意味は変わらない。

```sql
delete from draws where true;
delete from participants where true;
update prizes set stock = initial_stock
 where stock is distinct from initial_stock;
```

**★ここが教訓**：**手元の Postgres で通っても、Supabase では通らないことがある。**
手元には `safeupdate` が無いので、そこでは素通りしていた。
**「同じ Postgres でも Supabase は別物」**として扱うこと。
SQL を書いたら、**必ず Supabase の本番で1回通してから完成とする。**

**★`where true` を外さないこと。** 外すとまた弾かれる。

### ★合言葉が短すぎた

最初に設定した `reset_pass` が **6文字**だった。
リセットは全データを消す操作で、アプリの公開鍵(anonキー)は誰でも見られるため、
理屈のうえでは外から試せる。**15文字に付け直した。**

長さだけを確かめる SQL（中身は出ない）:

```sql
select key, length(value) as 文字数,
       (value <> btrim(value)) as 前後に空白がある
from fq_admin order by key;
```

**★合言葉は手打ちしない。** メモ帳に書いて、そこからコピーして貼る。
今回、手打ちで「思っていたのと違うものが保存されていた」状態になった。

### `fq-pass-eye-v1` — 合言葉を見るボタン

伏せ字（●●●）だと打ち間違いに気づけないので、入力欄の右に 👁 を付けた。
押すたびに 見える／隠れる が切り替わる。

- 本部モニターの大会リセット（`honbu.html`）
- クエストの関係者用の入口（`quest.html`）

**★人前で押さないこと。** 押すと画面にそのまま出る。
自動で隠す作りにはしていない（かえって混乱するため）。
**ページを開き直せば、必ず隠れた状態から始まる。**

検証：実際のブラウザで11項目、全通過
（最初は伏せ字／押すと見える／打った文字は消えない／もう一度で隠れる／
開き直すと必ず伏せ字から。本部・クエストの両方）。
