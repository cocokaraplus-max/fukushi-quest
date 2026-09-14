-- ============================================================
-- fq-zukan-v1 — キャラクター図鑑（2026-09-14）
--
-- 会場のあちこちに置いたQRを読むと、326キャラが1体ずつ図鑑に増える。
-- ★同じQRは5分間は反応しない。別の場所のQRなら読める。
--   → 一か所に居座れない。歩かないと集まらない、というルール。
--
-- ★ポイントとは別勘定。participants にも draws にも触らない。
--   ランキングもガチャの解放条件も、これまでどおり。
--
-- ★5分の判定はサーバーでやる。端末の履歴を消しても回避できない。
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。別プロジェクトです。
-- 【いつ流すか】図鑑を公開する前に1回
-- 【消すもの】ありません。既存のデータには触れません
-- ============================================================


-- ------------------------------------------------------------
-- 1. 図鑑のテーブル
-- ------------------------------------------------------------

-- 誰が どのキャラを 持っているか
create table if not exists zukan_owned (
  recog_no text     not null,
  char_id  smallint not null,
  got_at   timestamptz not null default now(),
  primary key (recog_no, char_id)
);
create index if not exists zukan_owned_recog_idx on zukan_owned (recog_no);

-- 誰が どの場所を いつ読んだか（5分の判定に使う。1人1場所につき1行だけ）
create table if not exists zukan_scans (
  recog_no   text not null,
  spot       text not null,
  scanned_at timestamptz not null default now(),
  hits       integer not null default 1,
  primary key (recog_no, spot)
);

-- 設定（キャラの数とクールダウン秒数。あとから数字だけ変えられる）
create table if not exists zukan_config (
  key   text primary key,
  value integer not null
);
insert into zukan_config (key, value) values
  ('char_count',   72),   -- 図鑑のキャラ数
  ('cooldown_sec', 300)   -- 同じQRが再び読めるまでの秒数（300=5分）
on conflict (key) do nothing;


-- ------------------------------------------------------------
-- 2. QRを読んだとき
--    返り値: {ok, reason, char, is_new, owned, total, wait}
-- ------------------------------------------------------------
create or replace function zukan_scan(p_recog text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_cool int;
  v_total int;
  v_last timestamptz;
  v_wait int;
  v_char int;
  v_rows int;
  v_new boolean;
  v_owned int;
begin
  if p_recog is null or length(btrim(p_recog)) = 0 then
    return json_build_object('ok', false, 'reason', 'no_recog');
  end if;
  if p_spot is null or length(btrim(p_spot)) = 0 then
    return json_build_object('ok', false, 'reason', 'no_spot');
  end if;

  select value into v_cool  from zukan_config where key = 'cooldown_sec';
  select value into v_total from zukan_config where key = 'char_count';
  v_cool  := coalesce(v_cool, 300);
  v_total := coalesce(v_total, 72);

  -- 同じ場所を前に読んだのはいつか
  select scanned_at into v_last
    from zukan_scans
   where recog_no = p_recog and spot = p_spot;

  -- まだ5分たっていない
  if v_last is not null and now() < v_last + make_interval(secs => v_cool) then
    v_wait := ceil(extract(epoch from (v_last + make_interval(secs => v_cool)) - now()))::int;
    select count(*) into v_owned from zukan_owned where recog_no = p_recog;
    return json_build_object('ok', false, 'reason', 'cooldown',
                             'wait', v_wait, 'owned', v_owned, 'total', v_total);
  end if;

  -- ★まだ持っていないキャラから選ぶ。
  --   図鑑は「埋まっていく」のが気持ちいいので、ダブりは最後まで出さない。
  --   全部そろっている人だけ、ランダムで1体返す（記念）。
  select g.n into v_char
    from generate_series(1, v_total) as g(n)
   where not exists (
     select 1 from zukan_owned o
      where o.recog_no = p_recog and o.char_id = g.n
   )
   order by random()
   limit 1;

  if v_char is null then
    v_char := 1 + floor(random() * v_total)::int;
    v_new := false;
  else
    insert into zukan_owned (recog_no, char_id) values (p_recog, v_char)
    on conflict (recog_no, char_id) do nothing;
    get diagnostics v_rows = row_count;
    v_new := (v_rows > 0);
  end if;

  -- この場所の記録を更新
  insert into zukan_scans (recog_no, spot, scanned_at, hits)
       values (p_recog, p_spot, now(), 1)
  on conflict (recog_no, spot)
    do update set scanned_at = now(), hits = zukan_scans.hits + 1;

  select count(*) into v_owned from zukan_owned where recog_no = p_recog;

  return json_build_object('ok', true, 'char', v_char, 'is_new', v_new,
                           'owned', v_owned, 'total', v_total);
end; $$;


-- ------------------------------------------------------------
-- 3. 自分の図鑑を読む（起動時に1回）
--    返り値: {ok, chars:[番号...], owned, total}
-- ------------------------------------------------------------
create or replace function zukan_list(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_total int;
  v_chars int[];
begin
  select value into v_total from zukan_config where key = 'char_count';
  v_total := coalesce(v_total, 72);

  if p_recog is null or length(btrim(p_recog)) = 0 then
    return json_build_object('ok', true, 'chars', '[]'::json, 'owned', 0, 'total', v_total);
  end if;

  select coalesce(array_agg(char_id order by char_id), '{}') into v_chars
    from zukan_owned where recog_no = p_recog;

  return json_build_object('ok', true,
                           'chars', to_json(v_chars),
                           'owned', coalesce(array_length(v_chars, 1), 0),
                           'total', v_total);
end; $$;


-- ------------------------------------------------------------
-- 4. 権限（匿名は関数ごしにしか触れない）
-- ------------------------------------------------------------
alter table zukan_owned  enable row level security;
alter table zukan_scans  enable row level security;
alter table zukan_config enable row level security;
-- ★ポリシーは作らない。= 匿名からの直接の読み書きは一切できない。
--   アプリは下の2つの関数（security definer）だけを呼ぶ。

revoke all on function zukan_scan(text, text) from public;
revoke all on function zukan_list(text)       from public;
grant execute on function zukan_scan(text, text) to anon, authenticated;
grant execute on function zukan_list(text)       to anon, authenticated;


-- ------------------------------------------------------------
-- 5. 大会リセットに図鑑も含める
--    ★中身は fq_reset_fix.sql のまま。図鑑の2行だけ足した。
--    ★where true を外さないこと（Supabase の安全装置に弾かれる）
-- ------------------------------------------------------------
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  ok boolean;
  np integer;
  nd integer;
  nz integer;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    -- ★総当たりを遅くするために、わざと1秒待ってから返す
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;

  select count(*) into np from participants;
  select count(*) into nd from draws;
  select count(*) into nz from zukan_owned;

  -- ★where true を外さないこと。外すと Supabase の安全装置に弾かれる。
  delete from draws where true;
  delete from participants where true;
  delete from zukan_owned where true;   -- fq-zukan-v1
  delete from zukan_scans where true;   -- fq-zukan-v1
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset (図鑑 ' || nz || '件も削除)');

  return json_build_object('ok', true, 'participants', np, 'draws', nd, 'zukan', nz);
end; $$;

revoke all on function fq_reset(text) from public;
grant execute on function fq_reset(text) to anon, authenticated;


-- ============================================================
-- 確認用（Run したあとに流すと様子が見えます）
-- ============================================================
-- select * from zukan_config;
-- select count(*) as 所持記録, count(distinct recog_no) as 人数 from zukan_owned;
-- select spot, count(*) as 人数, sum(hits) as 読まれた回数
--   from zukan_scans group by spot order by 3 desc;   -- どの場所が人気か
-- select char_id, count(*) from zukan_owned group by 1 order by 2 desc limit 10;

-- クールダウンを変えたいとき（例：3分にする）
-- update zukan_config set value = 180 where key = 'cooldown_sec';

-- 図鑑だけリセットしたいとき
-- delete from zukan_owned where true;
-- delete from zukan_scans where true;
