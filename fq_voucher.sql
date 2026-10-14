-- ============================================================
-- FUKUSHI QUEST — 景品の引換券（fq-voucher-v1）
--
-- 何が変わるか（★景品が「地域のお店のサービス」＝本物になるので、不正をサーバーで止める）
--   1) 端末ごとに「秘密の鍵」を配る。認識番号と鍵がそろわないと、ポイントも抽選も券も動かない
--      （これまでは連番の認識番号だけで動いたので、他人の番号を名乗れた）
--   2) ポイントは、読んだQRの記録からサーバーが数える。QRのコードは推測できない文字列にする
--      （これまでは端末が「増えた分」を自己申告していた＝書き換えれば無限ポイント）
--   3) 抽選は、当たり外れ・景品・引換券の発行まで全部サーバーで決める。1回ごとにポイントを使う
--      （これまでは当たりの等級をアプリが決めてサーバーに伝えていた）
--   4) 当たったら引換券（推測できない番号＋QR）を発行。お店は QR を読んで、
--      自分で決めた暗証番号を入れて「使用済み」にする。使えるのは1回だけ
--   5) 古い add_points / claim_prize / issue_recog は、アプリから呼べなくする
--
-- 使い方：福祉クエストの Supabase → SQL Editor → New query → 全部貼って Run。
--         2回以上 Run しても壊れません（データは消えません）。
-- ★先に supabase_schema.sql ／ supabase_migration_20260824.sql ／ fq_reset_button.sql ／
--   fq_zukan.sql ／ fq_logpose.sql が流れている前提です。
-- ★合言葉は fq_admin の reset_pass（大会リセットと同じ）を使います。ここには書きません。
-- ============================================================

create extension if not exists pgcrypto with schema extensions;


-- ------------------------------------------------------------
-- 1. 表
-- ------------------------------------------------------------

-- 端末（認識番号と秘密の鍵）。鍵そのものは保存しない（ハッシュだけ）
create table if not exists fq_devices (
  recog_no    text primary key,
  secret_hash text not null,
  created_at  timestamptz not null default now()
);

-- 会場のQR（?q= の値）。code は推測できない文字列、base はアプリの中の呼び名（talk_A など）
create table if not exists fq_codes (
  code     text primary key,
  base     text not null,
  label    text not null default '',
  points   integer not null default 1,
  enabled  boolean not null default true,
  sort     integer not null default 0
);
create unique index if not exists fq_codes_base_uniq on fq_codes (base);

-- だれがどのQRでポイントをもらったか（1つのQRで1回だけ）
create table if not exists fq_earned (
  recog_no  text not null,
  code      text not null,
  earned_at timestamptz not null default now(),
  primary key (recog_no, code)
);

-- 抽選の記録（ポイントを使った記録を兼ねる）
create table if not exists fq_draw_log (
  id         bigint generated always as identity primary key,
  recog_no   text not null,
  cost       integer not null,
  is_win     boolean not null default false,
  token      text,
  created_at timestamptz not null default now()
);
create index if not exists fq_draw_log_recog_idx on fq_draw_log (recog_no);

-- 数字の設定（本部の画面から変える）
create table if not exists fq_settings (
  key   text primary key,
  value integer not null
);
insert into fq_settings (key, value) values ('draw_cost', 1)     on conflict (key) do nothing; -- 1回まわすのに使うポイント
insert into fq_settings (key, value) values ('lose_weight', 3000) on conflict (key) do nothing; -- ハズレ玉の数（多いほど当たりにくい）

-- お店（協力店）。暗証番号はお店が自分で決める。setup_code は本部から渡す「はじめのコード」
create table if not exists fq_shops (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  note         text not null default '',
  setup_code   text not null unique,
  pin_hash     text,
  pin_fails    integer not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now()
);

-- 景品にお店・説明・期限をつける
alter table prizes add column if not exists shop_id     uuid references fq_shops(id) on delete set null;
alter table prizes add column if not exists description text not null default '';
alter table prizes add column if not exists expires_on  date;

-- 引換券。token は推測できない長い番号（QRの中身）、code は人が読む短い番号
create table if not exists fq_vouchers (
  token      text primary key,
  code       text not null unique,
  recog_no   text not null,
  prize_id   uuid,
  prize_name text not null,
  rarity     integer not null default 1,
  shop_id    uuid,
  shop_name  text not null default '',
  description text not null default '',
  expires_on date,
  issued_at  timestamptz not null default now(),
  used_at    timestamptz
);
create index if not exists fq_vouchers_recog_idx on fq_vouchers (recog_no);

-- ★どの表にもポリシーを作らない＝アプリから直接は読めない。すべて下の関数を通す
alter table fq_devices  enable row level security;
alter table fq_codes    enable row level security;
alter table fq_earned   enable row level security;
alter table fq_draw_log enable row level security;
alter table fq_settings enable row level security;
alter table fq_shops    enable row level security;
alter table fq_vouchers enable row level security;


-- ------------------------------------------------------------
-- 2. 会場のQRのコード（はじめの1回だけ作る。2回目の Run では作り直さない）
--    ★QRに印刷するのは、ここで作られた code。本部の画面の「QRのコード」で見られる
-- ------------------------------------------------------------
insert into fq_codes (code, base, label, points, sort)
select b.base || '.' || substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10), b.base, b.label, 1, b.sort
  from (values ('jigyosho','事業所を訪問',1), ('talk_A','職員Aと会話',2), ('talk_B','職員Bと会話',3),
               ('talk_C','職員Cと会話',4), ('check','適性診断',5), ('event_1','イベント参加①',6),
               ('event_2','イベント参加②',7)) as b(base, label, sort)
 where not exists (select 1 from fq_codes c where c.base = b.base);


-- ------------------------------------------------------------
-- 3. 中で使う道具（アプリからは呼べない）
-- ------------------------------------------------------------
create or replace function fq_auth(p_recog text, p_secret text)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from fq_devices
                  where recog_no = p_recog
                    and secret_hash = encode(extensions.digest(coalesce(p_secret,''), 'sha256'), 'hex'));
$$;

create or replace function fq_balance(p_recog text)
returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(c.points) from fq_earned e join fq_codes c on c.code = e.code
                    where e.recog_no = p_recog), 0)::int
       - coalesce((select sum(cost) from fq_draw_log where recog_no = p_recog), 0)::int;
$$;

create or replace function fq_earned_total(p_recog text)
returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(c.points) from fq_earned e join fq_codes c on c.code = e.code
                    where e.recog_no = p_recog), 0)::int;
$$;

create or replace function fq_setting(p_key text, p_default integer)
returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((select value from fq_settings where key = p_key), p_default);
$$;

create or replace function fq_admin_ok(p_pass text)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = p_pass from fq_admin where key = 'reset_pass'), false);
$$;

create or replace function fq_voucher_json(v fq_vouchers)
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('token', v.token, 'code', v.code, 'prize', v.prize_name, 'rarity', v.rarity,
                           'shop', v.shop_name, 'description', v.description, 'expires_on', v.expires_on,
                           'issued_at', v.issued_at, 'used_at', v.used_at,
                           'status', case when v.used_at is not null then 'used'
                                          when v.expires_on is not null and v.expires_on < (now() at time zone 'Asia/Tokyo')::date then 'expired'
                                          else 'ok' end);
$$;

revoke all on function fq_auth(text,text)         from public, anon, authenticated;
revoke all on function fq_balance(text)           from public, anon, authenticated;
revoke all on function fq_earned_total(text)      from public, anon, authenticated;
revoke all on function fq_setting(text,integer)   from public, anon, authenticated;
revoke all on function fq_admin_ok(text)          from public, anon, authenticated;
revoke all on function fq_voucher_json(fq_vouchers) from public, anon, authenticated;


-- ------------------------------------------------------------
-- 4. アプリ（参加者）から呼ぶ関数
-- ------------------------------------------------------------

-- 新しい端末：認識番号と秘密の鍵を配る（鍵はこの1回しか返らない）
create or replace function fq_device_new()
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_recog text; v_secret text;
begin
  v_recog  := lpad(nextval('recog_seq')::text, 4, '0');
  v_secret := encode(extensions.gen_random_bytes(24), 'hex');
  insert into fq_devices (recog_no, secret_hash)
       values (v_recog, encode(extensions.digest(v_secret, 'sha256'), 'hex'));
  return json_build_object('ok', true, 'recog', v_recog, 'secret', v_secret);
end; $$;

-- いまの状態：残りポイント・もらったQR・持っている引換券
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
    'bases', coalesce((select json_agg(c.base order by c.sort) from fq_earned e join fq_codes c on c.code = e.code
                        where e.recog_no = p_recog), '[]'::json),
    'vouchers', coalesce((select json_agg(fq_voucher_json(v) order by v.issued_at desc) from fq_vouchers v
                           where v.recog_no = p_recog), '[]'::json));
end; $$;

-- 会場のQRを読んだ：正しいコードなら1回だけポイント（ランキングの点数も更新）
create or replace function fq_scan(p_recog text, p_secret text, p_code text, p_nick text)
returns json
language plpgsql security definer set search_path = public as $$
declare c fq_codes; v_rows int; v_total int;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select * into c from fq_codes where code = btrim(coalesce(p_code,'')) and enabled;
  if c.code is null then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad_code');
  end if;
  insert into fq_earned (recog_no, code) values (p_recog, c.code) on conflict do nothing;
  get diagnostics v_rows = row_count;
  v_total := fq_earned_total(p_recog);
  -- ランキング（participants）は「もらったポイントの合計」をサーバーが書く
  insert into participants (recog_no, nickname, points)
       values (p_recog, left(coalesce(p_nick,''), 20), v_total)
  on conflict (recog_no) do update
     set points = v_total,
         nickname = case when coalesce(p_nick,'') <> '' then left(p_nick, 20) else participants.nickname end,
         updated_at = case when participants.points <> v_total then now() else participants.updated_at end;
  return json_build_object('ok', true, 'new', v_rows > 0, 'base', c.base, 'label', c.label,
                           'points', c.points, 'balance', fq_balance(p_recog), 'earned_total', v_total);
end; $$;

-- なまえ（ニックネーム）
create or replace function fq_set_name(p_recog text, p_secret text, p_nick text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_auth(p_recog, p_secret) then return json_build_object('ok', false, 'reason', 'auth'); end if;
  if coalesce(btrim(p_nick),'') = '' then return json_build_object('ok', true); end if;
  insert into participants (recog_no, nickname, points)
       values (p_recog, left(btrim(p_nick), 20), fq_earned_total(p_recog))
  on conflict (recog_no) do update set nickname = left(btrim(p_nick), 20);
  return json_build_object('ok', true);
end; $$;

-- 抽選：ポイントを使って1回。当たり外れ・景品・引換券の発行までここで決める
create or replace function fq_draw(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cost int; v_bal int; v_lose int; v_stock int; v_r double precision; v_acc int := 0;
  p record; won prizes; sh fq_shops; v fq_vouchers;
  v_token text; v_code text; v_try int := 0;
  ABC constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';  -- 見間違えやすい 0/O/1/I は使わない
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  -- 同じ端末から同時に押されても、1回ずつ順番に処理する
  perform pg_advisory_xact_lock(hashtext('fq_draw:' || p_recog));

  v_cost := greatest(1, fq_setting('draw_cost', 1));
  v_bal  := fq_balance(p_recog);
  if v_bal < v_cost then
    return json_build_object('ok', false, 'reason', 'points', 'balance', v_bal, 'cost', v_cost);
  end if;

  -- 在庫のある景品をロックしてから、玉の数で引く（在庫の個数＋ハズレ玉）
  perform 1 from prizes where stock > 0 for update;
  select coalesce(sum(stock), 0) into v_stock from prizes where stock > 0;
  v_lose := greatest(0, fq_setting('lose_weight', 3000));
  v_r := random() * (v_stock + v_lose);

  if v_stock = 0 or v_r >= v_stock then
    insert into fq_draw_log (recog_no, cost, is_win) values (p_recog, v_cost, false);
    insert into draws (recog_no, rarity, is_win) values (p_recog, 0, false);
    return json_build_object('ok', true, 'win', false, 'balance', v_bal - v_cost, 'cost', v_cost);
  end if;

  for p in select * from prizes where stock > 0 order by sort asc, created_at asc loop
    v_acc := v_acc + p.stock;
    if v_r < v_acc then
      update prizes set stock = stock - 1 where id = p.id returning * into won;
      exit;
    end if;
  end loop;
  if won.id is null then   -- 念のため（起きないはず）
    insert into fq_draw_log (recog_no, cost, is_win) values (p_recog, v_cost, false);
    return json_build_object('ok', true, 'win', false, 'balance', v_bal - v_cost, 'cost', v_cost);
  end if;

  select * into sh from fq_shops where id = won.shop_id;
  v_token := encode(extensions.gen_random_bytes(18), 'hex');
  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(ABC, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 32), 1);
    end loop;
    v_code := substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4);
    exit when not exists (select 1 from fq_vouchers where code = v_code);
    v_try := v_try + 1;
    if v_try > 20 then raise exception 'voucher code collision'; end if;
  end loop;

  insert into fq_vouchers (token, code, recog_no, prize_id, prize_name, rarity, shop_id, shop_name, description, expires_on)
       values (v_token, v_code, p_recog, won.id, won.name, won.rarity, sh.id, coalesce(sh.name, ''),
               coalesce(won.description, ''), won.expires_on)
  returning * into v;
  insert into fq_draw_log (recog_no, cost, is_win, token) values (p_recog, v_cost, true, v_token);
  insert into draws (recog_no, rarity, is_win, prize_id, prize_name) values (p_recog, won.rarity, true, won.id, won.name);

  return json_build_object('ok', true, 'win', true, 'rarity', won.rarity,
                           'voucher', fq_voucher_json(v), 'balance', v_bal - v_cost, 'cost', v_cost);
end; $$;


-- ------------------------------------------------------------
-- 5. お店の確認ページ（shop.html）から呼ぶ関数
-- ------------------------------------------------------------

-- QRの中身（token）で券を確かめる。token は推測できないので、だれが開いても中身は見せてよい
create or replace function fq_voucher_check(p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare v fq_vouchers;
begin
  select * into v from fq_vouchers where token = btrim(coalesce(p_token,''));
  if v.token is null then
    perform pg_sleep(0.5);
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;
  return json_build_object('ok', true, 'voucher', fq_voucher_json(v));
end; $$;

-- お店が暗証番号を入れて「使用済み」にする。5回続けて間違えたら10分止まる
create or replace function fq_voucher_redeem(p_token text, p_pin text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v fq_vouchers; sh fq_shops; v_left int;
begin
  select * into v from fq_vouchers where token = btrim(coalesce(p_token,'')) for update;
  if v.token is null then
    perform pg_sleep(0.5);
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;
  select * into sh from fq_shops where id = v.shop_id for update;
  if sh.id is null or sh.pin_hash is null then
    return json_build_object('ok', false, 'reason', 'no_pin');
  end if;
  if sh.locked_until is not null and sh.locked_until > now() then
    return json_build_object('ok', false, 'reason', 'locked',
                             'wait', ceil(extract(epoch from sh.locked_until - now()))::int);
  end if;
  if sh.pin_hash <> encode(extensions.digest(sh.id::text || ':' || coalesce(p_pin,''), 'sha256'), 'hex') then
    update fq_shops set pin_fails = pin_fails + 1,
                        locked_until = case when pin_fails + 1 >= 5 then now() + interval '10 minutes' else null end
     where id = sh.id
    returning greatest(0, 5 - pin_fails) into v_left;
    if v_left = 0 then update fq_shops set pin_fails = 0 where id = sh.id; end if;
    perform pg_sleep(0.5);
    return json_build_object('ok', false, 'reason', 'bad_pin', 'left', v_left);
  end if;
  update fq_shops set pin_fails = 0, locked_until = null where id = sh.id;
  if v.used_at is not null then
    return json_build_object('ok', false, 'reason', 'used', 'voucher', fq_voucher_json(v));
  end if;
  if v.expires_on is not null and v.expires_on < (now() at time zone 'Asia/Tokyo')::date then
    return json_build_object('ok', false, 'reason', 'expired', 'voucher', fq_voucher_json(v));
  end if;
  update fq_vouchers set used_at = now() where token = v.token returning * into v;
  return json_build_object('ok', true, 'voucher', fq_voucher_json(v));
end; $$;

-- お店が暗証番号を決める（本部から渡された「はじめのコード」を入れる）。決め直しもこれで
create or replace function fq_shop_set_pin(p_setup_code text, p_pin text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare sh fq_shops;
begin
  select * into sh from fq_shops where setup_code = upper(btrim(coalesce(p_setup_code,'')));
  if sh.id is null then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'reason', 'bad_setup');
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4,8}$' then
    return json_build_object('ok', false, 'reason', 'bad_pin_format');
  end if;
  update fq_shops set pin_hash = encode(extensions.digest(sh.id::text || ':' || p_pin, 'sha256'), 'hex'),
                      pin_fails = 0, locked_until = null
   where id = sh.id;
  return json_build_object('ok', true, 'shop', sh.name);
end; $$;


-- ------------------------------------------------------------
-- 6. 本部の画面（honbu.html）から呼ぶ関数（合言葉つき）
-- ------------------------------------------------------------
create or replace function fq_admin_voucher_data(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  return json_build_object(
    'ok', true,
    'settings', json_build_object('draw_cost', fq_setting('draw_cost', 1), 'lose_weight', fq_setting('lose_weight', 3000)),
    'shops', coalesce((select json_agg(json_build_object(
                'id', s.id, 'name', s.name, 'note', s.note, 'setup_code', s.setup_code, 'has_pin', s.pin_hash is not null,
                'issued', (select count(*) from fq_vouchers v where v.shop_id = s.id),
                'used',   (select count(*) from fq_vouchers v where v.shop_id = s.id and v.used_at is not null))
              order by s.created_at) from fq_shops s), '[]'::json),
    'prizes', coalesce((select json_agg(json_build_object(
                'id', p.id, 'name', p.name, 'rarity', p.rarity, 'stock', p.stock, 'initial_stock', p.initial_stock,
                'sort', p.sort, 'shop_id', p.shop_id, 'description', p.description, 'expires_on', p.expires_on)
              order by p.sort, p.created_at) from prizes p), '[]'::json),
    'codes', coalesce((select json_agg(json_build_object('code', c.code, 'base', c.base, 'label', c.label,
                'points', c.points, 'enabled', c.enabled) order by c.sort) from fq_codes c), '[]'::json),
    'vouchers', coalesce((select json_agg(json_build_object('code', v.code, 'prize', v.prize_name, 'shop', v.shop_name,
                'recog_no', v.recog_no, 'issued_at', v.issued_at, 'used_at', v.used_at, 'expires_on', v.expires_on)
              order by v.issued_at desc) from (select * from fq_vouchers order by issued_at desc limit 300) v), '[]'::json));
end; $$;

-- お店を足す／名前を直す（p_id が空なら新しく作り、はじめのコードを発行）
create or replace function fq_admin_shop_save(p_pass text, p_id text, p_name text, p_note text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare sh fq_shops; v_code text;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if coalesce(btrim(p_name),'') = '' then return json_build_object('ok', false, 'message', 'お店の名前を入れてください'); end if;
  if coalesce(p_id,'') = '' then
    v_code := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 10));
    insert into fq_shops (name, note, setup_code) values (btrim(p_name), coalesce(p_note,''), v_code) returning * into sh;
  else
    update fq_shops set name = btrim(p_name), note = coalesce(p_note,'') where id = p_id::uuid returning * into sh;
    if sh.id is null then return json_build_object('ok', false, 'message', 'お店が見つかりません'); end if;
    update fq_vouchers set shop_name = sh.name where shop_id = sh.id;
  end if;
  return json_build_object('ok', true, 'id', sh.id, 'setup_code', sh.setup_code);
end; $$;

-- はじめのコードを作り直す（お店が暗証番号を忘れたとき）。暗証番号は消える
create or replace function fq_admin_shop_newcode(p_pass text, p_id text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  v_code := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 10));
  update fq_shops set setup_code = v_code, pin_hash = null, pin_fails = 0, locked_until = null where id = p_id::uuid;
  return json_build_object('ok', found, 'setup_code', v_code);
end; $$;

-- 景品を足す／直す（p_id が空なら新しく作る）。在庫を直すと残数も同じだけ動く
create or replace function fq_admin_prize_save(p_pass text, p_id text, p_name text, p_rarity int, p_initial int,
                                               p_shop_id text, p_description text, p_expires_on text, p_sort int)
returns json
language plpgsql security definer set search_path = public as $$
declare pr prizes; v_diff int;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if coalesce(btrim(p_name),'') = '' then return json_build_object('ok', false, 'message', '景品の名前を入れてください'); end if;
  if coalesce(p_id,'') = '' then
    insert into prizes (name, rarity, stock, initial_stock, sort, shop_id, description, expires_on)
         values (btrim(p_name), greatest(1, least(4, coalesce(p_rarity,1))), greatest(0, coalesce(p_initial,0)),
                 greatest(0, coalesce(p_initial,0)), coalesce(p_sort, 0), nullif(p_shop_id,'')::uuid,
                 coalesce(p_description,''), nullif(p_expires_on,'')::date)
    returning * into pr;
  else
    select * into pr from prizes where id = p_id::uuid for update;
    if pr.id is null then return json_build_object('ok', false, 'message', '景品が見つかりません'); end if;
    v_diff := greatest(0, coalesce(p_initial,0)) - pr.initial_stock;
    update prizes set name = btrim(p_name), rarity = greatest(1, least(4, coalesce(p_rarity,1))),
                      initial_stock = greatest(0, coalesce(p_initial,0)), stock = greatest(0, stock + v_diff),
                      sort = coalesce(p_sort, 0), shop_id = nullif(p_shop_id,'')::uuid,
                      description = coalesce(p_description,''), expires_on = nullif(p_expires_on,'')::date
     where id = pr.id returning * into pr;
  end if;
  return json_build_object('ok', true, 'id', pr.id, 'stock', pr.stock);
end; $$;

create or replace function fq_admin_prize_delete(p_pass text, p_id text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  delete from prizes where id = p_id::uuid;
  return json_build_object('ok', found);
end; $$;

create or replace function fq_admin_settings_save(p_pass text, p_draw_cost int, p_lose_weight int)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  insert into fq_settings (key, value) values ('draw_cost', greatest(1, coalesce(p_draw_cost,1)))
    on conflict (key) do update set value = excluded.value;
  insert into fq_settings (key, value) values ('lose_weight', greatest(0, coalesce(p_lose_weight,0)))
    on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true);
end; $$;


-- ------------------------------------------------------------
-- 7. 大会リセットに、ポイント・抽選・引換券・端末も含める
--    ★お店・景品の設定・QRのコードは消さない（設定なので残す）
--    ★where true を外さないこと（Supabase の安全装置に弾かれる）
-- ------------------------------------------------------------
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
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;
  update fq_shops set pin_fails = 0, locked_until = null where pin_fails <> 0 or locked_until is not null;

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset (図鑑 ' || nz || ' / ゴール ' || ng || ' / 引換券 ' || nv || ' も削除)');

  return json_build_object('ok', true, 'participants', np, 'draws', nd,
                           'zukan', nz, 'goal', ng, 'vouchers', nv);
end; $$;


-- ------------------------------------------------------------
-- 8. 権限
--    ★古い関数は、アプリ（anon）から呼べなくする。不正の入口だったため
-- ------------------------------------------------------------
revoke execute on function add_points(text,text,integer) from public, anon, authenticated;
revoke execute on function claim_prize(text,integer)     from public, anon, authenticated;
revoke execute on function issue_recog()                 from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'fq_device_new()', 'fq_state(text,text)', 'fq_scan(text,text,text,text)', 'fq_set_name(text,text,text)',
    'fq_draw(text,text)', 'fq_voucher_check(text)', 'fq_voucher_redeem(text,text)', 'fq_shop_set_pin(text,text)',
    'fq_admin_voucher_data(text)', 'fq_admin_shop_save(text,text,text,text)', 'fq_admin_shop_newcode(text,text)',
    'fq_admin_prize_save(text,text,text,integer,integer,text,text,text,integer)', 'fq_admin_prize_delete(text,text)',
    'fq_admin_settings_save(text,integer,integer)', 'fq_reset(text)']
  loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

-- ============================================================
-- 確認用（Run のあとに別のクエリで）
--   select base, code from fq_codes order by sort;   -- 会場のQRに入れるコード
--   select key, value from fq_settings;              -- 1回のポイント・ハズレ玉
-- ============================================================
