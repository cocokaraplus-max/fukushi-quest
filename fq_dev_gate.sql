-- ============================================================
-- fq-dev-gate-v1 — 開発パネル／主催者設定を、自分だけが出せるようにする
--
-- ★これは Supabase の SQL Editor に貼って Run します。
-- ★★下の「ここに開発用の合言葉」を、自分で決めた合言葉に必ず書き換えてから Run すること。
--   ・リセット用の合言葉とは**別のもの**にしてください
--   ・意味のない20文字くらいの文字列に
--   ・誰にも見せない（AIにも渡さない）
--
-- これを流すと、開発パネルが出る条件が次の3つ「全部」になります。
--   1. URLに ?dev=1（または ?admin=1）が付いている、そのときだけ（端末は何も覚えない）
--   2. その端末が、下の fq_dev_devices に登録されている
--   3. 合言葉が合っている
-- ============================================================


-- ① 合言葉の箱（リセット用と共用。無ければ作る）--------------------
create table if not exists fq_admin (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table fq_admin enable row level security;
-- ★ポリシーを1つも作らない = アプリからは1行も読めない


-- ② 開発用の合言葉を設定する ----------------------------------------
-- ★★ここだけ書き換えてください（リセット用とは別の言葉に）★★
insert into fq_admin (key, value) values ('dev_pass', 'ここに開発用の合言葉')
on conflict (key) do update set value = excluded.value, updated_at = now();


-- ③ 許可する端末の一覧 ----------------------------------------------
create table if not exists fq_dev_devices (
  did      text primary key,
  label    text not null default '',
  added_at timestamptz not null default now()
);
alter table fq_dev_devices enable row level security;
-- ★ここもポリシーを作らない。アプリからは一覧を見られない。
-- ★★端末の登録は、この SQL Editor からしかできません。
--   （アプリから登録できるようにすると、合言葉を知った人が自分の端末を足せてしまうため）


-- ④ 判定する関数 ----------------------------------------------------
create or replace function fq_dev_check(p_pass text, p_did text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pass_ok boolean;
  reg_ok  boolean;
begin
  select (value = p_pass) into pass_ok from fq_admin where key = 'dev_pass';

  -- ★合言葉を先に見る。合っていない相手に、端末が登録済みかどうかを教えない。
  if coalesce(pass_ok, false) is not true then
    perform pg_sleep(1);   -- 総当たりを遅くする
    return json_build_object('ok', false, 'reason', 'pass',
                             'message', '合言葉が違います');
  end if;

  select exists(select 1 from fq_dev_devices where did = p_did) into reg_ok;
  if not reg_ok then
    return json_build_object('ok', false, 'reason', 'device',
                             'message', 'この端末は登録されていません');
  end if;

  return json_build_object('ok', true);
end; $$;

grant execute on function fq_dev_check(text, text) to anon, authenticated;


-- ============================================================
-- ⑤ 自分の端末を登録する（★あとで実行）
--
--   1) 自分のスマホ／パソコンで、アプリを ?dev=1 付きで開く
--        https://cocokaraplus-max.github.io/fukushi-quest/?dev=1
--   2) 出てくる箱に、合言葉を入れて「確認」を押す
--   3) 「この端末は登録されていません」と出て、**端末の番号**が表示される
--   4) その番号を、下の 'ここに端末番号' に貼って Run する
--   5) もう一度 ?dev=1 で開き直せば、パネルが出る
--
--   ★端末ごとに登録が必要です（スマホとパソコンを両方使うなら2回）
-- ============================================================
-- insert into fq_dev_devices (did, label) values ('ここに端末番号', '自分のスマホ')
--   on conflict (did) do update set label = excluded.label;


-- ============================================================
-- 確認・管理用
-- ============================================================
-- 登録した端末を見る
--   select did, label, added_at from fq_dev_devices order by added_at;
--
-- 登録を消す（端末を替えたとき）
--   delete from fq_dev_devices where label = '自分のスマホ';
--
-- 合言葉が効いているかの確認（わざと違う言葉で。1秒待たされて false ならOK）
--   select fq_dev_check('ちがう合言葉', 'なんでもよい');
