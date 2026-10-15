-- ============================================================
-- FUKUSHI QUEST — QRごとのポイントを変える（fq-code-points-v1）
--   ・本部（とジャービス）から、会場のQR1つあたりのポイントと「使う／使わない」を変えられるようにする
--   ・合言葉は fq_admin の reset_pass（大会リセットと同じ）
-- 使い方：福祉クエストの Supabase → SQL Editor → 全部貼って Run。2回以上 Run しても壊れません。
-- ★先に fq_voucher.sql が流れている前提です。
-- ============================================================
create or replace function fq_admin_code_save(p_pass text, p_base text, p_points int, p_enabled boolean)
returns json
language plpgsql security definer set search_path = public as $$
declare c fq_codes;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if p_points is null or p_points < 0 or p_points > 100 then return json_build_object('ok', false, 'message', 'ポイントは0〜100にしてください'); end if;
  update fq_codes set points = p_points, enabled = coalesce(p_enabled, enabled)
   where base = btrim(coalesce(p_base, ''))
  returning * into c;
  if c.code is null then return json_build_object('ok', false, 'message', 'そのQRはありません'); end if;
  -- ランキングの点数（もらったポイントの合計）も合わせ直す
  update participants pa set points = fq_earned_total(pa.recog_no)
   where exists (select 1 from fq_earned e where e.recog_no = pa.recog_no and e.code = c.code);
  return json_build_object('ok', true, 'base', c.base, 'label', c.label, 'points', c.points, 'enabled', c.enabled);
end; $$;

revoke all on function fq_admin_code_save(text,text,int,boolean) from public;
grant execute on function fq_admin_code_save(text,text,int,boolean) to anon, authenticated;
