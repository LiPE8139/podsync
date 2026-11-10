#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
coco.py — COCO 音乐下载站（http://120.26.220.116）的搜索/下载封装
供 GUI 或命令行调用；下载后自动补标签与封面，并放进 iPod 收件箱。

用法：
  python3 coco.py search  --q "周杰伦" --provider netease
  python3 coco.py download --id 18614888 --provider netease --quality lossless \
        --inbox ~/Music/iPod-Inbox --title "..." --artist "..." --album "..." --cover "http://..."
  python3 coco.py providers

输出统一为单行 JSON（GUI 直接解析）。
"""
from __future__ import annotations

import argparse
import json
import os
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.environ.get("COCO_BASE", "http://120.26.220.116")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
PROVIDERS = [("netease", "云音乐"), ("qq", "QQ音乐"), ("kugou", "酷狗")]
QUALITIES = [("lossless", "无损"), ("exhigh", "极高 320k"), ("standard", "标准 128k"), ("hires", "Hi-Res")]

sys.path.insert(0, os.path.join(HERE, "vendor"))

def _writable(d: str) -> bool:
    try:
        os.makedirs(d, exist_ok=True)
        probe = os.path.join(d, ".probe")
        with open(probe, "w") as f:
            f.write("x")
        os.remove(probe)
        return True
    except Exception:
        return False

CACHE_DIR = os.environ.get("COCO_CACHE") or os.path.join(
    os.path.expanduser("~/Library/Application Support/iPodSync"), "downloads")
if not _writable(CACHE_DIR):
    CACHE_DIR = os.path.join(HERE, ".downloads")
    os.makedirs(CACHE_DIR, exist_ok=True)

AUDIO_MAGIC = [
    (b"fLaC", ".flac", "flac"),
    (b"ID3", ".mp3", "mp3"),
    (b"\xff\xfb", ".mp3", "mp3"),
    (b"OggS", ".ogg", "vorbis"),
    (b"RIFF", ".wav", "wav"),
]


def jprint(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False))


def http_get(url: str, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()
    except Exception as e:  # noqa: BLE001
        return 0, {}, str(e).encode()


def api_search(q: str, provider: str, limit: int = 50, offset: int = 0):
    url = BASE + "/api/search?" + urllib.parse.urlencode(
        {"q": q, "provider": provider, "limit": min(max(limit, 1), 50), "offset": max(offset, 0)})
    data = None
    for attempt in range(4):
        st, _h, body = http_get(url, timeout=30)
        if st == 200 and body.strip():
            try:
                d = json.loads(body.decode("utf-8", "replace"))
            except Exception:
                d = None
            if d is not None:
                data = d
                if d.get("items"):
                    break
        time.sleep(1.2 * (attempt + 1))
    if data is None:
        return {"ok": False, "error": "搜索接口无响应，请稍后重试"}
    if "items" not in data:
        return {"ok": False, "error": data.get("error") or "搜索返回异常"}
    if not data["items"]:
        return {"ok": False, "error": "站点暂时没有返回结果（上游可能限流），稍后重试即可"}
    items = []
    for it in data["items"]:
        extra = it.get("extra") or {}
        items.append({
            "id": str(it.get("id")),
            "title": it.get("title") or "",
            "artist": it.get("artist") or "",
            "album": it.get("album") or "",
            "cover": it.get("cover") or extra.get("cover") or "",
            "duration": it.get("duration") or "",
            "provider": it.get("provider") or provider,
            "qualities": [{"value": q2.get("value"), "label": q2.get("label", ""),
                           "format": q2.get("format", "")} for q2 in (extra.get("qualityOptions") or [])],
        })
    return {"ok": True, "items": items, "offset": max(offset, 0), "count": len(items),
            "has_more": len(items) >= min(max(limit, 1), 50)}


def safe_name(name: str, maxlen=100) -> str:
    n = re.sub(r'[\\/:*?"<>|\r\n\t]+', "-", name)
    n = re.sub(r"\s+", " ", n).strip(" .")
    return (n or "untitled")[:maxlen]


def sniff_format(path: str):
    try:
        with open(path, "rb") as f:
            head = f.read(16)
    except OSError:
        return None
    for magic, ext, fam in AUDIO_MAGIC:
        if head.startswith(magic):
            return ext, fam
    if len(head) > 8 and head[4:8] == b"ftyp":
        return ".m4a", "m4a"
    return None


def ffprobe_ok(path: str) -> dict:
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams",
                              "-of", "json", path], capture_output=True, text=True, timeout=60).stdout
        j = json.loads(out or "{}")
        a = next((s for s in j.get("streams", []) if s.get("codec_type") == "audio"), {})
        return {"codec": a.get("codec_name"), "duration": float(j.get("format", {}).get("duration") or 0)}
    except Exception:
        return {}


def embed_meta(path: str, meta: dict, cover_path: str | None) -> None:
    """写标签 + 封面（FLAC / MP3 / M4A）。"""
    title = meta.get("title") or ""
    artist = meta.get("artist") or ""
    album = meta.get("album") or ""
    try:
        if path.lower().endswith(".flac"):
            from mutagen.flac import FLAC, Picture
            f = FLAC(path)
            f.delete()
            if title:
                f["TITLE"] = title
            if artist:
                f["ARTIST"] = artist
                f["ALBUMARTIST"] = artist
            if album:
                f["ALBUM"] = album
            if cover_path:
                pic = Picture()
                pic.type = 3
                pic.mime = "image/png" if cover_path.lower().endswith(".png") else "image/jpeg"
                pic.desc = "Cover"
                pic.data = open(cover_path, "rb").read()
                f.add_picture(pic)
            f.save()
        elif path.lower().endswith(".mp3"):
            from mutagen.id3 import ID3, TIT2, TPE1, TPE2, TALB, APIC
            try:
                t = ID3(path)
            except Exception:
                t = ID3()
            for k in list(t.keys()):
                del t[k]
            if title:
                t.add(TIT2(encoding=3, text=title))
            if artist:
                t.add(TPE1(encoding=3, text=artist))
                t.add(TPE2(encoding=3, text=artist))
            if album:
                t.add(TALB(encoding=3, text=album))
            if cover_path:
                t.add(APIC(encoding=3, mime="image/png" if cover_path.lower().endswith(".png") else "image/jpeg",
                           type=3, desc="Cover", data=open(cover_path, "rb").read()))
            t.save()
        elif path.lower().endswith((".m4a", ".m4b")):
            from mutagen.mp4 import MP4, MP4Cover
            m = MP4(path)
            m["\xa9nam"] = [title]
            m["\xa9ART"] = [artist]
            m["\xa9alb"] = [album]
            if cover_path:
                data = open(cover_path, "rb").read()
                m["covr"] = [MP4Cover(data, imageformat=MP4Cover.FORMAT_PNG
                                      if cover_path.lower().endswith(".png") else MP4Cover.FORMAT_JPEG)]
            m.save()
    except Exception as e:  # noqa: BLE001
        print("embed_meta warning:", e, file=sys.stderr)


def get_direct_url(song_id: str, provider: str, quality: str):
    try:
        st, _h, body = http_get(BASE + "/api/url?" + urllib.parse.urlencode(
            {"id": song_id, "provider": provider, "quality": quality}), timeout=30)
        if st == 200 and body:
            return json.loads(body.decode("utf-8", "replace")).get("url")
    except Exception:
        pass
    return None


def _emit_progress(got: int, total: int):
    pct = int(got * 100 / total) if total else -1
    print("PROGRESS\t%d\t%d\t%d" % (pct, got, total or 0), file=sys.stderr, flush=True)


def download_resumable(url: str, key: str, timeout=60, progress=None):
    """支持 Range 的断点续传：返回 (数据 bytes, 是否续传)。不支持 Range 时自动整段下载。"""
    part = os.path.join(CACHE_DIR, key + ".part")
    pos = os.path.getsize(part) if os.path.exists(part) else 0
    resumed = False
    for attempt in range(3):
        headers = {"User-Agent": UA}
        if pos:
            headers["Range"] = "bytes=%d-" % pos
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                status = getattr(r, "status", 200)
                mode = "ab" if (pos and status == 206) else "wb"
                if mode == "wb":
                    pos = 0
                resumed = resumed or (pos > 0 and status == 206)
                remaining = None
                total = 0
                cr = r.headers.get("Content-Range")
                if cr and "/" in cr:
                    try:
                        total = int(cr.split("/")[-1])
                        remaining = total
                    except Exception:
                        total = 0
                else:
                    try:
                        total = int(r.headers.get("Content-Length") or 0) + pos
                    except Exception:
                        total = 0
                written = pos
                with open(part, mode) as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
                        written += len(chunk)
                        if progress:
                            progress(written, total)
                got = os.path.getsize(part)
                if remaining is None or got >= remaining:
                    with open(part, "rb") as f:
                        data = f.read()
                    os.remove(part)
                    return data, resumed
                pos = got
            time.sleep(1.0)
        except Exception:
            time.sleep(1.5)
    # 最后尝试完整重下（清掉半截文件）
    try:
        os.remove(part)
    except OSError:
        pass
    body = download_memory(url, progress=progress)
    if body:
        return body, resumed
    st, _h, body = http_get(url, timeout=300)
    return (body if st == 200 else None), resumed


def download_memory(url: str, timeout=300, progress=None):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            total = 0
            try:
                total = int(r.headers.get("Content-Length") or 0)
            except Exception:
                total = 0
            buf = bytearray()
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                buf.extend(chunk)
                if progress:
                    progress(len(buf), total)
            return bytes(buf) if buf else None
    except Exception:
        return None


IPOD_OK = ("flac", "mp3", "aac", "alac", "vorbis", "opus", "wav", "aiff")


def needs_ipod_convert(src: str):
    """返回 (是否需要转码, 探测信息)。超过 iPod 能力（>48kHz、>16bit、不支持的格式）就需要。"""
    try:
        j = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams",
                                       "-of", "json", src], capture_output=True, text=True,
                                      timeout=60).stdout or "{}")
    except Exception:
        return False, {}
    a = next((x for x in j.get("streams", []) if x.get("codec_type") == "audio"), {})
    codec = (a.get("codec_name") or "").lower()
    sr = int(a.get("sample_rate") or 0)
    bits = int(a.get("bits_per_raw_sample") or a.get("bits_per_sample") or 0)
    info = {"codec": codec, "sr": sr, "bits": bits,
            "duration": float((j.get("format") or {}).get("duration") or 0),
            "size": os.path.getsize(src)}
    if codec not in IPOD_OK:
        return True, info
    if codec == "flac" and (sr > 48000 or bits > 16):
        return True, info
    return False, info


def to_ipod_alac(src: str, meta: dict) -> str:
    """转成 16bit / 44.1kHz ALAC（.m4a，附标签/封面），返回新文件路径；失败返回空串。"""
    aiff = src + ".tmp.aiff"
    m4a = os.path.splitext(src)[0] + ".m4a"
    tmp_m4a = m4a + ".tmp.m4a"
    try:
        r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src,
                            "-map", "0:a", "-c:a", "pcm_s16be", "-ar", "44100",
                            "-ac", "2", aiff], capture_output=True, text=True)
        if r.returncode != 0:
            print("ffmpeg 解码失败:", r.stderr.strip()[:160], file=sys.stderr)
            return ""
        r = subprocess.run(["afconvert", "-f", "m4af", "-d", "alac", aiff, tmp_m4a],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(tmp_m4a):
            print("afconvert 失败:", (r.stderr or r.stdout).strip()[:160], file=sys.stderr)
            return ""
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
            cov = meta.get("cover_bytes")
            if cov:
                data, mime = cov
                fmt = MP4Cover.FORMAT_PNG if "png" in (mime or "") else MP4Cover.FORMAT_JPEG
                m["covr"] = [MP4Cover(data, imageformat=fmt)]
            m.save()
        except Exception as e:  # noqa: BLE001
            print("ALAC 写标签失败:", e, file=sys.stderr)
        os.replace(tmp_m4a, m4a)
        return m4a
    finally:
        for x in (aiff, tmp_m4a):
            try:
                os.remove(x)
            except OSError:
                pass


def embedded_cover_bytes(path: str):
    """从源文件读内嵌封面，返回 (bytes, mime) 或 None。"""
    try:
        if path.lower().endswith(".flac"):
            from mutagen.flac import FLAC
            f = FLAC(path)
            if f.pictures:
                return f.pictures[0].data, f.pictures[0].mime
        elif path.lower().endswith(".mp3"):
            from mutagen.id3 import ID3
            t = ID3(path)
            for k in list(t.keys()):
                if k.startswith("APIC"):
                    return t[k].data, t[k].mime
        elif path.lower().endswith((".m4a", ".m4b")):
            from mutagen.mp4 import MP4
            m = MP4(path)
            covs = m.get("covr") or []
            if covs:
                return bytes(covs[0]), "image/png" if covs[0].imageformat == 14 else "image/jpeg"
    except Exception:
        pass
    return None


def prepare_for_ipod(path: str, meta: dict, inbox: str):
    """下载完立即处理：超过 iPod 能力就转成 ALAC 16bit/44.1kHz（并删除源文件）。
    返回 (最终路径, 是否转码)。"""
    converted = False
    need, _info = needs_ipod_convert(path)
    if need:
        meta2 = dict(meta)
        if not meta2.get("cover_bytes"):
            meta2["cover_bytes"] = embedded_cover_bytes(path)
        new_path = to_ipod_alac(path, meta2)
        if new_path:
            old_lrc = os.path.splitext(path)[0] + ".lrc"
            if os.path.exists(old_lrc):
                os.replace(old_lrc, os.path.splitext(new_path)[0] + ".lrc")
            try:
                os.remove(path)
            except OSError:
                pass
            path = new_path
            converted = True
            print("CONVERTED\t%s" % os.path.basename(path), file=sys.stderr, flush=True)
    return path, converted


def fetch_lyric(song_id: str, provider: str):
    """取歌词并转成标准 LRC 文本；没有歌词返回 None。"""
    url = BASE + "/api/lyric?" + urllib.parse.urlencode({"id": song_id, "provider": provider})
    st, _h, body = http_get(url, timeout=30)
    if st != 200 or not body:
        return None
    try:
        d = json.loads(body.decode("utf-8", "replace"))
    except Exception:
        return None
    lines = d.get("lines") or []
    if not lines:
        return None

    def mmss(t):
        try:
            t = float(t)
        except Exception:
            return "00:00"
        m = int(t // 60)
        s2 = t - m * 60
        return "%02d:%05.2f" % (m, s2)

    out = []
    if d.get("title"):
        out.append("[ti:%s]" % d["title"])
    for ln in lines:
        txt = (ln.get("text") or "").replace("\n", " ").strip()
        out.append("[%s]%s" % (mmss(ln.get("time", 0)), txt))
    return "\n".join(out) + "\n"


def cmd_search(args):
    jprint(api_search(args.q, args.provider, limit=args.limit, offset=args.offset))


def cmd_download(args):
    key = hashlib.md5(("%s|%s|%s" % (args.id, args.provider, args.quality)).encode()).hexdigest()
    direct = get_direct_url(args.id, args.provider, args.quality)
    body, resumed = (None, False)
    if direct:
        try:
            body, resumed = download_resumable(direct, key, progress=_emit_progress)
        except Exception:
            body = None
    st, headers = 200, {}
    if not body:
        url = BASE + "/api/download?" + urllib.parse.urlencode(
            {"id": args.id, "provider": args.provider, "quality": args.quality})
        _emit_progress(0, 0)
        st, headers, body = http_get(url, timeout=300)
        if body:
            _emit_progress(len(body), len(body))

    def incomplete(hdrs, data: bytes) -> bool:
        try:
            cl = int(hdrs.get("Content-Length") or 0)
        except Exception:
            cl = 0
        return cl > 0 and len(data) < cl

    if st != 200 or not body or incomplete(headers, body) or body[:1] in (b"{", b"<"):
        # 兜底：/api/url 取直链再下
        try:
            st2, _h2, b2 = http_get(BASE + "/api/url?" + urllib.parse.urlencode(
                {"id": args.id, "provider": args.provider, "quality": args.quality}), timeout=30)
            direct = json.loads(b2.decode("utf-8", "replace")).get("url")
        except Exception:
            direct = None
        if direct:
            st, headers, body = http_get(direct, timeout=300)
    if st != 200 or not body:
        detail = body[:300].decode("utf-8", "replace")
        jprint({"ok": False, "error": "下载失败（HTTP %s）%s" % (st, detail)})
        return 2
    if body[:1] in (b"{", b"<"):
        jprint({"ok": False, "error": "服务器返回错误：" + body[:200].decode("utf-8", "replace")})
        return 2

    inbox = os.path.expanduser(args.inbox)
    os.makedirs(inbox, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="coco-")
    tmp = os.path.join(tmpdir, "download.bin")
    with open(tmp, "wb") as f:
        f.write(body)

    sniff = sniff_format(tmp)
    if not sniff:
        jprint({"ok": False, "error": "无法识别下载文件格式"})
        return 2
    ext, _fam = sniff
    # 用正确扩展名命名临时文件，否则 mutagen 无法判断容器类型
    tmp_ext = tmp + ext
    os.replace(tmp, tmp_ext)
    tmp = tmp_ext
    info = ffprobe_ok(tmp)
    if not info:
        jprint({"ok": False, "error": "下载文件无法解析（可能被限流或链接失效）"})
        return 2

    # 封面
    cover = None
    if args.cover:
        st2, _h2, cbody = http_get(args.cover, timeout=60)
        if st2 == 200 and len(cbody) > 2000:
            cover = os.path.join(tmpdir, "cover" + (".png" if cbody[:4] == b"\x89PNG" else ".jpg"))
            with open(cover, "wb") as f:
                f.write(cbody)

    # 补标签/封面
    meta = {"title": args.title or "", "artist": args.artist or "", "album": args.album or ""}
    if not (meta["title"] and meta["artist"]):
        try:
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags",
                                  "-of", "json", tmp], capture_output=True, text=True).stdout
            tags = {k.lower(): v for k, v in (json.loads(out or "{}").get("format", {}).get("tags") or {}).items()}
            meta["title"] = meta["title"] or tags.get("title", "")
            meta["artist"] = meta["artist"] or tags.get("artist", "")
            meta["album"] = meta["album"] or tags.get("album", "")
        except Exception:
            pass
    embed_meta(tmp, meta, cover)

    base = safe_name("%s - %s" % (meta["artist"] or "Unknown Artist", meta["title"] or args.id))
    dst = os.path.join(inbox, base + ext)
    n = 2
    while os.path.exists(dst):
        if os.path.getsize(dst) == len(body):
            shutil.rmtree(tmpdir, ignore_errors=True)
            jprint({"ok": True, "path": dst, "duplicate": True, "format": ext.lstrip("."),
                    "title": meta["title"], "artist": meta["artist"], "album": meta["album"],
                    "duration": info.get("duration", 0)})
            return 0
        dst = os.path.join(inbox, "%s (%d)%s" % (base, n, ext))
        n += 1
    shutil.move(tmp, dst)
    shutil.rmtree(tmpdir, ignore_errors=True)

    # === 下载完成即处理成 iPod 可用状态（转码/镜像/删源） ===
    dst, converted = prepare_for_ipod(dst, meta, inbox)
    ext = os.path.splitext(dst)[1]

    # 歌词（CrazyPod 支持 .lrc）
    lyric_ok = False
    try:
        lrc = fetch_lyric(args.id, args.provider)
        if lrc:
            with open(os.path.splitext(dst)[0] + ".lrc", "w", encoding="utf-8") as f:
                f.write(lrc)
            lyric_ok = True
    except Exception as e:  # noqa: BLE001
        print("lyric warning:", e, file=sys.stderr)

    jprint({"ok": True, "path": dst, "format": ext.lstrip("."), "bytes": os.path.getsize(dst),
            "title": meta["title"], "artist": meta["artist"], "album": meta["album"],
            "duration": info.get("duration", 0), "lyric": lyric_ok, "resumed": resumed,
            "converted": converted})
    return 0


def _norm(x: str) -> str:
    return re.sub(r"[^0-9a-z\u4e00-\u9fff]+", "", (x or "").lower())


def cmd_album(args):
    """按专辑批量取歌：搜索「歌手 + 专辑」后过滤同名专辑。"""
    queries = ["%s %s" % (args.artist, args.album), args.album]
    seen, items = set(), []
    want = _norm(args.album)
    for q in queries:
        offset, got = 0, 0
        while got < 200:
            res = api_search(q.strip(), args.provider, limit=50, offset=offset)
            if not res.get("ok"):
                break
            page = res.get("items", [])
            for it in page:
                k = _norm(it.get("album") or "")
                if want and want not in k and k not in want:
                    continue
                if args.artist and _norm(args.artist) not in _norm(it.get("artist") or ""):
                    continue
                if it["id"] in seen:
                    continue
                seen.add(it["id"])
                items.append(it)
            got += len(page)
            if len(page) < 50:
                break
            offset += len(page)
        if items:
            break
    # 同专辑不同再版会重复返回同一首歌：按归一化标题去重（保留先出现的那版）
    def strip_ver(t: str) -> str:
        t = re.sub(r"[（(]\s*(19|20)\d{2}\s*(remaster|remastered|digital remaster|版|再版)[^）)]*[）)]", "", t or "", flags=re.I)
        t = re.sub(r"[（(]\s*(remaster|remastered|deluxe|expanded|bonus)[^）)]*[）)]", "", t, flags=re.I)
        return _norm(t)
    uniq, keys = [], set()
    for it in items:
        k = strip_ver(it.get("title") or "")
        if not k or k in keys:
            continue
        keys.add(k)
        uniq.append(it)
    jprint({"ok": True, "items": uniq})


def _artist_aliases(artist: str) -> list[str]:
    """用网易云公开搜索接口拿歌手的别名（如 周杰伦 → Jay Chou / 周董），失败就算了。"""
    try:
        url = ("https://music.163.com/api/search/get?" +
               urllib.parse.urlencode({"s": artist, "type": 100, "limit": 10, "offset": 0}))
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"})
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read().decode("utf-8", "replace"), strict=False)
        raw = (data.get("result") or {}).get("artists") or data.get("artists") or []
        want = _norm(artist)
        best = None
        for a in raw:
            if _norm(a.get("name") or "") == want:
                best = a
                break
        if best is None and raw:
            best = raw[0]
        out = []
        for al in (best or {}).get("alias") or []:
            al = (al or "").strip()
            if 1 <= len(al) <= 40 and _norm(al) != want and _norm(al) not in [ _norm(x) for x in out ]:
                out.append(al)
        return out[:3]
    except Exception:
        return []


def cmd_artist(args):
    """按歌手批量取歌（站点只有 /api/search，所以靠“歌手名/别名深翻页 + 专辑名补全”）。

    1) 用别名（周杰伦 → Jay Chou / 周董）分别深翻页搜索，收集该歌手的曲目；
    2) 从结果里拿专辑名，再按“歌手 + 专辑”搜索补全专辑曲目；
    3) 按 id + 标题/专辑去重，结果缓存到 IPODSYNC_HOME/artistcache，12 小时内复用。
    """
    artist = (args.artist or "").strip()
    if not artist:
        jprint({"ok": False, "error": "缺少歌手名"})
        return 2
    want = _norm(artist)

    cache_dir = os.path.join(os.environ.get("IPODSYNC_HOME", os.path.expanduser("~")),
                             "artistcache")
    cache_key = hashlib.md5(("%s|%s" % (artist, args.provider)).encode("utf-8")).hexdigest()[:16]
    cache_path = os.path.join(cache_dir, cache_key + ".json")
    if not args.refresh and os.path.exists(cache_path):
        try:
            age = time.time() - os.path.getmtime(cache_path)
            if age < 12 * 3600:
                with open(cache_path, "r", encoding="utf-8") as f:
                    cached = json.load(f)
                if cached.get("artist") == artist and cached.get("items"):
                    cached["cached"] = True
                    jprint(cached)
                    return 0
        except Exception:
            pass

    limit = max(1, min(args.limit, 1000))
    names = [artist]
    if args.provider == "netease":
        names += _artist_aliases(artist)
    names_norm = [_norm(n) for n in names if n]

    def matches(it):
        raw = it.get("artist") or ""
        toks = [_norm(x) for x in re.split(r"[,，/&、;；]+", raw) if x.strip()]
        if not toks:
            return False
        # 只认“完整歌手名”命中：避免 JayChou Echo / 周杰伦♚ 这类翻唱号混进来
        return any(t == n for t in toks for n in names_norm if n)

    seen, items = set(), []

    def take(it):
        if it["id"] in seen:
            return False
        seen.add(it["id"])
        items.append(it)
        return True

    def page_search(q, max_pages, collect):
        offset = 0
        for _ in range(max_pages):
            try:
                res = api_search(q, args.provider, limit=50, offset=offset)
            except Exception:
                break
            if not res.get("ok"):
                break
            page = res.get("items") or []
            for it in page:
                collect(it)
            if len(page) < 50:
                break
            offset += len(page)
            time.sleep(0.1)

    # 1) 歌手名 + 别名深翻页
    def take_artist(it):
        if matches(it):
            take(it)

    for n in names:
        if len(items) >= limit:
            break
        page_search(n, 10, take_artist)

    # 2) 专辑补全（曲目还不够多时才做，省时间）
    if len(items) < 300:
        album_seen = set()
        album_hits = []
        for it in list(items):
            alb = (it.get("album") or "").strip()
            k = _norm(alb)
            if not k or k in album_seen or k in ("未知专辑",):
                continue
            album_seen.add(k)
            album_hits.append(alb)
        empty_streak = 0
        for alb in album_hits[:16]:
            if len(items) >= limit:
                break
            before = len(items)
            w_alb = _norm(alb)

            def take_album(it):
                if not matches(it):
                    return
                a = _norm(it.get("album") or "")
                if w_alb not in a and a not in w_alb:
                    return
                take(it)

            page_search("%s %s" % (artist, alb), 2, take_album)
            empty_streak = empty_streak + 1 if len(items) == before else 0
            if empty_streak >= 4:
                break

    # 3) 标题+专辑去重（同一首歌不同 id 只留一个），主唱优先
    def strip_ver(t):
        t = re.sub(r"[（(]\s*(19|20)\d{2}\s*(remaster|remastered|digital remaster|版|再版)[^）)]*[）)]", "", t or "", flags=re.I)
        t = re.sub(r"[（(]\s*(remaster|remastered|deluxe|expanded|bonus)[^）)]*[）)]", "", t, flags=re.I)
        return _norm(t)

    uniq, keys = [], set()
    for it in items:
        k = (strip_ver(it.get("title") or ""), _norm(it.get("album") or ""))
        if not k[0] or k in keys:
            continue
        keys.add(k)
        uniq.append(it)
        if len(uniq) >= limit:
            break
    uniq.sort(key=lambda it: 0 if _norm(it.get("artist") or "").startswith(want) else 1)

    result = {"ok": True, "items": uniq, "artist": artist,
              "aliases": names[1:], "total": len(uniq)}
    try:
        os.makedirs(cache_dir, exist_ok=True)
        tmp = cache_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False)
        os.replace(tmp, cache_path)
    except Exception:
        pass
    jprint(result)
    return 0


def cmd_url(args):
    """取在线试听/下载用的直链。"""
    url = get_direct_url(args.id, args.provider, args.quality)
    jprint({"ok": bool(url), "url": url or ""})


def cmd_providers(_args):
    jprint({"ok": True,
            "providers": [{"value": v, "label": l} for v, l in PROVIDERS],
            "qualities": [{"value": v, "label": l} for v, l in QUALITIES]})


def main():
    ap = argparse.ArgumentParser(prog="coco", description="COCO 音乐下载站 搜索/下载")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("search")
    sp.add_argument("--q", required=True)
    sp.add_argument("--provider", default="netease")
    sp.add_argument("--limit", type=int, default=50, help="本页条数（站点上限 50）")
    sp.add_argument("--offset", type=int, default=0, help="起始偏移，用于分页")
    sp.set_defaults(func=cmd_search)

    sp = sub.add_parser("download")
    sp.add_argument("--id", required=True)
    sp.add_argument("--provider", default="netease")
    sp.add_argument("--quality", default="lossless")
    sp.add_argument("--inbox", required=True)
    sp.add_argument("--title", default="")
    sp.add_argument("--artist", default="")
    sp.add_argument("--album", default="")
    sp.add_argument("--cover", default="")
    sp.set_defaults(func=cmd_download)

    sp = sub.add_parser("album")
    sp.add_argument("--artist", default="")
    sp.add_argument("--album", required=True)
    sp.add_argument("--provider", default="netease")
    sp.set_defaults(func=cmd_album)

    sp = sub.add_parser("artist")
    sp.add_argument("--artist", required=True)
    sp.add_argument("--provider", default="netease")
    sp.add_argument("--limit", type=int, default=400, help="最多返回曲目数")
    sp.add_argument("--refresh", action="store_true", help="忽略缓存重新抓取")
    sp.set_defaults(func=cmd_artist)

    sp = sub.add_parser("url")
    sp.add_argument("--id", required=True)
    sp.add_argument("--provider", default="netease")
    sp.add_argument("--quality", default="exhigh")
    sp.set_defaults(func=cmd_url)

    sp = sub.add_parser("providers")
    sp.set_defaults(func=cmd_providers)

    args = ap.parse_args()
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
