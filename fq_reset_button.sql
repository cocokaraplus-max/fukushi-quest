-- ============================================================
-- fq-reset-button-v1 — 本部の画面からボタン一つで大会をリセットする
--
-- ★これは Supabase の SQL Editor に貼って Run します。1回だけでOK。
-- ★★下の「ここに合言葉」を、自分で決めた合言葉に必ず書き換えてから Run すること。
--   ・意味のある単語にしないこと。20文字くらいの、意味のない文字列にする
--   ・この合言葉は誰にも見せない（AIにも渡さない）
--   ・合言葉は Supabase の中だけに保存され、アプリの画面からは読めません
--     （fq_admin は行レベルセキュリティを有効にし、読み取りの許可を1つも作らない）
--
-- リセットするもの:
--   draws（抽選の履歴）を全部消す
--   participants（参加者）を全部消す
--   recog_seq（認識番号の連番）を1に戻す
--   prizes の残数を initial_stock（最初の数）に戻す
-- ============================================================


-- ① 合言葉を入れる箱 ------------------------------------------------
create table if not exists fq_admin (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table fq_admin enable row level security;
-- ★ポリシーを1つも作らない = 匿名（アプリ）からは1行も読めない。
--   合言葉が外に出ないのはこのため。ここに select のポリシーを足さないこと。


-- ② 合言葉を設定する ------------------------------------------------
-- ★★ここだけ書き換えてください ★★
insert into fq_admin (key, value) values ('reset_pass', 'ここに合言葉')
on conflict (key) do update set value = excluded.value, updated_at = now();


-- ③ リセットした記録を残す箱 ----------------------------------------
create table if not exists fq_reset_log (
  id                   bigint generated always as identity primary key,
  at                   timestamptz not null default now(),
  participants_deleted integer,
  draws_deleted        integer,
  note                 text
);
alter table fq_reset_log enable row level security;
-- こちらも匿名からは読めない（記録は Supabase の画面で見る）


-- ④ いまの件数を返す（合言葉なしで呼べる。数だけで、中身は出ない） --
create or replace function fq_stats()
returns json
language sql security definer set search_path = public as $$
  select json_build_object(
    'participants', (select count(*) from participants),
    'draws',        (select count(*) from draws),
    'points_total', (select coalesce(sum(points), 0) from participants),
    'next_recog',   (select last_value from recog_seq),
    'prizes_used',  (select count(*) from prizes where stock < initial_stock)
  );
$$;
grant execute on function fq_stats() to anon, authenticated;


-- ⑤ リセット本体 ----------------------------------------------------
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  ok boolean;
  np integer;
  nd integer;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    -- ★総当たりを遅くするために、わざと1秒待ってから返す
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;

  select count(*) into np from participants;
  select count(*) into nd from draws;

  -- ★where を外さないこと。Supabase には「うっかり全消し」を防ぐ安全装置(safeupdate)があり、
  --   where の付いていない delete / update は拒否される（2026-08-26 に実際に弾かれた）。
  delete from draws where true;
  delete from participants where true;
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset');

  return json_build_object('ok', true, 'participants', np, 'draws', nd);
end; $$;

revoke all on function fq_reset(text) from public;
grant execute on function fq_reset(text) to anon, authenticated;


-- ============================================================
-- 確認用（Run したあとに、これだけ流すと状態が見えます）
-- ============================================================
-- select fq_stats();
--
-- 合言葉が効いているかの確認（わざと違う言葉で呼ぶ。1秒待たされて false が返ればOK）
-- select fq_reset('ちがう合言葉');
--
-- 過去にリセットした記録
-- select * from fq_reset_log order by at desc;
