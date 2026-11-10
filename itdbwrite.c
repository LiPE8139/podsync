/* itdbwrite.c — 用 libgpod 生成/更新 iPod 的 iTunesDB + ArtworkDB（含 hash58 校验）
 *
 * 用法: itdbwrite <iPod挂载点> <manifest.tsv>
 *
 * manifest.tsv 每行 10 列（TAB 分隔）：
 *   1 文件                                 —— 以 '/' 开头=已在 iPod 上的相对路径（不拷贝）；
 *                                             否则=本地源文件（会被拷进 iPod_Control/Music/Fxx）
 *   2 标题   3 歌手   4 专辑   5 音轨号   6 年份   7 流派
 *   8 时长(秒)   9 码率(bps)   10 封面图片路径（可空）   11 歌词文件路径（可空）
 *
 * 每次运行都会用 manifest 重建 iTunesDB 与 ArtworkDB（已存在的曲目文件不会被重拷）。
 * 设备信息默认本机 iPod classic 80GB，可用环境变量覆盖：
 *   IPOD_MODEL（默认 MB147）  IPOD_GUID（默认 000A2700130F9207）
 */
#include <glib.h>
#include <gpod/itdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

extern int ipod_write_artwork_db(Itdb_iTunesDB *itdb);

static const char *env_or(const char *k, const char *d) {
    const char *v = g_getenv(k);
    return (v && *v) ? v : d;
}

/* 由后缀推断 iTunesDB 的 filetype 字符串（ALAC 与 AAC 都用 .m4a，这里按无损写） */
static const char *filetype_for_path(const char *path) {
    const char *suf = strrchr(path, '.');
    if (!suf) return "MPEG audio file";
    if (!g_ascii_strcasecmp(suf, ".m4a") || !g_ascii_strcasecmp(suf, ".m4b"))
        return "Apple Lossless audio file";
    if (!g_ascii_strcasecmp(suf, ".aac")) return "AAC audio file";
    if (!g_ascii_strcasecmp(suf, ".wav")) return "WAV audio file";
    if (!g_ascii_strcasecmp(suf, ".aiff") || !g_ascii_strcasecmp(suf, ".aif"))
        return "AIFF audio file";
    return "MPEG audio file";
}

/* 由后缀生成 iPod 的 filetype_marker（'.mp3' -> 'MP3 '） */
static guint32 marker_from_suffix(const char *path) {
    const char *suf = strrchr(path, '.');
    guint32 m = 0;
    int i;
    if (!suf) suf = ".";
    for (i = 1; i <= 4; ++i) {
        m <<= 8;
        if ((int)strlen(suf) > i)
            m |= g_ascii_toupper(suf[i]);
        else
            m |= ' ';
    }
    return m;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <ipod-mountpoint> <manifest.tsv>\n", argv[0]);
        return 2;
    }
    const char *mount = argv[1];
    const char *manifest = argv[2];
    GError *err = NULL;

    Itdb_iTunesDB *itdb = itdb_new();
    if (!itdb) { fprintf(stderr, "itdb_new failed\n"); return 1; }
    itdb_device_set_mountpoint(itdb->device, mount);
    itdb_device_set_sysinfo(itdb->device, "ModelNumStr", env_or("IPOD_MODEL", "MB147"));
    itdb_device_set_sysinfo(itdb->device, "FirewireGuid", env_or("IPOD_GUID", "000A2700130F9207"));

    Itdb_Playlist *mpl = itdb_playlist_new("iPod", FALSE);
    itdb_playlist_set_mpl(mpl);
    itdb_playlist_add(itdb, mpl, 0);

    FILE *f = fopen(manifest, "r");
    if (!f) { perror("manifest"); return 2; }

    char line[16384];
    int n = 0, bad = 0, art_ok = 0, art_bad = 0, copied = 0, lyric_ok = 0;
    while (fgets(line, sizeof line, f)) {
        g_strchomp(line);
        if (!line[0] || line[0] == '#') continue;
        char *fields[11] = {0};
        int k = 0;
        char *p = line;
        while (k < 11) {
            fields[k++] = p;
            char *tab = strchr(p, '\t');
            if (!tab) break;
            *tab = 0;
            p = tab + 1;
        }
        if (k < 8) { fprintf(stderr, "bad manifest line: %s\n", line); bad++; continue; }

        const char *src = fields[0];
        const char *title = fields[1];
        const char *artist = fields[2] ? fields[2] : "";
        const char *album = fields[3] ? fields[3] : "";
        int track_nr = fields[4] ? atoi(fields[4]) : 0;
        int year = fields[5] ? atoi(fields[5]) : 0;
        const char *genre = fields[6] ? fields[6] : "";
        double dur = fields[7] ? atof(fields[7]) : 0.0;
        long bitrate = fields[8] ? atol(fields[8]) : 0;
        const char *cover = (k > 9 && fields[9] && fields[9][0]) ? fields[9] : NULL;
        const char *lyric_path = (k > 10 && fields[10] && fields[10][0]) ? fields[10] : NULL;

        int on_ipod = (src[0] == '/');
        if (on_ipod) {
            gchar *full = g_build_filename(mount, src, NULL);
            struct stat st;
            if (stat(full, &st) != 0) {
                fprintf(stderr, "  ! 文件不存在，跳过: %s\n", full);
                g_free(full);
                bad++;
                continue;
            }
            g_free(full);
            if (st.st_size == 0) { bad++; continue; }
        }

        Itdb_Track *t = itdb_track_new();
        t->mediatype = ITDB_MEDIATYPE_AUDIO;
        t->title = g_strdup(title);
        t->artist = g_strdup(artist);
        t->album = g_strdup(album);
        t->albumartist = g_strdup(artist);
        t->genre = g_strdup(genre);
        t->track_nr = track_nr;
        t->year = year;
        t->tracklen = (gint32)(dur * 1000.0 + 0.5);
        if (bitrate > 0) t->bitrate = (gint32)bitrate;
        t->filetype = g_strdup(filetype_for_path(src));
        t->time_added = time(NULL);
        t->time_modified = t->time_added;

        if (on_ipod) {
            struct stat st;
            gchar *full = g_build_filename(mount, src, NULL);
            stat(full, &st);
            g_free(full);
            t->ipod_path = g_strdup(src);
            t->size = st.st_size;
            t->transferred = TRUE;
            t->filetype_marker = marker_from_suffix(src);
            itdb_track_add(itdb, t, -1);
            itdb_playlist_add_track(itdb_playlist_mpl(itdb), t, -1);
        } else {
            itdb_track_add(itdb, t, -1);
            if (!itdb_cp_track_to_ipod(t, src, &err)) {
                fprintf(stderr, "  ! 拷贝失败 [%s]: %s\n", src, err ? err->message : "?");
                if (err) g_clear_error(&err);
                bad++;
                continue;
            }
            itdb_playlist_add_track(itdb_playlist_mpl(itdb), t, -1);
            copied++;
        }

        if (cover) {
            if (!itdb_track_set_thumbnails(t, cover)) {
                fprintf(stderr, "  ! 封面失败: %s\n", title);
                art_bad++;
            } else {
                art_ok++;
            }
        }

        /* 歌词：读 .lrc，去掉时间标记后写入 iTunesDB（MHOD type 10） */
        if (lyric_path) {
            gchar *full = NULL;
            if (lyric_path[0] == '/')
                full = g_build_filename(mount, lyric_path, NULL);
            else
                full = g_strdup(lyric_path);
            gchar *content = NULL;
            if (g_file_get_contents(full, &content, NULL, NULL) && content && *content) {
                GString *plain = g_string_new("");
                gchar **lines = g_strsplit(content, "\n", -1);
                for (int i = 0; lines[i]; i++) {
                    gchar *ln = g_strstrip(g_strdup(lines[i]));
                    gchar *p2 = ln;
                    while (p2 && *p2 == '[') {
                        gchar *close = strchr(p2, ']');
                        if (!close) break;
                        p2 = close + 1;
                    }
                    if (*p2) {
                        if (plain->len) g_string_append_c(plain, '\n');
                        g_string_append(plain, p2);
                    }
                    g_free(ln);
                }
                g_strfreev(lines);
                if (plain->len) {
                    t->lyrics = g_strdup(plain->str);
                    t->lyrics_flag = 1;
                    lyric_ok++;
                }
                g_string_free(plain, TRUE);
            }
            g_free(content);
            g_free(full);
        }
        n++;
    }
    fclose(f);

    if (bad > 0) {
        fprintf(stderr, "\n%d 个条目有问题，中止（避免写出不完整的库）\n", bad);
        return 1;
    }
    if (!itdb_write(itdb, &err)) {
        fprintf(stderr, "写 iTunesDB 失败: %s\n", err ? err->message : "?");
        return 1;
    }
    if (art_ok > 0 && ipod_write_artwork_db(itdb) != 0) {
        fprintf(stderr, "写 ArtworkDB 失败\n");
    }
    printf("完成：%d 首曲目（新拷贝 %d），封面 %d 首（失败 %d），歌词 %d 首\n",
           n, copied, art_ok, art_bad, lyric_ok);
    itdb_free(itdb);
    return 0;
}
