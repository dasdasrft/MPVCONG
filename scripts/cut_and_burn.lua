--[[
    mpv 视频无损切片与字幕硬压制合一脚本 (全能版 - 智能路径兼容与流媒体增强版)
    文件名: cut_and_burn.lua
    
    【核心特性与修复】：
      - 智能本地路径还原 (彻底根除“无效的本地路径”报错与转义异常)：
        * 自动剥离浏览器/桌面拖拽产生的 file://、file:/// 前缀，自动进行 URL 百分号解码（空格与中文编码）
        * 相对路径结合 mpv 工作目录自动补全为规范绝对路径
        * 全面支持播放在线流媒体（YouTube/Bilibili/IPTV等），切片与音频提取自动识别真实流并保存至 cutfragments
      - 视频无损极速切片 (按 c 标记起点，再次按 c 标记终点，秒级无损输出)
      - 字幕 GPU 硬件压制 (按 Ctrl+b 一键调用 AMD 9070 XT AV1 AMF / NVENC / QSV 压制)
      - 独立原声音轨提取 (按 Ctrl+e 一键提取当前播放音轨为 320k MP3/AAC)
--]]

local mp = require 'mp'
local utils = require 'mp.utils'
local opt = require 'mp.options'

-- ====================================================
-- 配置区域 (可在此自定义默认参数)
-- ====================================================
local opts = {
    -- 统一输出目录：默认保存至 mpv 配置目录下的 cutfragments 文件夹
    output_dir = "~~/cutfragments",

    -- 切片配置
    capture_audio = true,
    prevent_black_frames = true,

    -- 压制配置
    video_codec = "av1",              -- 压制编码格式: "av1" (RX 9070 XT 硬件加速) / "h264"
    gpu_encoder = "amf",              -- 硬件加速平台: "amf" (AMD) / "nvenc" / "qsv" / "auto" / "cpu"
    bitrate_mode = "match_original",  -- 码率模式: "match_original" (1:1体积匹配) / "custom_bitrate"
    target_bitrate_mbps = 7.0,        -- 自定义码率数值 (Mbps)
    overwrite_existing = false,       -- 是否覆盖同名文件 (false 为自动递增重命名 _1.mp4, _2.mp4)
    osd_interval = 0.5,               -- OSD 刷新间隔 (秒)
    lock_cfr = true,                  -- 强制锁定恒定帧率 (CFR) 与时间戳对齐，杜绝加速漂移
    smart_audio_map = true,           -- 智能映射 mpv 当前选中的音轨，避免压制后多音轨语言选错
    cleanup_aborted_files = true,     -- 压制取消或失败时自动清除未完成的破损文件

    -- 音频提取配置
    audio_format = "mp3",             -- 提取音频格式: "mp3" (320k) / "m4a" / "copy"
    audio_bitrate = "320k"            -- MP3 码率: "320k"
}

-- 读取外部配置文件 script-opts/cut_and_burn.conf (若存在)
opt.read_options(opts, "cut_and_burn")
-- ====================================================

-- ----------------- 通用文件与目录工具 -----------------
local function get_file_dir(path)
    if not path then return nil end
    return path:match("^(.*)[/\\]")
end

local function get_file_stem(path)
    if not path then return nil end
    local filename = path:match("[^/\\]+$")
    return filename:match("^(.*)%.[^%.]+$") or filename
end

local function get_system_temp_dir()
    return os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
end

-- 自动探测并获取可用的 FFmpeg 绝对路径 (支持便携版与环境变量)
local cached_ffmpeg_path = nil
local function get_ffmpeg_path()
    if cached_ffmpeg_path then return cached_ffmpeg_path end

    -- 1. 检查 mpv 配置目录同级及其父目录（便携版标准布局：E:\MPV\mpv.exe 和 E:\MPV\ffmpeg.exe）
    local config_dir = mp.command_native({"expand-path", "~~/"})
    if config_dir and config_dir ~= "" then
        config_dir = config_dir:gsub("\\", "/")
        local candidates = {
            utils.join_path(config_dir, "ffmpeg.exe"),
            utils.join_path(config_dir, "ffmpeg"),
            utils.join_path(config_dir, "../ffmpeg.exe"),
            utils.join_path(config_dir, "../ffmpeg"),
            utils.join_path(config_dir, "../../ffmpeg.exe")
        }
        for _, c in ipairs(candidates) do
            local norm = mp.command_native({"normalize-path", c}) or c
            norm = norm:gsub("\\", "/")
            local info = utils.file_info(norm)
            if info and not info.is_dir then
                cached_ffmpeg_path = norm
                mp.msg.info("Auto-detected FFmpeg binary: " .. norm)
                return norm
            end
        end
    end

    -- 2. 检查 mpv 工作目录
    local cwd = mp.get_property("working-directory") or ""
    if cwd ~= "" then
        cwd = cwd:gsub("\\", "/")
        local c = utils.join_path(cwd, "ffmpeg.exe")
        local info = utils.file_info(c)
        if info and not info.is_dir then
            cached_ffmpeg_path = c
            return c
        end
    end

    -- 3. 回退到环境变量 PATH
    cached_ffmpeg_path = "ffmpeg"
    return "ffmpeg"
end

-- URL 百分号编码解码函数 (%20 -> 空格, 中文字符还原)
local function url_decode(str)
    if not str then return "" end
    str = str:gsub("+", " ")
    str = str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

-- 清洗文件名中的非法字符 (移除 Windows 禁用字符与控制符，避免 UTF-8 字符截断乱码)
local function sanitize_filename(name)
    if not name or name == "" then return "stream_clip" end
    local clean = name:gsub('[<>:"/\\|%?%*]', "_")
    clean = clean:gsub("%c", "_")
    clean = clean:gsub("%s+", " ")
    clean = clean:match("^%s*(.-)%s*$")
    if clean == "" or clean == "." or clean == ".." then
        return "stream_clip"
    end
    if #clean > 120 then
        local len = 120
        while len > 0 and (clean:byte(len) >= 128 and clean:byte(len) < 192) do
            len = len - 1
        end
        clean = clean:sub(1, len)
    end
    return clean
end

-- 智能解析并规范化媒体路径
local function resolve_media_source()
    local raw_path = mp.get_property("path")
    if not raw_path or raw_path == "" then
        return false, nil, nil, false, "未检测到正在播放的视频，请先播放媒体文件！"
    end

    -- 1. 剥离 file:// 协议头 (常见于拖拽打开或浏览器调用)
    if raw_path:match("^file://") then
        local local_p = raw_path:gsub("^file://localhost/", "")
        local_p = local_p:gsub("^file:///", "")
        local_p = local_p:gsub("^file://", "")
        local_p = url_decode(local_p)
        if local_p:match("^/[%a]:") then
            local_p = local_p:sub(2)
        end
        raw_path = local_p
    end

    -- 2. 检查是否为在线网络流 (http://, https://, ytdl:// 等)
    if raw_path:match("^%a+://") then
        local stream_url = mp.get_property("stream-open-filename") or raw_path
        if stream_url:match("^ytdl://") then
            stream_url = stream_url:gsub("^ytdl://", "")
        end
        local media_title = mp.get_property("media-title")
        local stem = sanitize_filename(media_title or raw_path:match("([^/?#]+)$") or "online_stream")
        return false, stream_url, stem, true, nil
    end

    -- 3. 本地文件：正斜杠统一化与绝对路径补全
    local clean_path = raw_path:gsub("\\", "/")
    
    -- 若为相对路径，结合 mpv 当前工作目录拼装为规范绝对路径
    local is_abs = clean_path:match("^%a+:/") or clean_path:match("^/")
    if not is_abs then
        local cwd = mp.get_property("working-directory") or ""
        cwd = cwd:gsub("\\", "/")
        if cwd ~= "" then
            if not cwd:match("/$") then cwd = cwd .. "/" end
            clean_path = cwd .. clean_path
        end
    end

    -- 调用 mpv 内建 normalize-path 消除路径冗余
    local norm = mp.command_native({"normalize-path", clean_path})
    if norm and norm ~= "" then
        clean_path = norm:gsub("\\", "/")
    end

    local stem = get_file_stem(clean_path)
    if not stem or stem == "" then
        local title = mp.get_property("media-title")
        stem = sanitize_filename(title or "video_clip")
    end

    return true, clean_path, stem, false, nil
end

local function safe_remove(filepath)
    if not filepath then return end
    local ok = os.remove(filepath)
    if not ok then
        mp.add_timeout(0.3, function()
            local ok2 = os.remove(filepath)
            if not ok2 then
                mp.add_timeout(1.2, function()
                    os.remove(filepath)
                end)
            end
        end)
    end
end

local function cleanup_directory_leftover_temps(dir)
    if not dir or dir == "" then return end
    local files = utils.readdir(dir, "files")
    if files then
        for _, fname in ipairs(files) do
            if fname:match("^%.?mpv_burn_.*%.tmp$") then
                safe_remove(utils.join_path(dir, fname))
            end
        end
    end
end

local function ensure_dir_exists(dir)
    if not dir or dir == "" then return false end
    local info = utils.file_info(dir)
    if info and info.is_dir then return true end

    if package.config:sub(1,1) == '\\' then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end

    local check = utils.file_info(dir)
    return check and check.is_dir
end

local function get_target_output_dir(video_path, is_stream)
    local raw_dir = opts.output_dir
    if is_stream or not raw_dir or raw_dir == "" or raw_dir == "same" then
        if not is_stream and (raw_dir == "same" or raw_dir == "") then
            local dir = get_file_dir(video_path)
            if dir and dir ~= "" and ensure_dir_exists(dir) then
                return dir
            end
        end
        raw_dir = "~~/cutfragments"
    end

    local expanded = mp.command_native({"expand-path", raw_dir})
    if expanded and expanded ~= "" then
        expanded = expanded:gsub("\\", "/")
        if ensure_dir_exists(expanded) then
            return expanded
        end
    end

    return (not is_stream and get_file_dir(video_path)) or get_system_temp_dir():gsub("\\", "/")
end

local function get_unique_output_path(dir, base_stem, ext)
    local out_path = utils.join_path(dir, base_stem .. ext)
    if opts.overwrite_existing then
        return out_path
    end

    if not utils.file_info(out_path) then
        return out_path
    end

    local counter = 1
    while true do
        local candidate = utils.join_path(dir, string.format("%s_%d%s", base_stem, counter, ext))
        if not utils.file_info(candidate) then
            return candidate
        end
        counter = counter + 1
    end
end

local function format_time(seconds)
    if not seconds or seconds < 0 then return "00:00:00" end
    local s = math.floor(seconds)
    local ms = math.floor((seconds - s) * 1000)
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    return string.format("%02d:%02d:%02d.%03d", h, m, sec, ms)
end

local function make_progress_bar(percent, width)
    width = width or 20
    local p = math.min(100, math.max(0, percent))
    local filled = math.floor(p / 100 * width)
    local empty = width - filled
    return string.rep("█", filled) .. string.rep("░", empty)
end

-- ===================================================================
-- 模块一：无损切片 (Slicing)
-- ===================================================================
local cut_start = nil
local is_cutting = false

local function slice_current_range(start_time, end_time)
    local is_local, video_path, stem, is_stream, err_msg = resolve_media_source()
    if not video_path then
        mp.osd_message(err_msg or "无法获取当前媒体路径，请确认是否正在播放！", 3)
        return
    end

    local dir = get_target_output_dir(video_path, is_stream)
    local ext = "mp4"
    if is_local then
        ext = video_path:match("%.([^%.]+)$") or "mp4"
    end

    local start_str = format_time(start_time):gsub(":", "-")
    local end_str = format_time(end_time):gsub(":", "-")
    local base_name = string.format("%s_%s-%s", stem, start_str, end_str)
    local out_path = get_unique_output_path(dir, base_name, "." .. ext)

    local target_desc = is_stream and "在线流媒体切片" or "本地无损切片"
    mp.osd_message(string.format("正在%s: %s -> %s", target_desc, format_time(start_time), format_time(end_time)), 4)
    is_cutting = true

    local duration = math.max(0.1, end_time - start_time)
    local ffmpeg_bin = get_ffmpeg_path()
    local args = {
        ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error"
    }

    if is_stream then
        table.insert(args, "-reconnect")
        table.insert(args, "1")
        table.insert(args, "-reconnect_streamed")
        table.insert(args, "1")
        table.insert(args, "-reconnect_delay_max")
        table.insert(args, "5")
    end

    table.insert(args, "-ss")
    table.insert(args, tostring(start_time))
    table.insert(args, "-i")
    table.insert(args, video_path)
    table.insert(args, "-t")
    table.insert(args, tostring(duration))
    table.insert(args, "-map")
    table.insert(args, "0")
    table.insert(args, "-c")
    table.insert(args, "copy")
    table.insert(args, "-ignore_unknown")

    if not opts.capture_audio then
        table.insert(args, "-an")
    end

    if opts.prevent_black_frames then
        table.insert(args, "-avoid_negative_ts")
        table.insert(args, "make_zero")
    end

    table.insert(args, out_path)

    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true
    }, function(success, result, error)
        is_cutting = false
        if success and result and result.status == 0 then
            mp.osd_message(string.format("【切片成功】\n已保存至:\n%s", out_path), 5)
            mp.msg.info("Sliced successfully: " .. out_path)
        else
            if is_stream then
                mp.osd_message("流媒体切片失败！部分分块或加密流（如YouTube）建议先下载到本地后再切片", 5)
            else
                mp.osd_message("切片失败，请检查控制台日志！", 4)
            end
            mp.msg.error("Slicing failed: " .. tostring((result and result.stderr) or error))
        end
    end)
end

local function toggle_slicing_mark()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end

    if not cut_start then
        cut_start = pos
        mp.osd_message(string.format("已标记切片起点: %s\n再次按下 c 标记终点并输出", format_time(cut_start)), 4)
    else
        local cut_end = pos
        if cut_end <= cut_start then
            mp.osd_message("切片终点必须大于起点，请重新标记！", 3)
            return
        end
        local s, e = cut_start, cut_end
        cut_start = nil
        slice_current_range(s, e)
    end
end

local function clear_slicing_mark()
    if cut_start then
        cut_start = nil
        mp.osd_message("已清除切片起点标记", 2)
    end
end

local function toggle_slicing_audio()
    opts.capture_audio = not opts.capture_audio
    mp.osd_message("切片音频捕捉: " .. (opts.capture_audio and "开启" or "关闭"), 2)
end

-- ===================================================================
-- 模块二：字幕压制 (Subtitle Burning with GPU Acceleration)
-- ===================================================================
local active_burn_process = nil
local burn_timer = nil
local current_progress_file = nil
local current_burn_output_file = nil

local function escape_ffmpeg_filter_path(path)
    if not path then return "" end
    local p = path:gsub("\\", "/")
    p = p:gsub(":", "\\:")
    p = p:gsub("'", "\\'")
    p = p:gsub("%[", "\\[")
    p = p:gsub("%]", "\\]")
    return p
end

local function get_current_sub_path()
    local track = mp.get_property_native("current-tracks/sub")
    if track and track["external-filename"] then
        local sub_p = track["external-filename"]
        if sub_p:match("^file://") then
            sub_p = url_decode(sub_p:gsub("^file://localhost/", ""):gsub("^file:///", ""):gsub("^file://", ""))
            if sub_p:match("^/[%a]:") then sub_p = sub_p:sub(2) end
        end
        return sub_p:gsub("\\", "/")
    end

    local track_list = mp.get_property_native("track-list")
    if track_list then
        for _, t in ipairs(track_list) do
            if t.type == "sub" and t.selected and t["external-filename"] then
                local sub_p = t["external-filename"]
                if sub_p:match("^file://") then
                    sub_p = url_decode(sub_p:gsub("^file://localhost/", ""):gsub("^file:///", ""):gsub("^file://", ""))
                    if sub_p:match("^/[%a]:") then sub_p = sub_p:sub(2) end
                end
                return sub_p:gsub("\\", "/")
            end
        end
    end

    local is_local, video_path, stem = resolve_media_source()
    if is_local and video_path then
        local dir = get_file_dir(video_path) or "."
        stem = stem or get_file_stem(video_path)
        local candidates = {
            utils.join_path(dir, stem .. ".styled.ass"),
            utils.join_path(dir, stem .. ".ass"),
            utils.join_path(dir, stem .. ".styled.srt"),
            utils.join_path(dir, stem .. ".zh.srt"),
            utils.join_path(dir, stem .. ".srt"),
            utils.join_path(dir, stem .. ".bilingual.srt"),
        }
        for _, c in ipairs(candidates) do
            local f = io.open(c, "r")
            if f then
                f:close()
                return c
            end
        end
    end

    return nil
end

local function build_subtitle_filter_str(sub_path)
    local escaped_sub = escape_ffmpeg_filter_path(sub_path)
    local is_srt = (sub_path:lower():match("%.srt$") ~= nil)

    local sub_pos = mp.get_property_number("sub-pos", 100)
    local sub_margin_y = mp.get_property_number("sub-margin-y", 36)
    local sub_margin_x = mp.get_property_number("sub-margin-x", 36)
    local sub_scale = mp.get_property_number("sub-scale", 1.0)
    local sub_align_y = mp.get_property("sub-align-y", "bottom")
    local sub_align_x = mp.get_property("sub-align-x", "center")
    local v_height = mp.get_property_number("video-params/h") or mp.get_property_number("dheight") or 1080

    local alignment = 2
    if sub_align_y == "top" then
        if sub_align_x == "left" then alignment = 7
        elseif sub_align_x == "right" then alignment = 9
        else alignment = 8 end
    elseif sub_align_y == "center" then
        if sub_align_x == "left" then alignment = 4
        elseif sub_align_x == "right" then alignment = 6
        else alignment = 5 end
    else
        if sub_align_x == "left" then alignment = 1
        elseif sub_align_x == "right" then alignment = 3
        else alignment = 2 end
    end

    local margin_v = sub_margin_y
    if sub_align_y == "bottom" then
        if sub_pos < 100 then
            local pos_offset = math.floor((100 - sub_pos) * (v_height / 100))
            margin_v = margin_v + pos_offset
        end
    elseif sub_align_y == "top" then
        if sub_pos > 0 then
            local pos_offset = math.floor(sub_pos * (v_height / 100))
            margin_v = margin_v + pos_offset
        end
    end

    local font_size = math.max(16, math.floor(48 * sub_scale))
    -- 统一使用 subtitles 滤镜：原生兼容 ASS/SSA/SRT 等所有格式，并完整支持 force_style 样式覆盖
    local filter_name = "subtitles"
    local style_override = string.format("Alignment=%d,MarginV=%d,MarginL=%d,MarginR=%d,FontSize=%d",
        alignment, margin_v, sub_margin_x, sub_margin_x, font_size)

    return string.format("%s=filename='%s':force_style='%s'", filter_name, escaped_sub, style_override), sub_pos
end

local function calculate_target_video_bitrate(total_duration)
    if opts.bitrate_mode == "custom_bitrate" and opts.target_bitrate_mbps then
        return math.floor(opts.target_bitrate_mbps * 1000000)
    end

    local v_bitrate = mp.get_property_number("video-bitrate")
    if v_bitrate and v_bitrate > 500000 then
        return math.floor(v_bitrate)
    end

    local file_size = mp.get_property_number("file-size")
    if file_size and total_duration and total_duration > 10 then
        local calc_bps = (file_size * 8) / total_duration
        local audio_reserve = 256000
        local target_v = math.max(1000000, calc_bps - audio_reserve)
        return math.floor(target_v)
    end

    return 7000000
end

local function get_audio_encoder_args()
    local a_codec = mp.get_property("audio-codec-name") or ""
    a_codec = a_codec:lower()

    if a_codec == "aac" or a_codec == "mp3" or a_codec == "ac3" or a_codec == "eac3" then
        return { "-c:a", "copy" }
    else
        return { "-c:a", "aac", "-b:a", "256k" }
    end
end

local function get_burn_encoder_args(encoder_type, target_bps)
    local max_bps = math.floor(target_bps * 1.5)
    local b_str = tostring(target_bps)
    local max_str = tostring(max_bps)

    if opts.video_codec == "av1" then
        if encoder_type == "amf" then
            return {
                "-c:v", "av1_amf",
                "-quality", "quality",
                "-rc", "vbr_latency",
                "-b:v", b_str,
                "-maxrate", max_str
            }
        elseif encoder_type == "nvenc" then
            return {
                "-c:v", "av1_nvenc",
                "-preset", "p5",
                "-b:v", b_str,
                "-maxrate", max_str
            }
        elseif encoder_type == "qsv" then
            return {
                "-c:v", "av1_qsv",
                "-preset", "fast",
                "-b:v", b_str,
                "-maxrate", max_str
            }
        else
            return {
                "-c:v", "libsvtav1",
                "-preset", "6",
                "-b:v", b_str
            }
        end
    else
        if encoder_type == "amf" then
            return {
                "-c:v", "h264_amf",
                "-quality", "quality",
                "-pix_fmt", "yuv420p",
                "-b:v", b_str,
                "-maxrate", max_str
            }
        elseif encoder_type == "nvenc" then
            return {
                "-c:v", "h264_nvenc",
                "-preset", "p5",
                "-rc", "vbr",
                "-b:v", b_str,
                "-maxrate", max_str
            }
        elseif encoder_type == "qsv" then
            return {
                "-c:v", "h264_qsv",
                "-preset", "fast",
                "-b:v", b_str,
                "-maxrate", max_str
            }
        else
            return {
                "-c:v", "libx264",
                "-preset", "fast",
                "-pix_fmt", "yuv420p",
                "-b:v", b_str,
                "-maxrate", max_str,
                "-bufsize", tostring(math.floor(target_bps * 2))
            }
        end
    end
end

local function parse_progress_file(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()

    local info = {}
    for k, v in content:gmatch("([%w_]+)=([^\r\n]*)") do
        info[k] = v
    end

    local out_time_us = tonumber(info["out_time_us"]) or 0
    local speed = info["speed"] or "N/A"
    local fps = info["fps"] or "N/A"
    local frame = info["frame"] or "0"

    return {
        current_sec = out_time_us / 1000000,
        speed = speed:gsub("^%s*(.-)%s*$", "%1"),
        fps = fps:gsub("^%s*(.-)%s*$", "%1"),
        frame = frame,
        is_end = (info["progress"] == "end")
    }
end

local function clean_up_burn_runtime(is_aborted_or_failed)
    if burn_timer then
        burn_timer:kill()
        burn_timer = nil
    end
    if current_progress_file then
        safe_remove(current_progress_file)
        current_progress_file = nil
    end
    if is_aborted_or_failed and opts.cleanup_aborted_files and current_burn_output_file then
        safe_remove(current_burn_output_file)
    end
    current_burn_output_file = nil
    active_burn_process = nil
end

local function run_ffmpeg_burn(video_path, sub_path, output_path, encoder_type, label, total_duration, target_bps, on_complete)
    local temp_dir = get_system_temp_dir()
    local progress_file = utils.join_path(temp_dir, "mpv_burn_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".tmp")
    current_progress_file = progress_file
    current_burn_output_file = output_path

    local filter_str, current_pos = build_subtitle_filter_str(sub_path)
    local ffmpeg_bin = get_ffmpeg_path()

    local args = {
        ffmpeg_bin,
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-progress", progress_file,
        "-i", video_path,
        "-vf", filter_str,
    }

    -- 锁定恒定帧率 (CFR) 杜绝时基漂移
    if opts.lock_cfr then
        local src_fps = mp.get_property_number("container-fps")
            or mp.get_property_number("estimated-vf-fps")
            or mp.get_property_number("fps")

        local fps_val = nil
        if src_fps and src_fps > 0 then
            if math.abs(src_fps - 23.976) < 0.02 then
                fps_val = "24000/1001"
            elseif math.abs(src_fps - 29.97) < 0.02 then
                fps_val = "30000/1001"
            elseif math.abs(src_fps - 59.94) < 0.02 then
                fps_val = "60000/1001"
            elseif math.abs(src_fps - math.floor(src_fps + 0.5)) < 0.001 then
                fps_val = tostring(math.floor(src_fps + 0.5))
            else
                fps_val = string.format("%.3f", src_fps)
            end
        end

        if fps_val then
            table.insert(args, "-r")
            table.insert(args, fps_val)
        end
        table.insert(args, "-fps_mode")
        table.insert(args, "cfr")
        table.insert(args, "-avoid_negative_ts")
        table.insert(args, "make_zero")
    end

    -- 智能音画流映射
    if opts.smart_audio_map then
        local aid = mp.get_property_number("aid")
        table.insert(args, "-map")
        table.insert(args, "0:v:0")
        table.insert(args, "-map")
        if aid and aid > 0 then
            table.insert(args, string.format("0:a:%d?", aid - 1))
        else
            table.insert(args, "0:a:0?")
        end
    end

    local enc_args = get_burn_encoder_args(encoder_type, target_bps)
    for _, a in ipairs(enc_args) do
        table.insert(args, a)
    end

    local audio_args = get_audio_encoder_args()
    for _, a in ipairs(audio_args) do
        table.insert(args, a)
    end

    table.insert(args, "-movflags")
    table.insert(args, "+faststart")
    table.insert(args, output_path)

    mp.msg.info(string.format("Executing burn ffmpeg [%s]: %s", encoder_type, table.concat(args, " ")))

    if burn_timer then
        burn_timer:kill()
    end

    local codec_tag = (opts.video_codec == "av1") and "AV1" or "H.264"
    local mbps_val = string.format("%.1fM", target_bps / 1000000)
    local pos_tag = (current_pos and current_pos < 100) and string.format(" | 位置: %d%%", current_pos) or ""

    burn_timer = mp.add_periodic_timer(opts.osd_interval, function()
        local prog = parse_progress_file(progress_file)
        if prog then
            local percent = 0
            if total_duration and total_duration > 0 then
                percent = math.floor((prog.current_sec / total_duration) * 100)
                percent = math.min(99, math.max(0, percent))
            end

            local bar = make_progress_bar(percent, 22)
            local time_str = string.format("%s / %s", format_time(prog.current_sec), format_time(total_duration))
            local speed_str = prog.speed
            local fps_str = prog.fps

            local osd_text = string.format(
                "【字幕压制中 - %s %s (%s 码率%s)】\n[%s] %2d%%\n进度: %s | 速度: %s | 帧率: %s fps\n(再次按快捷键可取消压制)",
                label, codec_tag, mbps_val, pos_tag, bar, percent, time_str, speed_str, fps_str
            )
            mp.osd_message(osd_text, opts.osd_interval + 0.6)
        else
            mp.osd_message(string.format("【字幕压制中 - %s %s】正在初始化编码管线...", label, codec_tag), opts.osd_interval + 0.6)
        end
    end)

    active_burn_process = mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true
    }, function(success, result, error)
        active_burn_process = nil
        on_complete(success, result, error)
    end)
end

local function try_burn_chain(encoders, idx, video_path, sub_path, output_path, total_duration, target_bps, on_success, on_fail)
    if idx > #encoders then
        on_fail("所有可用编码器均尝试失败")
        return
    end

    local current_enc = encoders[idx]
    local enc_labels = {
        amf = "AMD Radeon AMF",
        nvenc = "NVIDIA NVENC",
        qsv = "Intel QuickSync",
        cpu = "CPU"
    }
    local label = enc_labels[current_enc] or current_enc

    mp.msg.info(string.format("Attempting burn encoder [%d/%d]: %s", idx, #encoders, current_enc))
    mp.osd_message(string.format("正在启动编码器 [%s]...", label), 3)

    run_ffmpeg_burn(video_path, sub_path, output_path, current_enc, label, total_duration, target_bps, function(success, result, error)
        if success and result and result.status == 0 then
            on_success(label, output_path)
        else
            local err_msg = (result and result.stderr) or error or "未知错误"
            mp.msg.warn(string.format("Burn encoder [%s] failed: %s. Trying next...", current_enc, tostring(err_msg)))
            
            if idx < #encoders then
                local next_label = enc_labels[encoders[idx + 1]] or encoders[idx + 1]
                mp.osd_message(string.format("[%s] 不可用，自动切换至 [%s]...", label, next_label), 3)
                try_burn_chain(encoders, idx + 1, video_path, sub_path, output_path, total_duration, target_bps, on_success, on_fail)
            else
                on_fail(tostring(err_msg))
            end
        end
    end)
end

local function burn_current_video_and_sub(target_encoder)
    if active_burn_process then
        mp.osd_message("已主动取消正在进行的字幕压制任务！", 4)
        mp.abort_async_command(active_burn_process)
        clean_up_burn_runtime(true)
        return
    end

    local is_local, video_path, stem, is_stream, err_msg = resolve_media_source()
    if not video_path then
        mp.osd_message(err_msg or "未检测到正在播放的视频！", 3)
        return
    end

    if is_stream then
        mp.osd_message("【提示】字幕硬压制需完整的本地视频与字幕\n请先下载到本地后再执行压制！", 5)
        return
    end

    local sub_path = get_current_sub_path()
    if not sub_path then
        mp.osd_message("未检测到外挂字幕！请确认同目录下有同名字幕或已加载字幕轨", 4)
        return
    end

    local out_dir = get_target_output_dir(video_path, false)
    local temp_dir = get_system_temp_dir()
    cleanup_directory_leftover_temps(out_dir)
    cleanup_directory_leftover_temps(temp_dir)

    local ext = (opts.video_codec == "av1") and "_hardsub_av1.mp4" or "_hardsub.mp4"
    local output_path = get_unique_output_path(out_dir, stem, ext)
    local total_duration = mp.get_property_number("duration", 0)
    local target_bps = calculate_target_video_bitrate(total_duration)

    local req_enc = target_encoder or opts.gpu_encoder
    if req_enc == "" then req_enc = opts.gpu_encoder end

    local candidate_queue = {}
    if req_enc == "auto" then
        candidate_queue = { "amf", "nvenc", "qsv", "cpu" }
    elseif req_enc == "amf" then
        candidate_queue = { "amf", "cpu" }
    elseif req_enc == "nvenc" then
        candidate_queue = { "nvenc", "cpu" }
    elseif req_enc == "qsv" then
        candidate_queue = { "qsv", "cpu" }
    else
        candidate_queue = { "cpu" }
    end

    try_burn_chain(candidate_queue, 1, video_path, sub_path, output_path, total_duration, target_bps,
        function(success_label, out_file)
            clean_up_burn_runtime()
            cleanup_directory_leftover_temps(out_dir)
            cleanup_directory_leftover_temps(temp_dir)
            local finish_bar = make_progress_bar(100, 22)
            mp.osd_message(string.format("【压制完成 - %s】\n[%s] 100%%\n已输出至:\n%s", success_label, finish_bar, out_file), 6)
            mp.msg.info("Subtitle burning finished successfully: " .. out_file)
        end,
        function(fail_err)
            clean_up_burn_runtime(true)
            cleanup_directory_leftover_temps(out_dir)
            cleanup_directory_leftover_temps(temp_dir)
            mp.osd_message("压制失败！请检查显卡驱动或控制台日志", 5)
            mp.msg.error("All encoders failed: " .. tostring(fail_err))
        end
    )
end

-- ===================================================================
-- 模块三：独立原声音轨提取 (Audio Extraction - 响应 Ctrl+e)
-- ===================================================================
local is_extracting_audio = false

local function extract_audio_track()
    local is_local, video_path, stem, is_stream, err_msg = resolve_media_source()
    if not video_path then
        mp.osd_message(err_msg or "无法获取当前媒体路径，请确认是否正在播放！", 3)
        return
    end

    if is_extracting_audio then
        mp.osd_message("已有正在进行的音轨提取任务，请稍候...", 3)
        return
    end

    local dir = get_target_output_dir(video_path, is_stream)
    local pos = mp.get_property_number("time-pos") or 0

    local is_range = false
    local s_time, e_time
    if cut_start then
        s_time = cut_start
        e_time = pos
        if e_time <= s_time then
            e_time = mp.get_property_number("duration") or (s_time + 10)
        end
        is_range = true
        cut_start = nil
        clear_slicing_mark()
    end

    local base_name
    if is_range then
        local start_str = format_time(s_time):gsub(":", "-")
        local end_str = format_time(e_time):gsub(":", "-")
        base_name = string.format("%s_audio_%s-%s", stem, start_str, end_str)
    else
        base_name = string.format("%s_audio", stem)
    end

    local fmt = opts.audio_format or "mp3"
    local ext = "." .. fmt
    local out_path = get_unique_output_path(dir, base_name, ext)

    local target_desc = is_stream and "在线原声音轨" or "原声音轨"
    mp.osd_message(string.format("正在后台提取%s...\n%s", target_desc, out_path:match("[^/\\]+$")), 4)
    is_extracting_audio = true

    local aid = mp.get_property_number("aid")
    local map_audio = "0:a:0?"
    if aid and aid > 0 then
        map_audio = string.format("0:a:%d?", aid - 1)
    end

    local ffmpeg_bin = get_ffmpeg_path()
    local args = {
        ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error"
    }

    if is_stream then
        table.insert(args, "-reconnect")
        table.insert(args, "1")
        table.insert(args, "-reconnect_streamed")
        table.insert(args, "1")
        table.insert(args, "-reconnect_delay_max")
        table.insert(args, "5")
    end

    if is_range and s_time then
        table.insert(args, "-ss")
        table.insert(args, tostring(s_time))
        if e_time and e_time > s_time then
            table.insert(args, "-to")
            table.insert(args, tostring(e_time))
        end
    end

    table.insert(args, "-i")
    table.insert(args, video_path)
    table.insert(args, "-vn")
    table.insert(args, "-map")
    table.insert(args, map_audio)
    table.insert(args, "-map_metadata")
    table.insert(args, "0")

    if fmt == "mp3" then
        table.insert(args, "-c:a")
        table.insert(args, "libmp3lame")
        table.insert(args, "-b:a")
        table.insert(args, opts.audio_bitrate or "320k")
    elseif fmt == "m4a" then
        table.insert(args, "-c:a")
        table.insert(args, "aac")
        table.insert(args, "-b:a")
        table.insert(args, "256k")
    elseif fmt == "copy" then
        table.insert(args, "-c:a")
        table.insert(args, "copy")
    else
        table.insert(args, "-b:a")
        table.insert(args, "320k")
    end

    table.insert(args, out_path)

    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true
    }, function(success, result, error)
        is_extracting_audio = false
        if success and result and result.status == 0 then
            mp.osd_message(string.format("【音轨提取成功】\n已保存至:\n%s", out_path), 5)
            mp.msg.info("Extracted audio successfully: " .. out_path)
        else
            local fallback_args = {
                ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error"
            }
            if is_stream then
                table.insert(fallback_args, "-reconnect")
                table.insert(fallback_args, "1")
                table.insert(fallback_args, "-reconnect_streamed")
                table.insert(fallback_args, "1")
                table.insert(fallback_args, "-reconnect_delay_max")
                table.insert(fallback_args, "5")
            end
            if is_range and s_time then
                table.insert(fallback_args, "-ss")
                table.insert(fallback_args, tostring(s_time))
                if e_time and e_time > s_time then
                    table.insert(fallback_args, "-to")
                    table.insert(fallback_args, tostring(e_time))
                end
            end
            table.insert(fallback_args, "-i")
            table.insert(fallback_args, video_path)
            table.insert(fallback_args, "-vn")
            if fmt == "m4a" then
                table.insert(fallback_args, "-c:a")
                table.insert(fallback_args, "aac")
                table.insert(fallback_args, "-b:a")
                table.insert(fallback_args, "256k")
            else
                table.insert(fallback_args, "-c:a")
                table.insert(fallback_args, "libmp3lame")
                table.insert(fallback_args, "-b:a")
                table.insert(fallback_args, opts.audio_bitrate or "320k")
            end
            table.insert(fallback_args, out_path)

            mp.command_native_async({
                name = "subprocess",
                args = fallback_args,
                playback_only = false,
                capture_stdout = true,
                capture_stderr = true
            }, function(s2, r2, e2)
                if s2 and r2 and r2.status == 0 then
                    mp.osd_message(string.format("【音轨提取成功 (容错模式)】\n已保存至:\n%s", out_path), 5)
                else
                    if is_stream then
                        mp.osd_message("在线音频提取失败！建议先下载完整视频后再提取音轨", 5)
                    else
                        mp.osd_message("音轨提取失败，请检查 FFmpeg 环境！", 4)
                    end
                    local fail_detail = (r2 and r2.stderr) or (result and result.stderr) or e2 or error
                    mp.msg.error("Audio extraction failed: " .. tostring(fail_detail))
                end
            end)
        end
    end)
end

-- ===================================================================
-- 事件注册与按键绑定映射 (双向兼容旧 input.conf 与新 input.conf)
-- ===================================================================

-- 1. 切片按键与命令接口
mp.add_key_binding("c", "slicing_mark", toggle_slicing_mark)
mp.add_key_binding("C", "clear_slicing_mark", clear_slicing_mark)
mp.add_key_binding("Alt+a", "slicing_audio", toggle_slicing_audio)

mp.register_script_message("slicing-mark", toggle_slicing_mark)
mp.register_script_message("slicing-clear", clear_slicing_mark)
mp.register_script_message("slicing-audio-toggle", toggle_slicing_audio)

-- 2. 压制按键与命令接口
mp.add_key_binding("ctrl+b", "burn_current_sub", function() burn_current_video_and_sub(opts.gpu_encoder) end)
mp.register_script_message("burn-current-sub", burn_current_video_and_sub)

-- 3. 提取音轨按键与命令接口
mp.add_key_binding("ctrl+e", "extract_audio", extract_audio_track)
mp.register_script_message("extract-audio", extract_audio_track)

-- 4. 退出守护清理
mp.register_event("shutdown", function()
    if active_burn_process then
        mp.abort_async_command(active_burn_process)
        clean_up_burn_runtime(true)
    end
end)