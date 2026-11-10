#!/usr/bin/env python3
"""D 方案迁移：把 Rockbox 的 /Music FLAC 曲库转换成单份 ALAC 放到 iPod_Control/Music/F00，
同时更新状态文件与 iTunesDB，让原厂系统与 Rockbox 共用同一批文件。"""
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "vendor"))

MOUNT = sys.argv[1]
HOME = os.environ.get("IPODSYNC_HOME") or os.path.expanduser("~/Library/Application Support/iPodSync")
STATE = os.path.join(HOME, "ipodsync-state.json")
F00 = os.path.join(MOUNT, "iPod_Control", "Music", "F00")
MUSIC = os.path.join(MOUNT, "Music")
TMP = tempfile.mkdtemp(prefix="alac-mig-")

from mutagen.flac import FLAC
from mutagen.mp3 import MP3
from mutagen.id3 import ID3
from mutagen.mp4 import MP4, MP4Cover


def sanitize(name: str) -> str:
    name = re.sub(r'[\\/:*?"<>|]', "_", name)
    name = name.strip().lstrip(".")
    return name[:120] or "track"


def read_tags(src: str) -> dict:
    tags = {}
    cover = None
    try:
        if src.lower().endswith(".flac"):
            f = FLAC(src)
            t = f.tags or {}
            tags = {"title": (t.get("title") or [""])[0],
                    "artist": (t.get("artist") or t.get("albumartist") or [""])[0],
                    "album": (t.get("album") or [""])[0],
                    "genre": (t.get("genre") or [""])[0],
                    "track": (t.get("tracknumber") or ["0"])[0],
                    "year": (t.get("date") or [""])[0][:4]}
            if f.pictures:
                cover = (f.pictures[0].data, "image/png" if f.pictures[0].mime == "image/png" else "image/jpeg")
        elif src.lower().endswith(".mp3"):
            m = MP3(src)
            t = m.tags or {}
            tags = {"title": str(t.get("TIT2", "")),
                    "artist": str(t.get("TPE1", "")),
                    "album": str(t.get("TALB", "")),
                    "genre": str(t.get("TCON", "")),
                    "track": str(t.get("TRCK", "0")).split("/")[0],
                    "year": str(t.get("TDRC", ""))[:4]}
            for k in list(t.keys()):
                if k.startswith("APIC"):
                    cover = (t[k].data, t[k].mime)
                    break
    except Exception as e:
        print("  读标签失败:", src, e)
    return {"tags": tags, "cover": cover}


def convert(src: str, dst_m4a: str) -> bool:
    aiff = os.path.join(TMP, "in.aiff")
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src,
                        "-c:a", "pcm_s16be", "-ar", "44100", "-ac", "2", aiff],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("  ffmpeg 解码失败:", r.stderr.strip()[:160])
        return False
    r = subprocess.run(["afconvert", "-f", "m4af", "-d", "alac", aiff, dst_m4a],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(dst_m4a):
        print("  afconvert 失败:", (r.stderr or r.stdout).strip()[:160])
        return False
    info = read_tags(src)
    t = info["tags"]
    try:
        m = MP4(dst_m4a)
        if t.get("title"):
            m["\xa9nam"] = [t["title"]]
        if t.get("artist"):
            m["\xa9ART"] = [t["artist"]]
        if t.get("album"):
            m["\xa9alb"] = [t["album"]]
        if t.get("genre"):
            m["\xa9gen"] = [t["genre"]]
        if t.get("year"):
            m["\xa9day"] = [t["year"]]
        try:
            tn = int(t.get("track") or 0)
            if tn:
                m["trkn"] = [(tn, 0)]
        except ValueError:
            pass
        if info["cover"]:
            data, mime = info["cover"]
            fmt = MP4Cover.FORMAT_PNG if "png" in mime else MP4Cover.FORMAT_JPEG
            m["covr"] = [MP4Cover(data, imageformat=fmt)]
        m.save()
    except Exception as e:
        print("  写标签失败:", e)
    return True


def main():
    st = json.load(open(STATE, encoding="utf-8"))
    tracks = st.get("tracks", [])
    print("状态曲目:", len(tracks))
    migrated, failed = [], []
    used_names = set()

    for i, t in enumerate(tracks):
        rb = t.get("rockbox_path") or ""
        ap = t.get("apple_path") or ""
        name = os.path.basename(rb) if rb else ""
        src = os.path.join(MUSIC, name) if name and os.path.exists(os.path.join(MUSIC, name)) else ""
        if not src and ap:
            cand = os.path.join(MOUNT, ap.lstrip("/"))
            if os.path.exists(cand):
                src = cand
        label = (t.get("artist") or "?") + " - " + (t.get("title") or "?")
        print("[%d/%d] %s" % (i + 1, len(tracks), label))
        if not src:
            print("  找不到源文件，跳过")
            failed.append((label, "源文件不存在"))
            continue
        base = os.path.splitext(os.path.basename(src))[0]
        safe = sanitize(base)
        out = safe + ".m4a"
        if out in used_names:
            out = "%s-%d.m4a" % (safe, i)
        used_names.add(out)
        dst = os.path.join(F00, out)
        tmp_out = os.path.join(TMP, "out.m4a")
        if not convert(src, tmp_out):
            failed.append((label, "转码失败"))
            continue
        shutil.copy2(tmp_out, dst)
        size = os.path.getsize(dst)
        dur = float(t.get("duration") or 0)
        t["rockbox_path"] = "/iPod_Control/Music/F00/" + out
        t["apple_path"] = t["rockbox_path"]
        t["bitrate"] = int(size * 8 / dur) if dur else 0
        # 歌词：把原来的 .lrc 挪到 F00
        old_lrc = t.get("lrc_rel") or ""
        if old_lrc:
            src_lrc = os.path.join(MOUNT, old_lrc.lstrip("/"))
            if os.path.exists(src_lrc):
                new_rel = "/iPod_Control/Music/F00/" + os.path.splitext(out)[0] + ".lrc"
                shutil.copyfile(src_lrc, os.path.join(MOUNT, new_rel.lstrip("/")))
                t["lrc_rel"] = new_rel
            else:
                t["lrc_rel"] = ""
        migrated.append((t, src, dst, ap))
        print("  ✓ %s (%.1f MB)" % (out, size / 1e6))

    print("\n迁移成功 %d 首，失败 %d 首" % (len(migrated), len(failed)))
    for label, why in failed:
        print("  ✗", label, "|", why)
    if not migrated:
        print("没有成功迁移任何曲目，终止")
        return 1

    # 状态写回（先备份到 /tmp）
    shutil.copy2(STATE, os.path.join(TMP, "state-before.json"))
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    print("状态文件已更新")

    # 重建 iTunesDB
    manifest = os.path.join(TMP, "manifest.tsv")
    with open(manifest, "w", encoding="utf-8") as f:
        for t in tracks:
            if not t.get("apple_path"):
                continue
            cols = [t["apple_path"], t.get("title") or "", t.get("artist") or "",
                    t.get("album") or "", str(t.get("track") or ""), str(t.get("year") or ""),
                    t.get("genre") or "", "%.3f" % (t.get("duration") or 0),
                    str(t.get("bitrate") or 0), t.get("cover") or "", t.get("lrc_rel") or ""]
            f.write("\t".join(c.replace("\t", " ").replace("\n", " ") for c in cols) + "\n")
    exe = os.path.join(HERE, "itdbwrite")
    r = subprocess.run([exe, MOUNT, manifest], capture_output=True, text=True)
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()[:200])

    # 删除已迁移曲目的旧文件（只按记录的旧路径删，绝不动新生成的 m4a）
    removed = 0
    for t, src, _dst, old_apple in migrated:
        for p in (src,
                  os.path.splitext(src)[0] + ".lrc",
                  (os.path.join(MOUNT, old_apple.lstrip("/")) if old_apple else "")):
            if p and os.path.isfile(p) and not p.lower().endswith(".m4a"):
                try:
                    os.remove(p)
                    removed += 1
                except OSError:
                    pass
    # 顺带清掉 /Music 里残留的 flac/lrc/mp3（已迁移曲目之外的不动）
    for fn in os.listdir(MUSIC):
        if fn.startswith("."):
            continue
        p = os.path.join(MUSIC, fn)
        if fn.lower().endswith((".flac", ".lrc", ".mp3")):
            try:
                os.remove(p)
                removed += 1
            except OSError:
                pass
    print("已删除旧文件 %d 个" % removed)

    # 清 CrazyPod 缓存，让 Rockbox 重新扫描
    for fn in ("music-library.bin", "artwork.ready"):
        p = os.path.join(MOUNT, ".crazypod", "cache", fn)
        if os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                pass
    print("CrazyPod 缓存已清")
    got = len([f for f in os.listdir(F00) if f.lower().endswith(".m4a")])
    print("F00 里的 ALAC 文件数:", got)
    if got == 0:
        print("⚠ 警告：新文件似乎被误删，请立即用备份恢复！")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
