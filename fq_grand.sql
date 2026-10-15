-- ============================================================
-- FUKUSHI QUEST — 大抽選会（fq-grand-v1）
--
-- 決めたこと（2026-10-15 HIROさん）：大抽選会の対象は「ガチャを1回でもまわした人」
--   ・本部モニター（honbu.html?admin=1）の「大抽選会」で、ボタンを押すと対象者から1人をサーバーが選ぶ
--   ・同じ人は2回当たらない。「その場にいない」にした人も、もう選ばれない
--   ・参加者のアプリには、ガチャを1回まわすと「大抽選会の対象です」と出る
--
-- 使い方：福祉クエストの Supabase → SQL Editor → 全部貼って Run。2回以上 Run しても壊れません。
-- ★先に fq_voucher.sql が流れている前提です。合言葉は fq_admin の reset_pass を使います。
-- ============================================================

create table if not exists fq_grand_winners (
  id         bigint generated always as identity primary key,
  recog_no   text not null unique,
  nickname   text not null default '',
  label      text not null default '',      -- 何の賞か（例 特賞・1等）
  status     text not null default 'won' check (status in ('won','absent')),
  drawn_at   timestamptz not null default now()
);
alter table fq_grand_winners enable row level security;   -- ポリシーは作らない（関数からだけ触る）

-- 対象かどうか（中で使う）
create or replace function fq_grand_eligible(p_recog text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from fq_draw_log where recog_no = p_recog);
$$;
revoke all on function fq_grand_eligible(text) from public, anon, authenticated;

-- いまの状態（fq_voucher.sql の fq_state に「大抽選会の対象か」を足す）
create or replace function fq_state(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  return json_build_object(
    'ok', true,
    'balance', fq_balance(p_recog),
    'earned_total', fq_earned_total(p_recog),
    'cost', fq_setting('draw_cost', 1),
    'grand', fq_grand_eligible(p_recog),            -- fq-grand-v1
    'bases', coalesce((select json_agg(c.base order by c.sort) from fq_earned e join fq_codes c on c.code = e.code
                        where e.recog_no = p_recog), '[]'::json),
    'vouchers', coalesce((select json_agg(fq_voucher_json(v) order by v.issued_at desc) from fq_vouchers v
                           where v.recog_no = p_recog), '[]'::json));
end; $$;

-- 本部：対象者の数と、これまでの当選者
create or replace function fq_admin_grand_list(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  return json_build_object(
    'ok', true,
    'eligible', (select count(distinct recog_no) from fq_draw_log),
    'remaining', (select count(distinct d.recog_no) from fq_draw_log d
                   where not exists (select 1 from fq_grand_winners w where w.recog_no = d.recog_no)),
    'winners', coalesce((select json_agg(json_build_object('id', w.id, 'recog_no', w.recog_no, 'nickname', w.nickname,
                         'label', w.label, 'status', w.status, 'drawn_at', w.drawn_at) order by w.id desc)
                         from fq_grand_winners w), '[]'::json));
end; $$;

-- 本部：1人選ぶ（ガチャを1回でもまわした人のうち、まだ選ばれていない人から）
create or replace function fq_admin_grand_draw(p_pass text, p_label text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_recog text; v_nick text; w fq_grand_winners;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  perform pg_advisory_xact_lock(hashtext('fq_grand_draw'));      -- 2台で同時に押しても1人ずつ
  select d.recog_no into v_recog
    from (select distinct recog_no from fq_draw_log) d
   where not exists (select 1 from fq_grand_winners g where g.recog_no = d.recog_no)
   order by random() limit 1;
  if v_recog is null then
    return json_build_object('ok', false, 'message', '選べる人がもういません');
  end if;
  select coalesce(nickname, '') into v_nick from participants where recog_no = v_recog;
  insert into fq_grand_winners (recog_no, nickname, label)
       values (v_recog, coalesce(v_nick, ''), left(coalesce(p_label, ''), 40))
  returning * into w;
  return json_build_object('ok', true, 'id', w.id, 'recog_no', w.recog_no, 'nickname', w.nickname, 'label', w.label);
end; $$;

-- 本部：その場にいなかった（もう選ばれない）／やっぱりいた、を切り替える
create or replace function fq_admin_grand_mark(p_pass text, p_id bigint, p_status text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if p_status not in ('won','absent') then return json_build_object('ok', false, 'message', '状態が違います'); end if;
  update fq_grand_winners set status = p_status where id = p_id;
  return json_build_object('ok', found);
end; $$;

-- 大会リセットに大抽選会の当選者も含める（fq_voucher.sql の版に1行足したもの）
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean; np integer; nd integer; nz integer; ng integer; nv integer;
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
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;
  update fq_shops set pin_fails = 0, locked_until = null where pin_fails <> 0 or locked_until is not null;

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset (図鑑 ' || nz || ' / ゴール ' || ng || ' / 引換券 ' || nv || ' / 大抽選会 も削除)');

  return json_build_object('ok', true, 'participants', np, 'draws', nd,
                           'zukan', nz, 'goal', ng, 'vouchers', nv);
end; $$;

do $$
declare f text;
begin
  foreach f in array array['fq_state(text,text)', 'fq_admin_grand_list(text)', 'fq_admin_grand_draw(text,text)',
                           'fq_admin_grand_mark(text,bigint,text)', 'fq_reset(text)']
  loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
