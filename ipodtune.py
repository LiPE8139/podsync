#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipodtune.py — iPod Classic / CrazyPod 音乐整理 & 转码工具
=========================================================
把「重新填歌曲信息 → 超规格转码 → 检索/推荐封面 → 人工复核 → 安全写回」整条流水线封装成 CLI。

子命令：
  scan     扫描目录，探测真实格式/采样率/位深，判定哪些「明显超出 iPod Classic 能力」
  match    联网匹配 标题/歌手/专辑/封面（iTunes + MusicBrainz 交叉核对）
  review   交互式复核：确认或修正歌手/专辑，选择或推荐封面，不确定的当场告诉你
  convert  按复核结果转码 + 写入标签 + 嵌入封面（输出到 work/staging）
  apply    写回：目录 / 原目录 / iPod 卷（安全替换 + MD5 校验 + 清缓存 + 可选推出）
  report   生成中文 Markdown 报告（确定/模糊/未知/缺封面清单 + 推荐封面）
  selftest 用 ffmpeg 现场造测试文件，自检判定与转码链路
  run      scan + match 一条龙（不做交互，适合先看报告）

典型流程：
  python3 ipodtune.py scan   -d /Volumes/IPOD/Music
  python3 ipodtune.py match
  python3 ipodtune.py review          # 交互，逐首确认/改歌手/选封面
  python3 ipodtune.py convert
  python3 ipodtune.py apply --device  # 安全写回 iPod

依赖：ffmpeg/ffprobe（brew install ffmpeg）、mutagen（pip 或 ./bootstrap.sh）
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

# ---------------------------------------------------------------- 依赖加载
def _load_mutagen() -> bool:
    try:
        import mutagen  # noqa: F401
        return True
    except ImportError:
        pass
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.environ.get("IPODTUNE_PYLIB", ""), os.path.join(here, "vendor")):
        if cand and os.path.isdir(cand):
            sys.path.insert(0, cand)
            try:
                import mutagen  # noqa: F401
                return True
            except ImportError:
                continue
    return False


HAS_MUTAGEN = _load_mutagen()
if HAS_MUTAGEN:
    from mutagen.flac import FLAC, Picture
    from mutagen.id3 import ID3, TIT2, TPE1, TPE2, TALB, TRCK, TDRC, TCON, APIC

# ---------------------------------------------------------------- 预设/常量
PRESETS = {
    "flac": {
        "desc": "无损：转 16bit / ≤48kHz FLAC（推荐，CrazyPod 默认）",
        "target_codec": "flac",
        "max_rate": 48000,
        "max_bits": 16,
        "max_size": 4 * 1024 ** 3 - 1,      # FAT32 单文件上限
        "lossless": ("flac", "alac", "wav", "aiff", "ape", "wavpack"),
        "lossy_keep": ("mp3", "aac", "vorbis", "opus"),
    },
    "mp3": {
        "desc": "有损：无损源转 320kbps MP3（更省电/省空间）",
        "target_codec": "mp3",
        "mp3_bitrate": "320k",
        "max_rate": 48000,
        "max_bits": 16,
        "max_size": 4 * 1024 ** 3 - 1,
        "lossless": ("flac", "alac", "wav", "aiff", "ape", "wavpack"),
        "lossy_keep": ("mp3", "aac", "vorbis", "opus"),
    },
}

# ffprobe codec_name → 规范的格式家族
CODEC_FAMILY = {
    "mp3": "mp3", "mp2": "mp3", "mp1": "mp3",
    "flac": "flac",
    "aac": "aac", "alac": "alac",
    "vorbis": "vorbis", "opus": "opus",
    "pcm_s16le": "wav", "pcm_s24le": "wav", "pcm_s32le": "wav", "pcm_u8": "wav",
    "pcm_s16be": "aiff", "pcm_s24be": "aiff",
    "ape": "ape", "wavpack": "wavpack",
    "wmav1": "wma", "wmav2": "wma", "wmapro": "wma",
    "dsd_lsbf": "dsd", "dsd_msbf": "dsd",
}
EXT_FAMILY = {
    ".mp3": "mp3", ".mp2": "mp3",
    ".flac": "flac",
    ".m4a": "aac", ".mp4": "aac", ".aac": "aac",
    ".ogg": "vorbis", ".oga": "vorbis", ".opus": "opus",
    ".wav": "wav", ".aif": "aiff", ".aiff": "aiff",
    ".ape": "ape", ".wv": "wavpack",
    ".wma": "wma", ".dsf": "dsd", ".dff": "dsd",
}
# Rockbox / CrazyPod 自带这些解码器，一般可直接播
ROCKBOX_OK = {"flac", "mp3", "aac", "alac", "vorbis", "opus", "wav", "aiff"}
LOSSLESS = {"flac", "alac", "wav", "aiff", "ape", "wavpack"}
AUDIO_EXT = set(EXT_FAMILY) | {".mka", ".m4b"}
# 明显不是「原曲」的艺人/专辑关键字（翻唱团、伴奏、KTV…）
COVER_ACT_WORDS = (
    "karaoke", "tribute", "made famous", "in the style of", "vitamin string",
    "lullaby", "rockabye", "8-bit", "piano tribute", "string quartet",
    "studio group", "backing track", "instrumental version", "cover band",
)
BAD_ALBUM_WORDS = (
    "soundtrack", "motion picture", "greatest hits", "karaoke", "tribute",
    "instrumental", "remix", "compilation",
)
UA_BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"


# ---------------------------------------------------------------- 小工具
def die(msg: str, code: int = 2):
    print("✗ " + msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, timeout=600) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError("命令失败: %s\n%s" % (" ".join(cmd[:4]), (p.stderr or "").strip()[:400]))
    return p.stdout


def have(exe: str) -> bool:
    return shutil.which(exe) is not None


def norm(s: str) -> str:
    """归一化用于比较：小写、去掉标点/空格，保留中日韩字符。"""
    s = (s or "").lower().replace("\u2019", "'").replace("\u2018", "'")
    return re.sub(r"[^0-9a-z\u3040-\u30ff\u4e00-\u9fff]+", "", s)


def clean_query(title: str) -> str:
    t = re.sub(r"[\(\[].*?[\)\]]", " ", title or "")
    t = t.replace("\u2019", "'").replace("\u2018", "'")
    return re.sub(r"\s+", " ", t).strip() or (title or "")


def strip_edition(album: str) -> str:
    """去掉专辑名尾部的版本后缀：Coming Up (20th Anniversary Edition) → Coming Up"""
    if not album:
        return ""
    a = album.strip()
    while True:
        b = re.sub(r"\s*[\(\[]([^\)\]]*)[\)\]]\s*$", "", a)
        if b == a:
            break
        a = b
    a = re.sub(
        r"\s*-\s*(?:\d+(?:st|nd|rd|th)\s+)?(?:anniversary\s+edition|deluxe(?:\s+edition)?|"
        r"remaster(?:ed)?(?:\s+edition)?|special\s+edition|expanded\s+edition)\s*$",
        "", a, flags=re.I)
    return a.strip()


def md5_file(path: str, chunk=1 << 20) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0
    return str(n)


def now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def http_json(url: str, tries=3, timeout=25):
    last = None
    for _ in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA_BROWSER})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception as e:                       # noqa: BLE001
            last = e
            time.sleep(1.5)
    return {"_error": str(last)}


def http_bytes(url: str, tries=3, timeout=30):
    for _ in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA_BROWSER})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read()
            if data:
                return data
        except Exception:                            # noqa: BLE001
            time.sleep(1.5)
    return None


# ---------------------------------------------------------------- 探测
MAGIC = [
    (b"fLaC", "flac"), (b"ID3", "mp3"), (b"OggS", "ogg"), (b"RIFF", "wav"),
    (b"MAC ", "ape"), (b"wvpk", "wavpack"), (b"FORM", "aiff"), (b"DSD ", "dsd"),
    (b"\xff\xfb", "mp3"), (b"\xff\xf3", "mp3"), (b"\xff\xf2", "mp3"),
]


def magic_family(path: str):
    try:
        with open(path, "rb") as f:
            head = f.read(12)
    except OSError:
        return None
    for sig, fam in MAGIC:
        if head.startswith(sig):
            return fam
    if len(head) >= 8 and head[4:8] == b"ftyp":
        return "m4a"
    return None


def probe_file(path: str) -> dict:
    out = run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path])
    j = json.loads(out or "{}")
    st = j.get("streams") or []
    a = next((s for s in st if s.get("codec_type") == "audio"), {})
    fmt = j.get("format") or {}

    def _int(v):
        try:
            return int(v)
        except (TypeError, ValueError):
            return 0

    codec = (a.get("codec_name") or "").lower()
    fam = CODEC_FAMILY.get(codec, codec or "unknown")
    bits = _int(a.get("bits_per_raw_sample")) or _int(a.get("bits_per_sample"))
    tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    return {
        "codec": codec,
        "family": fam,
        "duration": float(fmt.get("duration") or a.get("duration") or 0),
        "sample_rate": _int(a.get("sample_rate")),
        "bits": bits,
        "channels": _int(a.get("channels")),
        "bitrate": _int(fmt.get("bit_rate") or a.get("bit_rate")),
        "size": os.path.getsize(path),
        "magic": magic_family(path),
        "tags": tags,
    }


def classify(entry: dict, preset: dict) -> list:
    """返回「需要转码」的原因列表；空列表表示只需要补标签/封面。"""
    p, reasons = entry["probe"], []
    fam = p["family"]
    if fam not in ROCKBOX_OK:
        reasons.append(("codec", "格式 %s 不在 CrazyPod 常用解码器内" % (fam or "未知")))
    if p["sample_rate"] > preset["max_rate"]:
        reasons.append(("rate", "采样率 %d Hz 高于 iPod 上限 %d Hz" % (p["sample_rate"], preset["max_rate"])))
    if p["bits"] > preset["max_bits"]:
        reasons.append(("depth", "位深 %d bit 高于 DAC 的 %d bit" % (p["bits"], preset["max_bits"])))
    if p["size"] > preset["max_size"]:
        reasons.append(("size", "单文件 %s 超过 FAT32 限制" % human(p["size"])))
    ext_fam = EXT_FAMILY.get(entry["ext"])
    if ext_fam and fam and ext_fam != fam and not (fam == "aac" and ext_fam in ("aac", "m4a")):
        reasons.append(("mislabel", "扩展名 %s 与真实格式 %s 不符（播放器会按扩展名选解码器，导致识别失败）"
                        % (entry["ext"], fam)))
    if preset["target_codec"] == "mp3" and fam in LOSSLESS:
        reasons.append(("to_mp3", "无损源在 MP3 预设下需转码"))
    return reasons


def cover_dirs_for(args, work: str, st: dict = None) -> list:
    dirs = list(getattr(args, "covers", None) or [])
    if st:
        dirs += [d for d in (st.get("meta", {}).get("cover_dirs") or []) if d]
    dirs.append(os.path.join(work, "local-covers"))
    out = []
    for d in dirs:
        if d and os.path.isdir(d) and d not in out:
            out.append(d)
    return out


def init_local_covers(work: str) -> str:
    lc = os.path.join(work, "local-covers")
    os.makedirs(lc, exist_ok=True)
    note = os.path.join(lc, "PUT-COVERS-HERE.txt")
    if not os.path.exists(note):
        with open(note, "w", encoding="utf-8") as f:
            f.write("把本地封面图片（jpg/png/bmp）放在这个目录，match 时会自动套用。\n"
                    "命名建议（任选其一，文件名只用于匹配，不会写入设备）：\n"
                    "  专辑名.jpg\n  歌手 - 专辑.jpg\n  歌名.jpg\n  歌手 - 歌名.jpg\n"
                    "也可以用 --covers 指定别的文件夹（可重复）。\n")
    return lc


def scan_dir(root: str, preset: dict) -> list:
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        die("目录不存在: %s" % root)
    entries = []
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            ext = os.path.splitext(fn)[1].lower()
            if ext not in AUDIO_EXT or fn.startswith("._"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                p = probe_file(path)
            except Exception as e:                   # noqa: BLE001
                print("  ! 探测失败 %s: %s" % (fn, str(e)[:120]), file=sys.stderr)
                continue
            e = {
                "file": fn,
                "path": path,
                "rel": os.path.relpath(path, root),
                "ext": ext,
                "probe": p,
                "title_guess": os.path.splitext(fn)[0],
                "reasons": [],
                "action": "keep",
                "match": None,
                "cover": None,
                "decision": {"status": "auto"},
            }
            e["reasons"] = classify(e, preset)
            e["action"] = "transcode" if e["reasons"] else "tag"
            entries.append(e)
    return entries


# ---------------------------------------------------------------- iTunes / MusicBrainz
class Net:
    def __init__(self, country="us", enabled=True):
        self.country = country
        self.enabled = enabled
        self.cache = {}
        self.errors = 0

    def _get(self, key, url):
        if not self.enabled:
            return {"results": []}
        if key in self.cache:
            return self.cache[key]
        j = http_json(url)
        if "_error" in j:
            self.errors += 1
            j = {"results": []}
        self.cache[key] = j
        return j

    def songs(self, term, attribute=None, limit=50):
        params = {"term": term, "entity": "song", "limit": limit, "country": self.country}
        if attribute:
            params["attribute"] = attribute
        url = "https://itunes.apple.com/search?" + urllib.parse.urlencode(params)
        return self._get(("song", term, attribute, limit), url).get("results") or []

    def albums(self, term, limit=25):
        url = "https://itunes.apple.com/search?" + urllib.parse.urlencode(
            {"term": term, "entity": "album", "limit": limit, "country": self.country})
        return self._get(("album", term, limit), url).get("results") or []

    def mb_recording(self, title, dur_s):
        if not self.enabled:
            return []
        lo, hi = int(dur_s * 0.97 * 1000), int(dur_s * 1.03 * 1000)
        q = 'recording:"%s" AND dur:[%d TO %d]' % (clean_query(title).replace('"', ""), lo, hi)
        url = "https://musicbrainz.org/ws/2/recording?" + urllib.parse.urlencode(
            {"query": q, "fmt": "json", "limit": 15})
        key = ("mb", q)
        if key in self.cache:
            return self.cache[key]
        j = http_json(url)
        recs = j.get("recordings") or []
        self.cache[key] = recs
        return recs


def cover_act(name: str) -> bool:
    n = (name or "").lower()
    return any(w in n for w in COVER_ACT_WORDS)


def score_candidate(it, title, dur, known_artists):
    t = (it.get("trackTimeMillis") or 0) / 1000.0
    if not t:
        return None
    diff = abs(t - dur)
    if diff > 2.0:                       # 时长硬门限：同名不同版本基本能排除
        return None
    artist = (it.get("artistName") or "").lower()
    album = (it.get("collectionName") or "").lower()
    s = diff
    if norm(it.get("trackName")) != norm(title):
        s += 0.5
    if artist not in known_artists:
        s += 1.2
    if cover_act(artist) or cover_act(album):
        s += 6.0
    if any(w in album for w in BAD_ALBUM_WORDS):
        s += 1.0
    return s, diff


def match_entry(entry: dict, net: Net, known_artists: set) -> None:
    title = entry["title_guess"]
    dur = entry["probe"]["duration"]
    cands = []
    for attr in ("songTerm", None):
        for it in net.songs(clean_query(title), attribute=attr,
                            limit=25 if attr else 50):
            if it.get("kind") != "song":
                continue
            r = score_candidate(it, title, dur, known_artists)
            if r:
                s, diff = r
                cands.append({
                    "score": round(s, 2), "diff": round(diff, 2),
                    "title": it.get("trackName"),
                    "artist": it.get("artistName"),
                    "album": strip_edition(it.get("collectionName") or ""),
                    "album_raw": it.get("collectionName") or "",
                    "track": it.get("trackNumber"),
                    "year": (it.get("releaseDate") or "")[:4],
                    "genre": it.get("primaryGenreName") or "",
                    "trackId": it.get("trackId"),
                    "collectionId": it.get("collectionId"),
                    "art": (it.get("artworkUrl100") or "").replace("100x100bb", "600x600bb"),
                })
        if cands:
            break
        time.sleep(0.25)

    # 去重 + 排序
    seen, uniq = set(), []
    for c in sorted(cands, key=lambda x: x["score"]):
        k = c.get("trackId")
        if k in seen:
            continue
        seen.add(k)
        uniq.append(c)
        if len(uniq) >= 3:
            break

    best = uniq[0] if uniq else None
    if not best:
        conf = "none"
    elif best["diff"] <= 0.8 and norm(best["title"]) == norm(title):
        conf = "high"
    elif best["diff"] <= 2.0:
        conf = "medium"
    else:
        conf = "low"
    entry["match"] = {"candidates": uniq, "best": best, "confidence": conf,
                      "checked_mb": False, "mb_hint": None}
    if best:
        entry["decision"]["title"] = best["title"]
        entry["decision"]["artist"] = best["artist"]
        entry["decision"]["album"] = best["album"]
        entry["decision"]["track"] = best["track"]
        entry["decision"]["year"] = best["year"]
        entry["decision"]["genre"] = best["genre"]
    else:
        entry["decision"].setdefault("title", title)


def mb_crosscheck(entry: dict, net: Net) -> None:
    """对不确定项用 MusicBrainz 交叉核对；无 iTunes 候选时把 MB 结果作为低置信候选。"""
    m = entry.get("match") or {}
    if m.get("checked_mb"):
        return
    m["checked_mb"] = True
    dur = entry["probe"]["duration"]
    if not dur or m.get("confidence") == "high":
        return
    recs = net.mb_recording(entry["title_guess"], dur)
    if not recs:
        return
    qn = norm(clean_query(entry["title_guess"]))

    def title_ok(r):
        rn = norm(r.get("title"))
        return bool(rn) and (rn == qn or rn in qn or qn in rn)

    top = next((r for r in recs if title_ok(r)), None)
    artists = " / ".join(a["artist"]["name"] for a in (top.get("artist-credit") or [])
                         if isinstance(a, dict) and a.get("artist")) if top else ""
    rels = (top.get("releases") or []) if top else []
    length = round((top.get("length") or 0) / 1000.0, 1) if top else 0
    m["mb_hint"] = {"title": top.get("title") if top else "",
                    "artist": artists,
                    "album": (rels[0].get("title") if rels else "") if top else "",
                    "duration": length}

    best = m.get("best")
    if best:
        # 只在 MB 结果标题吻合且时长差 ≤1s 时才认为真的冲突，避免噪声
        if (top and artists and length and abs(length - dur) <= 1.0
                and norm(artists) != norm(best.get("artist"))):
            m["mb_conflict"] = True
        return

    # 没有 iTunes 候选：把 MB 结果转成候选（置信度 low，供人工确认）
    if not top or not artists or not length or abs(length - dur) > 6:
        return
    cand = {"score": round(abs(length - dur), 2), "diff": round(abs(length - dur), 2),
            "title": top.get("title") or entry["title_guess"],
            "artist": artists,
            "album": strip_edition((rels[0].get("title") if rels else "") or ""),
            "album_raw": (rels[0].get("title") if rels else "") or "",
            "track": None, "year": "", "genre": "",
            "trackId": None, "collectionId": None, "art": None, "source": "musicbrainz"}
    m["candidates"] = [cand] + (m.get("candidates") or [])
    m["best"] = cand
    m["confidence"] = "low"
    d = entry["decision"]
    d["title"] = cand["title"]
    d["artist"] = cand["artist"]
    d["album"] = cand["album"]



def do_match(entries: list, net: Net) -> None:
    # 第一轮：无先验收缩，先拿到一批可信匹配，学习本批次的艺人
    for e in entries:
        match_entry(e, net, set())
    known = set()
    for e in entries:
        m = e.get("match") or {}
        b = m.get("best")
        if b and m.get("confidence") == "high" and b["diff"] <= 0.8:
            known.add((b["artist"] or "").lower())
    # 第二轮：用本批次已知艺人提高同名歌曲的命中率
    for e in entries:
        if (e.get("match") or {}).get("confidence") not in ("high",):
            match_entry(e, net, known)
    for e in entries:
        mb_crosscheck(e, net)


# ---------------------------------------------------------------- 封面
def fetch_art(url: str, work: str, key: str):
    if not url:
        return None
    cdir = os.path.join(work, "covers")
    os.makedirs(cdir, exist_ok=True)
    base = os.path.join(cdir, re.sub(r"[^0-9A-Za-z_.-]+", "_", key))
    for ext in (".jpg", ".png"):
        if os.path.exists(base + ext):
            return base + ext
    data = http_bytes(url)
    if not data or len(data) < 1500:
        return None
    ext = ".png" if data[:4] == b"\x89PNG" else ".jpg"
    path = base + ext
    with open(path, "wb") as f:
        f.write(data)
    return path


IMG_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".webp")
_COVER_INDEX_CACHE = {}


def _stem_norm(name: str) -> str:
    return norm(os.path.splitext(os.path.basename(name))[0])


def local_cover_index(dirs):
    """扫描本地封面文件夹，建立「归一化文件名 → 路径」索引。"""
    dirs = tuple(os.path.abspath(d) for d in dirs if d and os.path.isdir(d))
    if dirs in _COVER_INDEX_CACHE:
        return _COVER_INDEX_CACHE[dirs]
    idx = {}
    for d in dirs:
        try:
            for fn in sorted(os.listdir(d)):
                if fn.lower().endswith(IMG_EXT):
                    idx.setdefault(_stem_norm(fn), os.path.join(d, fn))
        except OSError:
            continue
    _COVER_INDEX_CACHE[dirs] = idx
    return idx


def find_local_cover(entry: dict, dirs):
    """按 专辑名 / 歌手 - 专辑 / 歌名 / 歌手 - 歌名 / 文件名 在本地封面夹里找图。"""
    idx = local_cover_index(dirs)
    if not idx:
        return None
    d = entry.get("decision") or {}
    best = (entry.get("match") or {}).get("best") or {}
    artist = (best.get("artist") or d.get("artist") or "").strip()
    album = (best.get("album") or d.get("album") or "").strip()
    album_raw = best.get("album_raw") or ""
    title = (best.get("title") or d.get("title") or entry.get("title_guess") or "").strip()
    keys = []
    for a in (album, album_raw):
        if a:
            keys += [norm(a), norm("%s %s" % (artist, a))]
    if title:
        keys += [norm(title), norm("%s %s" % (artist, title))]
    keys.append(norm(entry.get("title_guess") or ""))
    for k in keys:
        if k and k in idx:
            return idx[k]
    for k in keys:                       # 模糊：唯一包含匹配
        if not k or len(k) < 4:
            continue
        hits = [p for nk, p in idx.items() if k in nk or nk in k]
        if len(hits) == 1:
            return hits[0]
    return None


def local_cover_list(dirs):
    idx = local_cover_index(dirs)
    return [(nk, p) for nk, p in sorted(idx.items())]


def resolve_cover(entry: dict, net: Net, work: str, cover_dirs=None) -> None:
    cover_dirs = cover_dirs or []
    cur = (entry.get("cover") or {}).get("path")
    if cur and os.path.exists(cur):
        return
    # 0) 本地封面文件夹优先（用户自己放的图，命中率最高）
    lp = find_local_cover(entry, cover_dirs)
    if lp:
        entry["cover"] = {"path": lp, "source": "local-folder"}
        return
    m = entry.get("match") or {}
    best = m.get("best")
    if not best:
        entry["cover"] = None
        return
    # 1) 匹配曲目自带的专辑图
    path = fetch_art(best.get("art"), work, "track_%s" % best.get("trackId"))
    if not path:
        # 2) 专辑名精确检索
        for al in net.albums("%s %s" % (best["artist"], best["album"])):
            if norm(al.get("collectionName")) in (norm(best["album"]), norm(best.get("album_raw") or "")):
                path = fetch_art((al.get("artworkUrl100") or "").replace("100x100bb", "600x600bb"),
                                 work, "album_%s" % al.get("collectionId"))
                if path:
                    break
    if not path:
        # 3) 歌曲→专辑反查：Apple 的专辑检索索引常漏专辑，但按艺人搜歌能带出该专辑封面
        want = {norm(best.get("album") or ""), norm(best.get("album_raw") or "")} - {""}
        artist = (best.get("artist") or "").strip()
        if artist and want:
            for it in net.songs(artist, limit=100):
                cn = it.get("collectionName") or ""
                if norm(cn) in want:
                    path = fetch_art((it.get("artworkUrl100") or "").replace("100x100bb", "600x600bb"),
                                     work, "rev_%s" % it.get("collectionId"))
                    if path:
                        break
    entry["cover"] = {"path": path, "source": "itunes" if path else None}


def cover_options(entry: dict, net: Net, cover_dirs=None) -> list:
    """推荐封面：本地封面夹 / 当前封面 / 当前专辑 / 同艺人其它专辑。"""
    cover_dirs = cover_dirs or []
    m = entry.get("match") or {}
    d = entry.get("decision") or {}
    best = m.get("best") or {}
    artist = best.get("artist") or d.get("artist") or ""
    album = best.get("album") or d.get("album") or ""
    opts = []
    for nk, p in local_cover_list(cover_dirs)[:8]:
        opts.append({"label": "本地文件：%s" % os.path.basename(p), "kind": "path", "path": p})
    cur = (entry.get("cover") or {}).get("path")
    if cur:
        opts.insert(0, {"label": "当前已下载的封面", "kind": "path", "path": cur})
    if best.get("art"):
        opts.append({"label": "%s — %s（当前匹配专辑）" % (artist or "?", album or "?"),
                     "kind": "art", "art": best["art"]})
    elif album:
        for al in net.albums(("%s %s" % (artist, album)).strip()):
            cn = al.get("collectionName") or ""
            if norm(cn) == norm(album) or norm(cn) == norm(best.get("album_raw") or ""):
                opts.append({"label": "%s — %s" % (al.get("artistName") or "", cn), "kind": "art",
                             "art": (al.get("artworkUrl100") or "").replace("100x100bb", "600x600bb")})
                break
    if artist:
        seen = set()
        for it in net.songs(artist, limit=100):
            if (it.get("artistName") or "").lower() != artist.lower():
                continue
            cn = it.get("collectionName") or ""
            if not cn or cn in seen:
                continue
            seen.add(cn)
            opts.append({"label": "%s — %s（同艺人，替代）" % (artist, cn), "kind": "art",
                         "art": (it.get("artworkUrl100") or "").replace("100x100bb", "600x600bb")})
            if len(opts) >= 12:
                break
    return opts


def write_report(st: dict, work: str) -> str:
    entries = st["entries"]
    lines = []
    A = lines.append
    A("# iPod 音乐整理报告\n")
    A("- 生成时间：%s" % now())
    A("- 源目录：`%s`" % st["meta"]["root"])
    A("- 目标规格：**%s**" % PRESETS[st["meta"]["preset"]]["desc"])
    A("- 文件数：**%d**\n" % len(entries))

    need_tc = [e for e in entries if e["reasons"]]
    high = [e for e in entries if (e.get("match") or {}).get("confidence") == "high"]
    medium = [e for e in entries if (e.get("match") or {}).get("confidence") == "medium"]
    none = [e for e in entries if (e.get("match") or {}).get("confidence") in ("none", None)]
    no_cover = [e for e in entries if not (e.get("cover") or {}).get("path")]
    conflicts = [e for e in entries if (e.get("match") or {}).get("mb_conflict")]

    A("## 汇总\n")
    A("| 项目 | 数量 |")
    A("| --- | --- |")
    A("| 需要转码/修复 | %d |" % len(need_tc))
    A("| 匹配确定 | %d |" % len(high))
    A("| 匹配存疑（建议复核） | %d |" % len(medium))
    A("| 完全没匹配到 | %d |" % len(none))
    A("| 缺封面 | %d |" % len(no_cover))
    A("| MusicBrainz 与 iTunes 冲突 | %d |" % len(conflicts))
    A("")

    if need_tc:
        A("## 品质超出 iPod Classic 能力（需要转码）\n")
        A("| 文件 | 真实格式 | 采样率 | 位深 | 原因 |")
        A("| --- | --- | --- | --- | --- |")
        for e in need_tc:
            p = e["probe"]
            reasons = "；".join(r[1] for r in e["reasons"])
            A("| `%s` | %s | %s Hz | %s bit | %s |" % (
                e["rel"], p["family"], p["sample_rate"] or "?", p["bits"] or "?", reasons))
        A("")

    A("## 标签匹配结果\n")
    A("| 文件 | 标题 | 歌手 | 专辑 | 置信度 | 时长差 | 封面 |")
    A("| --- | --- | --- | --- | --- | --- | --- |")
    for e in entries:
        d = e.get("decision") or {}
        m = e.get("match") or {}
        b = m.get("best")
        conf = {"high": "确定", "medium": "存疑", "low": "可疑", "none": "无"}.get(
            m.get("confidence"), "-")
        diff = ("%.1fs" % b["diff"]) if b else "-"
        cov = "✓" if (e.get("cover") or {}).get("path") else "✗"
        A("| `%s` | %s | %s | %s | %s | %s | %s |" % (
            e["rel"], d.get("title") or "", d.get("artist") or "", d.get("album") or "",
            conf, diff, cov))
    A("")

    if medium or none or conflicts:
        A("## 需要你确认的（不确定清单）\n")
        for e in medium + none + conflicts:
            m = e.get("match") or {}
            A("### `%s`" % e["rel"])
            A("- 时长：%.2f 秒；候选：%d 个" % (e["probe"]["duration"], len(m.get("candidates") or [])))
            if m.get("mb_hint"):
                h = m["mb_hint"]
                A("- MusicBrainz 提示：%s — %s（%s）" % (h["artist"], h["title"], h.get("album") or "?"))
            if m.get("mb_conflict"):
                A("- ⚠️ **iTunes 与 MusicBrainz 艺人冲突**，请人工确认")
            for i, c in enumerate(m.get("candidates") or [], 1):
                A("  %d. %s — %s（时长差 %.1fs，专辑 %s）" % (
                    i, c["artist"], c["title"], c["diff"], c["album"]))
            if not m.get("candidates"):
                A("  - 没有任何候选，可尝试：`python3 ipodtune.py review` 输入歌手重新检索")
            A("")

    if no_cover:
        A("## 缺封面的曲目\n")
        for e in no_cover:
            A("- `%s`" % e["rel"])
        A("\n> 用 `review` 选择封面时可以：用推荐替代封面、指定本地图片、或跳过。\n")

    out = os.path.join(work, "report.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return out


# ---------------------------------------------------------------- 状态
def work_dir(p: str) -> str:
    p = os.path.abspath(p)
    os.makedirs(p, exist_ok=True)
    return p


def state_path(work: str) -> str:
    return os.path.join(work, "state.json")


def save_state(st: dict, work: str) -> None:
    tmp = state_path(work) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    os.replace(tmp, state_path(work))


def load_state(work: str) -> dict:
    p = state_path(work)
    if not os.path.exists(p):
        die("找不到状态文件 %s，请先运行 scan" % p)
    with open(p, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- scan / match
def cmd_scan(args):
    preset = PRESETS[args.preset]
    root = os.path.abspath(args.dir or find_music_dir())
    entries = scan_dir(root, preset)
    if not entries:
        die("目录里没有音频文件: %s" % root)
    w = work_dir(args.work)
    lc = init_local_covers(w)
    extra = list(getattr(args, "covers", None) or [])
    st = {"meta": {"root": root, "preset": args.preset, "created": now(),
                   "country": args.country, "jobs": args.jobs,
                   "cover_dirs": [lc] + extra},
          "entries": entries}
    save_state(st, w)
    tc = sum(1 for e in entries if e["reasons"])
    print("扫描完成：%d 个音频文件，其中 %d 个需要转码/修复" % (len(entries), tc))
    for e in entries:
        if e["reasons"]:
            print("  ▶ %-52s %s" % (e["rel"][:52], "；".join(r[1] for r in e["reasons"])))
    print("\n状态已写入 %s" % state_path(w))
    print("本地封面夹：%s（把 专辑名.jpg 丢进去即可自动套用）" % lc)
    print("下一步：python3 ipodtune.py match --work %s" % w)


def cmd_match(args):
    if not have("ffprobe"):
        die("缺少 ffprobe，请先 brew install ffmpeg")
    w = work_dir(args.work)
    st = load_state(w)
    cover_dirs = cover_dirs_for(args, w, st)
    st["meta"]["cover_dirs"] = cover_dirs
    net = Net(country=args.country, enabled=not args.no_network)
    if not net.enabled:
        print("（离线模式：跳过联网匹配，只保留文件名为标题）")
        for e in st["entries"]:
            e["match"] = {"candidates": [], "best": None, "confidence": "none"}
            e["decision"]["title"] = e["title_guess"]
    else:
        print("联网匹配 %d 首（iTunes%s）…" % (
            len(st["entries"]), " + MusicBrainz 交叉核对" if not args.no_mb else ""))
        do_match(st["entries"], net)
    for e in st["entries"]:
        resolve_cover(e, net, w, cover_dirs)
    st["meta"]["matched_at"] = now()
    save_state(st, w)
    rep = write_report(st, w)
    high = sum(1 for e in st["entries"] if (e.get("match") or {}).get("confidence") == "high")
    med = sum(1 for e in st["entries"] if (e.get("match") or {}).get("confidence") == "medium")
    none = sum(1 for e in st["entries"] if (e.get("match") or {}).get("confidence") in (None, "none"))
    nocov = sum(1 for e in st["entries"] if not (e.get("cover") or {}).get("path"))
    local_hit = sum(1 for e in st["entries"]
                    if (e.get("cover") or {}).get("source") == "local-folder")
    print("\n匹配完成：确定 %d，存疑 %d，未匹配 %d，缺封面 %d（其中本地封面命中 %d）"
          % (high, med, none, nocov, local_hit))
    print("报告：%s" % rep)
    if med or none or nocov:
        print("建议下一步：python3 ipodtune.py review --work %s" % w)


# ---------------------------------------------------------------- review
CONF_CN = {"high": "确定", "medium": "存疑", "low": "可疑", "none": "未匹配"}


def _needs_review(e: dict, review_all: bool) -> bool:
    m = e.get("match") or {}
    if review_all:
        return True
    return (m.get("confidence") in ("medium", "low", "none", None)
            or m.get("mb_conflict")
            or not (e.get("cover") or {}).get("path")
            or bool(e.get("reasons")))


def _show(entry: dict) -> None:
    p, m = entry["probe"], entry.get("match") or {}
    b = m.get("best")
    print("\n" + "─" * 78)
    print("▶ %s" % entry["rel"])
    print("  时长 %.2fs | %s | %d Hz | %d bit | %s" % (
        p["duration"], p["family"], p["sample_rate"], p["bits"], human(p["size"])))
    if entry["reasons"]:
        print("  ⚙ 需要转码：" + "；".join(r[1] for r in entry["reasons"]))
    if b:
        print("  匹配：%s — %s ｜ 专辑《%s》 ｜ 时长差 %.2fs ｜ 置信 %s" % (
            b["artist"], b["title"], b["album"] or "?", b["diff"], CONF_CN.get(m.get("confidence"), "?")))
    else:
        print("  匹配：无候选（可输入歌手重新检索）")
    if m.get("mb_hint"):
        h = m["mb_hint"]
        print("  MusicBrainz：%s — %s ｜ %s" % (h["artist"], h["title"], h.get("album") or "?"))
    if m.get("mb_conflict"):
        print("  ⚠ iTunes 与 MusicBrainz 艺人冲突，请确认")
    cov = (entry.get("cover") or {}).get("path")
    print("  封面：%s" % ("已获取 ✓" if cov else "缺 ✗"))


def _apply_candidate(entry: dict, c: dict) -> None:
    d = entry["decision"]
    d.update(title=c["title"], artist=c["artist"], album=c["album"],
             track=c.get("track"), year=c.get("year"), genre=c.get("genre"))
    entry["match"]["best"] = c
    entry["match"]["confidence"] = "high"
    entry["cover"] = {"path": None, "source": None}


def _pick_cover(entry: dict, net: Net, w: str, cover_dirs=None) -> None:
    opts = cover_options(entry, net, cover_dirs)
    if not opts:
        print("  没有可推荐的封面。")
        return
    print("\n  封面候选：")
    for i, o in enumerate(opts, 1):
        print("   %d) %s" % (i, o["label"]))
    print("   p) 指定本地图片路径    s) 不要封面    回车) 取消")
    ans = input("  选择: ").strip().lower()
    if ans in ("", "c"):
        return
    if ans == "s":
        entry["cover"] = {"path": None, "source": "skipped"}
        print("  已设为无封面")
        return
    if ans == "p":
        p = input("  图片路径（jpg/png）: ").strip().strip("'\"")
        if p and os.path.exists(p):
            d = os.path.join(w, "covers")
            os.makedirs(d, exist_ok=True)
            dst = os.path.join(d, "custom_" + hashlib.md5(p.encode()).hexdigest()[:10] + os.path.splitext(p)[1])
            shutil.copy2(p, dst)
            entry["cover"] = {"path": dst, "source": "local"}
            print("  已使用本地图片：%s" % dst)
        else:
            print("  路径不存在")
        return
    try:
        o = opts[int(ans) - 1]
    except (ValueError, IndexError):
        print("  无效编号")
        return
    if o["kind"] == "path":
        entry["cover"] = {"path": o["path"], "source": "local"}
        print("  已使用：%s" % o["path"])
        return
    path = fetch_art(o.get("art"), w, "alt_%s" % hashlib.md5(
        (o.get("art") or "").encode()).hexdigest()[:10])
    if path:
        entry["cover"] = {"path": path, "source": "itunes"}
        print("  已使用推荐封面")
    else:
        print("  该封面下载失败")


def cmd_review(args):
    w = work_dir(args.work)
    st = load_state(w)
    cover_dirs = cover_dirs_for(args, w, st)
    net = Net(country=st["meta"].get("country", "us"), enabled=not args.no_network)
    todo = [e for e in st["entries"] if _needs_review(e, args.all)]
    if not todo:
        print("没有需要复核的项目 🎉")
        return
    print("需要复核 %d 首（回车=确认当前结果；a=给歌手重搜；m=手动；c=选封面；s=跳过；q=保存退出）"
          % len(todo))
    changed = False
    for idx, e in enumerate(todo, 1):
        _show(e)
        while True:
            try:
                cmd = input("  [回车]确认 [a]歌手重搜 [m]手动 [c]封面 [s]跳过 [q]退出: ").strip().lower()
            except EOFError:
                cmd = "q"
            if cmd in ("", "y", "yes", "确认"):
                e["decision"]["status"] = "confirmed"
                changed = True
                break
            if cmd == "a":
                artist = input("  正确歌手（可留空只用歌名）: ").strip()
                term = ("%s %s" % (artist, clean_query(e["title_guess"]))).strip()
                cands = []
                for it in net.songs(term, limit=25):
                    if it.get("kind") != "song":
                        continue
                    d = (it.get("trackTimeMillis") or 0) / 1000.0
                    diff = abs(d - e["probe"]["duration"]) if d else 99
                    if diff > 5:
                        continue
                    cands.append({"score": diff, "diff": round(diff, 2), "title": it.get("trackName"),
                                  "artist": it.get("artistName"),
                                  "album": strip_edition(it.get("collectionName") or ""),
                                  "album_raw": it.get("collectionName") or "",
                                  "track": it.get("trackNumber"),
                                  "year": (it.get("releaseDate") or "")[:4],
                                  "genre": it.get("primaryGenreName") or "",
                                  "trackId": it.get("trackId"), "collectionId": it.get("collectionId"),
                                  "art": (it.get("artworkUrl100") or "").replace("100x100bb", "600x600bb")})
                cands.sort(key=lambda x: (x["diff"], 0 if x["artist"].lower() == artist.lower() else 1))
                cands = cands[:8]
                if not cands:
                    # iTunes 没有 → 用 MusicBrainz 按「歌名 + 时长」再找一遍，并按输入歌手过滤
                    mbrecs = net.mb_recording(clean_query(e["title_guess"]), e["probe"]["duration"])
                    for r in mbrecs:
                        arts = " / ".join(a["artist"]["name"] for a in (r.get("artist-credit") or [])
                                          if isinstance(a, dict) and a.get("artist"))
                        ln = (r.get("length") or 0) / 1000.0
                        dur0 = e["probe"]["duration"]
                        if not arts or not ln or abs(ln - dur0) > 6:
                            continue
                        if artist and artist.lower() not in arts.lower():
                            continue
                        rels = r.get("releases") or []
                        cands.append({"score": 0, "diff": round(abs(ln - dur0), 2),
                                      "title": r.get("title") or e["title_guess"], "artist": arts,
                                      "album": strip_edition((rels[0].get("title") if rels else "") or ""),
                                      "album_raw": (rels[0].get("title") if rels else "") or "",
                                      "track": None, "year": "", "genre": "", "trackId": None,
                                      "collectionId": None, "art": None, "source": "musicbrainz"})
                    cands = cands[:8]
                    if not cands:
                        print("  iTunes / MusicBrainz 都没有候选；可以直接用 c 选同艺人封面")
                        continue
                print("  候选：")
                for i, c in enumerate(cands, 1):
                    print("   %d) %s — %s ｜ 《%s》 ｜ Δ%.1fs" % (i, c["artist"], c["title"], c["album"], c["diff"]))
                sel = input("  选择编号（回车取消）: ").strip()
                if sel.isdigit() and 1 <= int(sel) <= len(cands):
                    _apply_candidate(e, cands[int(sel) - 1])
                    e["decision"]["status"] = "confirmed"
                    changed = True
                    resolve_cover(e, net, w, cover_dirs)
                    print("  已应用")
                    _show(e)
                continue
            if cmd == "m":
                print("  留空表示不改")
                for field, label in (("title", "标题"), ("artist", "歌手"), ("album", "专辑"),
                                     ("track", "音轨号"), ("year", "年份"), ("genre", "流派")):
                    cur = e["decision"].get(field) or ""
                    v = input("  %s [%s]: " % (label, cur)).strip()
                    if v:
                        e["decision"][field] = v
                e["decision"]["status"] = "confirmed"
                changed = True
                print("  已更新")
                _show(e)
                continue
            if cmd == "c":
                _pick_cover(e, net, w, cover_dirs)
                changed = True
                continue
            if cmd == "s":
                e["decision"]["status"] = "skipped"
                changed = True
                print("  已跳过（仅做格式修正，不写标签/封面）")
                break
            if cmd == "q":
                save_state(st, w)
                print("已保存，退出复核。")
                return
            print("  无效输入")
    save_state(st, w)
    rep = write_report(st, w)
    print("\n复核完成，报告已更新：%s" % rep)


# ---------------------------------------------------------------- convert
def _target_ext(preset: dict, entry: dict) -> str:
    fam = entry["probe"]["family"]
    if preset["target_codec"] == "mp3":
        return ".mp3"
    if fam in ("mp3",):
        return ".mp3"
    return ".flac"


def _tag_file(path: str, meta: dict, cover: str | None) -> None:
    if not HAS_MUTAGEN:
        return
    if path.lower().endswith(".flac"):
        a = FLAC(path)
        a.delete()
        a["TITLE"] = meta["title"] or ""
        if meta.get("artist"):
            a["ARTIST"] = meta["artist"]
            a["ALBUMARTIST"] = meta["artist"]
        if meta.get("album"):
            a["ALBUM"] = meta["album"]
        if meta.get("track"):
            a["TRACKNUMBER"] = str(meta["track"])
        if meta.get("year"):
            a["DATE"] = str(meta["year"])
        if meta.get("genre"):
            a["GENRE"] = meta["genre"]
        if cover:
            try:
                a.clear_pictures()      # 用新图替换旧内嵌图，避免叠加
            except AttributeError:
                pass
            pic = Picture()
            pic.type = 3
            pic.mime = "image/png" if cover.lower().endswith(".png") else "image/jpeg"
            pic.desc = "Cover"
            with open(cover, "rb") as f:
                pic.data = f.read()
            a.add_picture(pic)
        a.save()
    elif path.lower().endswith(".mp3"):
        try:
            t = ID3(path)
        except Exception:                            # noqa: BLE001
            t = ID3()
        for k in list(t.keys()):
            del t[k]
        t.add(TIT2(encoding=3, text=meta["title"] or ""))
        if meta.get("artist"):
            t.add(TPE1(encoding=3, text=meta["artist"]))
            t.add(TPE2(encoding=3, text=meta["artist"]))
        if meta.get("album"):
            t.add(TALB(encoding=3, text=meta["album"]))
        if meta.get("track"):
            t.add(TRCK(encoding=3, text=str(meta["track"])))
        if meta.get("year"):
            t.add(TDRC(encoding=3, text=str(meta["year"])))
        if meta.get("genre"):
            t.add(TCON(encoding=3, text=meta["genre"]))
        if cover:
            with open(cover, "rb") as f:
                data = f.read()
            t.add(APIC(encoding=3,
                       mime="image/png" if cover.lower().endswith(".png") else "image/jpeg",
                       type=3, desc="Cover", data=data))
        t.save()


def convert_entry(entry: dict, preset: dict, staging: str, dry: bool) -> dict:
    src = entry["path"]
    meta = dict(entry.get("decision") or {})
    meta.setdefault("title", entry["title_guess"])
    if meta.get("status") == "skipped":
        meta = {"title": entry["title_guess"], "artist": "", "album": "", "track": None,
                "year": "", "genre": ""}
    cover = (entry.get("cover") or {}).get("path")
    ext = _target_ext(preset, entry)
    out = os.path.join(staging, os.path.splitext(os.path.basename(entry["file"]))[0] + ext)
    os.makedirs(staging, exist_ok=True)
    if dry:
        return {"out": out, "action": entry["action"], "ok": True, "dry": True}

    need_tc = entry["action"] == "transcode" or _needs_format(entry, ext, preset)
    if need_tc:
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src, "-map", "0:a"]
        rate = entry["probe"]["sample_rate"]
        if preset["target_codec"] == "mp3":
            cmd += ["-c:a", "libmp3lame", "-b:a", preset.get("mp3_bitrate", "320k")]
            if rate and rate > preset["max_rate"]:
                cmd += ["-ar", str(preset["max_rate"])]
        else:
            cmd += ["-c:a", "flac", "-sample_fmt", "s16", "-compression_level", "5"]
            if rate and rate > preset["max_rate"]:
                cmd += ["-ar", "44100"]
            else:
                cmd += ["-ar", str(rate or 44100)]
        tmp = out + ".part"
        fmt = "mp3" if preset["target_codec"] == "mp3" else "flac"
        run(cmd + ["-f", fmt, tmp])
        os.replace(tmp, out)
    else:
        shutil.copy2(src, out)
    _tag_file(out, meta, cover)
    return {"out": out, "action": "transcode" if need_tc else "copy", "ok": True}


def _needs_format(entry: dict, ext: str, preset: dict) -> bool:
    fam = entry["probe"]["family"]
    want = "mp3" if ext == ".mp3" else "flac"
    if fam != want:
        return True
    if fam in LOSSLESS and entry["probe"]["bits"] > preset["max_bits"]:
        return True
    return False


def cmd_convert(args):
    preset = PRESETS[args.preset or "flac"]
    w = work_dir(args.work)
    st = load_state(w)
    if args.preset:
        st["meta"]["preset"] = args.preset
    staging = os.path.join(w, "staging")
    os.makedirs(staging, exist_ok=True)
    todo = st["entries"][: args.limit] if args.limit else st["entries"]
    print("转码 %d 个文件 → %s（预设：%s）" % (len(todo), staging, preset["desc"]))
    ok = fail = 0
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(convert_entry, e, preset, staging, args.dry_run): e for e in todo}
        for fut, e in list(futs.items()):
            try:
                r = fut.result()
                ok += 1
                results.append((e, r))
                print("  ✓ %-55s %s" % (e["rel"][:55], r["action"]))
            except Exception as ex2:                 # noqa: BLE001
                fail += 1
                print("  ✗ %-55s %s" % (e["rel"][:55], str(ex2)[:140]))
    st["meta"]["converted_at"] = now()
    st["meta"]["staging"] = staging
    st["results"] = [{"rel": e["rel"], "out": r["out"], "action": r["action"]} for e, r in results]
    save_state(st, w)
    total = sum(os.path.getsize(os.path.join(staging, f))
                for f in os.listdir(staging)) if os.path.isdir(staging) else 0
    print("\n完成：成功 %d，失败 %d；staging 共 %d 个文件 / %s" % (
        ok, fail, len(os.listdir(staging)), human(total)))
    if fail == 0:
        print("下一步：python3 ipodtune.py apply --device   （或 --to <目标目录>）")


# ---------------------------------------------------------------- apply
def find_music_dir() -> str:
    for cand in sorted(glob.glob("/Volumes/*")):
        base = os.path.basename(cand)
        if base in ("Macintosh HD", "Recovery"):
            continue
        for sub in ("Music", ""):
            p = os.path.join(cand, sub) if sub else cand
            if os.path.isdir(p) and (os.path.isdir(os.path.join(cand, ".rockbox"))
                                     or os.path.isdir(os.path.join(cand, "iPod_Control"))):
                return p
    die("没找到 iPod 卷，请用 -d 指定 Music 目录")


def _copy_verify(files, src_dir, dst_dir, dry) -> tuple:
    ok = bad = 0
    for f in files:
        s = os.path.join(src_dir, f)
        d = os.path.join(dst_dir, f)
        if dry:
            print("  [dry] %s → %s" % (s, d))
            ok += 1
            continue
        shutil.copy2(s, d)
        if md5_file(s) == md5_file(d):
            ok += 1
        else:
            bad += 1
            print("  ✗ MD5 不一致: %s" % f)
    return ok, bad


def cmd_apply(args):
    w = work_dir(args.work)
    st = load_state(w)
    staging = st["meta"].get("staging") or os.path.join(w, "staging")
    if not os.path.isdir(staging) or not os.listdir(staging):
        die("staging 为空，请先运行 convert")
    files = sorted(os.listdir(staging))
    if args.to:
        target, mode = os.path.abspath(args.to), "dir"
    elif args.device:
        target, mode = find_music_dir(), "device"
    elif args.inplace:
        target, mode = st["meta"]["root"], "inplace"
    else:
        die("请指定 --to <目录> 或 --device 或 --inplace")
    print("写回模式：%s → %s" % ({"dir": "目录", "device": "iPod 卷", "inplace": "原目录"}[mode], target))
    if mode == "dir":
        os.makedirs(target, exist_ok=True)
    need = sum(os.path.getsize(os.path.join(staging, f)) for f in files)
    free = shutil.disk_usage(target).free
    print("本次写入 %s，目标剩余 %s" % (human(need), human(free)))
    if need * 1.1 > free:
        die("空间不足：需要约 %s，目标只剩 %s" % (human(need * 1.1), human(free)))
    if mode == "device":
        try:
            info = run(["diskutil", "info", target])
            if "FAT32" not in info and "MS-DOS" not in info:
                print("⚠ 目标卷似乎不是 FAT32（Rockbox/CrazyPod 需要 FAT32），请先确认")
        except Exception:                            # noqa: BLE001
            pass
    if args.dry_run:
        _copy_verify(files, staging, target, True)
        return

    if mode == "inplace" and args.backup:
        bk = os.path.join(w, "originals", datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.makedirs(bk, exist_ok=True)
        for e in st["entries"]:
            if os.path.exists(e["path"]):
                shutil.copy2(e["path"], os.path.join(bk, e["file"]))
        print("原文件已备份到 %s" % bk)

    if mode in ("device", "inplace"):
        # 安全路径：先拷到临时目录 → 校验 → 再替换
        tmpdir = os.path.join(target, ".ipodtune-new")
        if os.path.exists(tmpdir):
            shutil.rmtree(tmpdir)
        os.makedirs(tmpdir)
        print("1/3 拷贝到临时目录…")
        ok, bad = _copy_verify(files, staging, tmpdir, False)
        print("    校验：成功 %d，失败 %d" % (ok, bad))
        if bad:
            die("MD5 校验失败，未改动任何原文件")
        print("2/3 替换…")
        old_names = {os.path.basename(r["rel"]) for r in st.get("results", [])} or set(files)
        for f in files:
            dst = os.path.join(target, f)
            if os.path.exists(dst):
                os.remove(dst)
            shutil.move(os.path.join(tmpdir, f), dst)
        # 清掉被替换掉的旧文件名（例如 x.mp3 → x.flac）
        for n in old_names:
            p = os.path.join(target, n)
            if os.path.exists(p) and n not in files:
                os.remove(p)
        shutil.rmtree(tmpdir, ignore_errors=True)
        print("3/3 清理缓存…")
        if mode == "device":
            cache = os.path.join(target, ".crazypod", "cache")
            for p in (os.path.join(cache, "music-library.bin"), os.path.join(cache, "artwork.ready")):
                if os.path.exists(p):
                    os.remove(p)
            shutil.rmtree(os.path.join(cache, "CV10"), ignore_errors=True)
            print("    已清 CrazyPod 音乐库/封面缓存")
    else:
        ok, bad = _copy_verify(files, staging, target, False)
        print("校验：成功 %d，失败 %d" % (ok, bad))

    try:
        subprocess.run(["sync"], check=False)
    except Exception:                                # noqa: BLE001
        pass
    if mode == "device" and not args.no_eject:
        info = run(["diskutil", "info", target])
        m = re.search(r"Part of Whole:\s*(\S+)", info)
        if m:
            run(["diskutil", "eject", "/dev/" + m.group(1)])
            print("已安全推出 %s" % m.group(1))
    print("完成。重新插回 iPod 后按住 Menu + Center 重启，等待重扫。")


# ---------------------------------------------------------------- report / selftest
def cmd_report(args):
    w = work_dir(args.work)
    st = load_state(w)
    print(write_report(st, w))


def cmd_selftest(args):
    if not (have("ffmpeg") and have("ffprobe")):
        die("自检需要 ffmpeg/ffprobe：brew install ffmpeg")
    tmp = os.path.join(work_dir(args.work), "selftest")
    if os.path.exists(tmp):
        shutil.rmtree(tmp)
    os.makedirs(tmp)
    print("生成测试素材：", tmp)
    run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=3:sample_rate=96000", "-c:a", "flac",
         "-sample_fmt", "s32", os.path.join(tmp, "hires96.flac")])
    run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=3:sample_rate=44100", "-c:a", "flac",
         "-sample_fmt", "s16", os.path.join(tmp, "ok.flac")])
    run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=3:sample_rate=44100", "-c:a", "libmp3lame",
         "-b:a", "320k", os.path.join(tmp, "ok.mp3")])
    shutil.copy(os.path.join(tmp, "ok.flac"), os.path.join(tmp, "mislabeled.mp3"))
    preset = PRESETS[args.preset or "flac"]
    entries = scan_dir(tmp, preset)
    got = {e["file"]: (e["action"], [r[0] for r in e["reasons"]]) for e in entries}
    print(json.dumps(got, ensure_ascii=False, indent=1))
    problems = []
    if got.get("hires96.flac", ("", []))[0] != "transcode":
        problems.append("24bit/96kHz 未被判定为需要转码")
    if "rate" not in got.get("hires96.flac", ("", []))[1]:
        problems.append("未识别采样率超限")
    if "depth" not in got.get("hires96.flac", ("", []))[1]:
        problems.append("未识别位深超限")
    if "mislabel" not in got.get("mislabeled.mp3", ("", []))[1]:
        problems.append("未识别 .mp3 里装 FLAC 的扩展名错配")
    if got.get("ok.mp3", ("", []))[0] != "tag":
        problems.append("合规 MP3 被误判需要转码")
    # 转码链路自检
    stg = os.path.join(tmp, "stage")
    r = convert_entry(entries[0], preset, stg, False)
    pr = probe_file(r["out"])
    if pr["sample_rate"] > preset["max_rate"] or pr["bits"] > preset["max_bits"]:
        problems.append("转码后参数仍超限: %s/%s" % (pr["sample_rate"], pr["bits"]))
    print("\n转码后：%d Hz / %d bit / %s" % (pr["sample_rate"], pr["bits"], pr["family"]))
    if problems:
        print("\n✗ 自检失败：")
        for p in problems:
            print("  - " + p)
        sys.exit(1)
    print("\n✓ 自检通过")


# ---------------------------------------------------------------- main
def _add_work(sp):
    """允许 --work / --covers 写在子命令之后。"""
    sp.add_argument("--work", default=argparse.SUPPRESS, help="工作目录（默认 ./.ipodtune）")
    sp.add_argument("--covers", action="append", default=argparse.SUPPRESS, metavar="DIR",
                    help="本地封面文件夹（可重复；文件名用 专辑名.jpg / 歌手 - 专辑.jpg / 歌名.jpg）")


def build_parser():
    ap = argparse.ArgumentParser(
        prog="ipodtune",
        description="iPod Classic / CrazyPod 音乐整理：重填标签、超规格转码、检索/推荐封面、安全写回")
    ap.add_argument("--work", default=os.path.join(os.getcwd(), ".ipodtune"), help="工作目录（默认 ./.ipodtune）")
    ap.add_argument("--covers", action="append", default=None, metavar="DIR",
                    help="本地封面文件夹（可重复）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("scan", help="扫描目录并判定是否需要转码")
    sp.add_argument("-d", "--dir", default=None, help="音乐目录（默认自动找 iPod 卷的 Music）")
    sp.add_argument("--preset", default="flac", choices=list(PRESETS))
    sp.add_argument("--country", default="us")
    sp.add_argument("--jobs", type=int, default=4)
    sp.set_defaults(func=cmd_scan)
    _add_work(sp)

    sp = sub.add_parser("match", help="联网匹配元数据与封面")
    sp.add_argument("--country", default="us")
    sp.add_argument("--no-network", action="store_true")
    sp.add_argument("--no-mb", action="store_true", help="不做 MusicBrainz 交叉核对")
    sp.set_defaults(func=cmd_match)
    _add_work(sp)

    sp = sub.add_parser("review", help="交互式复核（改歌手/选封面）")
    sp.add_argument("--all", action="store_true", help="连确定的也逐首过一遍")
    sp.add_argument("--no-network", action="store_true")
    sp.set_defaults(func=cmd_review)
    _add_work(sp)

    sp = sub.add_parser("convert", help="转码 + 写标签 + 嵌封面到 work/staging")
    sp.add_argument("--preset", default=None, choices=list(PRESETS))
    sp.add_argument("--jobs", type=int, default=4)
    sp.add_argument("--limit", type=int, default=0, help="只处理前 N 个（调试用）")
    sp.add_argument("--dry-run", action="store_true")
    sp.set_defaults(func=cmd_convert)
    _add_work(sp)

    sp = sub.add_parser("apply", help="把 staging 写回目标")
    sp.add_argument("--to", default=None, help="写到指定目录")
    sp.add_argument("--device", action="store_true", help="自动找 iPod 卷并安全替换")
    sp.add_argument("--inplace", action="store_true", help="覆盖源目录原文件")
    sp.add_argument("--backup", action="store_true", help="inplace 时先备份原文件")
    sp.add_argument("--no-eject", action="store_true")
    sp.add_argument("--dry-run", action="store_true")
    sp.set_defaults(func=cmd_apply)
    _add_work(sp)

    sp = sub.add_parser("report", help="重新生成 Markdown 报告")
    sp.set_defaults(func=cmd_report)
    _add_work(sp)

    sp = sub.add_parser("selftest", help="自检（生成测试文件验证判定/转码链路）")
    sp.add_argument("--preset", default="flac", choices=list(PRESETS))
    sp.set_defaults(func=cmd_selftest)
    _add_work(sp)

    def _run(args):
        return args

    sp = sub.add_parser("run", help="scan + match 一条龙")
    sp.add_argument("-d", "--dir", default=None)
    sp.add_argument("--preset", default="flac", choices=list(PRESETS))
    sp.add_argument("--country", default="us")
    sp.add_argument("--jobs", type=int, default=4)
    sp.add_argument("--no-network", action="store_true")

    def cmd_run(args):
        cmd_scan(argparse.Namespace(dir=args.dir, preset=args.preset, country=args.country,
                                    jobs=args.jobs, work=args.work,
                                    covers=getattr(args, "covers", None)))
        cmd_match(argparse.Namespace(country=args.country, no_network=args.no_network,
                                     no_mb=False, work=args.work))
    sp.set_defaults(func=cmd_run)
    _add_work(sp)
    return ap


def main():
    if not have("ffprobe"):
        die("缺少 ffprobe：请先 `brew install ffmpeg`（或运行 ./bootstrap.sh）")
    if not HAS_MUTAGEN:
        die("缺少 mutagen：请运行 ./bootstrap.sh，或 python3 -m pip install --target vendor mutagen")
    ap = build_parser()
    args = ap.parse_args()
    args.work = work_dir(args.work)
    args.func(args)


if __name__ == "__main__":
    main()
