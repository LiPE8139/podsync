#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipodsync.py — iPod 一键增量同步
================================
把音乐放进固定「收件箱」文件夹（默认 ~/Music/iPod-Inbox），双击「一键同步.command」即可：

  1) 扫描收件箱里所有新音乐（支持 flac / mp3 / m4a / wav / aiff / ogg / opus …）
  2) 自动查重：已同步过的（文件指纹相同）直接跳过；疑似重复的（标题+歌手+时长相近）会提醒
  3) 为原厂固件生成 MP3 镜像 + 写入 iTunesDB / ArtworkDB（封面）
  4) 为 Rockbox/CrazyPod 生成无损 FLAC 放进 /Music（超规格自动转 16bit/44.1kHz）
  5) 打印本次新增 / 重复 / 失败清单，并提示重启

命令：
  python3 ipodsync.py sync           # 一键同步（默认）
  python3 ipodsync.py sync --dry-run # 只看会发生什么
  python3 ipodsync.py status         # 查看已同步数量 / 收件箱待处理
  python3 ipodsync.py sync --force   # 疑似重复也强制加入

依赖：ffmpeg、libgpod（见 README 的「原厂曲库」章节）、ipodtune.py（同目录）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ipodtune as it  # noqa: E402  复用探测/匹配/写标签的代码

# 配置/状态/工作目录：默认与脚本同目录；GUI 版通过 IPODSYNC_HOME 指到 ~/Library/Application Support
HOME_DIR = os.environ.get("IPODSYNC_HOME") or HERE
try:
    os.makedirs(HOME_DIR, exist_ok=True)
except Exception:
    HOME_DIR = HERE            # 配置目录不可写时回退到脚本目录
    os.makedirs(HOME_DIR, exist_ok=True)
CFG_PATH = os.path.join(HOME_DIR, "ipodsync.json")
STATE_PATH = os.path.join(HOME_DIR, "ipodsync-state.json")
WORK = os.path.join(HOME_DIR, "sync-work")
AUDIO_EXT = {".flac", ".mp3", ".m4a", ".aac", ".wav", ".aif", ".aiff", ".ogg", ".oga", ".opus", ".ftyp"}
DEFAULT_CFG = {
    "inbox": os.path.expanduser("~/Music/iPod-Inbox"),
    "targets": {"rockbox": True, "apple": True},
    "apple_bitrate": "320k",
    "eject_after_sync": False,
    "clean_inbox": True,
    "library_mode": "alac",   # alac = 单份 ALAC 放 iPod_Control/Music（两系统共用）；dual = 旧的双份
    "mount": None,
}


# ---------------------------------------------------------------- 基础
def load_cfg() -> dict:
    cfg = dict(DEFAULT_CFG)
    if os.path.exists(CFG_PATH):
        try:
            cfg.update(json.load(open(CFG_PATH, encoding="utf-8")))
        except Exception:
            pass
    if os.environ.get("IPODSYNC_MOUNT"):
        cfg["mount"] = os.environ["IPODSYNC_MOUNT"]
    if os.environ.get("IPODSYNC_INBOX"):
        cfg["inbox"] = os.environ["IPODSYNC_INBOX"]
    if os.environ.get("IPODSYNC_LIBRARY_MODE"):
        cfg["library_mode"] = os.environ["IPODSYNC_LIBRARY_MODE"]
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(cfg["inbox"], exist_ok=True)
    return cfg


def save_cfg(cfg: dict) -> None:
    json.dump(cfg, open(CFG_PATH, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def load_state() -> dict:
    if os.path.exists(STATE_PATH):
        try:
            return json.load(open(STATE_PATH, encoding="utf-8"))
        except Exception:
            pass
    return {"version": 1, "tracks": []}


def save_state(st: dict) -> None:
    tmp = STATE_PATH + ".tmp"
    json.dump(st, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, STATE_PATH)


def find_mount(cfg: dict) -> str:
    if cfg.get("mount") and os.path.isdir(cfg["mount"]):
        return cfg["mount"]
    for c in sorted(os.listdir("/Volumes")) if os.path.isdir("/Volumes") else []:
        mp = os.path.join("/Volumes", c)
        if c in ("Macintosh HD", "Recovery") or not os.path.isdir(mp):
            continue
        if os.path.isdir(os.path.join(mp, "iPod_Control")) or os.path.isdir(os.path.join(mp, ".rockbox")):
            return mp
    return ""


def md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def safe_name(name: str, maxlen=110) -> str:
    n = re.sub(r'[\\/:*?"<>|\r\n\t]+', "-", name)
    n = re.sub(r"\s+", " ", n).strip(" .")
    return (n or "untitled")[:maxlen]


def norm_key(title: str, artist: str) -> str:
    return it.norm(title) + "|" + it.norm(artist)


# ---------------------------------------------------------------- 探测 / 标签
def probe(path: str) -> dict:
    j = json.loads(it.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path]) or "{}")
    a = next((s for s in j.get("streams", []) if s.get("codec_type") == "audio"), {})
    fmt = j.get("format", {})
    tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    return {
        "duration": float(fmt.get("duration") or a.get("duration") or 0),
        "codec": (a.get("codec_name") or "").lower(),
        "sample_rate": int(a.get("sample_rate") or 0),
        "bits": int(a.get("bits_per_raw_sample") or a.get("bits_per_sample") or 0),
        "bitrate": int(fmt.get("bit_rate") or 0),
        "tags": tags,
        "size": os.path.getsize(path),
    }


def meta_from_tags(p: dict, fallback_title: str) -> dict:
    t = p["tags"]
    title = t.get("title") or fallback_title
    return {
        "title": title,
        "artist": t.get("artist") or t.get("album_artist") or "",
        "album": t.get("album") or "",
        "track": (t.get("track") or t.get("tracknumber") or "").split("/")[0] or None,
        "year": (t.get("date") or t.get("year") or "")[:4],
        "genre": t.get("genre") or "",
    }


def extract_cover(src: str, key: str):
    """从源文件里抽内嵌封面；返回本地图片路径或 None。"""
    outdir = os.path.join(WORK, "covers")
    os.makedirs(outdir, exist_ok=True)
    data, ext = None, ".jpg"
    try:
        if src.lower().endswith(".flac"):
            from mutagen.flac import FLAC
            f = FLAC(src)
            if f.pictures:
                data = f.pictures[0].data
                ext = ".png" if "png" in (f.pictures[0].mime or "") else ".jpg"
        elif src.lower().endswith(".mp3"):
            from mutagen.id3 import ID3
            t = ID3(src)
            pics = [v for k, v in t.items() if k.startswith("APIC")]
            if pics:
                data = pics[0].data
                ext = ".png" if "png" in (pics[0].mime or "") else ".jpg"
        elif src.lower().endswith((".m4a", ".m4b", ".aac")):
            from mutagen.mp4 import MP4
            cov = MP4(src).tags.get("covr") if MP4(src).tags else None
            if cov:
                data = bytes(cov[0])
                ext = ".png" if data[:4] == b"\x89PNG" else ".jpg"
    except Exception:
        pass
    if not data:
        return None
    path = os.path.join(outdir, key + ext)
    with open(path, "wb") as f:
        f.write(data)
    return path


def fetch_cover_online(meta: dict, dur: float, key: str):
    """内嵌封面缺失时，用 iTunes 按「歌名 + 时长」找一张。"""
    net = it.Net(country="us", enabled=True)
    try:
        for cue in (("%s %s" % (meta["artist"], meta["title"])).strip(), meta["title"]):
            best = None
            for c in net.songs(cue, limit=25):
                if c.get("kind") != "song":
                    continue
                d = (c.get("trackTimeMillis") or 0) / 1000.0
                if not d or abs(d - dur) > 2.0:
                    continue
                if best is None or abs(d - dur) < abs(best[0] - dur):
                    best = (d, c)
            if best:
                art = (best[1].get("artworkUrl100") or "").replace("100x100bb", "600x600bb")
                if art:
                    return it.fetch_art(art, WORK, "remote_" + key)
    except Exception:
        pass
    return None


# ---------------------------------------------------------------- 转码 / 写标签
def transcode(src: str, dst: str, fmt: str, bitrate: str = "320k") -> None:
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src, "-map", "0:a"]
    if fmt == "flac":
        cmd += ["-c:a", "flac", "-sample_fmt", "s16", "-ar", "44100", "-compression_level", "5", "-map_metadata", "0"]
    elif fmt == "mp3":
        cmd += ["-c:a", "libmp3lame", "-b:a", bitrate, "-id3v2_version", "3", "-map_metadata", "0"]
    else:
        raise ValueError(fmt)
    it.run(cmd + ["-f", fmt, dst])


def needed_transcode(p: dict, target: str) -> bool:
    if target == "rockbox":
        if p["codec"] not in ("flac", "mp3"):
            return True
        if p["codec"] == "flac" and (p["sample_rate"] > 48000 or p["bits"] > 16):
            return True
        return False
    # apple：统一 MP3
    if p["codec"] == "mp3" and p["bitrate"] and p["bitrate"] <= 330000:
        return False
    return True


# ---------------------------------------------------------------- iTunesDB 重建
def rebuild_apple(st: dict, mount: str, dry: bool) -> int:
    tracks = [t for t in st["tracks"] if t.get("apple_path")]
    if not tracks:
        return 0
    exe = (os.environ.get("IPODSYNC_ITDBWRITE")
           or os.path.join(HERE, "runtime", "itdb", "bin", "itdbwrite")
           or os.path.join(HERE, "itdbwrite"))
    if not os.path.exists(exe):
        exe = shutil.which("itdbwrite") or "/tmp/itdbwrite"
    manifest = os.path.join(WORK, "apple-manifest.tsv")
    os.makedirs(os.path.dirname(manifest), exist_ok=True)
    with open(manifest, "w", encoding="utf-8") as f:
        for t in tracks:
            cols = [
                t["apple_path"], t.get("title", ""), t.get("artist", ""), t.get("album", ""),
                str(t.get("track") or ""), str(t.get("year") or ""), t.get("genre", ""),
                "%.3f" % t.get("duration", 0), str(t.get("bitrate") or 0),
                t.get("cover") or "",
            ]
            cols.append(t.get("lrc_rel") or "")
            f.write("\t".join(c.replace("\t", " ").replace("\n", " ") for c in cols) + "\n")
    if dry:
        print("  [dry] 将重建 iTunesDB/ArtworkDB：%d 首" % len(tracks))
        return len(tracks)
    if not os.path.exists(exe):
        print("  ✗ 找不到 itdbwrite（libgpod 写库工具），跳过原厂库更新")
        return 0
    p = subprocess.run([exe, mount, manifest], capture_output=True, text=True)
    tail = (p.stdout or "").strip().splitlines()
    if p.returncode != 0:
        print("  ✗ 写 iTunesDB 失败：%s" % ((p.stderr or "").strip().splitlines() or ["?"])[-1])
        return -1
    print("  ✓ " + (tail[-1] if tail else "iTunesDB 已更新"))
    return len(tracks)


# ---------------------------------------------------------------- 同步主流程
def bootstrap_state(st: dict, mount: str, mode: str = "alac") -> int:
    """首次运行时，把 iPod 上已有的曲库纳入状态，便于查重与保留封面。"""
    n = 0
    entries = {}
    def add(rec, key):
        cur = entries.setdefault(key, {"title": rec.get("title", ""), "artist": rec.get("artist", ""),
                                       "album": rec.get("album", ""), "duration": rec.get("duration", 0)})
        for k, v in rec.items():
            if v:
                cur[k] = v
    # /Music（Rockbox）
    mdir = os.path.join(mount, "Music")
    if os.path.isdir(mdir):
        for fn in sorted(os.listdir(mdir)):
            if fn.startswith("."):
                continue
            p = os.path.join(mdir, fn)
            if not os.path.isfile(p) or os.path.splitext(fn)[1].lower() not in AUDIO_EXT:
                continue
            try:
                pr = probe(p)
            except Exception:
                continue
            meta = meta_from_tags(pr, os.path.splitext(fn)[0])
            key = norm_key(meta["title"], meta["artist"]) + "|%.0f" % pr["duration"]
            rec = {"title": meta["title"], "artist": meta["artist"], "album": meta["album"],
                   "track": meta["track"], "year": meta["year"], "genre": meta["genre"],
                   "duration": round(pr["duration"], 3), "rockbox_path": "/Music/" + fn}
            if os.path.exists(os.path.splitext(p)[0] + ".lrc"):
                rec["lrc_rel"] = "/Music/" + os.path.splitext(fn)[0] + ".lrc"
            add(rec, key)
            n += 1
    # iPod_Control/Music（原厂镜像）
    adir = os.path.join(mount, "iPod_Control", "Music")
    if os.path.isdir(adir):
        for dp, _dn, fns in os.walk(adir):
            for fn in sorted(fns):
                p = os.path.join(dp, fn)
                if os.path.splitext(fn)[1].lower() not in AUDIO_EXT:
                    continue
                try:
                    pr = probe(p)
                except Exception:
                    continue
                meta = meta_from_tags(pr, os.path.splitext(fn)[0])
                rel = "/" + os.path.relpath(p, mount).replace(os.sep, "/")
                key = norm_key(meta["title"], meta["artist"]) + "|%.0f" % pr["duration"]
                cov = extract_cover(p, "boot_" + hashlib.md5(rel.encode()).hexdigest()[:10])
                rec = {"title": meta["title"], "artist": meta["artist"], "album": meta["album"],
                       "track": meta["track"], "year": meta["year"], "genre": meta["genre"],
                       "duration": round(pr["duration"], 3), "apple_path": rel,
                       "bitrate": pr["bitrate"], "cover": cov}
                if mode == "alac" and fn.lower().endswith((".m4a", ".m4b")):
                    rec["rockbox_path"] = rel
                add(rec, key)
                n += 1
    st["tracks"] = list(entries.values())
    return len(st["tracks"])


def sync(dry: bool, force: bool, eject: bool = False, only_file: str = None,
         keep_inbox: bool = False) -> int:
    cfg = load_cfg()
    st = load_state()
    mount = find_mount(cfg)
    if not mount:
        print("✗ 没有找到 iPod。请把 iPod 背板上的 HOLD 关掉、用数据线连上 Mac（原厂固件或 Rockbox 都可以）。")
        return 2
    targets = cfg["targets"]
    mode = cfg.get("library_mode", "alac")
    if not st["tracks"] and os.path.isdir(mount):
        cnt = bootstrap_state(st, mount, mode)
        if cnt:
            save_state(st)
            print("（首次运行：已把 iPod 上现有 %d 首纳入状态，便于查重与保留封面）" % cnt)
    print("iPod: %s" % mount)
    print("收件箱: %s" % cfg["inbox"])
    print("模式: %s" % ("单份 ALAC（两系统共用）" if mode == "alac" else "双份（/Music FLAC + 原厂 MP3）"))
    print("目标: Rockbox(/Music)=%s  原厂(MP3+iTunesDB)=%s\n" % (
        "开" if targets.get("rockbox") else "关", "开" if targets.get("apple") else "关"))

    files = []
    for dp, dns, fns in os.walk(cfg["inbox"]):
        dns[:] = [d for d in dns if not d.startswith(".")]
        for fn in sorted(fns):
            if fn.startswith("._") or fn.startswith("."):
                continue
            if os.path.splitext(fn)[1].lower() in AUDIO_EXT:
                files.append(os.path.join(dp, fn))

    only = None
    if only_file:
        try:
            only = set(json.load(open(only_file, encoding="utf-8")))
        except Exception:
            only = set()
        if not only:
            print("没有选中任何曲目。")
            return 0
        files = [f for f in files
                 if os.path.abspath(f) in only or os.path.basename(f) in only]
        if not files:
            print("选中的曲目已不在收件箱里。")
            return 0
        print("只同步选中的 %d 首。" % len(files))

    if not files:
        print("收件箱里没有待处理的音乐。把文件放进 %s 再运行即可。" % cfg["inbox"])
        return 0

    known_hash = {t["hash"]: t for t in st["tracks"] if t.get("hash")}
    by_key = {}
    for t in st["tracks"]:
        by_key.setdefault(norm_key(t.get("title", ""), t.get("artist", "")), []).append(t)

    added, dups, fails, skipped = [], [], [], []
    synced_srcs = []
    for src in files:
        fn = os.path.basename(src)
        print("— %s" % fn)
        h = md5(src)
        if h in known_hash:
            print("  · 已同步过（文件指纹相同），跳过")
            skipped.append(fn)
            continue
        p = probe(src)
        meta = meta_from_tags(p, os.path.splitext(fn)[0])
        # 疑似重复：同标题+歌手且时长差 ≤2s
        k = norm_key(meta["title"], meta["artist"])
        dup = next((t for t in by_key.get(k, []) if abs((t.get("duration") or 0) - p["duration"]) <= 2.0), None)
        if dup and not force:
            print("  ⚠ 疑似重复：已存在《%s — %s》（时长 %.1fs），本次跳过。要强制加入请加 --force"
                  % (dup.get("artist", "?"), dup.get("title", "?"), dup.get("duration", 0)))
            dups.append((fn, dup))
            continue

        key = hashlib.md5((h + fn).encode()).hexdigest()[:12]
        cover = extract_cover(src, key)
        if not cover:
            cover = fetch_cover_online(meta, p["duration"], key)
            if cover:
                print("  · 封面：在线获取")
            else:
                print("  ⚠ 没有封面（文件内嵌无图，在线也没找到），原厂侧会显示空白封面")
        else:
            print("  · 封面：来自文件内嵌")

        rec = {"hash": h, "title": meta["title"], "artist": meta["artist"], "album": meta["album"],
               "track": meta["track"], "year": meta["year"], "genre": meta["genre"],
               "duration": round(p["duration"], 3), "cover": cover,
               "bitrate": p["bitrate"], "added": time.strftime("%Y-%m-%d %H:%M:%S")}
        try:
            if mode == "alac":
                rel, br = sync_alac_single(src, p, meta, cover, mount, dry)
                rec["rockbox_path"] = rel
                rec["apple_path"] = rel
                rec["bitrate"] = br
                print("  ✓ ALAC: %s" % rel)
                lrc_src = os.path.splitext(src)[0] + ".lrc"
                if os.path.exists(lrc_src) and not dry:
                    lrc_rel = os.path.splitext(rel)[0] + ".lrc"
                    shutil.copyfile(lrc_src, os.path.join(mount, lrc_rel.lstrip("/")))
                    rec["lrc"] = True
                    rec["lrc_rel"] = lrc_rel
                    print("    ↩ 歌词: %s" % lrc_rel)
            elif targets.get("rockbox"):
                rec["rockbox_path"] = sync_rockbox(src, p, meta, cover, mount, dry)
                print("  ✓ Rockbox: %s" % rec["rockbox_path"])
                lrc_src = os.path.splitext(src)[0] + ".lrc"
                if os.path.exists(lrc_src) and not dry:
                    lrc_rel = os.path.splitext(rec["rockbox_path"])[0] + ".lrc"
                    shutil.copyfile(lrc_src, os.path.join(mount, lrc_rel.lstrip("/")))
                    rec["lrc"] = True
                    rec["lrc_rel"] = lrc_rel
                    print("    ↩ 歌词: %s" % lrc_rel)
            if targets.get("apple") and mode != "alac":
                rec["apple_path"], rec["bitrate"] = sync_apple(src, p, meta, cover, mount, dry, cfg)
                print("  ✓ 原厂镜像: %s" % rec["apple_path"])
            st["tracks"].append(rec)
            known_hash[h] = rec                      # 本次批次内也参与查重
            by_key.setdefault(k, []).append(rec)
            if not dry:
                save_state(st)
            added.append(fn)
            synced_srcs.append(src)
        except Exception as e:  # noqa: BLE001
            print("  ✗ 失败：%s" % str(e)[:200])
            fails.append((fn, str(e)[:120]))

    if targets.get("apple") and not dry and added:
        print("\n更新原厂 iTunesDB / ArtworkDB …")
        rebuild_apple(st, mount, dry)

    # 同步成功后清理收件箱（源文件 + 歌词 + 预生成的原厂镜像）
    if synced_srcs and not dry and cfg.get("clean_inbox", True) and not keep_inbox:
        cleaned = 0
        for src in synced_srcs:
            base = os.path.splitext(src)[0]
            for extra in (src, base + ".lrc",
                          os.path.join(os.path.dirname(src), ".ipod-sync-cache",
                                       os.path.basename(base) + ".mp3")):
                if os.path.exists(extra):
                    try:
                        os.remove(extra)
                        cleaned += 1
                    except OSError as e:
                        print("  ! 无法删除 %s：%s" % (extra, e))
        side = os.path.join(cfg["inbox"], ".ipod-sync-cache")
        try:
            if os.path.isdir(side) and not os.listdir(side):
                os.rmdir(side)
        except OSError:
            pass
        print("  ✓ 已清理收件箱源文件（%d 个，含歌词/镜像缓存）" % cleaned)

    print("\n===== 结果 =====")
    print("新增 %d，跳过(已存在) %d，疑似重复 %d，失败 %d" % (len(added), len(skipped), len(dups), len(fails)))
    for d in dups:
        print("  重复: %s  ≈《%s — %s》" % (d[0], d[1].get("artist", "?"), d[1].get("title", "?")))
        print("DUP:%s\t%s\t%s" % (d[0], d[1].get("artist", ""), d[1].get("title", "")))
    for f in fails:
        print("  失败: %s — %s" % f)
    if added:
        print("\n下一步：安全推出后重启 iPod（原生固件按住 Menu 约 1 秒进入；CrazyPod 直接开机即可）。")
    if not dry and (added or removed) and mount:
        refresh_crazypod_cache(mount, dry)

    if (cfg.get("eject_after_sync") or eject) and not dry and added:
        subprocess.run(["diskutil", "eject", mount], check=False)
    return 1 if fails else 0


def sync_alac_single(src, p, meta, cover, mount, dry):
    """把源文件转成 16/44.1 ALAC 放进 iPod_Control/Music/F00（原厂可播，Rockbox 曲库也扫描该目录）。"""
    mdir = os.path.join(mount, "iPod_Control", "Music", "F00")
    os.makedirs(mdir, exist_ok=True)
    name = safe_name("%s - %s" % (meta["artist"] or "Unknown Artist", meta["title"]))
    rel = "/iPod_Control/Music/F00/" + name + ".m4a"
    dst = os.path.join(mdir, name + ".m4a")
    n = 2
    while os.path.exists(dst):
        dst = os.path.join(mdir, "%s (%d).m4a" % (name, n))
        rel = "/iPod_Control/Music/F00/%s (%d).m4a" % (name, n)
        n += 1
    if dry:
        return rel, int(p.get("bitrate") or 0)

    # 已经是最优规格的 ALAC（16bit/44.1kHz）时直接拷贝
    if (p.get("codec") == "alac" and int(p.get("sr") or 0) == 44100
            and int(p.get("bits") or 0) <= 16):
        shutil.copy2(src, dst)
        size = os.path.getsize(dst)
        dur = p.get("duration") or 0
        return rel, (int(size * 8 / dur) if dur else 0)

    aiff = os.path.join(WORK, "alac_in.aiff")
    tmp_m4a = os.path.join(WORK, "alac_out.m4a")
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src,
                        "-c:a", "pcm_s16be", "-ar", "44100", "-ac", "2", aiff],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("ffmpeg 解码失败：%s" % r.stderr.strip()[:160])
    r = subprocess.run(["afconvert", "-f", "m4af", "-d", "alac", aiff, tmp_m4a],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(tmp_m4a):
        raise RuntimeError("afconvert 失败：%s" % (r.stderr or r.stdout).strip()[:160])
    # 写标签 + 封面
    try:
        from mutagen.mp4 import MP4, MP4Cover
        m = MP4(tmp_m4a)
        if meta.get("title"):
            m["\xa9nam"] = [meta["title"]]
        if meta.get("artist"):
            m["\xa9ART"] = [meta["artist"]]
        if meta.get("album"):
            m["\xa9alb"] = [meta["album"]]
        if meta.get("genre"):
            m["\xa9gen"] = [meta["genre"]]
        if meta.get("year"):
            m["\xa9day"] = [str(meta["year"])]
        if meta.get("track"):
            try:
                m["trkn"] = [(int(meta["track"]), 0)]
            except (TypeError, ValueError):
                pass
        if cover and os.path.exists(cover):
            data = open(cover, "rb").read()
            fmt = MP4Cover.FORMAT_PNG if cover.lower().endswith(".png") else MP4Cover.FORMAT_JPEG
            m["covr"] = [MP4Cover(data, imageformat=fmt)]
        m.save()
    except Exception as e:  # noqa: BLE001
        print("  ! ALAC 写标签失败：%s" % e)
    shutil.copy2(tmp_m4a, dst)
    size = os.path.getsize(dst)
    dur = p.get("duration") or 0
    bitrate = int(size * 8 / dur) if dur else 0
    try:
        os.remove(aiff)
        os.remove(tmp_m4a)
    except OSError:
        pass
    return rel, bitrate


def sync_rockbox(src, p, meta, cover, mount, dry):
    mdir = os.path.join(mount, "Music")
    os.makedirs(mdir, exist_ok=True)
    dst_ext = ".mp3" if p["codec"] == "mp3" else ".flac"
    name = safe_name("%s - %s" % (meta["artist"] or "Unknown Artist", meta["title"]))
    dst = os.path.join(mdir, name + dst_ext)
    n = 2
    while os.path.exists(dst):
        dst = os.path.join(mdir, "%s (%d)%s" % (name, n, dst_ext))
        n += 1
    if dry:
        return "/Music/" + os.path.basename(dst)
    if not needed_transcode(p, "rockbox"):
        shutil.copy2(src, dst)
    else:
        transcode(src, dst, "flac")
    it._tag_file(dst, meta, cover)
    return "/Music/" + os.path.basename(dst)


def sync_apple(src, p, meta, cover, mount, dry, cfg):
    mdir = os.path.join(mount, "iPod_Control", "Music", "F00")
    sidecar = os.path.join(os.path.dirname(src), ".ipod-sync-cache",
                           os.path.splitext(os.path.basename(src))[0] + ".mp3")
    os.makedirs(mdir, exist_ok=True)
    name = safe_name("%s - %s" % (meta["artist"] or "Unknown Artist", meta["title"]))
    dst = os.path.join(mdir, name + ".mp3")
    n = 2
    while os.path.exists(dst):
        dst = os.path.join(mdir, "%s (%d).mp3" % (name, n))
        n += 1
    bitrate = "320k"
    if dry:
        return ("/iPod_Control/Music/F00/" + os.path.basename(dst)), 320000
    if os.path.exists(sidecar) and os.path.getmtime(sidecar) >= os.path.getmtime(src):
        shutil.copy2(sidecar, dst)
        return ("/iPod_Control/Music/F00/" + os.path.basename(dst)), 320000
    if p["codec"] == "mp3" and not needed_transcode(p, "apple"):
        shutil.copy2(src, dst)
        bitrate = str(p["bitrate"] or 320000)
    else:
        transcode(src, dst, "mp3", cfg.get("apple_bitrate", "320k"))
        bitrate = str(int(str(cfg.get("apple_bitrate", "320k")).rstrip("k")) * 1000)
    it._tag_file(dst, meta, cover)
    return ("/iPod_Control/Music/F00/" + os.path.basename(dst)), int(bitrate)


# ---------------------------------------------------------------- 命令
COVER_CACHE = os.path.join(os.environ.get("IPODSYNC_HOME", HERE), "covercache")


def cover_for(src: str) -> str:
    """把音频内嵌封面导出成 jpg 缓存文件，返回路径（没有封面返回空串）。"""
    if not src or not os.path.exists(src):
        return ""
    try:
        st = os.stat(src)
        key = hashlib.md5(("%s|%d|%d" % (src, st.st_size, int(st.st_mtime))).encode()).hexdigest()
    except OSError:
        return ""
    out = os.path.join(COVER_CACHE, key + ".jpg")
    if os.path.exists(out):
        return out
    try:
        os.makedirs(COVER_CACHE, exist_ok=True)
    except OSError:
        return ""
    tmp = out + ".tmp"
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src,
                        "-map", "0:v?", "-c:v", "mjpeg", "-frames:v", "1", "-an",
                        "-f", "mjpeg", tmp],
                       capture_output=True)
    if r.returncode == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
        os.replace(tmp, out)
        return out
    try:
        os.remove(tmp)
    except OSError:
        pass
    return ""


def external_disks():
    """列出外接物理盘标识（disk4 等）。"""
    try:
        out = subprocess.run(["diskutil", "list"], capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return []
    ids = []
    for line in out.splitlines():
        if line.startswith("/dev/") and "external" in line:
            ids.append(line.split()[0].replace("/dev/", "").rstrip(":"))
    return ids


def ipod_media_name(disk_id: str) -> str:
    try:
        out = subprocess.run(["diskutil", "info", "/dev/" + disk_id],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return ""
    for line in out.splitlines():
        if "Device / Media Name:" in line:
            return line.split(":", 1)[1].strip()
    return ""


def find_attached_ipod():
    """返回 (disk_id, media_name)；设备已插着但未挂载时也能发现。"""
    for disk_id in external_disks():
        name = ipod_media_name(disk_id)
        if "ipod" in name.lower():
            return disk_id, name
    return "", ""


def cmd_refresh_crazypod(args):
    cfg = load_cfg()
    mount = find_mount(cfg)
    if not mount:
        print(json.dumps({"ok": False, "error": "iPod 未连接"}, ensure_ascii=False))
        return 2
    done = refresh_crazypod_cache(mount, dry=args.dry_run)
    print(json.dumps({"ok": True, "refreshed": done, "mount": mount}, ensure_ascii=False))
    return 0


def cmd_eject(args):
    """安全推出 iPod：优先整盘 eject，失败降级为卸载；返回是否已真正弹出。"""
    cfg = load_cfg()
    mount = find_mount(cfg)
    disk_id, media = find_attached_ipod()
    if not mount and not disk_id:
        print(json.dumps({"ok": False, "attached": False, "ejected": False,
                          "error": "iPod 未连接"}, ensure_ascii=False))
        return 2
    if mount and not (os.path.isdir(os.path.join(mount, "iPod_Control"))
                      or os.path.isdir(os.path.join(mount, ".rockbox"))):
        print(json.dumps({"ok": False, "attached": True, "ejected": False,
                          "error": "该卷不像 iPod，已拒绝推出"}, ensure_ascii=False))
        return 2

    log = []
    # 1) 整盘 eject（最彻底，设备会断电，可拔线）
    if disk_id:
        r = subprocess.run(["diskutil", "eject", "/dev/" + disk_id],
                           capture_output=True, text=True, timeout=120)
        log.append((r.stderr or r.stdout or "").strip())
        if r.returncode == 0:
            time.sleep(0.5)
            if not find_attached_ipod()[0]:
                print(json.dumps({"ok": True, "attached": False, "ejected": True}, ensure_ascii=False))
                return 0
    # 2) 按卷 eject
    if mount:
        r = subprocess.run(["diskutil", "eject", mount], capture_output=True, text=True, timeout=120)
        log.append((r.stderr or r.stdout or "").strip())
        if r.returncode == 0:
            time.sleep(0.5)
            if not find_attached_ipod()[0]:
                print(json.dumps({"ok": True, "attached": False, "ejected": True}, ensure_ascii=False))
                return 0
    # 3) 降级：只卸载卷（设备仍连接）
    if mount:
        r = subprocess.run(["diskutil", "unmount", mount], capture_output=True, text=True, timeout=120)
        log.append((r.stderr or r.stdout or "").strip())
        if r.returncode == 0:
            still = find_attached_ipod()[0]
            print(json.dumps({"ok": True, "attached": bool(still), "ejected": False,
                              "note": "已卸载，但设备仍未弹出（可拔线）"}, ensure_ascii=False))
            return 0
    err = "；".join(x for x in log if x) or "推出失败"
    print(json.dumps({"ok": False, "attached": bool(find_attached_ipod()[0]), "ejected": False,
                      "error": err[:300]}, ensure_ascii=False))
    return 1


def cmd_mount(args):
    """把已连接但未挂载的 iPod 重新挂载。"""
    disk_id, _media = find_attached_ipod()
    if not disk_id:
        print(json.dumps({"ok": False, "error": "iPod 未连接"}, ensure_ascii=False))
        return 2
    r = subprocess.run(["diskutil", "mountDisk", "/dev/" + disk_id],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        r = subprocess.run(["diskutil", "mount", "/dev/" + disk_id + "s1"],
                           capture_output=True, text=True, timeout=120)
    if r.returncode == 0:
        print(json.dumps({"ok": True, "mount": find_mount(load_cfg())}, ensure_ascii=False))
        return 0
    print(json.dumps({"ok": False, "error": (r.stderr or r.stdout or "挂载失败").strip()[:300]},
                     ensure_ascii=False))
    return 1


def refresh_crazypod_cache(mount: str, dry: bool = False) -> bool:
    """CrazyPod UI 有自己的音乐库缓存（.crazypod/cache/music-library.bin），
    新增/删除歌曲后必须清掉，否则 Rockbox 里看不到变化；下次开机会自动重建。"""
    cache_dir = os.path.join(mount, ".crazypod", "cache")
    lib = os.path.join(cache_dir, "music-library.bin")
    art = os.path.join(cache_dir, "artwork.ready")
    if not os.path.exists(lib):
        return False
    if dry:
        print("  [dry] 将重置 CrazyPod 音乐库缓存")
        return True
    try:
        bak_dir = os.path.join(HERE, "sync-work", "crazypod-cache-backup")
        os.makedirs(bak_dir, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(lib, os.path.join(bak_dir, "music-library.%s.bin" % stamp))
        os.remove(lib)
        if os.path.exists(art):
            os.remove(art)
        print("  ✓ 已重置 CrazyPod 音乐库缓存（下次开机自动重建，新歌会出现）")
        return True
    except OSError as e:
        print("  ! 重置 CrazyPod 缓存失败：%s" % e)
        return False


def _is_junk_track(t: dict) -> bool:
    if (t.get("title") or "").startswith("._"):
        return True
    for k in ("rockbox_path", "apple_path"):
        base = (t.get(k) or "").split("/")[-1]
        if base.startswith("._"):
            return True
    return False


def cmd_pending(args):
    """列出收件箱里的曲目及同步状态（供 GUI 选择同步）。"""
    cfg = load_cfg()
    st = load_state()
    before = len(st["tracks"])
    st["tracks"] = [t for t in st["tracks"] if not _is_junk_track(t)]
    if len(st["tracks"]) != before:
        save_state(st)
        print("已清理 %d 条 ._ 垃圾记录" % (before - len(st["tracks"])), file=sys.stderr)
    mount = find_mount(cfg)
    if not st["tracks"] and mount:
        n = bootstrap_state(st, mount, cfg.get("library_mode", "alac"))
        if n:
            save_state(st)
    known_hash = {t["hash"] for t in st["tracks"] if t.get("hash")}
    by_key = {}
    for t in st["tracks"]:
        by_key.setdefault(norm_key(t.get("title", ""), t.get("artist", "")), []).append(t)

    files = []
    for dp, dns, fns in os.walk(cfg["inbox"]):
        dns[:] = [d for d in dns if not d.startswith(".")]
        for fn in sorted(fns):
            if fn.startswith(".") or fn.startswith("._"):
                continue
            if os.path.splitext(fn)[1].lower() in AUDIO_EXT:
                files.append(os.path.join(dp, fn))

    items = []
    for src in files:
        try:
            h = md5(src)
            p = probe(src)
        except Exception:
            continue
        meta = meta_from_tags(p, os.path.splitext(os.path.basename(src))[0])
        status = "new"
        if h in known_hash:
            status = "synced"
        else:
            k = norm_key(meta["title"], meta["artist"])
            if any(abs((t.get("duration") or 0) - p["duration"]) <= 2.0 for t in by_key.get(k, [])):
                status = "duplicate"
        items.append({
            "path": os.path.abspath(src),
            "name": os.path.basename(src),
            "title": meta["title"] or os.path.splitext(os.path.basename(src))[0],
            "artist": meta["artist"] or "未知歌手",
            "album": meta["album"] or "未知专辑",
            "duration": round(p["duration"], 3),
            "status": status,
            "cover": cover_for(src),
        })
    # 追加：iPod 上现有的曲库（扫描 /Music 与原厂镜像，跳过 ._ 等隐藏文件）
    seen_keys = set()
    for it in items:
        seen_keys.add((norm_key(it["title"], it["artist"]), round(it["duration"])))
    if mount:
        scan_dirs = [os.path.join(mount, "Music"), os.path.join(mount, "iPod_Control", "Music", "F00")]
        for d in scan_dirs:
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                if fn.startswith("."):
                    continue
                fp = os.path.join(d, fn)
                if not os.path.isfile(fp) or os.path.splitext(fn)[1].lower() not in AUDIO_EXT:
                    continue
                try:
                    pr = probe(fp)
                except Exception:
                    continue
                meta = meta_from_tags(pr, os.path.splitext(fn)[0])
                key = (norm_key(meta["title"], meta["artist"]), round(pr["duration"]))
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                items.append({
                    "path": "",
                    "name": "",
                    "title": meta["title"] or os.path.splitext(fn)[0],
                    "artist": meta["artist"] or "未知歌手",
                    "album": meta["album"] or "未知专辑",
                    "duration": round(pr["duration"], 3),
                    "status": "synced",
                    "cover": cover_for(fp),
                })

    # 状态里有、但设备上文件已不存在的曲目（仍显示为已同步，便于对照）
    for t in st["tracks"]:
        if (t.get("title") or "").startswith("._"):
            continue
        key = (norm_key(t.get("title", ""), t.get("artist", "")), round(t.get("duration") or 0))
        if key in seen_keys:
            continue
        seen_keys.add(key)
        cov = ""
        for k in ("rockbox_path", "apple_path"):
            rel = t.get(k)
            if rel and mount:
                cov = cover_for(os.path.join(mount, rel.lstrip("/")))
                if cov:
                    break
        items.append({
            "path": "",
            "name": "",
            "title": t.get("title") or "",
            "artist": t.get("artist") or "未知歌手",
            "album": t.get("album") or "未知专辑",
            "duration": t.get("duration") or 0,
            "status": "synced",
            "cover": cov,
        })

    # 未同步排前面
    order = {"new": 0, "duplicate": 1, "synced": 2}
    items.sort(key=lambda x: (order.get(x["status"], 3), x["title"].lower()))

    json_out = {"ok": True, "mounted": bool(mount), "items": items}
    if getattr(args, "json", False):
        print("PENDING_JSON:" + json.dumps(json_out, ensure_ascii=False))
    else:
        for it in items:
            print("%-8s %-40s %-24s %s" % (it["status"], it["title"][:40], it["artist"][:24], it["album"][:30]))
        print("共 %d 首" % len(items))
    return 0


def cmd_prune(args):
    """清理：已被删除的曲目（文件不在了）与 iPod 上的孤儿文件。"""
    cfg = load_cfg()
    st = load_state()
    mount = find_mount(cfg)
    if not mount:
        print("PRUNE_JSON:" + json.dumps({"ok": False, "error": "iPod 未连接"}, ensure_ascii=False))
        return 2
    if not st["tracks"]:
        n = bootstrap_state(st, mount, cfg.get("library_mode", "alac"))
        if n:
            save_state(st)

    refs = set()
    kept = []
    dead = []
    changed = False
    for t in st["tracks"]:
        missing = []
        for key in ("rockbox_path", "apple_path"):
            rel = t.get(key)
            if not rel:
                continue
            full = os.path.join(mount, rel.lstrip("/"))
            if os.path.exists(full):
                refs.add(os.path.normpath(full))
                sib = os.path.splitext(full)[0] + ".lrc"
                if os.path.exists(sib):
                    refs.add(os.path.normpath(sib))
            else:
                missing.append(key)
        if missing:
            changed = True
            for key in missing:
                t.pop(key, None)
        if t.get("rockbox_path") or t.get("apple_path"):
            kept.append(t)
        else:
            dead.append(t)

    # iPod 上实际存在但不在状态里的文件 = 孤儿
    orphans = []
    for base in ("Music", "iPod_Control/Music"):
        root = os.path.join(mount, base)
        if not os.path.isdir(root):
            continue
        for dp, _dn, fns in os.walk(root):
            for fn in fns:
                if fn.startswith("."):
                    continue
                if os.path.splitext(fn)[1].lower() not in (AUDIO_EXT | {".lrc"}):
                    continue
                full = os.path.normpath(os.path.join(dp, fn))
                if full not in refs:
                    orphans.append(full)

    def rel(p):
        return "/" + os.path.relpath(p, mount)

    print("已删除的曲目（从状态中移除）：%d 首" % len(dead))
    for t in dead:
        print("  - %s — %s" % (t.get("artist", "?"), t.get("title", "?")))
    print("缺失文件的分支已清理：%d 首" % (0 if not changed else 1))
    print("孤儿文件：%d 个" % len(orphans))
    for p in orphans:
        print("  - %s (%s)" % (rel(p), it.human(os.path.getsize(p))))

    removed_files = 0
    if args.yes and orphans:
        for p in orphans:
            try:
                os.remove(p)
                removed_files += 1
            except OSError:
                pass
        print("已删除孤儿文件 %d 个" % removed_files)

    st["tracks"] = kept
    if not args.dry_run:
        save_state(st)
        if kept and any(t.get("apple_path") for t in kept):
            rebuild_apple(st, mount, False)
    print("PRUNE_JSON:" + json.dumps({
        "ok": True, "dead": len(dead), "orphans": len(orphans),
        "removed_files": removed_files, "remaining": len(kept),
        "dry_run": bool(args.dry_run)}, ensure_ascii=False))
    return 0


MODEL_COLORS = {
    "MB029": "silver", "MB147": "black", "MB150": "silver", "MB145": "black",
    "MB562": "silver", "MB565": "black", "MC293": "silver", "MC297": "black",
    "MA002": "black", "MA147": "black",
}

MODEL_NAMES = {
    "MA002": "iPod classic (6th generation)", "MB147": "iPod classic (6th generation)",
    "MB150": "iPod classic (6th generation)", "MA147": "iPod video (5th generation)",
    "MA448": "iPod video (5th generation)", "MB029": "iPod classic (6th generation)",
    "MA477": "iPod nano (5th generation)", "MB531": "iPod nano (5th generation)",
}


def read_device_info(mount: str) -> dict:
    info = {"model": "iPod", "model_num": "", "rockbox": "", "total": 0, "free": 0,
            "color": "black"}
    sysinfo = os.path.join(mount, "iPod_Control", "Device", "SysInfo")
    try:
        for line in open(sysinfo, encoding="utf-8", errors="replace"):
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            if k.strip().lower() == "modelnumstr":
                info["model_num"] = v.strip()
    except OSError:
        pass
    info["color"] = MODEL_COLORS.get(info["model_num"], "black")
    if info["model_num"]:
        info["model"] = MODEL_NAMES.get(info["model_num"], "iPod (%s)" % info["model_num"])
    rb = os.path.join(mount, ".rockbox", "rockbox-info.txt")
    try:
        for line in open(rb, encoding="utf-8", errors="replace"):
            if line.lower().startswith("version:"):
                info["rockbox"] = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    try:
        usage = shutil.disk_usage(mount)
        info["total"] = usage.total
        info["free"] = usage.free
    except OSError:
        pass
    return info


def cmd_status(args):
    cfg = load_cfg()
    st = load_state()
    mount = find_mount(cfg)
    info = read_device_info(mount) if mount else {"model": "未连接", "model_num": "",
                                                  "rockbox": "", "total": 0, "free": 0}
    disk_id, media = find_attached_ipod()
    files = []
    if os.path.isdir(cfg["inbox"]):
        for dp, dns, fns in os.walk(cfg["inbox"]):
            dns[:] = [d for d in dns if not d.startswith(".")]
            files += [f for f in fns
                      if os.path.splitext(f)[1].lower() in AUDIO_EXT and not f.startswith(".")]

    # 设备曲库曲目数（只数文件，不探测）
    library = 0
    if mount:
        for d in (os.path.join(mount, "Music"), os.path.join(mount, "iPod_Control", "Music", "F00")):
            if os.path.isdir(d):
                library += sum(1 for fn in os.listdir(d)
                               if not fn.startswith(".")
                               and os.path.splitext(fn)[1].lower() in AUDIO_EXT)

    if getattr(args, "json", False):
        print(json.dumps({
            "ok": True,
            "mounted": bool(mount),
            "attached": bool(mount or disk_id),
            "device": disk_id,
            "media": media,
            "mount": mount or "",
            "model": info["model"],
            "model_num": info["model_num"],
            "color": info.get("color", "black"),
            "rockbox": info["rockbox"],
            "total": info["total"],
            "free": info["free"],
            "inbox": cfg["inbox"],
            "inbox_files": len(files),
            "synced": library if mount else len(st["tracks"]),
            "state_tracks": len(st["tracks"]),
            "rockbox_tracks": sum(1 for t in st["tracks"] if t.get("rockbox_path")),
            "apple_tracks": sum(1 for t in st["tracks"] if t.get("apple_path")),
        }, ensure_ascii=False))
        return 0

    print("iPod: %s" % (mount or "未连接"))
    print("收件箱: %s" % cfg["inbox"])
    print("收件箱待处理: %d 个文件" % len(files))
    print("已同步曲目: %d 首（Rockbox %d / 原厂 %d）" % (
        len(st["tracks"]),
        sum(1 for t in st["tracks"] if t.get("rockbox_path")),
        sum(1 for t in st["tracks"] if t.get("apple_path"))))


def main():
    ap = argparse.ArgumentParser(prog="ipodsync", description="iPod 一键增量同步（Rockbox + 原厂）")
    sub = ap.add_subparsers(dest="cmd")
    sp = sub.add_parser("sync", help="扫描收件箱并增量同步")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--force", action="store_true", help="疑似重复也强制加入")
    sp.add_argument("--eject", action="store_true", help="成功后自动推出 iPod")
    sp.add_argument("--only", default=None, help="只同步 JSON 文件里列出的路径")
    sp.add_argument("--keep-inbox", action="store_true", help="同步后保留收件箱源文件")
    sp.set_defaults(func=lambda a: sync(a.dry_run, a.force, getattr(a, "eject", False),
                                          getattr(a, "only", None), getattr(a, "keep_inbox", False)))
    sp = sub.add_parser("status", help="查看状态")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("refresh-crazypod", help="重置 CrazyPod 音乐库缓存")
    sp.add_argument("--dry-run", action="store_true")
    sp.set_defaults(func=cmd_refresh_crazypod)

    sp = sub.add_parser("mount", help="重新挂载已连接的 iPod")
    sp.set_defaults(func=cmd_mount)

    sp = sub.add_parser("eject", help="安全推出 iPod")
    sp.set_defaults(func=cmd_eject)

    sp = sub.add_parser("pending", help="列出收件箱待同步曲目（JSON）")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_pending)

    sp = sub.add_parser("prune", help="清理已删除曲目与孤儿文件")
    sp.add_argument("--yes", action="store_true", help="实际删除孤儿文件（否则只报告）")
    sp.add_argument("--dry-run", action="store_true")
    sp.set_defaults(func=cmd_prune)
    args = ap.parse_args()
    if not getattr(args, "cmd", None):
        args = ap.parse_args(["sync"])
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
