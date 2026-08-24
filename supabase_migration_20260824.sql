-- ============================================================
-- FUKUSHI QUEST 326 — 追加SQL（2026-08-24 / 1500人規模むけ）
--
-- ★すでに supabase_schema.sql を Run 済みのプロジェクトに、
--   「あとから足す」ためのファイルです。既存のデータは消えません。
--
-- 使い方：Supabase の SQL Editor → New query → この中身を全部貼って Run。
--         2回以上 Run しても壊れません。
--
-- 入るもの：
--   1) 認識番号の連番発行（issue_recog）… かぶりをゼロにする
--   2) ガチャ回数の上限（1端末3回）をサーバー側で固定
--   3) ランキングの並べ替えを速くする索引
-- ============================================================


-- ============================================================
-- 1) 認識番号を「連番」で発行する
--    これまで：端末が 1000〜9999 の乱数を自分で決めていた（9000通り）
--    → 1500人だと、ほぼ確実に何組もかぶる（同じ番号＝データが混ざる）
--    これから：サーバーが 0001, 0002, 0003 … と順番に配る（かぶりゼロ）
-- ============================================================

create sequence if not exists recog_seq start 1;

create or replace function issue_recog()
returns text
language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  n := nextval('recog_seq');
  -- 4桁ゼロ埋め。10000人を超えたら自動で5桁になる（頭打ちしない）
  return lpad(n::text, 4, '0');
end; $$;

grant execute on function issue_recog() to anon, authenticated;
grant usage, select on sequence recog_seq to anon, authenticated;

-- ※ここでは participants に行を作りません。
--   「開いただけの人」を本部ランキングに出さないためです。
--   行は、なまえを入れるか最初のポイントが入った時点で作られます。


-- ============================================================
-- 2) ガチャ回数の上限をサーバー側で固定する（1端末 3回）
--
--    アプリの回数制限は端末の localStorage なので、
--    詳しい人なら書き換えて何度でも引けてしまう＝景品在庫が抜ける。
--    draws（履歴）の件数で数えて、4回目以降は必ず「ハズレ」を返す。
--
--    ★回数を変えたい時は、下の MAX_DRAWS の数字だけ変えて再度 Run。
-- ============================================================

create or replace function claim_prize(p_recog text, p_rarity integer)
returns prizes
language plpgsql security definer set search_path = public as $$
declare
  won   prizes;
  used  integer;
  MAX_DRAWS constant integer := 3;   -- ★1端末あたりのガチャ回数
begin
  -- すでに何回引いたか（当たり・ハズレの両方が draws に入っている）
  select count(*) into used from draws where recog_no = p_recog;
  if used >= MAX_DRAWS then
    return null;                      -- 上限超過 → アプリ側はハズレ演出になる
  end if;

  update prizes
     set stock = stock - 1
   where id = (
     select id from prizes
      where rarity = p_rarity and stock > 0
      order by sort asc, created_at asc
      for update skip locked
      limit 1
   )
  returning * into won;

  if won.id is null then
    insert into draws (recog_no, rarity, is_win) values (p_recog, p_rarity, false);
    return null;
  end if;

  insert into draws (recog_no, rarity, is_win, prize_id, prize_name)
    values (p_recog, p_rarity, true, won.id, won.name);
  return won;
end; $$;

grant execute on function claim_prize(text,integer) to anon, authenticated;

-- 回数チェックを速くする索引（1500人×3回でも一瞬で返る）
create index if not exists draws_recog_idx on draws (recog_no);


-- ============================================================
-- 3) ランキングの索引
--    参加者端末は「上位20人」と「自分の1行」しか取らなくなったので、
--    並べ替えが速いほど軽い。
-- ============================================================

create index if not exists participants_points_idx
  on participants (points desc, updated_at asc);


-- ============================================================
-- 確認用（Run したあとに、別のクエリで実行して確かめられます）
-- ============================================================
-- select issue_recog();                  -- → '0001' のような番号が返る
-- select currval('recog_seq');           -- → いま何番まで配ったか
-- select count(*) from participants;     -- → 参加者の人数
-- select recog_no, count(*) from draws group by 1 order by 2 desc limit 5;
--                                        -- → 1端末3回を超えている人がいないか
--
-- ★イベントをやり直す（テストの後片付け）
--   alter sequence recog_seq restart with 1;
--   delete from draws;
--   delete from participants;
--   update prizes set stock = initial_stock;
