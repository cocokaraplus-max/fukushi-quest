-- ============================================================
-- fq-reset-button-v1 の修正（2026-08-26）
--
-- ★症状: 本部の画面でリセットを押すと
--        「通信エラー: DELETE requires a WHERE clause」
--
-- ★原因: Supabase には「うっかり全消し」を防ぐ安全装置(safeupdate)が入っていて、
--        where の付いていない delete / update を拒否する。
--        関数の中に書いた
--            delete from draws;
--            delete from participants;
--            update prizes set stock = initial_stock;
--        が、どれも where 無しだったため弾かれた。
--        （手元のPostgresにはこの安全装置が無いので、そこでは通ってしまっていた）
--
-- ★直し方: 全部に where を付ける。意味は同じまま。
--        delete ... where true      … 全部が対象、と明示する
--        update ... where 値が違う行だけ … よけいな書き込みも減る
--
-- ★合言葉は書き換え不要です。このファイルに合言葉は入っていません。
--   そのままコピーして Supabase の SQL Editor で Run してください。
-- ============================================================

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

  -- ★where true を外さないこと。外すと Supabase の安全装置に弾かれる。
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
-- 確認用（Run したあとに流すと、いまの件数が見えます）
-- ============================================================
-- select fq_stats();
