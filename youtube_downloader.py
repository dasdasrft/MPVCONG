#!/usr/bin/env python3
"""
=================================================================================
 全能极简万能音视频下载器 (YouTube / 哔哩哔哩 / 全网 1800+ 站点旗舰版)

 核心架构与多站点特性:
  1. 全网平台广泛支持 (原生支持 YouTube、哔哩哔哩(Bilibili/b23.tv)、微博、抖音、X/Twitter 等)
  2. 智能网络分流引擎 (国内站点自动极速直连，海外站点自动通过代理，彻底解决地区版权受限与速度慢)
  3. B站特化支持 (支持 BV号直接粘贴、b23.tv 短链解析、多P分集与选集智能处理、大会员/高码率 Cookie 共享)
  4. 终极画质与协议防降级 (规避 YouTube SABR 协议拦截与 360p 降级，支持 4K/2K/1080p60/HDR)
  5. 独立双语字幕必存保障 (确保下载目录永久生成 [视频名].双语.srt 与单语源文件，MPV自动挂载)
  6. 智能播放列表与分P防误触 (自动识别单视频/单P，防止手误误下几十个全集)
  7. 智能字幕双语融合引擎 (自动抓取 ASR/翻译字幕，时间轴毫秒级对齐去重，生成双语.srt)
  8. 多线程并发切片加速 (--concurrent-fragments 动态可调，跑满带宽)
  9. 独立目录规整管理与 .temp 临时碎片自动清理
 10. 全模式直达指令 (c 仅下封面 | z 仅下字幕 | a 仅下MP3 | b 批量下载 | u 内核在线更新)
 11. 性能与健壮性强化 (I/O流无阻塞批量缓冲、Windows 孤儿进程防御、配置原子化写入自愈)
=================================================================================
"""

import sys
import os
import json
import copy
import shutil
import subprocess
import socket
import datetime
import re

# ======================= 预编译正则与常量 =======================

RE_PCT = re.compile(r'([0-9\.]+)%')
RE_SIZE = re.compile(r'of\s+[~≈]?\s*([0-9\.]+\s*[a-zA-Z]+)')
RE_SPEED = re.compile(r'at\s+([0-9\.]+\s*[a-zA-Z]+/s)')
RE_ETA = re.compile(r'ETA\s+([0-9:]+)')
RE_URL = re.compile(r'https?://[^\s"\'<>]+')
RE_BV = re.compile(r'^BV[a-zA-Z0-9]{10}$', re.I)
RE_TAGS = re.compile(r'<[^>]+>')
RE_SUB_SUFFIX = re.compile(r'\.(zh-hans|zh-cn|zh-hant|zh-tw|zh|ai-zh|en-orig|en-us|en)\.(srt|vtt)$', re.I)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CWD = os.getcwd()

CONFIG_DIR_NAME = "ytdl_config"
CONFIG_DIR = os.path.join(SCRIPT_DIR, CONFIG_DIR_NAME)
DOWNLOADS_DIR = os.path.join(SCRIPT_DIR, "downloads")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")

os.makedirs(CONFIG_DIR, exist_ok=True)
os.makedirs(DOWNLOADS_DIR, exist_ok=True)

# 常见国内站点域名清单（自动直连，不走海外代理，避免因海外 IP 触发版权限制或限速）
DOMESTIC_DOMAINS = [
    "bilibili.com", "b23.tv", "biliapi.net", "bilivideo.com",
    "douyin.com", "iesdouyin.com", "weibo.com", "weibo.cn",
    "kuaishou.com", "xiaohongshu.com", "xhslink.com",
    "iqiyi.com", "youku.com", "qq.com", "mgtv.com", "163.com"
]

DEFAULT_CONFIG = {
    "first_run": True,
    "proxy_port": 7890,
    "custom_proxy": None,
    "cookie_mode": "file",
    "cookie_browser": "edge",
    "custom_cookie_path": None,
    "preferences": {
        "mode": "1",                # 1: 视频模式, 2: MP3, 3: M4A, 4: WAV, 5: 仅下封面, 6: 仅下字幕
        "resolution": "1",          # 1: 最佳, 2: 4K, 3: 2K, 4: 1080p, 5: 720p, 6: 480p
        "codec": "1",               # 1: 自动, 2: H264, 3: VP9, 4: AV1
        "container": "mp4",         # 容器格式: mp4 或 mkv
        "concurrent_fragments": 5,  # 多分片并发加速数 (推荐 4-8)
        "embed_chapters": True,     # 内嵌章节标记
        "split_chapters": False,    # 是否按章节分割成独立视频
        "download_subs": True,      # 下载字幕 (支持自动翻译与官方字幕)
        "bilingual_subs": True,     # 自动生成中英双语合并字幕文件 (双语.srt)
        "embed_thumbnail": True,    # 视频/音频内嵌封面
        "save_thumbnail": True,     # 保存独立封面图片文件 (JPG)
        "embed_metadata": True,     # 嵌入完整元数据
        "save_audio_track": False,  # 在文件夹额外留存一份独立原声音轨 (默认关闭)
        "audio_track_format": "mp3", # 独立音轨格式: mp3 (推荐320k), m4a, copy(无损原流)
    }
}

# 原声音轨过滤表达式：优先原声音轨 (format_note包含original)，其次排除配音轨 (dubbed)，最后回退到通用最佳音频
AUDIO_TRACK_FILTER = "ba[format_note*=original]/ba[format_note!*=dubbed]/ba"

# ======================= 工具与进程安全 =======================

def pause_exit(code=0):
    try:
        input("\n按回车键退出程序...")
    except Exception:
        pass
    sys.exit(code)

def kill_process_tree(proc):
    """
    Windows 下彻底清理 yt-dlp 衍生出来的 ffmpeg 等子进程，
    杜绝后台孤儿进程持续偷跑带宽与拉满 CPU。
    """
    if not proc:
        return
    try:
        if sys.platform == "win32":
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3
            )
        else:
            proc.terminate()
            proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass

def find_local_executable(name: str) -> str:
    """
    智能就近探测可执行文件，支持与 MPV 播放器目录结构无缝协同
    """
    candidates = [
        os.path.join(SCRIPT_DIR, f"{name}.exe"),
        os.path.join(SCRIPT_DIR, name),
        os.path.join(SCRIPT_DIR, "bin", f"{name}.exe"),
        os.path.join(SCRIPT_DIR, "tools", f"{name}.exe"),
        os.path.join(CWD, f"{name}.exe"),
        os.path.join(CWD, name),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return os.path.abspath(c)
    return shutil.which(name)

def detect_common_ports() -> int:
    for test_port in [7890, 10809, 10808, 7897, 1080, 20811, 1082]:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.1)
            if s.connect_ex(("127.0.0.1", test_port)) == 0:
                return test_port
    return 7890

def deep_merge(base: dict, update: dict) -> dict:
    """递归深度合并字典，确保旧配置文件加载时无痛自愈补全新键"""
    result = base.copy()
    for k, v in update.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result

def load_config() -> dict:
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    if os.path.isfile(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
                if isinstance(saved, dict):
                    cfg = deep_merge(DEFAULT_CONFIG, saved)
        except Exception:
            pass
    return cfg

def save_config(cfg: dict):
    """
    采用临时文件写入加原子替换机制，避免强退/断电造成 config.json 损坏为 0 字节
    """
    try:
        tmp_file = CONFIG_FILE + ".tmp"
        with open(tmp_file, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        os.replace(tmp_file, CONFIG_FILE)
    except Exception as e:
        print(f"[-] 保存配置失败: {e}")

def get_active_proxy(cfg: dict) -> str:
    if cfg.get("custom_proxy"):
        val = str(cfg["custom_proxy"]).strip()
        if val.lower() in ["none", "off", "direct", "0", "直连"]:
            return ""
        return val
    port = cfg.get("proxy_port", 7890)
    if not port or port == 0:
        return ""
    return f"http://127.0.0.1:{port}"

def is_domestic_site(url: str) -> bool:
    """智能判定是否为国内站点（自动直连避开代理）"""
    lower_u = url.lower()
    return any(domain in lower_u for domain in DOMESTIC_DOMAINS)

def get_cookie_args(cfg: dict) -> list:
    mode = cfg.get("cookie_mode", "file")
    if mode == "browser":
        b_name = cfg.get("cookie_browser", "edge")
        return ["--cookies-from-browser", b_name]

    target_files = [
        cfg.get("custom_cookie_path"),
        os.path.join(CONFIG_DIR, "cookies.txt"),
        os.path.join(SCRIPT_DIR, "cookies.txt"),
    ]
    for c_path in target_files:
        if c_path and os.path.isfile(c_path):
            return ["--cookies", c_path]
    return []

def get_cookie_status_text(cfg: dict) -> str:
    mode = cfg.get("cookie_mode", "file")
    if mode == "browser":
        return f"直接从浏览器读取 ({cfg.get('cookie_browser', 'edge')})"
    elif mode == "none":
        return "未启用"
    else:
        active_f = os.path.join(CONFIG_DIR, "cookies.txt")
        if os.path.isfile(active_f):
            sz = round(os.path.getsize(active_f) / 1024, 1)
            return f"文件载入 [{CONFIG_DIR_NAME}/cookies.txt] ({sz}KB)"
        return "未放置"

def format_pref_summary(prefs: dict) -> str:
    mode = str(prefs.get("mode", "1"))
    if mode == "2": return "仅音频 (MP3 320k) | 保存封面"
    elif mode == "3": return "仅音频 (M4A) | 保存封面"
    elif mode == "4": return "仅音频 (WAV) | 保存封面"
    elif mode == "5": return "仅下载封面图片 (JPG原图)"
    elif mode == "6": return "仅下载字幕 (中英双语SRT)"

    res_names = {"1": "最佳画质", "2": "4K", "3": "2K(1440p)", "4": "1080p", "5": "720p", "6": "480p"}
    codec_names = {"1": "自动编码", "2": "H.264优先", "3": "VP9优先", "4": "AV1优先"}
    
    res_str = res_names.get(str(prefs.get("resolution", "1")), "最佳画质")
    codec_str = codec_names.get(str(prefs.get("codec", "1")), "自动编码")
    container_str = prefs.get("container", "mp4").upper()
    thumb_str = "封面" if prefs.get("save_thumbnail", True) else "无封面"
    sub_str = "双语字幕" if prefs.get("download_subs", True) else "无字幕"
    audio_str = f"独立音轨({prefs.get('audio_track_format', 'mp3').upper()})" if prefs.get("save_audio_track", False) else "无独立音轨"
    speed_str = f"并发x{prefs.get('concurrent_fragments', 5)}"
    
    return f"{res_str} | {container_str} | {thumb_str} | {sub_str} | {audio_str} | {speed_str}"

# ======================= 字幕解析与双语合并模块 =======================

def time_to_ms(t_str: str) -> int:
    """自适应解析 SRT/VTT 各种变体时间戳为毫秒"""
    t_str = t_str.strip().replace(",", ".")
    if not t_str:
        return 0
    parts = t_str.split(":")
    try:
        if len(parts) == 3:      # HH:MM:SS.mmm
            h, m, s = int(parts[0]), int(parts[1]), float(parts[2])
            return int((h * 3600 + m * 60 + s) * 1000)
        elif len(parts) == 2:    # MM:SS.mmm
            m, s = int(parts[0]), float(parts[1])
            return int((m * 60 + s) * 1000)
        elif len(parts) == 1:
            return int(float(parts[0]) * 1000)
    except Exception:
        pass
    return 0

def clean_subtitle_text(raw_text: str) -> str:
    cleaned = RE_TAGS.sub("", raw_text)
    lines = []
    for line in cleaned.split("\n"):
        line_s = line.strip()
        if line_s and (not lines or line_s != lines[-1]):
            lines.append(line_s)
    return "\n".join(lines)

def parse_srt(content: str) -> list:
    blocks = re.split(r"\n\s*\n", content.strip())
    subtitles = []
    for block in blocks:
        lines = [l.strip() for l in block.split("\n") if l.strip()]
        if not lines:
            continue
        time_idx = -1
        for i, line in enumerate(lines):
            if "-->" in line:
                time_idx = i
                break
        if time_idx != -1:
            time_range = lines[time_idx]
            raw_text = "\n".join(lines[time_idx+1:])
            cleaned_text = clean_subtitle_text(raw_text)
            times = time_range.split("-->")
            if len(times) == 2:
                s_ms = time_to_ms(times[0])
                e_ms = time_to_ms(times[1])
                subtitles.append({
                    "start": s_ms,
                    "end": e_ms,
                    "time_str": time_range.strip(),
                    "text": cleaned_text
                })
    return subtitles

def merge_bilingual(zh_subs: list, en_subs: list) -> str:
    if not zh_subs and not en_subs:
        return ""
    if not zh_subs:
        return "\n".join(f"{i+1}\n{s['time_str']}\n{s['text']}\n" for i, s in enumerate(en_subs))
    if not en_subs:
        return "\n".join(f"{i+1}\n{s['time_str']}\n{s['text']}\n" for i, s in enumerate(zh_subs))

    merged = []
    if len(zh_subs) == len(en_subs):
        for i in range(len(zh_subs)):
            t_str = zh_subs[i]["time_str"]
            zh_t = zh_subs[i]["text"]
            en_t = en_subs[i]["text"]
            merged.append(f"{i+1}\n{t_str}\n{zh_t}\n{en_t}\n")
        return "\n".join(merged)

    for i, zh in enumerate(zh_subs):
        t_str = zh["time_str"]
        zh_t = zh["text"]
        matched = []
        for en in en_subs:
            if max(zh["start"], en["start"]) < min(zh["end"], en["end"]):
                if en["text"] and en["text"] not in matched:
                    matched.append(en["text"])
        en_t = " ".join(matched)
        body = f"{zh_t}\n{en_t}" if en_t else zh_t
        merged.append(f"{i+1}\n{t_str}\n{body}\n")
    return "\n".join(merged)

def process_bilingual_subtitles(downloads_dir: str):
    """扫描下载目录各视频文件夹，合并中文与英文字幕生成 [视频名].双语.srt"""
    for root, dirs, files in os.walk(downloads_dir):
        if ".temp" in root:
            continue
        
        zh_files = []
        en_files = []
        
        for f in files:
            lf = f.lower()
            if not (lf.endswith(".srt") or lf.endswith(".vtt")):
                continue
            if "双语" in f or "bilingual" in lf:
                continue

            if any(k in lf for k in ["zh-hans", "zh-cn", "zh", "ai-zh"]):
                zh_files.append((0 if "zh-hans" in lf else 1, f))
            elif "zh-hant" in lf or "zh-tw" in lf:
                zh_files.append((2, f))
            elif any(k in lf for k in [".en.", "en-orig", "en-us", "en."]):
                en_files.append((0 if "en-orig" in lf else 1, f))

        if zh_files and en_files:
            zh_files.sort(key=lambda x: x[0])
            en_files.sort(key=lambda x: x[0])
            
            selected_zh = os.path.join(root, zh_files[0][1])
            selected_en = os.path.join(root, en_files[0][1])
            
            base_name = RE_SUB_SUFFIX.sub("", zh_files[0][1])
            bilingual_path = os.path.join(root, f"{base_name}.双语.srt")
            
            try:
                with open(selected_zh, "r", encoding="utf-8", errors="ignore") as fz:
                    zh_content = fz.read()
                with open(selected_en, "r", encoding="utf-8", errors="ignore") as fe:
                    en_content = fe.read()

                zh_subs = parse_srt(zh_content)
                en_subs = parse_srt(en_content)
                merged_srt = merge_bilingual(zh_subs, en_subs)
                if merged_srt:
                    with open(bilingual_path, "w", encoding="utf-8") as fb:
                        fb.write(merged_srt)
                    print(f"[+] 已生成双语字幕: {os.path.basename(bilingual_path)}")
            except Exception as e:
                print(f"[-] 合并双语字幕出错: {e}")

def extract_standalone_audio_tracks(downloads_dir: str, ffmpeg_exe: str, audio_format: str = "mp3", verbose: bool = True) -> int:
    """从视频中抽取一份独立的音频文件 (MP3 320k / M4A / 无损原流)"""
    if not ffmpeg_exe:
        if verbose:
            print("[!] 未检测到 ffmpeg 组件，无法抽取独立音轨。请将 ffmpeg.exe 放在程序同级目录下。")
        return 0

    video_exts = (".mp4", ".mkv", ".webm", ".flv", ".avi", ".mov", ".ts", ".m4v")
    fmt = audio_format.lower().strip(".") or "mp3"
    extracted_count = 0

    for root, dirs, files in os.walk(downloads_dir):
        if ".temp" in root:
            continue
        
        for f in files:
            name, ext = os.path.splitext(f)
            if ext.lower() in video_exts:
                video_path = os.path.join(root, f)
                target_ext = ".m4a" if fmt == "copy" else f".{fmt}"
                audio_path = os.path.join(root, f"{name}{target_ext}")

                if os.path.isfile(audio_path) and os.path.getsize(audio_path) > 0:
                    continue

                if verbose:
                    print(f"[*] 正在从视频中提取独立原声音轨: {os.path.basename(video_path)} -> {target_ext} ...")

                success = False
                err_log = ""

                # 方案 1: 优选抽取第 1 音轨 (锁定原声) 并写入元数据
                cmd1 = [ffmpeg_exe, "-y", "-i", video_path, "-vn", "-map", "0:a:0?", "-map_metadata", "0"]
                if fmt == "mp3":
                    cmd1.extend(["-b:a", "320k", audio_path])
                elif fmt == "m4a":
                    cmd1.extend(["-c:a", "aac", "-b:a", "256k", audio_path])
                elif fmt == "wav":
                    cmd1.extend(["-c:a", "pcm_s16le", audio_path])
                elif fmt == "copy":
                    cmd1.extend(["-c:a", "copy", audio_path])
                else:
                    cmd1.extend(["-b:a", "320k", audio_path])

                try:
                    res1 = subprocess.run(cmd1, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
                    if res1.returncode == 0 and os.path.isfile(audio_path) and os.path.getsize(audio_path) > 0:
                        success = True
                    else:
                        err_log = res1.stderr
                except Exception as e:
                    err_log = str(e)

                # 方案 2: 若失败且为 MP3，执行高容错转码回退
                if not success and fmt == "mp3":
                    cmd2 = [ffmpeg_exe, "-y", "-i", video_path, "-vn", "-c:a", "libmp3lame", "-b:a", "320k", audio_path]
                    try:
                        res2 = subprocess.run(cmd2, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
                        if res2.returncode == 0 and os.path.isfile(audio_path) and os.path.getsize(audio_path) > 0:
                            success = True
                    except Exception:
                        pass

                # 方案 3: 若均失败，尝试无损原流提取为 .m4a
                if not success:
                    audio_fallback = os.path.join(root, f"{name}.m4a")
                    cmd3 = [ffmpeg_exe, "-y", "-i", video_path, "-vn", "-c:a", "copy", audio_fallback]
                    try:
                        res3 = subprocess.run(cmd3, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
                        if res3.returncode == 0 and os.path.isfile(audio_fallback) and os.path.getsize(audio_fallback) > 0:
                            success = True
                            audio_path = audio_fallback
                    except Exception:
                        pass

                if success:
                    sz_mb = round(os.path.getsize(audio_path) / (1024 * 1024), 2)
                    print(f"[+] ✅ 已成功保存独立原声音轨: {os.path.basename(audio_path)} ({sz_mb} MB)")
                    extracted_count += 1
                else:
                    if verbose:
                        first_err = err_log.strip().splitlines()[-1] if err_log.strip() else "未知原因"
                        print(f"[-] 提取独立音轨失败 ({os.path.basename(video_path)}): {first_err}")

    return extracted_count

def clean_temp_dir():
    temp_dir = os.path.join(DOWNLOADS_DIR, ".temp")
    if os.path.isdir(temp_dir):
        try:
            for item in os.listdir(temp_dir):
                item_path = os.path.join(temp_dir, item)
                if os.path.isdir(item_path):
                    shutil.rmtree(item_path, ignore_errors=True)
                elif os.path.isfile(item_path):
                    os.remove(item_path)
        except Exception:
            pass

# ======================= 参数构建与下载执行 =======================

def build_params_from_prefs(prefs: dict):
    mode = str(prefs.get("mode", "1"))
    container = prefs.get("container", "mp4").lower()
    cf = int(prefs.get("concurrent_fragments", 5))

    base_flags = [
        "--continue",
        "--retries", "10",
        "--fragment-retries", "10",
        "--concurrent-fragments", str(cf),
        "--no-warnings",
        "--progress",
    ]

    # 模式 5：仅下载封面图片
    if mode == "5":
        extra = base_flags + [
            "--skip-download",
            "--write-thumbnail",
            "--convert-thumbnails", "jpg"
        ]
        return None, None, extra

    # 模式 6：仅下载字幕
    if mode == "6":
        extra = base_flags + [
            "--skip-download",
            "--write-subs",
            "--write-auto-subs",
            "--sub-langs", "zh.*,en.*,en-orig",
            "--sub-format", "srt/vtt/best",
            "--convert-subs", "srt",
            "--compat-options", "no-live-chat"
        ]
        return None, None, extra

    # 模式 2, 3, 4：仅音频
    if mode in ["2", "3", "4"]:
        fmt_map = {"2": ("mp3", "320K"), "3": ("m4a", None), "4": ("wav", None)}
        audio_fmt, quality = fmt_map[mode]
        extra = base_flags + ["-x", "--audio-format", audio_fmt, "--embed-metadata"]
        if prefs.get("embed_thumbnail", True):
            extra.append("--embed-thumbnail")
        if prefs.get("save_thumbnail", True):
            extra.extend(["--write-thumbnail", "--convert-thumbnails", "jpg"])
        if quality:
            extra.extend(["--audio-quality", quality])
        return f"{AUDIO_TRACK_FILTER}/best", None, extra

    # 模式 1：常规视频
    res_map = {"1": None, "2": "2160", "3": "1440", "4": "1080", "5": "720", "6": "480"}
    codec_map = {"1": None, "2": "avc1", "3": "vp9", "4": "av01"}

    max_h = res_map.get(str(prefs.get("resolution", "1")), None)
    vcodec = codec_map.get(str(prefs.get("codec", "1")), None)

    extra_flags = base_flags + ["--embed-metadata"]
    sort_rules = []
    if max_h:
        sort_rules.append(f"res:{max_h}")
    else:
        sort_rules.append("res")
    sort_rules.extend(["fps", "codec", "size", "br"])
    extra_flags.extend(["-S", ",".join(sort_rules)])

    if max_h and vcodec:
        format_spec = (
            f"bv*[height<={max_h}][vcodec^={vcodec}]+({AUDIO_TRACK_FILTER})/"
            f"bv*[height<={max_h}]+({AUDIO_TRACK_FILTER})/"
            f"b[height<={max_h}]/bv*+({AUDIO_TRACK_FILTER})/b"
        )
    elif max_h:
        format_spec = (
            f"bv*[height<={max_h}]+({AUDIO_TRACK_FILTER})/"
            f"b[height<={max_h}]/bv*+({AUDIO_TRACK_FILTER})/b"
        )
    elif vcodec:
        format_spec = (
            f"bv*[vcodec^={vcodec}]+({AUDIO_TRACK_FILTER})/"
            f"bv*+({AUDIO_TRACK_FILTER})/b"
        )
    else:
        format_spec = f"bv*+({AUDIO_TRACK_FILTER})/b"
    
    if prefs.get("embed_chapters", True):
        extra_flags.append("--embed-chapters")
    if prefs.get("split_chapters", False):
        extra_flags.append("--split-chapters")

    if prefs.get("embed_thumbnail", True):
        extra_flags.append("--embed-thumbnail")
    if prefs.get("save_thumbnail", True):
        extra_flags.extend(["--write-thumbnail", "--convert-thumbnails", "jpg"])
    
    if prefs.get("download_subs", True):
        extra_flags.extend([
            "--write-subs",
            "--write-auto-subs",
            "--sub-langs", "zh.*,en.*,en-orig",
            "--sub-format", "srt/vtt/best",
            "--convert-subs", "srt",
            "--compat-options", "no-live-chat"
        ])

    return format_spec, container, extra_flags

def prompt_quality_choice(cfg: dict, is_playlist: bool = False, custom_title: str = "") -> tuple:
    """为当前视频或列表单独选择下载画质与格式"""
    prefs = cfg.get("preferences", {}).copy()
    default_res = str(prefs.get("resolution", "1"))
    default_mode = str(prefs.get("mode", "1"))
    
    res_names = {"1": "最佳画质", "2": "4K", "3": "2K", "4": "1080p", "5": "720p", "6": "480p"}
    
    if default_mode == "2":
        def_label = "MP3音频"
    elif default_mode in ["3", "4"]:
        def_label = "音频"
    else:
        def_label = res_names.get(default_res, "最佳画质")

    target_type = custom_title if custom_title else ("列表合集" if is_playlist else "单视频")
    prompt_str = f"[{target_type}] 选择画质 [1:最佳 2:4K 3:2K 4:1080p 5:720p 6:480p 7:MP3音频] (回车默认[{def_label}]): "
    
    choice = input(prompt_str).strip().lower()
    if choice in ['q', 'quit', 'skip']:
        return None, None
        
    if not choice:
        if prefs.get("mode") in ["2", "3", "4"]:
            label = "MP3音频" if prefs.get("mode") == "2" else "音频"
        else:
            label = res_names.get(str(prefs.get("resolution", "1")), "最佳画质")
        return prefs, label
        
    if choice == "7":
        prefs["mode"] = "2"
        return prefs, "MP3音频"
    elif choice in res_names:
        prefs["mode"] = "1"
        prefs["resolution"] = choice
        return prefs, res_names[choice]
    else:
        label = res_names.get(str(prefs.get("resolution", "1")), "最佳画质")
        return prefs, label

def render_terminal_bar(percent: float, total_str: str = "", speed_str: str = "", eta_str: str = "", bar_length: int = 26):
    percent = max(0.0, min(100.0, percent))
    filled_len = int(bar_length * percent / 100.0)
    try:
        bar = "█" * filled_len + "░" * (bar_length - filled_len)
    except Exception:
        bar = "=" * filled_len + "-" * (bar_length - filled_len)
    
    parts = [f"{percent:5.1f}%"]
    if total_str:
        parts.append(total_str.strip())
    if speed_str and speed_str != "Unknown":
        parts.append(speed_str.strip())
    if eta_str and eta_str != "Unknown":
        parts.append(f"ETA {eta_str.strip()}")
        
    line = f"\r [{bar}] " + " | ".join(parts)
    try:
        sys.stdout.write(line.ljust(80))
        sys.stdout.flush()
    except Exception:
        pass

def setup_plugins() -> list:
    """自动检测并挂载 pip 安装的 yt-dlp 插件 (如 bgutil-ytdlp-pot-provider)"""
    plugin_dirs = []
    local_plugin_dir = os.path.join(SCRIPT_DIR, "yt-dlp-plugins")
    os.makedirs(local_plugin_dir, exist_ok=True)
    plugin_dirs.append(local_plugin_dir)

    candidate_sp = []
    try:
        import site
        if hasattr(site, "getsitepackages"):
            candidate_sp.extend(site.getsitepackages())
        if hasattr(site, "getusersitepackages"):
            candidate_sp.append(site.getusersitepackages())
    except Exception:
        pass
    for p in sys.path:
        if "site-packages" in p or "dist-packages" in p:
            candidate_sp.append(p)

    seen = set()
    for sp in candidate_sp:
        if not sp or sp in seen or not os.path.isdir(sp):
            continue
        seen.add(sp)
        src_yt_plugins = os.path.join(sp, "yt_dlp_plugins")
        if os.path.isdir(src_yt_plugins):
            plugin_dirs.append(sp)
            dst_target = os.path.join(local_plugin_dir, "yt_dlp_plugins")
            try:
                if not os.path.exists(dst_target):
                    shutil.copytree(src_yt_plugins, dst_target, dirs_exist_ok=True)
            except Exception:
                pass
        try:
            for item in os.listdir(sp):
                if "bgutil" in item.lower():
                    plugin_dirs.append(sp)
                    break
        except Exception:
            pass

    return list(dict.fromkeys(plugin_dirs))

def stream_process_lines(pipe):
    """
    高性能流式读取子进程输出，遇 \r 或 \n 立即返回单行。
    利用底层缓冲区批量读入已就绪字节，兼顾 0 延迟刷新体验与极低 CPU 系统调用开销。
    """
    buf = ""
    raw_reader = getattr(pipe, "buffer", pipe)
    read_method = getattr(raw_reader, "read1", None)

    while True:
        try:
            if read_method:
                chunk_bytes = read_method(1024)
                if not chunk_bytes:
                    if buf:
                        yield buf
                    break
                chunk = chunk_bytes.decode("utf-8", errors="replace")
            else:
                chunk = pipe.read(1)
                if not chunk:
                    if buf:
                        yield buf
                    break
        except Exception:
            break

        buf += chunk
        while True:
            pos_r = buf.find("\r")
            pos_n = buf.find("\n")
            if pos_r == -1 and pos_n == -1:
                break
            if pos_r != -1 and pos_n != -1:
                pos = min(pos_r, pos_n)
            elif pos_r != -1:
                pos = pos_r
            else:
                pos = pos_n

            line = buf[:pos]
            advance = 2 if pos + 1 < len(buf) and buf[pos:pos+2] in ("\r\n", "\n\r") else 1
            buf = buf[pos+advance:]
            if line:
                yield line

def execute_download(ytdlp_exe: str, ffmpeg_exe: str, url: str, 
                     format_spec: str, merge_format: str, extra_flags: list,
                     proxy_url: str, cfg: dict, is_playlist: bool = False,
                     quality_label: str = ""):
    temp_dir = os.path.join(DOWNLOADS_DIR, ".temp")
    
    is_bili = "bilibili.com" in url.lower() or "b23.tv" in url.lower()
    is_yt = "youtube" in url.lower() or "youtu.be" in url.lower()
    
    if is_playlist:
        if is_bili:
            out_tmpl = "%(series|playlist_title|title)s/%(playlist_index&P{:02d} - |)s%(title)s/%(title)s.%(ext)s"
        else:
            out_tmpl = "%(playlist_title)s/%(playlist_index)02d - %(title)s/%(title)s.%(ext)s"
    else:
        out_tmpl = "%(title)s/%(title)s.%(ext)s"

    effective_proxy = "" if is_domestic_site(url) else proxy_url

    cmd = [
        ytdlp_exe,
        "--paths", f"home:{DOWNLOADS_DIR}",
        "--paths", f"temp:{temp_dir}",
        "--force-ipv4",
        "--force-overwrites",
        "-o", out_tmpl,
    ]

    for p_dir in setup_plugins():
        if os.path.isdir(p_dir):
            cmd.extend(["--plugin-dirs", p_dir])

    if is_yt:
        has_cookies = bool(get_cookie_args(cfg))
        if has_cookies:
            yt_client_arg = "youtube:player_client=tv,web_safari,web_embedded"
        else:
            yt_client_arg = "youtube:player_client=android_vr,tv,web_safari,web_embedded"
        cmd.extend(["--extractor-args", yt_client_arg])

    if effective_proxy: cmd.extend(["--proxy", effective_proxy])
    if ffmpeg_exe: cmd.extend(["--ffmpeg-location", ffmpeg_exe])
    if get_cookie_args(cfg): cmd.extend(get_cookie_args(cfg))
    if format_spec: cmd.extend(["-f", format_spec])
    if merge_format: cmd.extend(["--merge-output-format", merge_format])

    cmd.extend(extra_flags)
    cmd.append(url)

    sub_active = cfg.get("preferences", {}).get("download_subs", True)

    if not ffmpeg_exe:
        print("\n" + "!" * 65)
        print(" 【严重警告】未在当前目录检测到 ffmpeg.exe！")
        print(" 📌 降级原因: YouTube 和 B站 的 1080p/2K/4K 视频均为音画分离流。")
        print("    缺少 ffmpeg 会导致音视频无法合并，内核将被迫降级为 360p！")
        print(" 💡 解决办法: 请将 ffmpeg.exe 放入本程序同级目录，即可解锁最高画质。")
        print("!" * 65)
        c_low = input("是否仍然继续以 360p 低画质下载? (y/N，回车取消): ").strip().lower()
        if c_low not in ['y', 'yes']:
            print("[-] 已取消本次下载任务，请放置 ffmpeg.exe 后再试。")
            return -1

    if is_bili and not get_cookie_args(cfg):
        if quality_label in ["4K", "2K", "1080p", "最佳画质"]:
            print(" [提示] B站未登录游客最高仅支持 360p/480p。如需 1080p/4K，请在 [s] 设置中开启浏览器直读 Cookies。")

    tag = f" [{quality_label}]" if quality_label else ""
    print(f"\n[*] 开始下载{tag}: {url}")

    last_total_size = ""
    had_progress = False
    ret_code = 0
    proc = None

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True,
            encoding="utf-8",
            errors="replace"
        )

        for line in stream_process_lines(proc.stdout):
            m_pct = RE_PCT.search(line)
            if '[download]' in line and m_pct:
                had_progress = True
                try:
                    pct_val = float(m_pct.group(1))
                except Exception:
                    pct_val = 0.0
                    
                m_size = RE_SIZE.search(line)
                m_speed = RE_SPEED.search(line)
                m_eta = RE_ETA.search(line)
                
                if m_size:
                    last_total_size = m_size.group(1).strip()
                    
                size_str = last_total_size
                speed_str = m_speed.group(1) if m_speed else ""
                eta_str = m_eta.group(1) if m_eta else ""
                
                render_terminal_bar(pct_val, size_str, speed_str, eta_str)
            else:
                if "ERROR:" in line or "error:" in line.lower():
                    if had_progress:
                        sys.stdout.write("\n")
                        had_progress = False
                    print(line.strip())

        proc.wait()
        ret_code = proc.returncode

    except KeyboardInterrupt:
        kill_process_tree(proc)
        if had_progress:
            sys.stdout.write("\n")
        print("\n[!] 用户中断了当前下载任务。")
        return -1
    finally:
        if had_progress:
            sys.stdout.write("\n")
            sys.stdout.flush()

    if sub_active and cfg.get("preferences", {}).get("bilingual_subs", True):
        process_bilingual_subtitles(DOWNLOADS_DIR)
    if cfg.get("preferences", {}).get("save_audio_track", False):
        afmt = cfg.get("preferences", {}).get("audio_track_format", "mp3")
        extract_standalone_audio_tracks(DOWNLOADS_DIR, ffmpeg_exe, audio_format=afmt, verbose=True)
    clean_temp_dir()

    if ret_code == 0:
        print("[+] 下载完成")
    else:
        print(f"[!] 下载结束 (状态码: {ret_code})")
    return ret_code

def check_video_formats(ytdlp_exe: str, url: str, proxy_url: str, cfg: dict):
    print("\n" + "=" * 65)
    print("        🔍 正在探测该视频在平台上的所有画质与格式清单...")
    print("=" * 65)
    effective_proxy = "" if is_domestic_site(url) else proxy_url
    cmd = [ytdlp_exe, "-F", url]
    for p_dir in setup_plugins():
        if os.path.isdir(p_dir):
            cmd.extend(["--plugin-dirs", p_dir])
    if "youtube" in url.lower() or "youtu.be" in url.lower():
        has_cookies = bool(get_cookie_args(cfg))
        if has_cookies:
            yt_client_arg = "youtube:player_client=tv,web_safari,web_embedded"
        else:
            yt_client_arg = "youtube:player_client=android_vr,tv,web_safari,web_embedded"
        cmd.extend(["--extractor-args", yt_client_arg])
    if effective_proxy:
        cmd.extend(["--proxy", effective_proxy])
    if get_cookie_args(cfg):
        cmd.extend(get_cookie_args(cfg))
    try:
        subprocess.run(cmd)
    except Exception as e:
        print(f"[-] 格式探测失败: {e}")
    input("\n按回车键返回...")

def update_ytdlp(ytdlp_exe: str, proxy_url: str):
    print("\n[*] 正在检查并更新 yt-dlp 核心组件...")
    cmd = [ytdlp_exe, "-U"]
    if proxy_url:
        cmd.extend(["--proxy", proxy_url])
    try:
        subprocess.run(cmd)
        print("[+] 更新完成。")
    except Exception as e:
        print(f"[-] 更新失败: {e}")
    input("\n按回车键返回...")

def parse_urls(raw_input: str) -> list:
    """从文本、多行粘贴、短链接、BV号或文件路径中提取所有有效 URL"""
    raw_input = raw_input.strip(' "\'')
    
    if RE_BV.match(raw_input):
        return [f"https://www.bilibili.com/video/{raw_input}"]

    if os.path.isfile(raw_input) and raw_input.lower().endswith(".txt"):
        try:
            with open(raw_input, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.readlines()
            urls = []
            for l in lines:
                sub_urls = parse_urls(l.strip())
                urls.extend(sub_urls)
            return urls
        except Exception:
            pass

    found = RE_URL.findall(raw_input)
    if found:
        return found
    if "youtu" in raw_input or "bili" in raw_input:
        return [raw_input]
    return []

def resolve_playlist_intent(url: str) -> bool:
    """智能判定是否下载播放列表/分P合集，防止误把单视频当合集下载"""
    lower_u = url.lower()
    if "bilibili.com" in lower_u:
        if "?p=" in lower_u or "&p=" in lower_u:
            ans = input("\n[提示] 检测到该 B站 链接指定了单 P 分集。\n是否下载该视频的全部选集/分P合集? (y/N，回车默认仅下载当前单P): ").strip().lower()
            return ans in ['y', 'yes']
        return False

    if "list=" in lower_u:
        if "v=" in lower_u:
            ans = input("\n[提示] 检测到该链接属于一个 YouTube 合集/播放列表。\n是否下载整个播放列表合集? (y/N，回车默认仅下载当前单个视频): ").strip().lower()
            return ans in ['y', 'yes']
        return True
    return False

# ======================= 统一任务调度派发中心 (DRY 核心) =======================

def dispatch_download_tasks(urls: list, cfg: dict, local_ytdlp: str, local_ffmpeg: str,
                            forced_mode: str = None, prompt_choice: bool = True):
    """
    统一下载派发中心: 消除命令行启动、交互主循环、快捷指令间数百行重复代码
    """
    if not urls:
        print("[-] 未识别到有效链接。")
        return
    
    active_proxy = get_active_proxy(cfg)
    total = len(urls)

    if forced_mode:
        task_prefs = cfg.get("preferences", {}).copy()
        task_prefs["mode"] = str(forced_mode)
        mode_labels = {"2": "MP3音频", "3": "M4A音频", "4": "WAV音频", "5": "封面图片", "6": "双语字幕"}
        quality_label = mode_labels.get(str(forced_mode), "快捷模式")
    elif prompt_choice:
        title = f"批量统一 (共 {total} 个任务)" if total > 1 else "单任务"
        task_prefs, quality_label = prompt_quality_choice(cfg, is_playlist=False, custom_title=title)
        if task_prefs is None:
            print("[-] 下载任务已取消。")
            return
    else:
        task_prefs = cfg.get("preferences", {}).copy()
        quality_label = ""

    format_spec, merge_format, extra_flags = build_params_from_prefs(task_prefs)

    for idx, u in enumerate(urls, 1):
        if total > 1:
            print(f"\n[{idx}/{total}] 任务链接: {u}")
        is_pl = resolve_playlist_intent(u)
        run_flags = extra_flags.copy()
        run_flags.append("--yes-playlist" if is_pl else "--no-playlist")
        execute_download(
            local_ytdlp, local_ffmpeg, u,
            format_spec, merge_format, run_flags,
            active_proxy, cfg, is_playlist=is_pl,
            quality_label=quality_label
        )
    
    if total > 1:
        print(f"\n🎉 批量队列全部完成！共处理 {total} 个任务。")

# ======================= 菜单系统与向导 =======================

def advanced_menu(current_prefs: dict, cfg: dict):
    print("\n================== 进阶定制配置 ==================")
    new_prefs = current_prefs.copy()
    
    print("\n请选择下载模式:")
    print("  [1] 视频模式 (可附带封面、双语字幕、章节)")
    print("  [2] 音频MP3 (320k 极高音质)")
    print("  [3] 音频M4A")
    print("  [4] 音频WAV (无损)")
    print("  [5] 仅下载封面图片 (超清JPG)")
    print("  [6] 仅下载中英双语字幕 (SRT文件)")
    new_prefs["mode"] = input("选择模式 (回车保持当前): ").strip() or str(current_prefs.get('mode', '1'))

    if new_prefs["mode"] == "1":
        print("\n请选择最高画质:")
        print("  [1] 最佳画质(原画/不限)  [2] 4K  [3] 2K(1440p)  [4] 1080p  [5] 720p")
        new_prefs["resolution"] = input("选择画质 (回车保持当前): ").strip() or str(current_prefs.get('resolution', '1'))
        
        print("\n请选择视频编码偏好:")
        print("  [1] 自动匹配(画质优先)  [2] H.264优先(高兼容)  [3] VP9  [4] AV1")
        new_prefs["codec"] = input("选择编码 (回车保持当前): ").strip() or str(current_prefs.get('codec', '1'))

        print("\n请选择视频容器格式:")
        print("  [1] MP4 (高兼容性，推荐)  [2] MKV (高级格式，支持更丰富的软字幕效果)")
        ct = input("选择容器 [1-2] (回车保持当前): ").strip()
        if ct == "1": new_prefs["container"] = "mp4"
        elif ct == "2": new_prefs["container"] = "mkv"

        print("\n是否按章节自动切片为独立小视频片段?")
        print("  [1] 否 (保持单个整片，内嵌章节标记，推荐)  [2] 是 (按章节切成若干独立小视频)")
        sc = input("选择 [1-2] (回车保持当前): ").strip()
        if sc == "2": new_prefs["split_chapters"] = True
        elif sc == "1": new_prefs["split_chapters"] = False

        print("\n是否在视频文件夹中额外留存一份独立原声音轨文件 (如 MP3 320k)?")
        print("  [1] 是 (提取独立音频方便随时单独收听)  [2] 否 (仅保存在视频内)")
        sa_choice = input("选择 [1-2] (回车保持当前): ").strip()
        if sa_choice == "1":
            new_prefs["save_audio_track"] = True
            af = input("独立音频格式 [1: MP3 320k (默认/高兼容) 2: M4A 3: 无损原流提取(copy)]: ").strip()
            if af == "2": new_prefs["audio_track_format"] = "m4a"
            elif af == "3": new_prefs["audio_track_format"] = "copy"
            else: new_prefs["audio_track_format"] = "mp3"
        elif sa_choice == "2":
            new_prefs["save_audio_track"] = False

        print("\n是否保存独立封面图片文件 (JPG)?")
        print("  [1] 是 (保存在视频文件夹内)  [2] 否 (仅内嵌到视频中)")
        st = input("选择 [1-2] (回车保持当前): ").strip()
        if st == "1": new_prefs["save_thumbnail"] = True
        elif st == "2": new_prefs["save_thumbnail"] = False

        print("\n是否下载并合成中英双语字幕?")
        print("  [1] 是 (下载中英字幕轨并生成双语 SRT，推荐)  [2] 否")
        sb = input("选择 [1-2] (回车保持当前): ").strip()
        if sb == "1":
            new_prefs["download_subs"] = True
            new_prefs["bilingual_subs"] = True
        elif sb == "2":
            new_prefs["download_subs"] = False
            new_prefs["bilingual_subs"] = False

    save_it = input("\n是否将此配置保存为默认偏好? (y/N): ").strip().lower()
    if save_it in ['y', 'yes']:
        cfg["preferences"] = new_prefs
        save_config(cfg)
        print("✅ 偏好已更新并保存。")
        
    return build_params_from_prefs(new_prefs)[0], new_prefs.get("container", "mp4") if new_prefs["mode"] == "1" else None, build_params_from_prefs(new_prefs)[2], False

def settings_menu(cfg: dict, ytdlp_exe: str):
    while True:
        pref = cfg.get("preferences", {})
        sub_status = "开启 (中英双轨+自动合成双语SRT)" if pref.get("download_subs", True) else "已关闭"
        thumb_status = "开启 (保存JPG封面)" if pref.get("save_thumbnail", True) else "已关闭"
        frag_num = pref.get("concurrent_fragments", 5)
        proxy_desc = get_active_proxy(cfg) or "直连/TUN模式 (不设代理)"
        
        print("\n================== 系统与环境设置 ==================")
        print(f" 1. 代理配置 [当前: {proxy_desc} (国内站点自动智能直连)]")
        print(f" 2. Cookies 配置 [当前: {get_cookie_status_text(cfg)}]")
        print(f" 3. 独立封面保存开关 [当前: {thumb_status}]")
        audio_status = f"开启 ({pref.get('audio_track_format', 'mp3').upper()} 320k)" if pref.get("save_audio_track", False) else "已关闭"
        print(f" 4. 双语字幕下载开关 [当前: {sub_status}]")
        print(f" 5. 独立原声音轨留存开关 [当前: {audio_status}]")
        print(f" 6. 多线程并发切片加速 [当前: {frag_num} 条线程并发]")
        print(" 7. 在线升级 yt-dlp 核心组件")
        print(" 8. 安装/修复 YouTube 4K/1080p 令牌插件 (解决年龄限制视频仅360p)")
        print(" 9. 重新运行初始化向导")
        print(" 10. 返回主菜单")
        print("====================================================")
        choice = input("请选择操作 [1-10]: ").strip()
        if choice == "1":
            p = input("请输入代理端口或完整地址 (如 7890、http://127.0.0.1:7890，输入 0 为直连): ").strip()
            if p:
                if p in ["0", "none", "off", "直连"]:
                    cfg["custom_proxy"] = "none"
                    cfg["proxy_port"] = 0
                elif p.isdigit():
                    cfg["proxy_port"] = int(p)
                    cfg["custom_proxy"] = f"http://127.0.0.1:{p}"
                else:
                    cfg["custom_proxy"] = p
                save_config(cfg)
                print("✅ 代理配置已保存。")
        elif choice == "2":
            print(f"\nCookies 模式: [1]文件模式({CONFIG_DIR_NAME}/cookies.txt) [2]浏览器直读(推荐解锁B站4K) [3]关闭")
            c = input("选择 [1-3]: ").strip()
            if c == "1":
                cfg["cookie_mode"] = "file"
                save_config(cfg)
                print(f"✅ 已切换为文件模式，请确保 cookies.txt 放在 {CONFIG_DIR_NAME} 目录下。")
            elif c == "2":
                b = input("请输入浏览器名称 (如 edge, chrome, firefox，默认 edge): ").strip().lower() or "edge"
                cfg["cookie_mode"] = "browser"
                cfg["cookie_browser"] = b
                save_config(cfg)
                print(f"✅ 已切换为读取 {b} 浏览器。")
            elif c == "3":
                cfg["cookie_mode"] = "none"
                save_config(cfg)
                print("✅ 已停用 Cookies。")
        elif choice == "3":
            current_st = pref.get("save_thumbnail", True)
            cfg["preferences"]["save_thumbnail"] = not current_st
            save_config(cfg)
            status_desc = "开启 (每次下载视频附带保存超清 JPG 封面)" if cfg["preferences"]["save_thumbnail"] else "关闭"
            print(f"✅ 独立封面保存已切换为: {status_desc}")
        elif choice == "4":
            current_sb = pref.get("download_subs", True)
            cfg["preferences"]["download_subs"] = not current_sb
            cfg["preferences"]["bilingual_subs"] = not current_sb
            save_config(cfg)
            status_desc = "开启 (自动下载中英字幕并生成双语 SRT)" if cfg["preferences"]["download_subs"] else "关闭"
            print(f"✅ 双语字幕功能已切换为: {status_desc}")
        elif choice == "5":
            current_sa = pref.get("save_audio_track", False)
            cfg["preferences"]["save_audio_track"] = not current_sa
            if cfg["preferences"]["save_audio_track"]:
                af = input("请输入独立音频格式 [1: MP3 320k (默认) 2: M4A 3: copy无损原流]: ").strip()
                if af == "2": cfg["preferences"]["audio_track_format"] = "m4a"
                elif af == "3": cfg["preferences"]["audio_track_format"] = "copy"
                else: cfg["preferences"]["audio_track_format"] = "mp3"
            save_config(cfg)
            status_desc = f"开启 ({cfg['preferences'].get('audio_track_format', 'mp3').upper()})" if cfg["preferences"]["save_audio_track"] else "关闭"
            print(f"✅ 独立原声音轨留存已切换为: {status_desc}")
        elif choice == "6":
            fr = input("请输入并发分片线程数 [1-16] (回车默认 5): ").strip()
            if fr.isdigit() and 1 <= int(fr) <= 16:
                cfg["preferences"]["concurrent_fragments"] = int(fr)
                save_config(cfg)
                print(f"✅ 并发分片加速已设置为: {fr}")
        elif choice == "7":
            update_ytdlp(ytdlp_exe, get_active_proxy(cfg))
        elif choice == "8":
            print("\n" + "=" * 60)
            print("  正在安装/更新 YouTube 官方浏览器令牌插件 (yt-dlp-getpot-wpc)...")
            print("  该插件由 yt-dlp 核心维护者开发，直接利用本机浏览器自动生成 GVS 令牌")
            print("  彻底解锁【年龄限制 / 18禁】视频的 1080p/4K 限制，无需配置外部服务器")
            print("=" * 60)
            try:
                subprocess.run([sys.executable, "-m", "pip", "install", "-U", "yt-dlp-getpot-wpc"])
                print("✅ 插件安装完毕！如遇年龄限制视频，内核将自动调用浏览器生成验证令牌。")
            except Exception as e:
                print(f"[-] 安装失败: {e}")
            input("\n按回车键返回...")
        elif choice == "9":
            first_run_wizard(cfg)
            break
        elif choice == "10" or not choice:
            break

def first_run_wizard(cfg: dict):
    print("\n" + "=" * 70)
    print("      🎉 全能音视频下载助手 (YouTube / 哔哩哔哩 / 全网支持版) 🎉")
    print("=" * 70)
    print("说明: 所有选项均已配置最佳默认值，直接一路按【回车】即可快速完成设置。")
    
    detected_port = detect_common_ports()
    p_in = input(f"\n【1/7】网络代理端口 (回车默认 {detected_port}，输入 0 为直连/TUN模式): ").strip()
    if p_in == "0" or p_in.lower() in ["none", "direct", "直连"]:
        cfg["proxy_port"] = 0
        cfg["custom_proxy"] = "none"
    else:
        cfg["proxy_port"] = int(p_in) if p_in.isdigit() else detected_port
        cfg["custom_proxy"] = f"http://127.0.0.1:{cfg['proxy_port']}"

    print("\n【2/7】Cookies 登录策略 (推荐选 2 浏览器读取，可直接解锁 B站大会员/4K 与 YouTube 会员)")
    print(f"  [1] 文件模式 ({CONFIG_DIR_NAME}/cookies.txt)  [2] 浏览器直读 (推荐，回车默认)  [3] 暂时跳过")
    c_choice = input("选择 [1-3] (回车默认 2): ").strip() or "2"
    if c_choice == "1":
        cfg["cookie_mode"] = "file"
    elif c_choice == "3":
        cfg["cookie_mode"] = "none"
    else:
        cfg["cookie_mode"] = "browser"
        cfg["cookie_browser"] = input("浏览器名称 (回车默认 edge，支持 chrome/firefox 等): ").strip().lower() or "edge"

    print("\n【3/7】默认视频画质上限")
    print("  [1] 最佳画质(原画/不限，回车默认)  [2] 4K  [3] 2K(1440p)  [4] 1080p  [5] 720p")
    cfg["preferences"]["resolution"] = input("选择 [1-5] (回车默认 1): ").strip() or "1"

    print("\n【4/7】编码与封装格式 (支持智能链式回退，告别断崖式降级)")
    print("  [1] 自动匹配(画质优先/默认)  [2] H.264优先(老设备高兼容)  [3] VP9  [4] AV1")
    cfg["preferences"]["codec"] = input("视频编码偏好 [1-4] (回车默认 1): ").strip() or "1"
    
    print("  封装容器格式: [1] MP4 (通用高兼容，默认)  [2] MKV (高级格式，支持丰富软字幕)")
    ct_in = input("封装容器选择 [1-2] (回车默认 1): ").strip() or "1"
    cfg["preferences"]["container"] = "mkv" if ct_in == "2" else "mp4"

    print("\n【5/7】多线程并发切片加速 (突破单连接限速，跑满宽带)")
    frag_in = input("请输入分片并发线程数 [1-16] (回车默认 5 线程并发): ").strip()
    if frag_in.isdigit() and 1 <= int(frag_in) <= 16:
        cfg["preferences"]["concurrent_fragments"] = int(frag_in)
    else:
        cfg["preferences"]["concurrent_fragments"] = 5

    print("\n【6/7】超清独立封面图下载 (JPG 格式)")
    print("  是否在视频文件夹中额外留存一张同名超清 JPG 封面图?")
    print("  [1] 是 (推荐，方便在资源管理器中直接预览海报，回车默认)  [2] 否 (仅内嵌到视频文件)")
    th_in = input("选择 [1-2] (回车默认 1): ").strip() or "1"
    cfg["preferences"]["save_thumbnail"] = (th_in == "1")

    print("\n【7/8】独立原声音轨留存 (MP3 320k)")
    print("  是否在下载视频的同时，在同级文件夹额外保存一份单独的原声音频文件 (MP3)?")
    print("  [1] 是 (方便拷贝到手机/车载音乐独立收听)  [2] 否 (仅保存在视频内，回车默认)")
    sa_in = input("选择 [1-2] (回车默认 2): ").strip() or "2"
    cfg["preferences"]["save_audio_track"] = (sa_in == "1")
    cfg["preferences"]["audio_track_format"] = "mp3"

    print("\n【8/8】中英双语字幕与视频章节")
    print("  [1] 全功能开启 (下载中英双轨 + 自动对齐合成双语SRT + 内嵌章节标记，强烈推荐)")
    print("  [2] 仅内嵌章节标记 (不下载字幕)")
    print("  [3] 极简模式 (不下载字幕，不嵌入章节)")
    sub_in = input("选择 [1-3] (回车默认 1): ").strip() or "1"
    if sub_in == "1":
        cfg["preferences"]["download_subs"] = True
        cfg["preferences"]["bilingual_subs"] = True
        cfg["preferences"]["embed_chapters"] = True
    elif sub_in == "2":
        cfg["preferences"]["download_subs"] = False
        cfg["preferences"]["bilingual_subs"] = False
        cfg["preferences"]["embed_chapters"] = True
    else:
        cfg["preferences"]["download_subs"] = False
        cfg["preferences"]["bilingual_subs"] = False
        cfg["preferences"]["embed_chapters"] = False

    cfg["first_run"] = False
    save_config(cfg)
    print("\n" + "=" * 70)
    print("✅ 全功能初始化配置完成！支持直接粘贴 YouTube / B站链接或拖拽文件极速下载。")
    print("提示: 随时可在主界面输入 [m] 修改偏好 或 输入 [s] 进入系统设置重新调整。")
    print("=" * 70)
    input("按回车键进入主界面...")

# ======================= 主程序入口 =======================

def main():
    cfg = load_config()
    local_ytdlp = find_local_executable("yt-dlp")
    local_ffmpeg = find_local_executable("ffmpeg")

    if not local_ytdlp:
        print("[错误] 未在当前目录下找到 yt-dlp.exe！")
        pause_exit(1)

    if not local_ffmpeg:
        print("\n================================================================")
        print(" 【严重警告】未在当前目录检测到 ffmpeg.exe！")
        print(" yt-dlp 将无法合成 1080p/2K/4K 分离流，被迫降级为 360p！")
        print(" 请将 ffmpeg.exe 放入程序同级目录下。")
        print("================================================================\n")

    if cfg.get("first_run", True):
        first_run_wizard(cfg)

    ffmpeg_text = "已就绪" if local_ffmpeg else "❌ 缺失 (强制降级 360p)"

    # 1. 命令行直接调用或多文件拖拽启动
    if len(sys.argv) > 1:
        raw_args = " ".join(sys.argv[1:])
        targets = parse_urls(raw_args)
        if targets:
            dispatch_download_tasks(targets, cfg, local_ytdlp, local_ffmpeg, prompt_choice=True)
            pause_exit(0)

    # 2. 交互式主循环
    while True:
        try:
            active_proxy = get_active_proxy(cfg)
            proxy_show = active_proxy if active_proxy else "直连/TUN"
            print(f"\n[状态] 代理: {proxy_show} | FFmpeg: {ffmpeg_text} | 当前: {format_pref_summary(cfg.get('preferences', {}))}")
            print("指令: 粘贴链接直接下载 | e 补提已有视频音轨 | f 探测画质 | c 封面 | z 字幕 | a 音频 | b 批量 | s 设置 | 回车退出")

            raw_in = input("输入链接或指令: ").strip()
            if not raw_in:
                break
            
            cmd_key = raw_in.lower()
            
            # 补提已有视频音轨
            if cmd_key == 'e':
                print("\n[*] 正在扫描 downloads 目录下所有视频并补提独立原声音轨...")
                afmt = cfg.get("preferences", {}).get("audio_track_format", "mp3")
                count = extract_standalone_audio_tracks(DOWNLOADS_DIR, local_ffmpeg, audio_format=afmt, verbose=True)
                if count > 0:
                    print(f"🎉 处理完成！已为 {count} 个视频补全了独立原声音轨。")
                else:
                    print("[i] 未发现缺少独立音轨的视频文件，或未检测到 ffmpeg 组件。")
                continue

            # 画质探测诊断模式
            elif cmd_key == 'f':
                url_in = input("\n[画质探测模式] 请输入链接 (回车取消): ").strip()
                urls = parse_urls(url_in)
                if urls:
                    check_video_formats(local_ytdlp, urls[0], active_proxy, cfg)
                continue

            # 快捷仅下封面
            elif cmd_key == 'c':
                url_in = input("\n[仅下封面模式] 请输入链接 (直接回车取消): ").strip()
                dispatch_download_tasks(parse_urls(url_in), cfg, local_ytdlp, local_ffmpeg, forced_mode="5", prompt_choice=False)
                continue

            # 快捷仅下双语字幕
            elif cmd_key == 'z':
                url_in = input("\n[仅下双语字幕模式] 请输入链接 (直接回车取消): ").strip()
                dispatch_download_tasks(parse_urls(url_in), cfg, local_ytdlp, local_ffmpeg, forced_mode="6", prompt_choice=False)
                continue

            # 快捷仅下 MP3 音频
            elif cmd_key == 'a':
                url_in = input("\n[仅下 MP3 音频模式] 请输入链接 (直接回车取消): ").strip()
                dispatch_download_tasks(parse_urls(url_in), cfg, local_ytdlp, local_ffmpeg, forced_mode="2", prompt_choice=False)
                continue

            # 批量下载队列
            elif cmd_key == 'b':
                print("\n================== 批量下载队列 ==================")
                print(" 支持方式: 1. 一次性粘贴多个链接 (空格或换行分隔)")
                print("           2. 直接拖入包含多个链接的 .txt 文本文件")
                raw = input("\n请输入链接列表或 txt 文件路径: ").strip()
                dispatch_download_tasks(parse_urls(raw), cfg, local_ytdlp, local_ffmpeg, prompt_choice=True)
                continue

            # 在线升级内核
            elif cmd_key == 'u':
                update_ytdlp(local_ytdlp, active_proxy)
                continue

            # 修改偏好与临时执行
            elif cmd_key == 'm':
                advanced_menu(cfg.get("preferences", {}), cfg)
                url_in = input("\n请输入链接 (直接回车返回主菜单): ").strip()
                dispatch_download_tasks(parse_urls(url_in), cfg, local_ytdlp, local_ffmpeg, prompt_choice=False)
                continue

            # 系统设置
            elif cmd_key == 's':
                settings_menu(cfg, local_ytdlp)
                continue

            elif cmd_key in ['q', 'exit', 'quit']:
                break

            # 默认：直接处理输入的链接（单条/多条/txt路径）
            else:
                urls = parse_urls(raw_in)
                dispatch_download_tasks(urls, cfg, local_ytdlp, local_ffmpeg, prompt_choice=True)

        except KeyboardInterrupt:
            print("\n[!] 检测到中断信号。输入回车继续，或输入 q 退出。")
            cont = input().strip().lower()
            if cont in ['q', 'exit', 'quit']:
                break

if __name__ == "__main__":
    main()
