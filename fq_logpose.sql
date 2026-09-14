-- ============================================================
-- fq-logpose-v1 — ログポース（2026-09-14）
--
-- 会場の8か所を、参加者ごとに「ちがう順番」で回らせる仕掛け。
-- アプリには常に「つぎに行く1か所」だけが出る。
-- そこのQRを読むと、次の行き先が出る。ぜんぶ回るとゴール。
--
-- ★人によって順番が違う ＝ 参加者が会場中にばらける。
--   全員が同じ順番だと1か所に行列ができて他が閑散とする。
--   順番をバラすだけで、運営が何もしなくても分散する。
--
-- ★1人で完結する。人に話しかけられない子も詰まらない。
--
-- ★ルートは保存しない。
--   「まだ読んでいないスポットのうち、その人の順番で次の1つ」を毎回計算する。
--   順番は md5(認識番号 || スポット名) で決まるので、人ごとに違い、毎回同じ。
--   → 当日スポットを増やしても既存の人が壊れない。
--   → 自由に読んだQRも「訪問済み」になるので、同じ場所に戻されない。
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。別プロジェクトです。
-- 【いつ流すか】fq_zukan.sql を流したあと
-- 【消すもの】ありません。zukan_scan は作り直しますが、引数も戻り値の形も同じです
-- ============================================================


-- ------------------------------------------------------------
-- 1. スポット（＝QRを置く場所）
--    ★ヒントも場所の名前も、当日この表を直せば即反映される。
--      本部モニター（honbu.html?admin=1）から画面で編集できる。
-- ------------------------------------------------------------
create table if not exists logpose_spots (
  spot     text primary key,                    -- ?z= の値と同じ（例 iriguchi）
  ord      smallint not null default 0,         -- 画面に出す番号（①〜⑧）
  name     text not null default '',            -- 場所の名前（例 キッチンカー）
  hint     text not null default '',            -- なぞなぞ（例 いいにおいがするところ）
  enabled  boolean not null default true,
  updated_at timestamptz not null default now()
);

-- ゴールした人（本部モニターの「ゴール ◯人」に使う）
create table if not exists logpose_goal (
  recog_no text primary key,
  done_at  timestamptz not null default now()
);

-- ゴール報酬のキャラ番号。★この子は普通のスキャンでは絶対に出ない。
insert into zukan_config (key, value) values ('goal_char', 31)
on conflict (key) do nothing;

-- 仮のスポット8か所（名前もヒストも当日に書き換える前提）
insert into logpose_spots (spot, ord, name, hint) values
  ('iriguchi', 1, '入口',          'すべてが はじまる ところ'),
  ('hall',     2, 'ホール',        'いちばん おおきな こえが きこえる ところ'),
  ('cafe',     3, 'カフェ',        'あたたかい のみものの におい'),
  ('kitchen',  4, 'キッチンカー',  'おなかが なりそうな ところ'),
  ('booth_a',  5, 'Aブース',       'はたらく ひとの はなしが きける ところ'),
  ('booth_b',  6, 'Bブース',       'てで さわって ためせる ところ'),
  ('shindan',  7, '適性診断ブース','じぶんの ことが わかる ところ'),
  ('stage',    8, 'ステージ',      'おんがくが きこえてくる ほう')
on conflict (spot) do nothing;


-- ------------------------------------------------------------
-- 2. いまの状態（アプリが起動時と読み取りのたびに呼ぶ）
--    返り値: {ok, total, visited, done, next:{spot,ord,name,hint}}
-- ------------------------------------------------------------
create or replace function logpose_state(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_total   int;
  v_visited int;
  v_next    logpose_spots;
  v_done    boolean;
begin
  select count(*) into v_total from logpose_spots where enabled;
  if p_recog is null or length(btrim(p_recog)) = 0 or v_total = 0 then
    return json_build_object('ok', true, 'total', coalesce(v_total,0),
                             'visited', 0, 'done', false, 'next', null);
  end if;

  select count(*) into v_visited
    from logpose_spots s
   where s.enabled
     and exists (select 1 from zukan_scans z
                  where z.recog_no = p_recog and z.spot = s.spot);

  v_done := (v_visited >= v_total);

  if not v_done then
    -- ★その人だけの順番。md5 なので人ごとに違い、何度呼んでも同じ。
    select s.* into v_next
      from logpose_spots s
     where s.enabled
       and not exists (select 1 from zukan_scans z
                        where z.recog_no = p_recog and z.spot = s.spot)
     order by md5(p_recog || '#' || s.spot)
     limit 1;
  end if;

  return json_build_object(
    'ok', true, 'total', v_total, 'visited', v_visited, 'done', v_done,
    'next', case when v_next.spot is null then null else
      json_build_object('spot', v_next.spot, 'ord', v_next.ord,
                        'name', v_next.name, 'hint', v_next.hint) end
  );
end; $$;


-- ------------------------------------------------------------
-- 3. QRを読んだとき（fq_zukan.sql の zukan_scan を作り直す）
--    ★引数も戻り値の形も同じ。ログポースの項目が増えるだけ。
--    ★変えたのは3点:
--       ・ゴール報酬のキャラは、普通のスキャンでは出さない
--       ・5分待ちでも「その場所に居た」ことは記録する（ルートは進む）
--       ・ぜんぶ回ったらゴール報酬を渡す
-- ------------------------------------------------------------
create or replace function zukan_scan(p_recog text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_cool int; v_total int; v_goal int;
  v_last timestamptz; v_wait int;
  v_char int; v_rows int; v_new boolean; v_owned int;
  v_lp json; v_just_goal boolean := false;
  v_lp_total int; v_lp_visited int;
begin
  if p_recog is null or length(btrim(p_recog)) = 0 then
    return json_build_object('ok', false, 'reason', 'no_recog');
  end if;
  if p_spot is null or length(btrim(p_spot)) = 0 then
    return json_build_object('ok', false, 'reason', 'no_spot');
  end if;

  select value into v_cool  from zukan_config where key = 'cooldown_sec';
  select value into v_total from zukan_config where key = 'char_count';
  select value into v_goal  from zukan_config where key = 'goal_char';
  v_cool  := coalesce(v_cool, 300);
  v_total := coalesce(v_total, 72);
  v_goal  := coalesce(v_goal, 0);

  select scanned_at into v_last
    from zukan_scans where recog_no = p_recog and spot = p_spot;

  -- ★5分待ちでも「来た」ことは記録する。ルートが進まないと詰むため。
  insert into zukan_scans (recog_no, spot, scanned_at, hits)
       values (p_recog, p_spot, coalesce(v_last, now()), 1)
  on conflict (recog_no, spot) do update
     set hits = zukan_scans.hits + 1,
         scanned_at = case when v_last is null
                            or now() >= v_last + make_interval(secs => v_cool)
                           then now() else zukan_scans.scanned_at end;

  -- ゴール判定（ぜんぶ回ったら報酬の子を渡す）
  select count(*) into v_lp_total from logpose_spots where enabled;
  if v_lp_total > 0 then
    select count(*) into v_lp_visited
      from logpose_spots s
     where s.enabled
       and exists (select 1 from zukan_scans z
                    where z.recog_no = p_recog and z.spot = s.spot);
    if v_lp_visited >= v_lp_total and v_goal > 0 then
      insert into logpose_goal (recog_no) values (p_recog)
      on conflict (recog_no) do nothing;
      get diagnostics v_rows = row_count;
      if v_rows > 0 then
        insert into zukan_owned (recog_no, char_id) values (p_recog, v_goal)
        on conflict (recog_no, char_id) do nothing;
        v_just_goal := true;
      end if;
    end if;
  end if;

  v_lp := logpose_state(p_recog);

  -- まだ5分たっていない → キャラは渡さない（ルートは上で進んでいる）
  if v_last is not null and now() < v_last + make_interval(secs => v_cool) then
    v_wait := ceil(extract(epoch from (v_last + make_interval(secs => v_cool)) - now()))::int;
    select count(*) into v_owned from zukan_owned where recog_no = p_recog;
    return json_build_object('ok', false, 'reason', 'cooldown', 'wait', v_wait,
                             'owned', v_owned, 'total', v_total,
                             'logpose', v_lp, 'just_goal', v_just_goal);
  end if;

  -- ★まだ持っていない子から選ぶ。ゴール報酬の子は普通のスキャンでは出さない。
  select g.n into v_char
    from generate_series(1, v_total) as g(n)
   where g.n <> v_goal
     and not exists (select 1 from zukan_owned o
                      where o.recog_no = p_recog and o.char_id = g.n)
   order by random()
   limit 1;

  if v_char is null then
    select g.n into v_char from generate_series(1, v_total) as g(n)
     where g.n <> v_goal order by random() limit 1;
    v_new := false;
  else
    insert into zukan_owned (recog_no, char_id) values (p_recog, v_char)
    on conflict (recog_no, char_id) do nothing;
    get diagnostics v_rows = row_count;
    v_new := (v_rows > 0);
  end if;

  select count(*) into v_owned from zukan_owned where recog_no = p_recog;

  return json_build_object('ok', true, 'char', v_char, 'is_new', v_new,
                           'owned', v_owned, 'total', v_total,
                           'logpose', v_lp, 'just_goal', v_just_goal,
                           'goal_char', v_goal);
end; $$;


-- ------------------------------------------------------------
-- 4. 本部の画面からヒントを編集する（合言葉つき）
--    ★合言葉は大会リセットと同じ fq_admin.reset_pass を使う。
--      現場で触るのは主催者だけ、という前提。
-- ------------------------------------------------------------
create or replace function logpose_admin_list(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean; v json;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  select coalesce(json_agg(row_to_json(t) order by t.ord, t.spot), '[]'::json) into v
    from (select spot, ord, name, hint, enabled from logpose_spots) t;
  return json_build_object('ok', true, 'spots', v,
    'goal_char', (select value from zukan_config where key = 'goal_char'),
    'goal_count', (select count(*) from logpose_goal));
end; $$;

create or replace function logpose_admin_save(
  p_pass text, p_spot text, p_ord int, p_name text, p_hint text, p_enabled boolean)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  if p_spot is null or length(btrim(p_spot)) = 0 then
    return json_build_object('ok', false, 'message', '場所の記号（?z= の値）が空です');
  end if;
  insert into logpose_spots (spot, ord, name, hint, enabled, updated_at)
       values (btrim(p_spot), coalesce(p_ord,0), coalesce(p_name,''),
               coalesce(p_hint,''), coalesce(p_enabled,true), now())
  on conflict (spot) do update
     set ord = excluded.ord, name = excluded.name, hint = excluded.hint,
         enabled = excluded.enabled, updated_at = now();
  return json_build_object('ok', true);
end; $$;

create or replace function logpose_admin_delete(p_pass text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  delete from logpose_spots where spot = p_spot;
  return json_build_object('ok', true);
end; $$;


-- ------------------------------------------------------------
-- 5. 権限
-- ------------------------------------------------------------
alter table logpose_spots enable row level security;
alter table logpose_goal  enable row level security;
-- ★ポリシーは作らない。匿名からテーブルを直接は触れない。関数ごしだけ。

revoke all on function logpose_state(text)        from public;
revoke all on function logpose_admin_list(text)   from public;
revoke all on function logpose_admin_save(text,text,int,text,text,boolean) from public;
revoke all on function logpose_admin_delete(text,text) from public;
grant execute on function logpose_state(text)      to anon, authenticated;
grant execute on function logpose_admin_list(text) to anon, authenticated;
grant execute on function logpose_admin_save(text,text,int,text,text,boolean) to anon, authenticated;
grant execute on function logpose_admin_delete(text,text) to anon, authenticated;


-- ------------------------------------------------------------
-- 6. 大会リセットにログポースも含める
--    ★where true を外さないこと（Supabase の安全装置に弾かれる）
-- ------------------------------------------------------------
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean; np integer; nd integer; nz integer; ng integer;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;

  select count(*) into np from participants;
  select count(*) into nd from draws;
  select count(*) into nz from zukan_owned;
  select count(*) into ng from logpose_goal;

  delete from draws where true;
  delete from participants where true;
  delete from zukan_owned where true;
  delete from zukan_scans where true;
  delete from logpose_goal where true;     -- fq-logpose-v1
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;
  -- ★logpose_spots（ヒントの設定）は消さない。設定なので残す。

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset (図鑑 ' || nz || ' / ゴール ' || ng || ' も削除)');

  return json_build_object('ok', true, 'participants', np, 'draws', nd,
                           'zukan', nz, 'goal', ng);
end; $$;

revoke all on function fq_reset(text) from public;
grant execute on function fq_reset(text) to anon, authenticated;


-- ============================================================
-- 確認用
-- ============================================================
-- select spot, ord, name, hint, enabled from logpose_spots order by ord;
-- select count(*) as ゴールした人 from logpose_goal;
-- select value as ゴール報酬のキャラ番号 from zukan_config where key='goal_char';
--
-- ゴール報酬の子を変えたいとき（例：50番にする）
-- update zukan_config set value = 50 where key = 'goal_char';
--
-- スポットを一時的に止めたいとき（そこのQRが壊れた等）
-- update logpose_spots set enabled = false where spot = 'cafe';
