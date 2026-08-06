-- ============================================================
-- FUKUSHI QUEST 326 — 共有バックエンド スキーマ（無料Supabase用）
-- TASUKARU とは別プロジェクトで実行すること。
-- Supabase の SQL Editor に貼り付けて Run。
-- ============================================================

-- 参加者（なまえ＝ニックネーム、認識番号、ポイント）
create table if not exists participants (
  recog_no    text primary key,          -- 認識番号（端末ごとの4桁など）
  nickname    text not null default '',
  points      integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 景品（在庫）
create table if not exists prizes (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  rarity        integer not null default 1,   -- 1:青 2:緑 3:赤 4:虹 など
  stock         integer not null default 0,    -- 残数
  initial_stock integer not null default 0,
  sort          integer not null default 0,
  created_at    timestamptz not null default now()
);

-- ガチャ履歴
create table if not exists draws (
  id             bigint generated always as identity primary key,
  recog_no       text,
  rarity         integer,
  is_win         boolean not null default false,
  prize_id       uuid,
  prize_name     text,
  created_at     timestamptz not null default now()
);

-- ランキング用ビュー（ポイント降順）
create or replace view ranking as
  select recog_no, nickname, points,
         rank() over (order by points desc, updated_at asc) as rank
  from participants;

-- ============================================================
-- RPC: ポイント加算（参加者を upsert して加算）
-- ============================================================
create or replace function add_points(p_recog text, p_nick text, p_delta integer)
returns participants
language plpgsql security definer set search_path = public as $$
declare row participants;
begin
  insert into participants (recog_no, nickname, points)
    values (p_recog, coalesce(p_nick,''), greatest(p_delta,0))
  on conflict (recog_no) do update
    set points = participants.points + p_delta,
        nickname = case when excluded.nickname <> '' then excluded.nickname else participants.nickname end,
        updated_at = now()
  returning * into row;
  return row;
end; $$;

-- ============================================================
-- RPC: 景品確定（当選時）。指定レアリティで在庫のある景品を
--       アトミックに1つ減算し、履歴を残す。無ければ null（=ハズレ扱い）。
-- ============================================================
create or replace function claim_prize(p_recog text, p_rarity integer)
returns prizes
language plpgsql security definer set search_path = public as $$
declare won prizes;
begin
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

-- ============================================================
-- 権限・RLS（匿名は 読み取り＋RPC のみ。書き込みはRPC経由に限定）
-- ============================================================
alter table participants enable row level security;
alter table prizes       enable row level security;
alter table draws        enable row level security;

drop policy if exists p_read_participants on participants;
drop policy if exists p_read_prizes on prizes;
create policy p_read_participants on participants for select using (true);
create policy p_read_prizes       on prizes       for select using (true);
-- draws は書き込み/読み取りともRPC(security definer)経由のみ（匿名の直接アクセス無し）

grant execute on function add_points(text,text,integer) to anon, authenticated;
grant execute on function claim_prize(text,integer)     to anon, authenticated;
grant select on ranking to anon, authenticated;

-- リアルタイム配信（本部タブレットのライブ表示用）
alter publication supabase_realtime add table prizes;
alter publication supabase_realtime add table participants;

-- ============================================================
-- 例：景品の初期投入（本部の管理で入れ替え可）
-- ============================================================
insert into prizes (name, rarity, stock, initial_stock, sort) values
  ('地域店舗 商品券 500円', 1, 100, 100, 10),
  ('カフェ ドリンク券',      1, 100, 100, 11),
  ('オリジナルグッズ',        2,  50,  50, 20),
  ('ノベルティ 文具セット',   2,  50,  50, 21),
  ('キッチンカー 利用券',     3,  20,  20, 30),
  ('特賞 コラボグッズ',       4,   5,   5, 40)
on conflict do nothing;
