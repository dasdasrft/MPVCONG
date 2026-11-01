# MPV Windows Updater (Enhanced & Optimized for PS 7 & 5.1)
# -------------------------------------------------------------
# 动态唯一定位 MPV 根目录（无论从任何终端、批处理或工作目录启动均能准确锚定）
$script:mpvDir = if ($PSScriptRoot) {
    if ((Split-Path $PSScriptRoot -Leaf) -ieq "installer") {
        Split-Path $PSScriptRoot -Parent
    } else {
        $PSScriptRoot
    }
} else {
    (Get-Location).Path
}

$fallback7z = Join-Path $script:mpvDir "7z\7zr.exe"
$useragent = "mpv-win-updater"

# 镜像加速源列表（用于无本地代理时的国内公共加速）
$script:ghMirrors = @(
    "https://gh-proxy.com/", # 1. 公共加速源 A
    "https://ghproxy.net/",  # 2. 公共加速源 B
    "https://ghfast.top/"    # 3. 公共加速源 C
)

# 智能探测本地代理（如 Clash 7890/7897, v2ray 10808/10809 等）
$script:detectedProxy = $null
function Get-SmartProxy {
    if ($script:detectedProxy -ne $null) {
        return $script:detectedProxy
    }

    # 1. 检查环境变量
    foreach ($var in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
        $val = [System.Environment]::GetEnvironmentVariable($var)
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            try {
                $p = [System.Net.WebProxy]::new($val)
                $testReq = [System.Net.HttpWebRequest]::Create("https://github.com")
                $testReq.Proxy = $p
                $testReq.Timeout = 1000
                $testReq.Method = "HEAD"
                $testRes = $testReq.GetResponse()
                $testRes.Close()
                $script:detectedProxy = $p
                Write-Host "[√] 已自动检测并挂载环境变量代理: $val" -ForegroundColor Green
                return $script:detectedProxy
            } catch {}
        }
    }

    # 2. 检查本机常见客户端代理端口
    $candidatePorts = @(7890, 7897, 10809, 10808, 20171, 1080)
    foreach ($port in $candidatePorts) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $iar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(120)
            if ($ok -and $client.Connected) {
                $client.EndConnect($iar)
                $client.Close()
                $proxyUrl = "http://127.0.0.1:$port"
                $p = [System.Net.WebProxy]::new($proxyUrl)
                $testReq = [System.Net.HttpWebRequest]::Create("https://github.com")
                $testReq.Proxy = $p
                $testReq.Timeout = 1000
                $testReq.Method = "HEAD"
                $testRes = $testReq.GetResponse()
                $testRes.Close()
                $script:detectedProxy = $p
                Write-Host "[√] 已自动检测到本地代理客户端 ($proxyUrl)，启用极速官方直连！" -ForegroundColor Green
                return $script:detectedProxy
            }
            $client.Close()
        } catch {}
    }

    $script:detectedProxy = $false
    return $null
}

function Test-FileReady ($path) {
    if (-not (Test-Path $path)) { return $false }
    $item = Get-Item $path -ErrorAction Ignore
    if (-not $item -or $item.Length -eq 0) { return $false }
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        if ($stream) {
            $stream.Close()
            $stream.Dispose()
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

function Assert-NoProcessLocked([string[]]$processNames) {
    foreach ($proc in $processNames) {
        $found = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host "`n[!] 检测到 $proc.exe 正在运行中！" -ForegroundColor Yellow
            Write-Host "    为了避免文件被系统锁定导致更新失败或文件损坏，请先关闭相关程序。" -ForegroundColor Yellow
            while ($true) {
                $ans = Read-KeyOrTimeout "是否已关闭 $proc.exe 并继续？[Y/n] (默认=Y)" "Y"
                Write-Host ""
                if ($ans -eq 'Y' -or $ans -eq 'y') {
                    $stillRunning = Get-Process -Name $proc -ErrorAction SilentlyContinue
                    if (-not $stillRunning) {
                        Write-Host "[√] $proc.exe 已退出，继续执行。" -ForegroundColor Green
                        break
                    } else {
                        Write-Host "[!] $proc.exe 仍在运行，请确保完全退出。" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "[!] 用户选择跳过等待，后续文件写入若被占用可能会报错。" -ForegroundColor Yellow
                    break
                }
            }
        }
    }
}

function Open-EdgeDownload ($url) {
    $foundCmd = Get-Command "msedge.exe" -ErrorAction Ignore
    $edgeCmd = $null
    if ($foundCmd) {
        $edgeCmd = $foundCmd.Source
    }
    if (-not $edgeCmd) {
        $edgePaths = @(
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
            (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
            (Join-Path $env:LocalAppData "Microsoft\Edge\Application\msedge.exe")
        )
        foreach ($p in $edgePaths) {
            if ($p -and (Test-Path $p)) {
                $edgeCmd = $p
                break
            }
        }
    }

    if ($edgeCmd) {
        Start-Process $edgeCmd -ArgumentList $url
    } else {
        Start-Process $url
    }
}

# 兜底方案：通过浏览器下载并自动监听 Downloads 目录
function Download-WithEdge ($target, $link) {
    $filename = [System.IO.Path]::GetFileName($target)
    $destDir = Split-Path $target -Parent
    if ([string]::IsNullOrWhiteSpace($destDir)) {
        $destDir = (Get-Location).Path
    } else {
        $destDir = [System.IO.Path]::GetFullPath($destDir)
    }
    $targetFilePath = Join-Path $destDir $filename

    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "提示: 正在切换为通过 Microsoft Edge 浏览器下载组件" -ForegroundColor Yellow
    Write-Host "目标文件: $filename" -ForegroundColor White
    Write-Host "保存路径: $targetFilePath" -ForegroundColor White
    Write-Host "下载直链: $link" -ForegroundColor Gray
    Write-Host "========================================================" -ForegroundColor Cyan

    $downloadsDir = [System.IO.Path]::Combine($env:USERPROFILE, "Downloads")
    try {
        $regDownloads = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{374DE290-123F-4565-9164-39C4925E467B}" -ErrorAction Ignore
        if ($regDownloads) {
            $downloadsDir = [System.Environment]::ExpandEnvironmentVariables($regDownloads)
        }
    } catch {}

    $startTime = (Get-Date).AddSeconds(-15)

    Write-Host "正在调用 Edge 浏览器打开下载链接..." -ForegroundColor Green
    Open-EdgeDownload $link

    Write-Host "Edge 已打开并请求下载。脚本正在等待下载完成..." -ForegroundColor Cyan
    Write-Host "提示: " -ForegroundColor Yellow
    Write-Host " 1. 如果 Edge 弹出安全提示（如提示保留文件），请点击'保留'。" -ForegroundColor Gray
    Write-Host " 2. 若保存到系统下载目录 [$downloadsDir]，脚本会自动检测并移动覆盖过来。" -ForegroundColor Gray
    Write-Host " 3. 任何时候按任意键可触发手动检查或手动指定文件路径。" -ForegroundColor Gray
    Write-Host ""

    $prefix = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    $ext = [System.IO.Path]::GetExtension($filename)
    $dots = 0

    while ($true) {
        if (Test-Path $targetFilePath) {
            $destItem = Get-Item $targetFilePath -ErrorAction Ignore
            if ($destItem -and $destItem.LastWriteTime -ge $startTime -and (Test-FileReady $targetFilePath)) {
                Write-Host "`n[√] 在目标路径检测到最新下载的文件: $filename" -ForegroundColor Green
                break
            }
        }

        if (Test-Path $downloadsDir) {
            $candidateFile = Join-Path $downloadsDir $filename
            $crdownload = Join-Path $downloadsDir ($filename + ".crdownload")

            if ((-not (Test-Path $crdownload)) -and (Test-Path $candidateFile)) {
                $candItem = Get-Item $candidateFile -ErrorAction Ignore
                if ($candItem -and $candItem.LastWriteTime -ge $startTime -and (Test-FileReady $candidateFile)) {
                    Write-Host "`n[√] 在系统下载目录检测到完成的文件，正在移入目标路径..." -ForegroundColor Green
                    try {
                        Move-Item -Path $candidateFile -Destination $targetFilePath -Force
                        if (Test-Path $targetFilePath) {
                            Write-Host "已成功移入: $filename" -ForegroundColor Green
                            break
                        }
                    } catch {
                        Write-Host "`n移动文件失败: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            } else {
                $filterPattern = "$prefix*$ext"
                $matchingItems = Get-ChildItem -Path $downloadsDir -Filter $filterPattern -ErrorAction Ignore |
                    Where-Object {
                        $_.LastWriteTime -ge $startTime -and
                        -not $_.Name.EndsWith(".crdownload") -and
                        $_.Length -gt 0
                    } |
                    Sort-Object LastWriteTime -Descending

                foreach ($item in $matchingItems) {
                    $itemCr = $item.FullName + ".crdownload"
                    if ((-not (Test-Path $itemCr)) -and (Test-FileReady $item.FullName)) {
                        Write-Host "`n[√] 在系统下载目录检测到匹配文件 [$($item.Name)]，正在移入目标路径..." -ForegroundColor Green
                        try {
                            Move-Item -Path $item.FullName -Destination $targetFilePath -Force
                            if (Test-Path $targetFilePath) {
                                Write-Host "已成功移入并重命名为: $filename" -ForegroundColor Green
                                break
                            }
                        } catch {
                            Write-Host "`n移动文件失败: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
                if ((Test-Path $targetFilePath) -and ((Get-Item $targetFilePath).LastWriteTime -ge $startTime)) {
                    break
                }
            }
        }

        $hasKey = $false
        try {
            if ([System.Console]::KeyAvailable) {
                $hasKey = $true
            }
        } catch {}

        if ($hasKey) {
            $key = [System.Console]::ReadKey($true)
            Write-Host "`n[用户按键响应] 正在检查当前状态..." -ForegroundColor Yellow
            Write-Host "如果文件保存在其他路径，可直接粘贴文件完整路径后按回车；" -ForegroundColor Cyan
            Write-Host "若已确认目标文件已就绪，可直接输入 'y' 后按回车；或直接按回车继续自动等待: " -NoNewline -ForegroundColor Cyan
            $customPath = Read-Host
            if (-not [string]::IsNullOrWhiteSpace($customPath)) {
                $customPath = $customPath.Trim('"').Trim("'")
                if ($customPath -eq "y" -or $customPath -eq "Y") {
                    if (Test-Path $targetFilePath) {
                        Write-Host "[√] 用户已确认目标文件就绪: $filename" -ForegroundColor Green
                        break
                    }
                } elseif ((Test-Path $customPath) -and (Test-FileReady $customPath)) {
                    Copy-Item -Path $customPath -Destination $targetFilePath -Force
                    Write-Host "[√] 已成功从指定路径载入: $filename" -ForegroundColor Green
                    break
                } else {
                    Write-Host "[×] 指定路径不存在或文件未写入完成: $customPath" -ForegroundColor Red
                }
            }
        }

        $dots = ($dots + 1) % 4
        $indicator = ("." * $dots) + (" " * (3 - $dots))
        Write-Host "`r等待下载中 $indicator" -NoNewline -ForegroundColor Gray
        Start-Sleep -Milliseconds 1500
    }
}

# 核心智能下载引擎（本地代理优先 -> 多路高速镜像 -> 低速自动熔断 -> 兜底 Edge）
function Invoke-SmartDownload ($target, $link) {
    if ([string]::IsNullOrWhiteSpace($link)) {
        Write-Host "[×] 下载链接为空，无法进行下载。" -ForegroundColor Red
        return
    }

    $filename = [System.IO.Path]::GetFileName($target)
    $destDir = Split-Path $target -Parent
    if ([string]::IsNullOrWhiteSpace($destDir)) {
        $destDir = $script:mpvDir
    } else {
        $destDir = [System.IO.Path]::GetFullPath($destDir)
    }
    if (-not (Test-Path $destDir)) {
        $null = New-Item -ItemType Directory -Path $destDir -Force
    }
    $targetFilePath = Join-Path $destDir $filename
    $tempFilePath = $targetFilePath + ".part"

    $downloadSuccess = $false
    $proxy = Get-SmartProxy

    # 构造待尝试的下载通道列表
    $channelsToTry = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($link -match "^https?://github\.com/") {
        # 1. 若探测到本地代理，优先通过本地代理直连官方（极速无反代中转瓶颈）
        if ($proxy) {
            $channelsToTry.Add([PSCustomObject]@{
                Url = $link
                Proxy = $proxy
                Desc = "本地代理直连 ($($proxy.Address.Authority))"
            })
        }

        # 2. 依次添加国内常用镜像加速源（不走代理直连）
        foreach ($m in $script:ghMirrors) {
            if (-not [string]::IsNullOrEmpty($m)) {
                $channelsToTry.Add([PSCustomObject]@{
                    Url = $m + $link
                    Proxy = $null
                    Desc = "镜像加速 ($([System.Uri]::new($m).Host))"
                })
            }
        }

        # 3. 官方直连兜底（无代理直连）
        if (-not $proxy) {
            $channelsToTry.Add([PSCustomObject]@{
                Url = $link
                Proxy = $null
                Desc = "官方直连"
            })
        }
    } else {
        $channelsToTry.Add([PSCustomObject]@{
            Url = $link
            Proxy = $proxy
            Desc = if ($proxy) { "通过本地代理" } else { "官方直连" }
        })
    }

    foreach ($channel in $channelsToTry) {
        $url = $channel.Url
        $chProxy = $channel.Proxy
        $sourceDesc = $channel.Desc
        Write-Host "[i] 正在尝试下载: $filename [$sourceDesc]" -ForegroundColor Cyan

        $webReq = $null
        $response = $null
        $responseStream = $null
        $fileStream = $null

        try {
            $webReq = [System.Net.HttpWebRequest]::Create($url)
            $webReq.Method = "GET"
            $webReq.UserAgent = $useragent
            $webReq.Timeout = 10000
            $webReq.ReadWriteTimeout = 20000
            $webReq.AllowAutoRedirect = $true

            if ($chProxy) {
                $webReq.Proxy = $chProxy
            } else {
                # 显式禁止走可能失效的旧系统代理
                $webReq.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
            }

            if ($url.StartsWith("https://api.github.com") -or $url.StartsWith("https://github.com")) {
                $token = Get-GitHubToken
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    $webReq.Headers.Add("Authorization", "Bearer $token")
                }
            }

            $response = $webReq.GetResponse()
            $totalBytes = $response.ContentLength
            $responseStream = $response.GetResponseStream()

            if (Test-Path $tempFilePath) {
                Remove-Item $tempFilePath -Force -ErrorAction SilentlyContinue
            }

            $fileStream = [System.IO.File]::Create($tempFilePath)
            $buffer = New-Object byte[] 65536
            $bytesRead = 0
            $totalRead = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $lastUpdate = [DateTime]::MinValue

            while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $bytesRead)
                $totalRead += $bytesRead

                $now = [DateTime]::Now
                if (($now - $lastUpdate).TotalMilliseconds -ge 250 -or $totalRead -eq $totalBytes) {
                    $lastUpdate = $now
                    $elapsedSec = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    $speedMB = ($totalRead / 1048576) / $elapsedSec
                    $currentMB = $totalRead / 1048576

                    if ($totalBytes -gt 0) {
                        $totalMB = $totalBytes / 1048576
                        $percent = [Math]::Min(100, [int](($totalRead / $totalBytes) * 100))
                        $barLen = 20
                        $doneLen = [int](($percent / 100) * $barLen)
                        $bar = ("=" * $doneLen) + ("-" * ($barLen - $doneLen))
                        $line = "`r    [进度] [$bar] {0,3}% | {1:N1}/{2:N1} MB | {3:N2} MB/s  " -f $percent, $currentMB, $totalMB, $speedMB

                        # 智能低速熔断切换：大文件若超过 3.5 秒且平均速度严重偏低 (< 0.5 MB/s)，自动放弃并尝试下一更优节点
                        if ($elapsedSec -ge 3.5 -and $totalBytes -gt 5242880 -and $speedMB -lt 0.5 -and $percent -lt 30) {
                            throw ("当前通道带宽受限（速度仅 {0:N2} MB/s），自动触发熔断切换更优节点" -f $speedMB)
                        }
                    } else {
                        $line = "`r    [进度] 已下载 {0:N1} MB | 速度: {1:N2} MB/s  " -f $currentMB, $speedMB
                    }
                    Write-Host $line -NoNewline -ForegroundColor Green
                }
            }

            Write-Host ""
            $fileStream.Flush()
            $fileStream.Close()
            $fileStream.Dispose()
            $fileStream = $null

            $responseStream.Close()
            $responseStream.Dispose()
            $responseStream = $null

            $response.Close()
            $response = $null

            if ((Test-Path $tempFilePath) -and ((Get-Item $tempFilePath).Length -gt 0)) {
                Move-Item -Path $tempFilePath -Destination $targetFilePath -Force
                Write-Host "[√] 下载完成并已保存至: $filename" -ForegroundColor Green
                $downloadSuccess = $true
                break
            }
        }
        catch {
            Write-Host ""
            Write-Host "    [!] 当前通道异常/过慢: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally {
            if ($fileStream) { $fileStream.Dispose() }
            if ($responseStream) { $responseStream.Dispose() }
            if ($response) { $response.Close() }
            if (Test-Path $tempFilePath) { Remove-Item $tempFilePath -Force -ErrorAction SilentlyContinue }
        }
    }

    # 如果所有直接通道均失败，优雅降级到 Edge
    if (-not $downloadSuccess) {
        Write-Host "[!] 所有命令行直接通道均受限，切换为 Edge 浏览器辅助下载..." -ForegroundColor Yellow
        Download-WithEdge $target $link
    }
}

function Get-7z {
    # 1. 优先使用 MPV 目录自带的 7zr.exe（最稳定、无第三方兼容风险）
    $local7z = Join-Path $script:mpvDir "7z\7zr.exe"
    if (Test-Path $local7z) {
        return $local7z
    }
    # 2. 检查本机 7-Zip 标准安装路径
    $7zdir = Get-ItemPropertyValue -ErrorAction Ignore "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip" "InstallLocation"
    if ($7zdir -and (Test-Path (Join-Path $7zdir "7z.exe"))) {
        return Join-Path $7zdir "7z.exe"
    }
    # 3. 检查系统全局 PATH 里的 7z.exe
    $7z_command = Get-Command -CommandType Application -ErrorAction Ignore 7z.exe | Select-Object -Last 1
    if ($7z_command -and (Test-Path $7z_command.Source)) {
        return $7z_command.Source
    }
    if (Test-Path $fallback7z) {
        return $fallback7z
    }
    return $null
}

function Check-7z {
    if (-not (Get-7z))
    {
        $null = New-Item -ItemType Directory -Force (Split-Path $fallback7z)
        $download_file = $fallback7z
        Write-Host "正在准备 7z 解压工具..." -ForegroundColor Green
        Invoke-SmartDownload $download_file "https://www.7-zip.org/a/7zr.exe"
    }
    else
    {
        Write-Host "[√] 7-Zip 解压工具已就绪" -ForegroundColor Green
    }
}

function Extract-Archive ($file) {
    $archivePath = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $script:mpvDir $file }
    if (-not (Test-Path $archivePath)) {
        Write-Host "[×] 待解压文件不存在: $archivePath" -ForegroundColor Red
        return $false
    }

    Assert-NoProcessLocked @("mpv", "ffmpeg", "yt-dlp", "deno")

    Write-Host "[i] 正在解压覆盖至: $script:mpvDir" -ForegroundColor Green
    Write-Host "    压缩包: $([System.IO.Path]::GetFileName($archivePath))" -ForegroundColor Gray

    # 格式自适应：7zr.exe (精简版) 仅支持 7z/xz 格式不支持 zip；对于 zip 优先使用 Windows 自带的 tar.exe 或 Expand-Archive
    $ext = [System.IO.Path]::GetExtension($archivePath).ToLower()
    if ($ext -eq ".zip") {
        $tarCmd = Get-Command -CommandType Application -ErrorAction Ignore tar.exe | Select-Object -Last 1
        if ($tarCmd) {
            $tarArgs = @("-xf", $archivePath, "-C", $script:mpvDir)
            $process = Start-Process -FilePath $tarCmd.Source -ArgumentList $tarArgs -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -eq 0) {
                Write-Host "[√] 解压覆盖成功完成！" -ForegroundColor Green
                return $true
            }
        }
        try {
            Expand-Archive -Path $archivePath -DestinationPath $script:mpvDir -Force -ErrorAction Stop
            Write-Host "[√] 解压覆盖成功完成！" -ForegroundColor Green
            return $true
        } catch {}
    }

    $7z = Get-7z
    if (-not $7z -or (-not (Test-Path $7z))) {
        Write-Host "[×] 未找到 7z 解压工具，解压中断。" -ForegroundColor Red
        return $false
    }

    # 关键修复：
    # 1. 显式指定 -o 输出目录至 MPV 根目录
    # 2. 采用参数数组形式避免 PowerShell 7 下 ! 符号被拆分或传递异常
    # 3. 实时显示解压进度并捕获 ExitCode
    $extractArgs = @(
        "x",
        "-y",
        "-o$script:mpvDir",
        "-xr!updater.ps1",
        $archivePath
    )

    $process = Start-Process -FilePath $7z -ArgumentList $extractArgs -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -eq 0) {
        Write-Host "[√] 解压覆盖成功完成！" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[×] 解压过程返回错误 (ExitCode: $($process.ExitCode))" -ForegroundColor Red
        return $false
    }
}

function Check-PowershellVersion {
    $version = $PSVersionTable.PSVersion.Major
    $edition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { "Desktop" }
    Write-Host "[i] 当前 PowerShell 环境: v$($PSVersionTable.PSVersion) ($edition)" -ForegroundColor Green
    if ($version -le 2)
    {
        Write-Host "[×] 不支持 PowerShell $version，请升级后重试。" -ForegroundColor Red
        throw
    }
}

function Check-Ytplugin {
    $ytdlp = Get-ChildItem "yt-dlp*.exe" -ErrorAction Ignore
    $youtubedl = Get-ChildItem "youtube-dl.exe" -ErrorAction Ignore
    if ($ytdlp) {
        return $ytdlp.ToString()
    }
    elseif ($youtubedl) {
        return $youtubedl.ToString()
    }
    else {
        return $null
    }
}

function Check-Ytplugin-In-System {
    $ytp = Get-Command -CommandType Application -ErrorAction Ignore yt-dlp.exe | Select-Object -Last 1
    if (-not $ytp) {
        $ytp = Get-Command -CommandType Application -ErrorAction Ignore youtube-dl.exe | Select-Object -Last 1
    }
    return [bool]($ytp -and ((Split-Path $ytp.Source) -ne (Get-Location)))
}

function Check-Mpv {
    $mpv = (Get-Location).Path + "\mpv.exe"
    $is_exist = Test-Path $mpv
    return $is_exist
}

function Download-Archive ($filename, $link) {
    Invoke-SmartDownload $filename $link
}

function Get-GitHubToken {
    $file = "settings.xml"

    if (Test-Path $file) {
        $filePath = (Resolve-Path $file).Path
        [xml]$doc = Get-Content $filePath
        $settings = $doc.SelectSingleNode("/settings")
        if ($settings) {
            $githubtoken = $settings.SelectSingleNode("githubtoken")
        }
        if ($settings -and ($null -eq $githubtoken)) {
            $newNode = $doc.CreateElement("githubtoken")
            $newNode.AppendChild($doc.CreateTextNode("unset")) | out-null
            $settings.AppendChild($newNode) | out-null
            $doc.Save($filePath)
            $githubtoken = $newNode
        }
        if ($settings -and ($null -ne $githubtoken)) {
            $token = ([string]$githubtoken.InnerText).Trim()
            if (-not [string]::IsNullOrWhiteSpace($token) -and (-not [string]::Equals($token, "unset", [System.StringComparison]::OrdinalIgnoreCase))) {
                return $token
            }
        }
    }

    $token = ([string]$env:GH_TOKEN).Trim()
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        return $token
    }

    $token = ([string]$env:GITHUB_TOKEN).Trim()
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        return $token
    }

    return $null
}

# 增强版 GitHub API 请求函数：带代理探测与镜像源自动切换
function Invoke-GitHubApi($Uri) {
    $token = Get-GitHubToken
    $headers = @{
        "User-Agent" = $useragent
        "Accept" = "application/vnd.github.v3+json"
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers["Authorization"] = "Bearer $token"
    }

    $proxy = Get-SmartProxy

    $apiTargets = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($proxy) {
        $apiTargets.Add([PSCustomObject]@{ Url = $Uri; Proxy = $proxy })
    }
    if ($Uri.StartsWith("https://api.github.com/")) {
        $apiTargets.Add([PSCustomObject]@{ Url = "https://gh-proxy.com/" + $Uri; Proxy = $null })
        $apiTargets.Add([PSCustomObject]@{ Url = "https://ghproxy.net/" + $Uri; Proxy = $null })
    }
    $apiTargets.Add([PSCustomObject]@{ Url = $Uri; Proxy = $null })

    foreach ($target in $apiTargets) {
        try {
            $irmParams = @{
                Uri = $target.Url
                Headers = $headers
                TimeoutSec = 5
                ErrorAction = "Stop"
            }
            if ($target.Proxy) {
                $irmParams.Proxy = $target.Proxy.Address.ToString()
            }
            $resp = Invoke-RestMethod @irmParams
            if ($resp) {
                return $resp
            }
        } catch {}
    }
    return $null
}

function Download-Ytplugin ($plugin, $version) {
    $link = ""
    $plugin_exe = ""
    switch -wildcard ($plugin) {
        "yt-dlp*" {
            Write-Host "正在准备下载 $plugin ($version)..." -ForegroundColor Green
            $32bit = ""
            if (-Not (Test-Path (Join-Path $env:windir "SysWow64"))) {
                $32bit = "_x86"
            }
            $ytdlp_channel = Check-Ytdlp-Channel
            if ($ytdlp_channel -eq 'stable') {
                $repo = "https://github.com/yt-dlp/yt-dlp"
            }
            elseif ($ytdlp_channel -eq 'nightly') {
                $repo = "https://github.com/yt-dlp/yt-dlp-nightly-builds"
            }
            elseif ($ytdlp_channel -eq 'master') {
                $repo = "https://github.com/yt-dlp/yt-dlp-master-builds"
            }
            if ($version -eq "latest") {
                $link = -join($repo, "/releases/latest/download/", $plugin, $32bit, ".exe")
            } else {
                $link = -join($repo, "/releases/download/", $version, "/", $plugin, $32bit, ".exe")
            }
            $plugin_exe = -join($plugin, $32bit, ".exe")
        }
        "youtube-dl" {
            Write-Host "正在准备下载 $plugin ($version)..." -ForegroundColor Green
            $link = -join("https://yt-dl.org/downloads/", $version, "/youtube-dl.exe")
            $plugin_exe = "youtube-dl.exe"
        }
    }
    Assert-NoProcessLocked @("yt-dlp", "youtube-dl")
    Invoke-SmartDownload $plugin_exe $link
}



function Get-Latest-Mpv($Arch) {
    $api_gh = "https://api.github.com/repos/zhongfly/mpv-winbuild/releases/latest"
    $json = Invoke-GitHubApi $api_gh
    if ($json -and $json.assets) {
        $asset = $json.assets | Where-Object { $_.name -match "mpv-$Arch-[0-9]{8}" } | Select-Object -First 1
        if ($asset) {
            return $asset.name, $asset.browser_download_url
        }
    }
    return $null, $null
}

function Get-Latest-Ytplugin ($plugin) {
    switch -wildcard ($plugin) {
        "yt-dlp*" {
            $ytdlp_channel = Check-Ytdlp-Channel
            $repoPath = "yt-dlp/yt-dlp"
            if ($ytdlp_channel -eq 'nightly') {
                $repoPath = "yt-dlp/yt-dlp-nightly-builds"
            } elseif ($ytdlp_channel -eq 'master') {
                $repoPath = "yt-dlp/yt-dlp-master-builds"
            }

            Write-Host "正在获取 yt-dlp ($ytdlp_channel) 最新版本信息..." -ForegroundColor Green
            $apiUrl = "https://api.github.com/repos/$repoPath/releases/latest"
            $json = Invoke-GitHubApi $apiUrl
            if ($json -and $json.tag_name) {
                return $json.tag_name
            }

            # 备用方案：通过 Atom 订阅源
            $atomUrls = @(
                "https://github.com/$repoPath/releases.atom",
                "https://gh-proxy.com/https://github.com/$repoPath/releases.atom"
            )
            foreach ($atomUrl in $atomUrls) {
                try {
                    $atomResp = Invoke-WebRequest $atomUrl -MaximumRedirection 3 -TimeoutSec 5 -UseBasicParsing -UserAgent $useragent -ErrorAction Stop
                    if ($atomResp -and $atomResp.Content) {
                        $xml = [xml]$atomResp.Content
                        $entryLink = $xml.feed.entry[0].link.href
                        $ver = $entryLink.split("/")[-1]
                        if (-not [string]::IsNullOrWhiteSpace($ver)) {
                            return $ver
                        }
                    }
                } catch {}
            }

            Write-Host "[!] 无法解析具体版本号，将直接按最新版 (latest) 进行拉取。" -ForegroundColor Yellow
            return "latest"
        }
        "youtube-dl" {
            $link = "https://yt-dl.org/downloads/latest/youtube-dl.exe"
            Write-Host "正在获取 youtube-dl 最新版本..." -ForegroundColor Green
            try {
                $resp = Invoke-WebRequest $link -MaximumRedirection 0 -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
                $redirect_link = $resp.Headers.Location
                if ($redirect_link) {
                    $version = $redirect_link.split("/")[4]
                    return $version
                }
            } catch {}
            return "latest"
        }
    }
}

function Get-Latest-FFmpeg ($Arch) {
    $api_gh = "https://api.github.com/repos/zhongfly/mpv-winbuild/releases/latest"
    $json = Invoke-GitHubApi $api_gh
    if ($json -and $json.assets) {
        $asset = $json.assets | Where-Object { $_.name -match "ffmpeg-$Arch-git-" } | Select-Object -First 1
        if ($asset) {
            return $asset.name, $asset.browser_download_url
        }
    }
    return $null, $null
}

function Get-Arch {
    $FilePath = [System.IO.Path]::Combine((Get-Location).Path, 'mpv.exe')
    if (-not (Test-Path $FilePath)) {
        return [PSCustomObject]@{ FilePath = $FilePath; FileType = 'x86_64' }
    }

    [int32]$MACHINE_OFFSET = 4
    [int32]$PE_POINTER_OFFSET = 60
    [byte[]]$data = New-Object -TypeName System.Byte[] -ArgumentList 4096
    $stream = $null

    try {
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList ($FilePath, 'Open', 'Read', 'ReadWrite')
        $stream.Read($data, 0, 4096) | Out-Null
        [int32]$PE_HEADER_ADDR = [System.BitConverter]::ToInt32($data, $PE_POINTER_OFFSET)
        [int32]$machineUint = [System.BitConverter]::ToUInt16($data, $PE_HEADER_ADDR + $MACHINE_OFFSET)

        $fileType = 'x86_64'
        switch ($machineUint) {
            0x014c { $fileType = 'i686' }
            0x0200 { $fileType = 'Itanium' }
            0x8664 { $fileType = 'x86_64' }
        }

        return [PSCustomObject]@{
            FilePath = $FilePath
            FileType = $fileType
        }
    }
    catch {
        return [PSCustomObject]@{ FilePath = $FilePath; FileType = 'x86_64' }
    }
    finally {
        if ($stream) {
            $stream.Close()
            $stream.Dispose()
        }
    }
}

function Get-RegexGroupValue($Text, [string[]]$Patterns, $GroupName) {
    if ([string]::IsNullOrEmpty([string]$Text)) {
        return $null
    }

    foreach ($pattern in $Patterns) {
        $match = [regex]::Match([string]$Text, $pattern)
        if ($match.Success) {
            $group = $match.Groups[$GroupName]
            if ($group -and -not [string]::IsNullOrEmpty($group.Value)) {
                return $group.Value
            }
        }
    }

    return $null
}

function Test-CommitEquivalent($Left, $Right) {
    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) {
        return $false
    }

    $shorter = [string]$Left
    $longer = [string]$Right
    if ($shorter.Length -gt $longer.Length) {
        $shorter = [string]$Right
        $longer = [string]$Left
    }

    return $longer.StartsWith($shorter, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-BinaryBuildDate ($filePath) {
    if (-not $filePath -or (-not (Test-Path $filePath))) { return "" }
    try {
        $fs = [System.IO.File]::OpenRead($filePath)
        $br = New-Object System.IO.BinaryReader($fs)
        try {
            if ($fs.Length -lt 64) { return "" }
            $mz = $br.ReadBytes(2)
            if ($mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) { return "" }
            $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peOffset = $br.ReadInt32()
            if ($fs.Length -lt ($peOffset + 24)) { return "" }
            $fs.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peSig = $br.ReadBytes(4)
            if ($peSig[0] -ne 0x50 -or $peSig[1] -ne 0x45) { return "" }
            $fs.Seek($peOffset + 8, [System.IO.SeekOrigin]::Begin) | Out-Null
            $timestamp = $br.ReadUInt32()
            if ($timestamp -gt 0 -and $timestamp -lt 0x7FFFFFFF) {
                $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
                $dtUtc = $epoch.AddSeconds($timestamp)
                $dtLocal = $dtUtc.ToLocalTime()
                return $dtLocal.ToString("yyyy-MM-dd")
            }
        } finally {
            $br.Close()
            $fs.Close()
        }
    } catch {}
    try {
        return (Get-Item $filePath).LastWriteTime.ToString("yyyy-MM-dd")
    } catch {
        return ""
    }
}

function ExtractGitFromFile {
    try {
        $stripped = .\mpv.com --no-config --version 2>$null | Select-String "mpv" | Select-Object -First 1
        if (-not $stripped) {
            $stripped = .\mpv --no-config | Select-String "mpv" | Select-Object -First 1
        }
        $patterns = @(
            "-g(?<commit>[0-9A-Fa-f]{7,40})(?=[^0-9A-Fa-f]|$)"
        )
        return Get-RegexGroupValue $stripped $patterns "commit"
    } catch {
        return $null
    }
}

function ExtractGitFromURL($filename) {
    $patterns = @(
        "-git-(?<commit>[0-9A-Fa-f]{7,40})(?=[^0-9A-Fa-f]|$)"
    )
    return Get-RegexGroupValue $filename $patterns "commit"
}

function ExtractDateFromFile {
    try {
        $date = (Get-Item ./mpv.exe).LastWriteTimeUtc
        $day = $date.Day.ToString("00")
        $month = $date.Month.ToString("00")
        $year = $date.Year.ToString("0000")
        return "$year$month$day"
    } catch {
        return ""
    }
}

function ExtractDateFromURL($filename) {
    $patterns = @(
        "-(?<date>[0-9]{8})-git-[0-9A-Fa-f]{7,40}(?=[^0-9A-Fa-f]|$)"
    )
    return Get-RegexGroupValue $filename $patterns "date"
}

function Ensure-Deno([string]$Context = "update") {
    $deno_exe = Join-Path (Get-Location) "deno.exe"
    if (Test-Path $deno_exe) {
        $remote_name = ""
        try {
            $remote_name = (Invoke-WebRequest "https://dl.deno.land/release-latest.txt" -UseBasicParsing -UserAgent $useragent -TimeoutSec 6).Content.Trim()
        } catch {}

        if (-not [string]::IsNullOrWhiteSpace($remote_name)) {
            try {
                $current_version = (& $deno_exe --version 2>$null | Select-String "deno" | Select-Object -First 1).ToString()
                $pattern = "deno\s+(?<ver>[0-9a-zA-Z\.-]+)"
                $m = [Regex]::Match($current_version, $pattern)
                if ($m.Success) {
                    $current_tag = $m.Groups['ver'].Value
                    $latest_norm = $remote_name.TrimStart('v')
                    $denoBuildDate = Get-BinaryBuildDate $deno_exe
                    $dateText = if ($denoBuildDate) { " (构建日期: $denoBuildDate)" } else { "" }
                    if ($current_tag -eq $latest_norm) {
                        Write-Host "[√] Deno 运行时已是最新版本 -- $remote_name$dateText" -ForegroundColor Green
                        return
                    }
                    else {
                        Write-Host "[!] 检测到 Deno 新版本可用 ($current_tag$dateText -> $remote_name)" -ForegroundColor Yellow
                    }
                }
            }
            catch {}

            $upgradePrompt = "是否现在升级本地 Deno 运行时？[Y/n] (默认=Y)"
            $upgradeResp = Read-KeyOrTimeout $upgradePrompt "Y"
            Write-Host ""
            if ($upgradeResp -eq 'Y' -or $upgradeResp -eq 'y') {
                $download_link = "https://dl.deno.land/release/$remote_name/deno-x86_64-pc-windows-msvc.zip"
                $archive = "deno-x86_64-pc-windows-msvc.zip"
                Write-Host "正在下载 Deno $remote_name..." -ForegroundColor Green
                Assert-NoProcessLocked @("deno")
                Invoke-SmartDownload $archive $download_link
                Check-7z
                $extractOk = Extract-Archive $archive
                if ($extractOk) {
                    Check-Autodelete $archive
                } else {
                    Write-Host "[!] Deno 解压未成功，已保留压缩包: $archive" -ForegroundColor Yellow
                }
            }
        }
        return
    }

    if ($Context -ne 'install') {
        return
    }
    if (-Not (Test-Path (Join-Path $env:windir "SysWow64"))) {
        Write-Host "Deno 不支持 32 位系统，已跳过。" -ForegroundColor Yellow
        return
    }

    Write-Host "Deno 是推荐的 JavaScript 外部执行引擎，用于加速 yt-dlp 解析 YouTube。" -ForegroundColor Yellow
    $resp = Read-KeyOrTimeout "是否下载安装 Deno？[Y/n] (默认=Y)" "Y"
    Write-Host ""
    if ($resp -ne 'Y' -and $resp -ne 'y') { return }

    try {
        $remote_name = (Invoke-WebRequest "https://dl.deno.land/release-latest.txt" -UseBasicParsing -UserAgent $useragent -TimeoutSec 6).Content.Trim()
        $download_link = "https://dl.deno.land/release/$remote_name/deno-x86_64-pc-windows-msvc.zip"
        $archive = "deno-x86_64-pc-windows-msvc.zip"
        Write-Host "正在下载 Deno $remote_name..." -ForegroundColor Green
        Assert-NoProcessLocked @("deno")
        Invoke-SmartDownload $archive $download_link
        Check-7z
        $extractOk = Extract-Archive $archive
        if ($extractOk) {
            Check-Autodelete $archive
        } else {
            Write-Host "[!] Deno 解压未成功，已保留压缩包: $archive" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[!] 获取 Deno 最新版本失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Test-Admin
{
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $user).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Create-XML{
@"
<settings>
  <arch>unset</arch>
  <autodelete>unset</autodelete>
  <getffmpeg>unset</getffmpeg>
  <getytdl>unset</getytdl>
  <ytdlpchannel>unset</ytdlpchannel>
  <githubtoken>unset</githubtoken>
</settings>
"@ | Set-Content "settings.xml" -Encoding UTF8
}

function Check-Arch($arch) {
    $get_arch = ""
    $file = "settings.xml"

    if (-not (Test-Path $file)) { Create-XML }
    [xml]$doc = Get-Content $file
    if ($doc.settings.arch -eq "unset") {
        if ($arch -eq "i686") {
            $get_arch = "i686"
        }
        else {
            $result = Read-KeyOrTimeout "选择 64 位构建版本: [1=x86_64 / 2=x86_64-v3 (需 CPU 支持 AVX2)] (默认=1)" "D1"
            Write-Host ""
            if ($result -eq 'D1' -or $result -eq '1') {
                $get_arch = "x86_64"
            }
            elseif ($result -eq 'D2' -or $result -eq '2') {
                $get_arch = "x86_64-v3"
            }
            else {
                $get_arch = "x86_64"
            }
        }
        $doc.settings.arch = $get_arch
        $doc.Save($file)
    }
    else {
        $get_arch = $doc.settings.arch
    }
    return $get_arch
}

function Check-Autodelete($archive) {
    $autodelete = ""
    $file = "settings.xml"

    if (-not (Test-Path $file)) { exit }
    [xml]$doc = Get-Content $file
    if ($doc.settings.autodelete -eq "unset") {
        $result = Read-KeyOrTimeout "解压完成后是否自动删除压缩包？[Y/n] (默认=Y)" "Y"
        Write-Host ""
        if ($result -eq 'Y' -or $result -eq 'y') {
            $autodelete = "true"
        }
        elseif ($result -eq 'N' -or $result -eq 'n') {
            $autodelete = "false"
        }
        else {
            $autodelete = "true"
        }
        $doc.settings.autodelete = $autodelete
        $doc.Save($file)
    }
    if ($doc.settings.autodelete -eq "true") {
        if (Test-Path $archive)
        {
            Remove-Item -Force $archive -ErrorAction SilentlyContinue
        }
    }
}

function Check-GetFFmpeg() {
    $get_ffmpeg = ""
    $file = "settings.xml"

    if (-not (Test-Path $file)) { exit }
    [xml]$doc = Get-Content $file
    if ($doc.settings.getffmpeg -eq "unset") {
        Write-Host "FFmpeg 组件尚未安装。 " -ForegroundColor Green -NoNewline
        $result = Read-KeyOrTimeout "是否下载安装 FFmpeg？[Y/n] (默认=n)" "N"
        Write-Host ""
        if ($result -eq 'Y' -or $result -eq 'y') {
            $get_ffmpeg = "true"
        }
        else {
            $get_ffmpeg = "false"
        }
        $doc.settings.getffmpeg = $get_ffmpeg
        $doc.Save($file)
    }
    else {
        $get_ffmpeg = $doc.settings.getffmpeg
    }
    return $get_ffmpeg
}

function Check-GetYTDL() {
    $get_ytdl = ""
    $file = "settings.xml"

    if (-not (Test-Path $file)) { exit }
    [xml]$doc = Get-Content $file
    if ($null -eq $doc.settings.getytdl) {
        $yt = Check-Ytplugin
        if ($yt -eq $null){
            $get_ytdl = "unset"
        }
        elseif ((Get-Item $yt).BaseName -Match "yt-dlp*") {
            $get_ytdl = "ytdlp"
        }
        else {
            $get_ytdl = "youtubedl"
        }
        $newNode = $doc.CreateElement("getytdl")
        $newNode.AppendChild($doc.CreateTextNode($get_ytdl)) | out-null
        $doc.settings.appendchild($newNode) | out-null
        $doc.Save($file)
    }
    else {
        $get_ytdl = $doc.settings.getytdl
    }

    if ($get_ytdl -eq "unset") {
        $result = Read-KeyOrTimeout "选择要安装的下载器: [1=yt-dlp (推荐) / 2=youtube-dl / N=不安装] (默认=1)" "D1"
        Write-Host ""
        if ($result -eq 'D1' -or $result -eq '1') {
            $get_ytdl = "ytdlp"
        }
        elseif ($result -eq 'D2' -or $result -eq '2') {
            $get_ytdl = "youtubedl"
        }
        else {
            $get_ytdl = "false"
        }
        $doc.settings.getytdl = $get_ytdl
        $doc.Save($file)
    }

    return $get_ytdl
}

function Check-Ytdlp-Channel() {
    $ytdlp_channel = ""
    $file = "settings.xml"

    if (-not (Test-Path $file)) { exit }
    [xml]$doc = Get-Content $file
    if ($null -eq $doc.settings.ytdlpchannel) {
        $newNode = $doc.CreateElement("ytdlpchannel")
        $newNode.AppendChild($doc.CreateTextNode("unset")) | out-null
        $doc.settings.appendchild($newNode) | out-null
    }
    if ($doc.settings.ytdlpchannel -eq "unset") {
        $result = Read-KeyOrTimeout "选择 yt-dlp 更新通道: [1=stable (稳定版) / 2=nightly (每日构建) / 3=master] (默认=1)" "D1"
        Write-Host ""
        if ($result -eq 'D1' -or $result -eq '1') {
            $ytdlp_channel = "stable"
        }
        elseif ($result -eq 'D2' -or $result -eq '2') {
            $ytdlp_channel = "nightly"
        }
        elseif ($result -eq 'D3' -or $result -eq '3') {
            $ytdlp_channel = "master"
        }
        else {
            $ytdlp_channel = "stable"
        }
        $doc.settings.ytdlpchannel = $ytdlp_channel
        $doc.Save($file)
    }
    else {
        $ytdlp_channel = $doc.settings.ytdlpchannel
    }
    return $ytdlp_channel
}

function Upgrade-Mpv {
    Write-Host "`n>>> [1/3] 检查 MPV 播放器内核更新..." -ForegroundColor Cyan
    $need_download = $false
    $remoteName = ""
    $download_link = ""
    $arch = ""

    if (Check-Mpv) {
        $file_arch = (Get-Arch).FileType
        $arch = Check-Arch $file_arch
        $remoteName, $download_link = Get-Latest-Mpv $arch

        if ([string]::IsNullOrWhiteSpace($remoteName) -or [string]::IsNullOrWhiteSpace($download_link)) {
            Write-Host "[!] 未能获取到远端 MPV 构建信息，跳过本次 MPV 更新。" -ForegroundColor Yellow
            return
        }

        $localgit = ExtractGitFromFile
        $localdate = ExtractDateFromFile
        $remotegit = ExtractGitFromURL $remoteName
        $remotedate = ExtractDateFromURL $remoteName

        $localBuildDate = Get-BinaryBuildDate (Join-Path $script:mpvDir "mpv.exe")
        $localDisplayDate = if ($localBuildDate) { $localBuildDate } elseif ($localdate -match '^(?<y>\d{4})(?<m>\d{2})(?<d>\d{2})$') { "$($Matches.y)-$($Matches.m)-$($Matches.d)" } else { $localdate }
        $remoteDisplayDate = if ($remotedate -match '^(?<y>\d{4})(?<m>\d{2})(?<d>\d{2})$') { "$($Matches.y)-$($Matches.m)-$($Matches.d)" } else { $remotedate }

        Write-Host "    本地版本: Git[$localgit] 构建日期[$localDisplayDate]" -ForegroundColor Gray
        Write-Host "    远端版本: Git[$remotegit] 构建日期[$remoteDisplayDate]" -ForegroundColor Gray

        if ([string]::IsNullOrEmpty($localgit) -or [string]::IsNullOrEmpty($remotegit) -or [string]::IsNullOrEmpty($localdate) -or [string]::IsNullOrEmpty($remotedate)) {
            Write-Host "[!] 版本元数据未能完全比对，将拉取最新构建。" -ForegroundColor Yellow
            $need_download = $true
        }
        elseif (Test-CommitEquivalent $localgit $remotegit) {
            if ($localdate -eq $remotedate) {
                Write-Host "[√] MPV 已是最新构建 -- $remoteName" -ForegroundColor Green
                $need_download = $false
            }
            else {
                Write-Host "[!] 发现 MPV 新构建可用 ($remoteName)" -ForegroundColor Green
                $need_download = $true
            }
        }
        else {
            Write-Host "[!] 发现 MPV 新构建可用 ($remoteName)" -ForegroundColor Green
            $need_download = $true
        }
    }
    else {
        Write-Host "MPV 播放器尚未安装。 " -ForegroundColor Green -NoNewline
        $result = Read-KeyOrTimeout "是否现在下载并安装 MPV？[Y/n] (默认=Y)" "Y"
        Write-Host ""

        if ($result -eq 'Y' -or $result -eq 'y') {
            $need_download = $true
            if (Test-Path (Join-Path $env:windir "SysWow64")) {
                $original_arch = "x86_64"
            }
            else {
                $original_arch = "i686"
            }
            $arch = Check-Arch $original_arch
            $remoteName, $download_link = Get-Latest-Mpv $arch
        }
        else {
            $need_download = $false
        }
    }

    if ($need_download -and (-not [string]::IsNullOrWhiteSpace($download_link))) {
        Download-Archive $remoteName $download_link
        Check-7z
        $extractOk = Extract-Archive $remoteName
        if ($extractOk) {
            Check-Autodelete $remoteName
        } else {
            Write-Host "[!] 解压未成功，已保留原始压缩包供排查: $remoteName" -ForegroundColor Yellow
        }
    }
}

function Upgrade-Ytplugin {
    Write-Host "`n>>> [2/3] 检查视频解析工具 (yt-dlp) 更新..." -ForegroundColor Cyan
    if (Check-Ytplugin-In-System) {
        Write-Host "[i] 系统路径中已安装 yt-dlp/youtube-dl，跳过本地副本更新。" -ForegroundColor Green
        return
    }
    $yt = Check-Ytplugin
    if ($yt) {
        $latest_release = Get-Latest-Ytplugin((Get-Item $yt).BaseName)
        $current_ver = ""
        try {
            $current_ver = (& $yt --version 2>$null | Select-Object -First 1).Trim()
        } catch {}

        $localYtDate = Get-BinaryBuildDate $yt
        $ytDateHint = if ($current_ver -match '^\d{4}\.\d{2}\.\d{2}$') { " 构建日期[$($current_ver.Replace('.', '-'))]" } elseif ($localYtDate) { " 构建日期[$localYtDate]" } else { "" }
        $remoteYtDateHint = if ($latest_release -match '^\d{4}\.\d{2}\.\d{2}$') { " 构建日期[$($latest_release.Replace('.', '-'))]" } else { "" }

        Write-Host "    本地版本: $current_ver$ytDateHint" -ForegroundColor Gray
        Write-Host "    最新版本: $latest_release$remoteYtDateHint" -ForegroundColor Gray

        if ($latest_release -ne "latest" -and $current_ver -eq $latest_release) {
            Write-Host "[√] $((Get-Item $yt).BaseName) 已是最新版本 ($latest_release)" -ForegroundColor Green
            if ((Get-Item $yt).BaseName -Match "yt-dlp*") {
                Ensure-Deno "update"
            }
        }
        else {
            Write-Host "[!] 发现新版本可用 ($((Get-Item $yt).BaseName) -> $latest_release)" -ForegroundColor Green
            if ((Get-Item $yt).BaseName -Match "yt-dlp*") {
                Download-Ytplugin "yt-dlp" $latest_release
                Ensure-Deno "update"
            }
            else {
                Download-Ytplugin "youtube-dl" $latest_release
            }
        }
    }
    else {
        Write-Host "尚未检测到 yt-dlp 或 youtube-dl。" -ForegroundColor Yellow
        $ytdl = Check-GetYTDL
        if ($ytdl -eq 'ytdlp') {
            $latest_release = Get-Latest-Ytplugin "yt-dlp"
            Download-Ytplugin "yt-dlp" $latest_release
            Ensure-Deno "install"
        }
        elseif ($ytdl -eq 'youtubedl') {
            $latest_release = Get-Latest-Ytplugin "youtube-dl"
            Download-Ytplugin "youtube-dl" $latest_release
        }
    }
}

function Upgrade-FFmpeg {
    Write-Host "`n>>> [3/3] 检查 FFmpeg 编解码器组件更新..." -ForegroundColor Cyan
    $get_ffmpeg = Check-GetFFmpeg
    if ($get_ffmpeg -eq "false") {
        Write-Host "[i] 根据配置文件设置，已跳过 FFmpeg。" -ForegroundColor Gray
        return
    }

    if (Test-Path (Join-Path $env:windir "SysWow64")) {
        $original_arch = "x86_64"
        $arch = Check-Arch $original_arch
    }
    else {
        $arch = "i686"
    }

    $need_download = $false
    $remote_name, $download_link = Get-Latest-FFmpeg $arch
    if ([string]::IsNullOrWhiteSpace($remote_name) -or [string]::IsNullOrWhiteSpace($download_link)) {
        Write-Host "[!] 未能获取到远端 FFmpeg 构建信息，跳过更新。" -ForegroundColor Yellow
        return
    }

    $ffmpeg = (Get-Location).Path + "\ffmpeg.exe"
    $ffmpeg_exist = Test-Path $ffmpeg

    if ($ffmpeg_exist) {
        $ffmpeg_file = .\ffmpeg -version 2>$null | Select-String "ffmpeg" | Select-Object -First 1
        $file_patterns = @(
            "git-[0-9]{4}-[0-9]{2}-[0-9]{2}-(?<commit>[0-9A-Fa-f]{7,40})(?=[^0-9A-Fa-f]|$)",
            "N-\d+-g(?<commit>[0-9A-Fa-f]{7,40})(?=[^0-9A-Fa-f]|$)"
        )
        $url_patterns = @(
            "-git-(?<commit>[0-9A-Fa-f]{7,40})(?=[^0-9A-Fa-f]|$)"
        )
        $local_git = Get-RegexGroupValue $ffmpeg_file $file_patterns "commit"
        $remote_git = Get-RegexGroupValue $remote_name $url_patterns "commit"

        $localFfmpegDate = Get-BinaryBuildDate $ffmpeg
        $remoteFfmpegDate = ExtractDateFromURL $remote_name
        $remoteFfmpegDisplay = if ($remoteFfmpegDate -match '^(?<y>\d{4})(?<m>\d{2})(?<d>\d{2})$') { "$($Matches.y)-$($Matches.m)-$($Matches.d)" } else { "" }
        $remoteDateText = if ($remoteFfmpegDisplay) { " 构建日期[$remoteFfmpegDisplay]" } else { "" }

        Write-Host "    本地版本: Git[$local_git] 构建日期[$localFfmpegDate]" -ForegroundColor Gray
        Write-Host "    远端版本: Git[$remote_git]$remoteDateText" -ForegroundColor Gray

        if ([string]::IsNullOrEmpty($local_git) -or [string]::IsNullOrEmpty($remote_git)) {
            Write-Host "[!] 无法完全比对 Git commit，将拉取最新版本。" -ForegroundColor Yellow
            $need_download = $true
        }
        elseif (Test-CommitEquivalent $local_git $remote_git) {
            Write-Host "[√] FFmpeg 已是最新构建 -- $remote_name" -ForegroundColor Green
            $need_download = $false
        }
        else {
            Write-Host "[!] 发现 FFmpeg 新版本可用" -ForegroundColor Green
            $need_download = $true
        }
    }
    else {
        $need_download = $true
    }

    if ($need_download -and (-not [string]::IsNullOrWhiteSpace($download_link))) {
        Download-Archive $remote_name $download_link
        Check-7z
        $extractOk = Extract-Archive $remote_name
        if ($extractOk) {
            Check-Autodelete $remote_name
        } else {
            Write-Host "[!] 解压未成功，已保留原始压缩包供排查: $remote_name" -ForegroundColor Yellow
        }
    }
}

function Read-KeyOrTimeout ($prompt, $defaultKey){
    $seconds = 7
    $startTime = Get-Date
    $timeOut = New-TimeSpan -Seconds $seconds

    Write-Host "$prompt " -ForegroundColor Green -NoNewline

    # 平滑显示剩余秒数倒计时
    while ($true) {
        $elapsed = (Get-Date) - $startTime
        $remaining = [Math]::Max(0, [int]($seconds - $elapsed.TotalSeconds))

        # 检查按键
        $hasKey = $false
        try {
            if ([System.Console]::KeyAvailable) {
                $hasKey = $true
            }
        } catch {}

        if ($hasKey) {
            $pressed = [System.Console]::ReadKey($true)
            $retKey = $pressed.Key.ToString()
            # 如果是回车，使用默认键
            if ($retKey -eq "Enter") {
                return $defaultKey
            }
            # 如果按下了数字或字母键
            if ($pressed.KeyChar -match "[0-9a-zA-Z]") {
                return $pressed.KeyChar.ToString().ToUpper()
            }
            return $retKey
        }

        if ($elapsed -ge $timeOut) {
            break
        }

        Write-Host "`r$prompt [倒计时 ${remaining}s] " -NoNewline -ForegroundColor Gray
        Start-Sleep -Milliseconds 200
    }

    return $defaultKey
}

function Show-Summary-And-Wait ($hasError, $errorMsg) {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "               一键更新与组件状态检查报告               " -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan

    $mpvVer = "未安装"
    $mpvOk = $false
    try {
        $raw = & .\mpv.com --no-config --version 2>$null | Select-Object -First 1
        if ($raw -match "mpv\s+(?<v>[^\s]+)") {
            $mpvVer = $Matches['v']
            $mpvOk = $true
        }
    } catch {}
    if ($mpvOk) {
        $mpvDate = Get-BinaryBuildDate (Join-Path $script:mpvDir "mpv.exe")
        $dateText = if ($mpvDate) { " | 构建于 $mpvDate" } else { "" }
        Write-Host " [√] MPV 播放器      : 正常 ($mpvVer$dateText)" -ForegroundColor Green
    } else {
        Write-Host " [×] MPV 播放器      : 异常/未找到" -ForegroundColor Red
    }

    $ytdlpVer = "未安装"
    $ytdlpOk = $false
    try {
        $raw = & .\yt-dlp.exe --version 2>$null | Select-Object -First 1
        if ($raw) {
            $ytdlpVer = $raw.Trim()
            $ytdlpOk = $true
        }
    } catch {}
    if ($ytdlpOk) {
        $ytdlpDate = Get-BinaryBuildDate (Join-Path $script:mpvDir "yt-dlp.exe")
        $dateText = if ($ytdlpVer -match '^\d{4}\.\d{2}\.\d{2}$') { " | 构建于 $($ytdlpVer.Replace('.', '-'))" } elseif ($ytdlpDate) { " | 构建于 $ytdlpDate" } else { "" }
        Write-Host " [√] yt-dlp 视频解析 : 正常 ($ytdlpVer$dateText)" -ForegroundColor Green
    } else {
        Write-Host " [×] yt-dlp 视频解析 : 异常/未找到" -ForegroundColor Red
    }

    $denoVer = "未安装"
    $denoOk = $false
    try {
        $raw = & .\deno.exe --version 2>$null | Select-String "deno" | Select-Object -First 1
        if ($raw -match "deno\s+(?<v>[^\s]+)") {
            $denoVer = "v" + $Matches['v'].TrimStart('v')
            $denoOk = $true
        }
    } catch {}
    if ($denoOk) {
        $denoDate = Get-BinaryBuildDate (Join-Path $script:mpvDir "deno.exe")
        $dateText = if ($denoDate) { " | 构建于 $denoDate" } else { "" }
        Write-Host " [√] Deno 运行时     : 正常 ($denoVer$dateText)" -ForegroundColor Green
    } else {
        Write-Host " [×] Deno 运行时     : 异常/未找到" -ForegroundColor Red
    }

    $ffmpegVer = "未安装"
    $ffmpegOk = $false
    try {
        $raw = & .\ffmpeg.exe -version 2>$null | Select-Object -First 1
        if ($raw -match "ffmpeg version\s+(?<v>[^\s]+)") {
            $ffmpegVer = $Matches['v']
            $ffmpegOk = $true
        }
    } catch {}
    if ($ffmpegOk) {
        $ffmpegDate = Get-BinaryBuildDate (Join-Path $script:mpvDir "ffmpeg.exe")
        $dateText = if ($ffmpegDate) { " | 构建于 $ffmpegDate" } else { "" }
        Write-Host " [√] FFmpeg 编解码器 : 正常 ($ffmpegVer$dateText)" -ForegroundColor Green
    } else {
        Write-Host " [×] FFmpeg 编解码器 : 异常/未找到" -ForegroundColor Red
    }

    Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    if ($hasError) {
        Write-Host " 执行状态: 更新过程中存在异常" -ForegroundColor Yellow
        Write-Host " 提示信息: $errorMsg" -ForegroundColor Red
    } else {
        Write-Host " 执行状态: 全部组件已成功通过检查与更新，状态正常！" -ForegroundColor Green
    }
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "提示: 窗口不会自动关闭，您可以随时查看上方信息。" -ForegroundColor Gray
    Write-Host "请按任意键退出窗口..." -ForegroundColor Yellow

    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try {
            $null = [System.Console]::ReadKey($true)
        } catch {
            Read-Host "按回车键退出..."
        }
    }
}

#
# 脚本主入口
#
if (Test-Admin) {
    Write-Host "[i] 当前以管理员权限运行" -ForegroundColor Yellow
}
else {
    Write-Host "[i] 当前以普通用户权限运行" -ForegroundColor Gray
}

try {
    Check-PowershellVersion
    # 兼容处理 TLS 协议配置（适用于 PS 5.1）
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    $global:progressPreference = 'silentlyContinue'

    Upgrade-Mpv
    Upgrade-Ytplugin
    Upgrade-FFmpeg
    Show-Summary-And-Wait $false ""
}
catch [System.Exception] {
    Show-Summary-And-Wait $true $_.Exception.Message
    exit 1
}
