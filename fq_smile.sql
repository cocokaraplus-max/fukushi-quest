-- ============================================================
-- FUKUSHI QUEST — 笑顔コンテスト（fq-smile-v1）
--
-- 決めたこと（2026-10-17 HIROさん）：
--   ・1人1票。登録したなまえと番号（participants.recog_no）で数える
--   ・途中経過は最後まで見せない（参加者側には票数を一切返さない）
--   ・投票は当日、会場でやってもらう
--   ・同じ票数のときは同率で表示する（1位を決めるのは現場）
--
-- 使い方：福祉クエストの Supabase → SQL Editor → 全部貼って Run。
--         2回以上 Run しても壊れません。
-- ★先に fq_voucher.sql と fq_grand.sql が流れている前提です。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 入れもの
-- ------------------------------------------------------------

-- 笑顔の写真
create table if not exists fq_smiles (
  id         bigint generated always as identity primary key,
  no         integer not null unique,          -- 会場で読み上げる番号
  title      text    not null default '',      -- 写真につける一言（本名は入れない運用）
  img_url    text    not null default '',      -- img/smile/01.jpg のような相対パスでも可
  active     boolean not null default true,    -- false にすると投票の一覧から消える
  sort       integer not null default 0,
  created_at timestamptz not null default now()
);
alter table fq_smiles enable row level security;        -- ポリシーは作らない（関数からだけ触る）

-- 投票。recog_no を主キーにすることで「1人1票」がデータの形で保証される
create table if not exists fq_smile_votes (
  recog_no  text   primary key,
  smile_id  bigint not null references fq_smiles(id) on delete cascade,
  voted_at  timestamptz not null default now()
);
alter table fq_smile_votes enable row level security;
create index if not exists fq_smile_votes_smile_idx on fq_smile_votes (smile_id);

-- 受付の開け閉め。既定は 0（締切）＝当日まで誤って投票されない
insert into fq_settings (key, value) values ('smile_open', 0)
  on conflict (key) do nothing;


-- ------------------------------------------------------------
-- 2. アプリ（参加者）から呼ぶ関数
--    ★票数は絶対に返さない。ここが「途中経過を見せない」の肝。
-- ------------------------------------------------------------

-- 写真の一覧と、自分がどれに入れたか
create or replace function fq_smile_list(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_mine bigint;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select smile_id into v_mine from fq_smile_votes where recog_no = p_recog;
  return json_build_object(
    'ok', true,
    'open', (fq_setting('smile_open', 0) = 1),
    'mine', v_mine,                                   -- まだなら null
    'photos', coalesce((select json_agg(json_build_object(
                          'id', s.id, 'no', s.no, 'title', s.title, 'img', s.img_url)
                          order by s.sort, s.no)
                        from fq_smiles s where s.active), '[]'::json));
end; $$;

-- 投票する（押しまちがえても、締切までなら入れ直せる）
create or replace function fq_smile_vote(p_recog text, p_secret text, p_id bigint)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'message', 'もう一度おためしください');
  end if;
  if fq_setting('smile_open', 0) <> 1 then
    return json_build_object('ok', false, 'message', 'いまは投票を受け付けていません');
  end if;
  if not exists (select 1 from fq_smiles where id = p_id and active) then
    return json_build_object('ok', false, 'message', 'その写真は見つかりませんでした');
  end if;
  -- なまえを登録していない人は投票できない（1人1票を人で数えるため）
  if not exists (select 1 from participants where recog_no = p_recog) then
    return json_build_object('ok', false, 'message', 'さきに なまえの登録をしてください');
  end if;

  insert into fq_smile_votes (recog_no, smile_id) values (p_recog, p_id)
    on conflict (recog_no) do update set smile_id = excluded.smile_id, voted_at = now();

  return json_build_object('ok', true, 'mine', p_id);
end; $$;


-- ------------------------------------------------------------
-- 3. 本部から呼ぶ関数（合言葉が要る）
-- ------------------------------------------------------------

-- 集計。同じ票数は同じ順位になる（1位が2人なら2人とも rank=1）
create or replace function fq_admin_smile_list(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  return json_build_object(
    'ok', true,
    'open', (fq_setting('smile_open', 0) = 1),
    'total_votes', (select count(*) from fq_smile_votes),
    'voters',      (select count(distinct recog_no) from fq_smile_votes),
    'rows', coalesce((
      select json_agg(json_build_object(
               'id', t.id, 'no', t.no, 'title', t.title, 'img', t.img_url,
               'active', t.active, 'votes', t.votes, 'rank', t.rnk,
               'tie', t.tie)                              -- 同じ順位が他にもいるか
             order by t.rnk, t.no)
      from (
        select s.id, s.no, s.title, s.img_url, s.active,
               count(v.recog_no)::int as votes,
               rank() over (order by count(v.recog_no) desc)::int as rnk,
               (count(*) over (partition by count(v.recog_no)) > 1) as tie
          from fq_smiles s
          left join fq_smile_votes v on v.smile_id = s.id
         group by s.id, s.no, s.title, s.img_url, s.active
      ) t), '[]'::json));
end; $$;

-- 写真の登録・書きかえ（p_id が null なら新規）
create or replace function fq_admin_smile_save(p_pass text, p_id bigint, p_no integer,
                                               p_title text, p_img text, p_active boolean, p_sort integer)
returns json
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  if p_no is null or p_no < 1 then
    return json_build_object('ok', false, 'message', '番号を入れてください');
  end if;
  if exists (select 1 from fq_smiles where no = p_no and (p_id is null or id <> p_id)) then
    return json_build_object('ok', false, 'message', 'その番号はもう使われています');
  end if;

  if p_id is null then
    insert into fq_smiles (no, title, img_url, active, sort)
         values (p_no, left(coalesce(p_title,''), 60), coalesce(p_img,''),
                 coalesce(p_active, true), coalesce(p_sort, p_no))
      returning id into v_id;
  else
    update fq_smiles
       set no = p_no, title = left(coalesce(p_title,''), 60), img_url = coalesce(p_img,''),
           active = coalesce(p_active, true), sort = coalesce(p_sort, p_no)
     where id = p_id
    returning id into v_id;
    if v_id is null then return json_build_object('ok', false, 'message', 'その写真は見つかりませんでした'); end if;
  end if;
  return json_build_object('ok', true, 'id', v_id);
end; $$;

-- 写真を消す（入っていた票も一緒に消えます）
create or replace function fq_admin_smile_delete(p_pass text, p_id bigint)
returns json
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  select count(*) into n from fq_smile_votes where smile_id = p_id;
  delete from fq_smiles where id = p_id;
  if not found then return json_build_object('ok', false, 'message', 'その写真は見つかりませんでした'); end if;
  return json_build_object('ok', true, 'votes_deleted', n);
end; $$;

-- 投票の受付を開ける／締め切る
create or replace function fq_admin_smile_open(p_pass text, p_open boolean)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  insert into fq_settings (key, value) values ('smile_open', case when p_open then 1 else 0 end)
    on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true, 'open', p_open);
end; $$;


-- ------------------------------------------------------------
-- 4. 大会リセットに投票も含める（fq_grand.sql の版に1行足したもの）
--    ★写真そのもの（fq_smiles）は消しません。消したいときは本部の画面から。
-- ------------------------------------------------------------
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean; np integer; nd integer; nz integer; ng integer; nv integer; ns integer;
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
  select count(*) into nv from fq_vouchers;
  select count(*) into ns from fq_smile_votes;      -- fq-smile-v1

  delete from draws where true;
  delete from participants where true;
  delete from zukan_owned where true;
  delete from zukan_scans where true;
  delete from logpose_goal where true;     -- fq-logpose-v1
  delete from fq_vouchers where true;      -- fq-voucher-v1
  delete from fq_draw_log where true;
  delete from fq_earned where true;
  delete from fq_devices where true;
  delete from fq_grand_winners where true; -- fq-grand-v1
  delete from fq_smile_votes where true;   -- fq-smile-v1（写真は残す）
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;
  update fq_shops set pin_fails = 0, locked_until = null where pin_fails <> 0 or locked_until is not null;

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset (図鑑 ' || nz || ' / ゴール ' || ng || ' / 引換券 ' || nv
                    || ' / 大抽選会 / 笑顔の投票 ' || ns || ' も削除)');

  return json_build_object('ok', true, 'participants', np, 'draws', nd,
                           'zukan', nz, 'goal', ng, 'vouchers', nv, 'smile_votes', ns);
end; $$;


-- ------------------------------------------------------------
-- 5. 呼べるようにする
-- ------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['fq_smile_list(text,text)', 'fq_smile_vote(text,text,bigint)',
                           'fq_admin_smile_list(text)',
                           'fq_admin_smile_save(text,bigint,integer,text,text,boolean,integer)',
                           'fq_admin_smile_delete(text,bigint)', 'fq_admin_smile_open(text,boolean)',
                           'fq_reset(text)']
  loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

-- 確認用（流したあとに出ます）
select '笑顔コンテスト fq-smile-v1 を入れました。いまの受付：'
       || case when fq_setting('smile_open', 0) = 1 then '受付中' else '締切（本部から開けてください）' end as result;
