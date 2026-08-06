# 共有バックエンド（無料 Supabase）セットアップ手順

> 目的：**景品在庫を本部タブレットでライブ表示／ランキングを各端末で閲覧**。
> TASUKARU とは**別プロジェクト**で作成すること（混ざらない）。

## 1. Supabase 無料プロジェクトを作る（あなたの操作）
1. https://supabase.com で Sign up（無料。GitHub 等でOK）。※アカウント作成は本人操作が必要。
2. **New project** → 名前 `fukushi-quest`、Region = **Northeast Asia (Tokyo)**、DBパスワードを設定して控える。**Free** プランでOK。

## 2. テーブルと関数を作る
3. 左メニュー **SQL Editor** → **New query** → `supabase_schema.sql` の中身を全部貼り付け → **Run**。
   - participants / prizes / draws、ランキングビュー、在庫アトミック減算関数、RLS、realtime配信、例景品まで一括で入る。

## 3. 接続情報を設定
4. 左下 **Settings → API** で以下をコピー：
   - **Project URL**（`https://xxxx.supabase.co`）
   - **anon public** キー（フロント公開用。RLS＋RPCで保護されるので公開してよいキー）
5. `config.js` を開き、2か所を貼り替え：
   ```js
   window.FQ_CONFIG = {
     SUPABASE_URL:      "https://xxxx.supabase.co",
     SUPABASE_ANON_KEY: "（anon public キー）"
   };
   ```

## 4. 本部モニターを開く
6. `honbu.html` を本部タブレットで開く → 在庫・ランキングが**ライブ表示**（景品確定で在庫が減り、ポイントで順位が動く）。
   - ローカル確認は `python3 -m http.server` 経由で。公開時は静的ホスティングの URL で。

## 5. アプリ本体（index.html）への配線 ← ✅ 完了済み
`index.html` に共有バックエンドを配線済みです。**演出（正本）は一切変更していません。**
`config.js` が未設定（`YOUR-PROJECT` のまま）なら、これまで通り**オフラインで演出が動く**ようになっており、
`config.js` に実値を入れた瞬間だけ共有機能が有効になります。

配線した内容：
- 参加者登録（なまえ＋認識番号=端末の4桁ID）→ `participants` に upsert（なまえを入れると登録）
- ポイント獲得（QR/クエスト）→ `add_points(認識番号, なまえ, 増分)` で**差分だけ**加算（二重加算しない）
- ガチャ当選 → `claim_prize(認識番号, レアリティ)` で在庫を**アトミック減算**。売切れ時は `null` ＝**ハズレ演出**
- 各端末に **🏆 ランキング閲覧**セクションを追加（自分の順位をハイライト・自動更新）
- 起動時にサーバー在庫を各端末の当選確率へ同期（在庫が減ると当たりにくくなる／0個は出ない）
- 通信が切れた時は演出を止めないよう、ローカル付与にフォールバック

**あなたがやること（キーは私に渡さなくてOK）：**
1. 上の 1〜3 で Supabase を作成し `supabase_schema.sql` を Run。
2. `config.js` の2か所（URL / anon public キー）を自分で貼り替えて保存。
3. フォルダごと無料ホスティングへ公開 → `index.html` を開くと共有機能ON、`honbu.html` が本部モニター。

※ 景品テーブルには絵文字・種類の列が無いため、当選景品の絵文字/種類は**レア度から自動補完**します
（青🎁=イベント賞／緑🎀=イベント賞／赤🎫=地域協賛賞／虹🌈=特賞）。景品名はサーバーの登録名をそのまま表示します。
※ anon キーは「公開用キー」なので config.js に埋め込んで問題ありません（書き込みは関数経由＝RLSで保護）。

## 6. 景品の在庫を変える（任意）
初期在庫は `supabase_schema.sql` の最後の `insert` で入ります。数量や景品を変えたい時は
Supabase の **Table Editor → prizes** で `name/rarity/stock/initial_stock/sort` を直接編集（在庫を戻す時は `stock` を `initial_stock` に）。
本部モニターは変更を**リアルタイム反映**します。
