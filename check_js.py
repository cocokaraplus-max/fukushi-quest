#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""押す前の点検（fq-check-js-v1）… HTML の中の JavaScript の文法を見る

    python3 check_js.py

なぜ要るか
  福祉クエストは HTML1枚に JavaScript が全部入っている作りなので、
  カンマを1つ落としただけでページ全体が動かなくなる。しかも開くまで分からない。
  実際、診断の文言を差し替えたときと、高速料金の欄を足したときの2回、
  この形の間違いで危うくクエストの画面を丸ごと止めるところだった。
  どちらも node --check が見つけてくれた。だから毎回かけることにする。

  何もなければ「ぜんぶ通りました」で終わり、終了コード0。
  1つでもおかしければ、どのファイルの何行目かを書いて、終了コード1で止まる。

  node が無いときは【飛ばさずに失敗する】。点検したつもりで緑になるのが一番まずいため。
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_DIRS = ("node_modules", ".git")
SCRIPT = re.compile(r"<script\b([^>]*)>(.*?)</script>", re.S | re.I)
SRC_ATTR = re.compile(r"\bsrc\s*=", re.I)
TYPE_ATTR = re.compile(r"""\btype\s*=\s*["']([^"']+)["']""", re.I)
JS_TYPES = ("", "text/javascript", "application/javascript", "module")


def html_files():
    out = []
    for p in glob.glob(os.path.join(HERE, "**", "*.html"), recursive=True):
        rel = os.path.relpath(p, HERE)
        if any(rel.startswith(d + os.sep) for d in SKIP_DIRS):
            continue
        out.append(p)
    return sorted(out)


def blocks_of(path):
    """<script> の中身を (何番目か, 何行目から始まるか, 中身) で返す。src= と JSON は見ない。"""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    out = []
    for i, m in enumerate(SCRIPT.finditer(text)):
        attrs, body = m.group(1), m.group(2)
        if SRC_ATTR.search(attrs):
            continue
        t = TYPE_ATTR.search(attrs)
        if t and t.group(1).strip().lower() not in JS_TYPES:
            continue   # application/json などは JavaScript ではない
        if not body.strip():
            continue
        line = text.count("\n", 0, m.start(2)) + 1
        out.append((i, line, body))
    return out


def main():
    node = shutil.which("node")
    if not node:
        print("★node が見つかりません。点検できないので止めます。")
        print("  （飛ばして緑にすると、点検したつもりで壊れたものを通してしまいます）")
        return 1

    files = html_files()
    ng = []
    n_blocks = 0
    tmpdir = tempfile.mkdtemp(prefix="fqjs_")
    try:
        for p in files:
            for idx, line0, body in blocks_of(p):
                n_blocks += 1
                tmp = os.path.join(tmpdir, "b%d.js" % n_blocks)
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(body)
                r = subprocess.run([node, "--check", tmp], capture_output=True, text=True)
                if r.returncode != 0:
                    msg = (r.stderr or "").strip().split("\n")
                    detail = ""
                    for ln in msg:
                        if "SyntaxError" in ln:
                            detail = ln.strip()
                            break
                    # node が言う行番号を、HTML の中の行番号に直す
                    m = re.search(r"b\d+\.js:(\d+)", r.stderr or "")
                    at = ("%d行目あたり" % (line0 + int(m.group(1)) - 1)) if m else "どこかは分かりません"
                    ng.append("%s の %d個目の <script>：%s（%s）"
                              % (os.path.relpath(p, HERE), idx + 1, detail or "文法がおかしいです", at))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("見たファイル %d 枚／<script> %d か所" % (len(files), n_blocks))
    print("═" * 56)
    if ng:
        print("★%d か所おかしいところがあります。押す前に直してください。\n" % len(ng))
        for i, m in enumerate(ng, 1):
            print("  %2d. %s" % (i, m))
        return 1
    if n_blocks == 0:
        print("★<script> が1つも見つかりませんでした。点検になっていないので止めます。")
        return 1
    print("ぜんぶ通りました。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
