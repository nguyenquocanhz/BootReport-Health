<#
  BootReport.ps1 - Xuat bao cao boot Windows ra file HTML
  Cach dung (PowerShell, nen chay Run as administrator):
      powershell -ExecutionPolicy Bypass -File .\BootReport.ps1
      powershell -ExecutionPolicy Bypass -File .\BootReport.ps1 -Days 30 -Out D:\boot.html
#>
param(
    [int]$Days = 60,
    [string]$Out = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'BootReport.html'),
    [switch]$NoOpen,
    [switch]$Elevated,
    [ValidateSet('auto','vi','en')][string]$Lang = 'auto'
)

# Chon ngon ngu bao cao / Report language: auto = theo ngon ngu hien thi cua Windows
$uiLang = $Lang
if ($uiLang -eq 'auto') {
    if ((Get-UICulture).TwoLetterISOLanguageName -eq 'vi') { $uiLang = 'vi' } else { $uiLang = 'en' }
}
$Messages = @{
    vi = @{
        denied  = 'Ban da tu choi cap quyen Administrator. Script can quyen nay de doc log.'
        nolog   = 'Khong doc duoc log. Hay chay PowerShell bang quyen Administrator.'
        collect = 'Dang thu thap thong tin pin, o dia, RAM, su kien he thong...'
        done    = 'Da xuat bao cao'
        enter   = 'Nhan Enter de dong cua so'
    }
    en = @{
        denied  = 'Administrator permission was denied. The script needs it to read the logs.'
        nolog   = 'Could not read the log. Please run PowerShell as Administrator.'
        collect = 'Collecting battery, disk, RAM and system event data...'
        done    = 'Report saved'
        enter   = 'Press Enter to close this window'
    }
}
$M = $Messages[$uiLang]

# Tu xin quyen Administrator neu chua co
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSCommandPath) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                     '-Days', $Days, '-Out', "`"$Out`"", '-Lang', $Lang, '-Elevated')
        if ($NoOpen) { $argList += '-NoOpen' }
    } else {
        $rawUrl = 'https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.ps1'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "irm $rawUrl | iex")
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host $M.denied -ForegroundColor Yellow
    }
    exit
}

$log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$start = (Get-Date).AddDays(-$Days)

function N($v) { if ($v) { [int64]$v } else { 0 } }

try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 100,101,102,103,106,109; StartTime = $start } -ErrorAction Stop
} catch {
    Write-Host $M.nolog -ForegroundColor Yellow
    Write-Host $_.Exception.Message
    if ($Elevated) { Read-Host $M.enter | Out-Null }
    exit 1
}

$boots = New-Object System.Collections.ArrayList
$items = New-Object System.Collections.ArrayList

foreach ($e in $events) {
    $x = [xml]$e.ToXml()
    $h = @{}
    foreach ($d in $x.Event.EventData.Data) { $h[$d.Name] = $d.'#text' }
    $time = $e.TimeCreated.ToString('o')

    if ($e.Id -eq 100) {
        [void]$boots.Add([pscustomobject]@{
            time     = $time
            level    = $e.LevelDisplayName
            boot     = N $h['BootTime']
            main     = N $h['MainPathBootTime']
            post     = N $h['BootPostBootTime']
            kernel   = N $h['BootKernelInitTime']
            driver   = N $h['BootDriverInitTime']
            devices  = N $h['BootDevicesInitTime']
            smss     = N $h['BootSmssInitTime']
            services = N $h['BootCriticalServicesInitTime']
            profile  = N $h['BootUserProfileProcessingTime']
            loader   = N $h['OSLoaderDuration']
        })
    } else {
        $name = $h['Name']
        if (-not $name) { $name = $h['FriendlyName'] }
        if (-not $name) { $name = $h['DeviceName'] }
        if (-not $name) { $name = "(khong ro) Event $($e.Id)" }
        $total = N $h['TotalTime']
        [void]$items.Add([pscustomobject]@{
            time    = $time
            id      = $e.Id
            name    = $name
            friendly= $h['FriendlyName']
            company = $h['Company']
            path    = $h['Path']
            total   = $total
            deg     = N $h['DegradationTime']
        })
    }
}

# ---------- Suc khoe laptop ----------
Write-Host $M.collect -ForegroundColor Cyan

function Get-Prop($o, $p) { if ($null -ne $o -and $null -ne $o.$p) { $o.$p } else { $null } }
function Count-Ev($f) { try { @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop).Count } catch { 0 } }

# -- Pin (powercfg /batteryreport, du phong bang WMI) --
$battery = $null
$wb = $null
try { $wb = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1 } catch {}
$design = 0; $full = 0; $cycles = 0; $maker = $null; $chem = $null; $bname = $null
try {
    $tmp = Join-Path $env:TEMP 'bootreport-battery.xml'
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    & powercfg.exe /batteryreport /xml /output $tmp 2>&1 | Out-Null
    if (Test-Path $tmp) {
        $bx = New-Object System.Xml.XmlDocument
        $bx.Load($tmp)
        $bn = $bx.SelectSingleNode("//*[local-name()='Battery'][*[local-name()='DesignCapacity']]")
        if ($bn) {
            $get = { param($n) $c = $bn.SelectSingleNode("*[local-name()='$n']"); if ($c) { $c.InnerText } else { $null } }
            $design = N (& $get 'DesignCapacity')
            $full   = N (& $get 'FullChargeCapacity')
            $cycles = N (& $get 'CycleCount')
            $maker  = & $get 'Manufacturer'
            $chem   = & $get 'Chemistry'
            $bname  = & $get 'Id'
        }
    }
} catch {}
if ($design -le 0) {
    try {
        $sd = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1
        $fc = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
        $design = N (Get-Prop $sd 'DesignedCapacity')
        $full   = N (Get-Prop $fc 'FullChargedCapacity')
        if (-not $maker) { $maker = Get-Prop $sd 'ManufactureName' }
    } catch {}
}
if ($cycles -le 0) {
    try {
        $cc = Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop | Select-Object -First 1
        $cycles = N (Get-Prop $cc 'CycleCount')
    } catch {}
}
if ($wb -or $design -gt 0) {
    $pct = $null
    if ($design -gt 0) { $pct = [math]::Round($full / $design * 100, 1) }
    $battery = [pscustomobject]@{
        name = $bname; maker = $maker; chemistry = $chem
        design = $design; full = $full; cycles = $cycles; percent = $pct
        charge = Get-Prop $wb 'EstimatedChargeRemaining'
        status = Get-Prop $wb 'BatteryStatus'
    }
}

# -- O dia (SMART / do mon) --
$disks = @()
try {
    $disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        $r = $null
        try { $r = $_ | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        [pscustomobject]@{
            name     = $_.FriendlyName
            media    = [string]$_.MediaType
            bus      = [string]$_.BusType
            health   = [string]$_.HealthStatus
            sizeGB   = [math]::Round($_.Size / 1GB)
            wear     = Get-Prop $r 'Wear'
            temp     = Get-Prop $r 'Temperature'
            hours    = Get-Prop $r 'PowerOnHours'
            readErr  = Get-Prop $r 'ReadErrorsTotal'
            writeErr = Get-Prop $r 'WriteErrorsTotal'
        }
    })
} catch {}

$vols = @()
try {
    $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
        [pscustomobject]@{
            letter = [string]$_.DriveLetter; label = $_.FileSystemLabel
            sizeGB = [math]::Round($_.Size / 1GB, 1); freeGB = [math]::Round($_.SizeRemaining / 1GB, 1)
        }
    })
} catch {}

# -- He thong --
$sys = $null
try {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    $bio = Get-CimInstance Win32_BIOS
    $sys = [pscustomobject]@{
        model      = ("$($cs.Manufacturer) $($cs.Model)").Trim()
        os         = $os.Caption
        osVersion  = $os.Version
        lastBoot   = $os.LastBootUpTime.ToString('o')
        cpu        = $cpu.Name
        cores      = $cpu.NumberOfCores
        threads    = $cpu.NumberOfLogicalProcessors
        load       = $cpu.LoadPercentage
        ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        ramFreeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        ramModules = $mem.Count
        ramSpeed   = ($mem | Select-Object -First 1).Speed
        bios       = $bio.SMBIOSBIOSVersion
    }
} catch {}

# -- Su kien loi 30 ngay gan nhat --
$since = (Get-Date).AddDays(-30)
$diskErr = (Count-Ev @{ LogName = 'System'; ProviderName = 'disk'; Level = 1,2,3; StartTime = $since }) +
           (Count-Ev @{ LogName = 'System'; ProviderName = 'Ntfs'; Id = 55; StartTime = $since })
$events = [pscustomobject]@{
    unexpectedShutdown = Count-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
    diskErrors         = $diskErr
    hardwareErrors     = Count-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
    bugchecks          = Count-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
}

# -- Nguon dien / Power source (AC mains vs battery) --
$acOnline = $null
try {
    $bsw = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $bsw) { $acOnline = [bool]$bsw.PowerOnline }
} catch {}
if (-not $wb -and $design -le 0) {
    $powerSource = 'ac-desktop'          # khong co pin -> may ban / server chay dien truc tiep
} elseif ($null -ne $acOnline) {
    $powerSource = if ($acOnline) { 'ac' } else { 'battery' }
} elseif ($battery -and $null -ne $battery.status) {
    $powerSource = if ([int]$battery.status -eq 1) { 'battery' } else { 'ac' }
} else {
    $powerSource = $null
}

$health = [pscustomobject]@{
    battery = $battery
    power   = $powerSource
    disks   = $disks
    volumes = $vols
    system  = $sys
    events  = $events
}

$payload = [pscustomobject]@{
    lang      = $uiLang
    health    = $health
    computer  = $env:COMPUTERNAME
    generated = (Get-Date).ToString('o')
    days      = $Days
    boots     = @($boots)
    items     = @($items)
}
$json = ConvertTo-Json -InputObject $payload -Depth 5 -Compress
$json = $json -replace '</', '<\/'

$html = @'
<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Windows health and boot report</title>
<style>
:root{
  --bg:#eef1f4; --panel:#ffffff; --ink:#14202b; --muted:#5d6b78; --line:#d9dfe5;
  --accent:#0f6e6e; --warn:#c98a00; --bad:#c23b32; --ok:#2f8a57; --bar:#cfe3e3;
}
@media (prefers-color-scheme:dark){
  :root{ --bg:#0f1519; --panel:#172027; --ink:#e6edf2; --muted:#8fa0ad; --line:#27343e;
         --accent:#4fc1c1; --warn:#e3a82b; --bad:#ef6a60; --ok:#5cc489; --bar:#24424a; }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 "Segoe UI Variable","Segoe UI",system-ui,sans-serif}
main{max-width:1080px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:26px;margin:0 0 4px;font-weight:650;letter-spacing:-.01em}
h2{font-size:17px;margin:34px 0 12px;font-weight:650}
.sub{color:var(--muted);margin:0 0 22px}
.verdict{background:var(--panel);border:1px solid var(--line);border-left:5px solid var(--accent);border-radius:6px;padding:16px 20px}
.verdict p{margin:0 0 6px}
.verdict p:last-child{margin:0}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin-top:14px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:12px 16px}
.stat b{display:block;font-size:24px;font-weight:650;font-variant-numeric:tabular-nums}
.stat span{color:var(--muted);font-size:13px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:16px;overflow-x:auto}
svg{display:block;width:100%;height:auto}
.legend{display:flex;gap:16px;color:var(--muted);font-size:13px;margin-top:8px;flex-wrap:wrap}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
.tabs{display:flex;gap:6px;margin-bottom:10px;flex-wrap:wrap}
.tabs button{font:inherit;background:transparent;color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:5px 14px;cursor:pointer}
.tabs button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff}
.tabs button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
th{font-weight:600;color:var(--muted);font-size:13px}
td.num,th.num{text-align:right}
td.name{white-space:normal;max-width:380px;word-break:break-word}
.meter{display:inline-block;height:8px;border-radius:4px;background:var(--accent);vertical-align:middle;margin-right:8px;min-width:2px}
.tag{font-size:12px;padding:1px 8px;border-radius:10px;color:#fff}
.tag.Error{background:var(--bad)} .tag.Warning{background:var(--warn)} .tag.Information{background:var(--ok)}
.empty{color:var(--muted);padding:10px}
.small{color:var(--muted);font-size:13px;margin-top:8px}
.hwrap{display:flex;gap:28px;align-items:center;flex-wrap:wrap}
.hwrap svg{width:140px;flex:none}
.ring-bg{fill:none;stroke:var(--line);stroke-width:12}
.ring-fg{fill:none;stroke-width:12;stroke-linecap:round;transform:rotate(-90deg);transform-origin:70px 70px}
.ring-fg.ok{stroke:var(--ok)} .ring-fg.warn{stroke:var(--warn)} .ring-fg.bad{stroke:var(--bad)}
.ring-num{font-size:30px;font-weight:650;fill:var(--ink);text-anchor:middle}
.ring-lbl{font-size:12px;fill:var(--muted);text-anchor:middle}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 20px;margin:0}
.kv dt{color:var(--muted)} .kv dd{margin:0;font-variant-numeric:tabular-nums}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px}
.dot.ok{background:var(--ok)} .dot.warn{background:var(--warn)} .dot.bad{background:var(--bad)}
td .note{display:block;color:var(--muted);font-size:12px;white-space:normal}
.footer{margin-top:36px;padding-top:16px;border-top:1px solid var(--line);text-align:center;color:var(--muted);font-size:13px}
.footer a{color:var(--accent);text-decoration:none}
.footer a:hover{text-decoration:underline}
</style>
</head>
<body>
<main>
  <h1 data-i18n="title"></h1>
  <p class="sub" id="sub"></p>
  <section class="verdict" id="verdict"></section>
  <div class="stats" id="stats"></div>

  <h2 data-i18n="hBattery"></h2>
  <div class="panel" id="battery"></div>

  <h2 data-i18n="hHealth"></h2>
  <div class="panel" id="checks"></div>
  <p class="small" id="sysinfo"></p>

  <h2 data-i18n="hChart"></h2>
  <div class="panel">
    <div id="chart"></div>
    <div class="legend">
      <span><i style="background:var(--ok)"></i><span data-i18n="legOk"></span></span>
      <span><i style="background:var(--warn)"></i><span data-i18n="legWarn"></span></span>
      <span><i style="background:var(--bad)"></i><span data-i18n="legBad"></span></span>
    </div>
  </div>

  <h2 data-i18n="hOff"></h2>
  <div class="tabs" id="tabs" role="group"></div>
  <div class="panel" id="offenders"></div>
  <p class="small" data-i18n="offNote"></p>

  <h2 data-i18n="hTable"></h2>
  <div class="panel" id="bootTable"></div>

  <footer class="footer">
    <p data-i18n="footerText"></p>
  </footer>
</main>

<script>
const D = __DATA__;
const L = D.lang === "vi" ? "vi" : "en";
const LOC = L === "vi" ? "vi-VN" : "en-US";

const TX = {
vi:{
 title:"Báo cáo sức khỏe và khởi động Windows",
 subtitle:"{0} · {1} ngày gần nhất · tạo lúc {2}",
 hBattery:"Sức khỏe pin", hHealth:"Sức khỏe laptop", hChart:"Thời gian boot theo từng lần",
 hOff:"Thủ phạm làm chậm boot", hTable:"30 lần boot gần nhất",
 legOk:"Bình thường", legWarn:"Chậm (Warning)", legBad:"Rất chậm (Error)",
 offNote:"Sắp xếp theo tổng thời gian trung bình. Cột “Chậm thêm” là phần thời gian vượt mức bình thường mà Windows ghi nhận.",
 tabsAria:"Loại thành phần",
 noBoot:"Không có sự kiện boot nào trong khoảng thời gian này.",
 noData:"Không có dữ liệu.",
 vLast:"<b>10 lần boot gần nhất:</b> trung bình {0} tổng, trong đó {1} để tới desktop và {2} sau khi vào desktop (app nền vẫn đang tải).",
 vPost:"Phần lớn thời gian nằm <b>sau khi vào desktop</b>. Nguyên nhân thường là app khởi động cùng Windows. Xem bảng “App” bên dưới.",
 vProf:"Nạp profile người dùng mất {0}. Có thể do OneDrive, thư mục mạng hoặc profile quá nặng.",
 vDrv:"Driver/thiết bị nạp lâu (driver {0}, thiết bị {1}). Xem bảng “Driver”, cập nhật hoặc gỡ driver nghi ngờ.",
 vSvc:"Các service quan trọng nạp lâu ({0}). Xem bảng “Service”.",
 vElse:"Phần lớn thời gian nằm trước khi tới desktop. Xem bảng thủ phạm để biết thành phần cụ thể.",
 sBoots:"lần boot được ghi nhận", sAvg:"boot trung bình", sWorst:"chậm nhất · {0}", sErrWarn:"lần Error / Warning",
 gApp:"App", gDriver:"Driver", gService:"Service", gOther:"Khác",
 noGroup:"Không có mục nào trong nhóm này. Windows không ghi nhận thành phần nào làm chậm.",
 cName:"Tên", cCount:"Số lần", cAvg:"Thời gian TB", cMax:"Lâu nhất", cExtra:"Chậm thêm TB",
 cTime:"Thời điểm", cTotal:"Tổng", cMain:"Tới desktop", cPost:"Sau boot", cKernel:"Kernel", cDriver:"Driver", cDevices:"Thiết bị", cProfile:"Profile", cLevel:"Mức",
 lvOk:"Tốt", lvWarn:"Cần theo dõi", lvBad:"Có vấn đề",
 noBattery:"Không tìm thấy pin — máy đang dùng nguồn điện trực tiếp (máy bàn/PC), hoặc pin không báo cáo được.",
 ckPower:"Nguồn điện", pwAc:"Đang cắm điện (AC)", pwBattery:"Đang chạy bằng pin", pwDesktop:"Nguồn điện trực tiếp (máy bàn, không có pin)",
 bMsgNone:"Không đọc được dung lượng thiết kế nên chưa tính được độ chai pin.",
 bMsgOk:"Pin còn tốt, giữ được phần lớn dung lượng ban đầu.",
 bMsgWarn:"Pin đã chai ở mức trung bình, thời lượng dùng giảm rõ rệt.",
 bMsgBad:"Pin chai nhiều, nên cân nhắc thay pin nếu thời lượng dùng không đủ.",
 ringAria:"Sức khỏe pin {0}", ringLbl:"sức khỏe pin", unknown:"không rõ",
 kDesign:"Dung lượng thiết kế", kFull:"Dung lượng đầy hiện tại", kCycles:"Số chu kỳ sạc", kCharge:"Mức pin hiện tại",
 kStatus:"Trạng thái", kMaker:"Nhà sản xuất", kChem:"Loại pin",
 bs1:"Đang dùng pin", bs2:"Đang cắm sạc", bs3:"Đã đầy", bs4:"Pin yếu", bs5:"Pin gần cạn", bs6:"Đang sạc", bs11:"Sạc một phần", bsCode:"Mã {0}",
 ckBattery:"Pin", ckBatteryVal:"{0}% dung lượng thiết kế",
 ckCycles:"Chu kỳ sạc pin", ckCyclesVal:"{0} chu kỳ", ckCyclesNote:"Pin laptop thường suy giảm rõ sau khoảng 500 đến 1000 chu kỳ.",
 ckDisk:"Ổ đĩa: {0}", dWear:"đã mòn {0}%", dHours:"{0} giờ hoạt động",
 dBadNote:"Windows báo ổ đĩa không ở trạng thái Healthy. Hãy sao lưu dữ liệu.",
 dWearNote:"Ổ gần hết tuổi thọ ghi.",
 dErrNote:"Có lỗi đọc/ghi (đọc {0}, ghi {1}).",
 dWatchNote:"Mòn hoặc nhiệt độ ổ ở mức cần theo dõi.",
 ckVol:"Ổ {0}:{1}", ckVolVal:"trống {0} / {1} GB ({2}%)", ckVolNote:"Ổ gần đầy sẽ làm máy chậm và SSD chóng mòn hơn.",
 ckRam:"RAM", ckRamVal:"{0} GB · đang dùng {1}%{2}", ckRamNote:"RAM gần đầy lúc tạo báo cáo.",
 ckUp:"Thời gian chưa khởi động lại", ckUpVal:"{0} ngày",
 ckUpNote:"Fast Startup có thể khiến máy không thật sự khởi động lại. Hãy Restart (không phải Shut down) để làm mới hệ thống.",
 evVal:"{0} lần trong 30 ngày",
 evShut:"Tắt máy đột ngột (Kernel-Power 41)", evShutNote:"Mất điện, treo máy hoặc giữ nút nguồn. Nếu lặp lại, hãy kiểm tra nguồn, nhiệt độ và RAM.",
 evDisk:"Lỗi ổ đĩa / hệ thống tập tin", evDiskNote:"Chạy chkdsk và kiểm tra SMART bằng CrystalDiskInfo.",
 evWhea:"Lỗi phần cứng (WHEA)", evWheaNote:"Windows ghi nhận lỗi CPU, RAM hoặc bus PCIe. Cần kiểm tra phần cứng.",
 evBsod:"Màn hình xanh (BugCheck)", evBsodNote:"Xem file dump bằng WhoCrashed hoặc BlueScreenView để biết driver gây lỗi.",
 summary:"<b>{0}</b> mục tốt · <b>{1}</b> cần theo dõi · <b>{2}</b> có vấn đề",
 hdrItem:"Hạng mục", hdrValue:"Giá trị", hdrRating:"Đánh giá",
 sysinfo:"{0} · {1} ({2} nhân, {3} luồng) · {4} {5} · BIOS {6}",
 footerText:"© 2026 BootReport · Phát triển bởi NGUYỄN QUỐC ANH · Mã nguồn mở (MIT License)"
},
en:{
 title:"Windows health and boot report",
 subtitle:"{0} · last {1} days · generated {2}",
 hBattery:"Battery health", hHealth:"Laptop health", hChart:"Boot time per boot",
 hOff:"What slows down boot", hTable:"Last 30 boots",
 legOk:"Normal", legWarn:"Slow (Warning)", legBad:"Very slow (Error)",
 offNote:"Sorted by average total time. “Extra delay” is the time beyond normal that Windows recorded.",
 tabsAria:"Component type",
 noBoot:"No boot events in this period.",
 noData:"No data.",
 vLast:"<b>Last 10 boots:</b> {0} on average, of which {1} to reach the desktop and {2} after the desktop appears (background apps still loading).",
 vPost:"Most of the time is spent <b>after the desktop appears</b>. This is usually startup apps. See the “App” table below.",
 vProf:"Loading the user profile takes {0}. Possible causes: OneDrive, network folders or a very large profile.",
 vDrv:"Drivers/devices load slowly (drivers {0}, devices {1}). See the “Driver” table; update or remove suspect drivers.",
 vSvc:"Critical services load slowly ({0}). See the “Service” table.",
 vElse:"Most of the time is spent before the desktop appears. See the table below for specific components.",
 sBoots:"boots recorded", sAvg:"average boot", sWorst:"slowest · {0}", sErrWarn:"Error / Warning boots",
 gApp:"App", gDriver:"Driver", gService:"Service", gOther:"Other",
 noGroup:"Nothing in this group. Windows did not record any component slowing boot.",
 cName:"Name", cCount:"Count", cAvg:"Avg time", cMax:"Longest", cExtra:"Avg extra delay",
 cTime:"Time", cTotal:"Total", cMain:"To desktop", cPost:"After boot", cKernel:"Kernel", cDriver:"Driver", cDevices:"Devices", cProfile:"Profile", cLevel:"Level",
 lvOk:"Good", lvWarn:"Watch", lvBad:"Problem",
 noBattery:"No battery — this machine runs on direct AC power (desktop/PC), or the battery cannot report.",
 ckPower:"Power source", pwAc:"On AC power (plugged in)", pwBattery:"On battery", pwDesktop:"Direct AC power (desktop, no battery)",
 bMsgNone:"Design capacity unavailable, so battery wear can't be calculated.",
 bMsgOk:"Battery is in good shape and keeps most of its original capacity.",
 bMsgWarn:"Battery has moderate wear; runtime is noticeably reduced.",
 bMsgBad:"Battery is heavily worn; consider replacing it if runtime is not enough.",
 ringAria:"Battery health {0}", ringLbl:"battery health", unknown:"unknown",
 kDesign:"Design capacity", kFull:"Current full capacity", kCycles:"Charge cycles", kCharge:"Current charge",
 kStatus:"Status", kMaker:"Manufacturer", kChem:"Chemistry",
 bs1:"On battery", bs2:"Plugged in", bs3:"Fully charged", bs4:"Low", bs5:"Critical", bs6:"Charging", bs11:"Partially charged", bsCode:"Code {0}",
 ckBattery:"Battery", ckBatteryVal:"{0}% of design capacity",
 ckCycles:"Battery cycles", ckCyclesVal:"{0} cycles", ckCyclesNote:"Laptop batteries typically degrade noticeably after about 500 to 1000 cycles.",
 ckDisk:"Drive: {0}", dWear:"{0}% worn", dHours:"{0} power-on hours",
 dBadNote:"Windows reports the drive is not Healthy. Back up your data.",
 dWearNote:"Drive is near the end of its write endurance.",
 dErrNote:"Read/write errors (read {0}, write {1}).",
 dWatchNote:"Wear or temperature is worth watching.",
 ckVol:"Volume {0}:{1}", ckVolVal:"{0} / {1} GB free ({2}%)", ckVolNote:"A nearly full drive slows the PC and wears SSDs faster.",
 ckRam:"RAM", ckRamVal:"{0} GB · {1}% in use{2}", ckRamNote:"RAM was nearly full when the report was generated.",
 ckUp:"Time since last restart", ckUpVal:"{0} days",
 ckUpNote:"Fast Startup can keep Windows from truly restarting. Use Restart (not Shut down) to refresh the system.",
 evVal:"{0} time(s) in the last 30 days",
 evShut:"Unexpected shutdowns (Kernel-Power 41)", evShutNote:"Power loss, freezes or holding the power button. If it repeats, check power, temperature and RAM.",
 evDisk:"Disk / file system errors", evDiskNote:"Run chkdsk and check SMART with CrystalDiskInfo.",
 evWhea:"Hardware errors (WHEA)", evWheaNote:"Windows logged CPU, RAM or PCIe bus errors. Hardware check needed.",
 evBsod:"Blue screens (BugCheck)", evBsodNote:"Inspect the dump with WhoCrashed or BlueScreenView to find the faulty driver.",
 summary:"<b>{0}</b> good · <b>{1}</b> to watch · <b>{2}</b> with problems",
 hdrItem:"Item", hdrValue:"Value", hdrRating:"Rating",
 sysinfo:"{0} · {1} ({2} cores, {3} threads) · {4} {5} · BIOS {6}",
 footerText:"© 2026 BootReport · Developed by NGUYEN QUOC ANH · Open-source under MIT License"
}};

function t(k){
  let s = TX[L][k]; if(s==null) s = TX.en[k]; if(s==null) s = k;
  for(let i=1;i<arguments.length;i++) s = s.split("{"+(i-1)+"}").join(arguments[i]);
  return s;
}
const $ = id => document.getElementById(id);
const sec = ms => (ms/1000).toFixed(1) + " s";
const esc = s => String(s==null?"":s).replace(/[&<>"]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const fmtDate = tm => new Date(tm).toLocaleString(LOC,{day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"});
const avg = a => a.length ? a.reduce((x,y)=>x+y,0)/a.length : 0;
const num = v => v==null ? null : Number(v);

const boots = [].concat(D.boots || []).sort((a,b)=>new Date(a.time)-new Date(b.time));
const items = [].concat(D.items || []);

document.documentElement.lang = L;
document.title = t("title");
document.querySelectorAll("[data-i18n]").forEach(e=>{ e.textContent = t(e.dataset.i18n); });
$("tabs").setAttribute("aria-label", t("tabsAria"));
$("sub").textContent = t("subtitle", D.computer, D.days, new Date(D.generated).toLocaleString(LOC));

/* ---- Verdict + stats ---- */
(function(){
  if(!boots.length){ $("verdict").innerHTML = "<p>"+t("noBoot")+"</p>"; return; }
  const last = boots.slice(-10);
  const aMain = avg(last.map(b=>b.main)), aPost = avg(last.map(b=>b.post));
  const aDrv = avg(last.map(b=>b.driver)), aDev = avg(last.map(b=>b.devices));
  const aSvc = avg(last.map(b=>b.services)), aProf = avg(last.map(b=>b.profile));
  const lines = [];
  lines.push("<p>"+t("vLast", sec(avg(last.map(b=>b.boot))), sec(aMain), sec(aPost))+"</p>");
  if(aPost > aMain) lines.push("<p>"+t("vPost")+"</p>");
  else if(aProf > 15000) lines.push("<p>"+t("vProf", sec(aProf))+"</p>");
  else if(aDrv > 10000 || aDev > 10000) lines.push("<p>"+t("vDrv", sec(aDrv), sec(aDev))+"</p>");
  else if(aSvc > 15000) lines.push("<p>"+t("vSvc", sec(aSvc))+"</p>");
  else lines.push("<p>"+t("vElse")+"</p>");
  $("verdict").innerHTML = lines.join("");

  const errs = boots.filter(b=>b.level==="Error").length, warns = boots.filter(b=>b.level==="Warning").length;
  const worst = boots.reduce((m,b)=>b.boot>m.boot?b:m, boots[0]);
  $("stats").innerHTML = [
    [boots.length, t("sBoots")],
    [sec(avg(boots.map(b=>b.boot))), t("sAvg")],
    [sec(worst.boot), t("sWorst", fmtDate(worst.time))],
    [errs+" / "+warns, t("sErrWarn")]
  ].map(s=>`<div class="stat"><b>${esc(s[0])}</b><span>${esc(s[1])}</span></div>`).join("");
})();

/* ---- Battery & laptop health ---- */
const H = D.health || {};
const dotHtml = s => `<span class="dot ${s}" aria-hidden="true"></span>${t({ok:"lvOk",warn:"lvWarn",bad:"lvBad"}[s])}`;
const bsLabel = c => (c in {1:1,2:1,3:1,4:1,5:1,6:1,11:1}) ? t("bs"+c) : (c>=7&&c<=9) ? t("bs6") : t("bsCode", c);

(function(){
  const b = H.battery, box = $("battery");
  if(!b){ box.innerHTML = '<div class="empty">'+t("noBattery")+'</div>'; return; }
  const pct = num(b.percent);
  const st = pct==null ? "warn" : pct>=80 ? "ok" : pct>=60 ? "warn" : "bad";
  const msg = pct==null ? t("bMsgNone") : pct>=80 ? t("bMsgOk") : pct>=60 ? t("bMsgWarn") : t("bMsgBad");
  const C = 2*Math.PI*52, arc = (pct==null?0:Math.min(pct,100))/100*C;
  const ring = `<svg viewBox="0 0 140 140" width="140" height="140" role="img" aria-label="${esc(t("ringAria", pct==null?t("unknown"):pct+"%"))}">
    <circle class="ring-bg" cx="70" cy="70" r="52"/>
    <circle class="ring-fg ${st}" cx="70" cy="70" r="52" stroke-dasharray="${arc} ${C}"/>
    <text class="ring-num" x="70" y="76">${pct==null?"?":Math.round(pct)+"%"}</text>
    <text class="ring-lbl" x="70" y="96">${esc(t("ringLbl"))}</text></svg>`;
  const rows = [];
  if(b.design>0) rows.push([t("kDesign"), b.design.toLocaleString(LOC)+" mWh"]);
  if(b.full>0)   rows.push([t("kFull"), b.full.toLocaleString(LOC)+" mWh"]);
  if(b.cycles>0) rows.push([t("kCycles"), b.cycles]);
  if(b.charge!=null) rows.push([t("kCharge"), b.charge+"%"]);
  if(b.status!=null) rows.push([t("kStatus"), bsLabel(Number(b.status))]);
  if(b.maker) rows.push([t("kMaker"), b.maker]);
  if(b.chemistry) rows.push([t("kChem"), b.chemistry]);
  box.innerHTML = `<div class="hwrap">${ring}<div><p style="margin:0 0 10px"><b>${dotHtml(st)}</b> · ${esc(msg)}</p>
    <dl class="kv">${rows.map(r=>`<dt>${esc(r[0])}</dt><dd>${esc(r[1])}</dd>`).join("")}</dl></div></div>`;
})();

(function(){
  const checks = [];
  const add = (name, value, s, note) => checks.push({name, value, s, note});
  const pw = H.power;
  if(pw) add(t("ckPower"), t(pw==="battery"?"pwBattery":pw==="ac-desktop"?"pwDesktop":"pwAc"), "ok", "");
  const b = H.battery;
  if(b && b.percent!=null) add(t("ckBattery"), t("ckBatteryVal", b.percent), b.percent>=80?"ok":b.percent>=60?"warn":"bad", "");
  if(b && b.cycles>0) add(t("ckCycles"), t("ckCyclesVal", b.cycles), b.cycles>=1000?"bad":b.cycles>=500?"warn":"ok", t("ckCyclesNote"));

  [].concat(H.disks||[]).forEach(d=>{
    const parts = [d.health||t("unknown"), `${d.media||""} ${d.sizeGB} GB`.trim()];
    if(d.wear!=null) parts.push(t("dWear", d.wear));
    if(d.temp!=null && d.temp>0) parts.push(d.temp+"°C");
    if(d.hours!=null) parts.push(t("dHours", Number(d.hours).toLocaleString(LOC)));
    let s = "ok", note = "";
    if(d.health && d.health!=="Healthy"){ s="bad"; note=t("dBadNote"); }
    else if(d.wear!=null && d.wear>=80){ s="bad"; note=t("dWearNote"); }
    else if((d.wear!=null && d.wear>=50) || d.readErr>0 || d.writeErr>0 || (d.temp!=null && d.temp>=70)){
      s="warn"; note = (d.readErr>0||d.writeErr>0) ? t("dErrNote", d.readErr||0, d.writeErr||0) : t("dWatchNote");
    }
    add(t("ckDisk", d.name||"?"), parts.join(" · "), s, note);
  });

  [].concat(H.volumes||[]).forEach(v=>{
    const free = v.sizeGB>0 ? v.freeGB/v.sizeGB*100 : 100;
    add(t("ckVol", v.letter, v.label?" ("+v.label+")":""), t("ckVolVal", v.freeGB, v.sizeGB, free.toFixed(0)), free<10?"bad":free<20?"warn":"ok", free<20?t("ckVolNote"):"");
  });

  const S = H.system;
  if(S){
    const used = S.ramTotalGB>0 ? (1-S.ramFreeGB/S.ramTotalGB)*100 : 0;
    add(t("ckRam"), t("ckRamVal", S.ramTotalGB, used.toFixed(0), S.ramSpeed?" · "+S.ramSpeed+" MHz":""), used>=90?"warn":"ok", used>=90?t("ckRamNote"):"");
    const days = (new Date(D.generated)-new Date(S.lastBoot))/86400000;
    add(t("ckUp"), t("ckUpVal", days.toFixed(1)), days>14?"warn":"ok", days>14?t("ckUpNote"):"");
  }

  const E = H.events || {};
  const ev = (nameKey, n, warnAt, badAt) => add(t(nameKey), t("evVal", n), n>=badAt?"bad":n>=warnAt?"warn":"ok", n>0?t(nameKey+"Note"):"");
  ev("evShut", E.unexpectedShutdown||0, 1, 3);
  ev("evDisk", E.diskErrors||0, 1, 5);
  ev("evWhea", E.hardwareErrors||0, 1, 5);
  ev("evBsod", E.bugchecks||0, 1, 3);

  const cnt = {ok:0,warn:0,bad:0}; checks.forEach(c=>cnt[c.s]++);
  const head = `<p style="margin:0 0 10px">${t("summary", cnt.ok, cnt.warn, cnt.bad)}</p>`;
  $("checks").innerHTML = head + `<table><thead><tr><th>${t("hdrItem")}</th><th>${t("hdrValue")}</th><th>${t("hdrRating")}</th></tr></thead><tbody>` +
    checks.map(c=>`<tr><td class="name">${esc(c.name)}</td><td class="name">${esc(c.value)}${c.note?`<span class="note">${esc(c.note)}</span>`:""}</td><td>${dotHtml(c.s)}</td></tr>`).join("") + `</tbody></table>`;
  if(S) $("sysinfo").textContent = t("sysinfo", S.model, S.cpu, S.cores, S.threads, S.os, S.osVersion, S.bios);
})();

/* ---- Chart ---- */
(function(){
  if(!boots.length){ $("chart").innerHTML = '<div class="empty">'+t("noData")+'</div>'; return; }
  const W=1000,H2=260,Lm=48,R=10,T=10,B=28;
  const max = Math.max(...boots.map(b=>b.boot))*1.1 || 1;
  const bw = (W-Lm-R)/boots.length;
  let g = "";
  for(let i=0;i<=4;i++){
    const v = max*i/4, y = H2-B-(H2-B-T)*i/4;
    g += `<line x1="${Lm}" x2="${W-R}" y1="${y}" y2="${y}" stroke="var(--line)"/><text x="${Lm-6}" y="${y+4}" text-anchor="end" font-size="11" fill="var(--muted)">${Math.round(v/1000)}s</text>`;
  }
  boots.forEach((b,i)=>{
    const h = (H2-B-T)*b.boot/max, x = Lm+i*bw+bw*0.15, w = Math.max(bw*0.7,1.5);
    const c = b.level==="Error"?"var(--bad)":b.level==="Warning"?"var(--warn)":"var(--ok)";
    g += `<rect x="${x}" y="${H2-B-h}" width="${w}" height="${h}" fill="${c}" rx="1.5"><title>${fmtDate(b.time)} · ${sec(b.boot)} (${b.level})</title></rect>`;
  });
  const step = Math.ceil(boots.length/8);
  boots.forEach((b,i)=>{ if(i%step===0) g += `<text x="${Lm+i*bw+bw/2}" y="${H2-8}" font-size="11" text-anchor="middle" fill="var(--muted)">${new Date(b.time).toLocaleDateString(LOC,{day:"2-digit",month:"2-digit"})}</text>`; });
  $("chart").innerHTML = `<svg viewBox="0 0 ${W} ${H2}" role="img" aria-label="${esc(t("hChart"))}">${g}</svg>`;
})();

/* ---- Offenders ---- */
const groups = [
  {key:"app",     label:"gApp",     ids:[101]},
  {key:"driver",  label:"gDriver",  ids:[102]},
  {key:"service", label:"gService", ids:[103]},
  {key:"other",   label:"gOther",   ids:[106,109]}
];
function renderOff(g){
  const rows = {};
  items.filter(i=>g.ids.includes(i.id)).forEach(i=>{
    const r = rows[i.name] || (rows[i.name] = {name:i.name, company:i.company, n:0, tot:0, max:0, deg:0});
    r.n++; r.tot += i.total; r.deg += i.deg; r.max = Math.max(r.max, i.total);
  });
  const list = Object.values(rows).map(r=>({...r, avg:r.tot/r.n, avgDeg:r.deg/r.n})).sort((a,b)=>b.avg-a.avg).slice(0,15);
  if(!list.length){ $("offenders").innerHTML = '<div class="empty">'+t("noGroup")+'</div>'; return; }
  const top = list[0].avg || 1;
  $("offenders").innerHTML = `<table><thead><tr><th>${t("cName")}</th><th class="num">${t("cCount")}</th><th>${t("cAvg")}</th><th class="num">${t("cMax")}</th><th class="num">${t("cExtra")}</th></tr></thead><tbody>` +
    list.map(r=>`<tr><td class="name">${esc(r.name)}${r.company?`<br><span style="color:var(--muted);font-size:12px">${esc(r.company)}</span>`:""}</td><td class="num">${r.n}</td><td><span class="meter" style="width:${Math.max(2,r.avg/top*140)}px"></span>${sec(r.avg)}</td><td class="num">${sec(r.max)}</td><td class="num">${sec(r.avgDeg)}</td></tr>`).join("") +
    `</tbody></table>`;
}
(function(){
  let cur = groups.find(g=>items.some(i=>g.ids.includes(i.id))) || groups[0];
  const tabs = $("tabs");
  function draw(){
    tabs.innerHTML = groups.map(g=>{
      const n = items.filter(i=>g.ids.includes(i.id)).length;
      return `<button data-k="${g.key}" aria-pressed="${g===cur}">${esc(t(g.label))} (${n})</button>`;
    }).join("");
    tabs.querySelectorAll("button").forEach(b=>b.onclick=()=>{ cur = groups.find(g=>g.key===b.dataset.k); draw(); });
    renderOff(cur);
  }
  draw();
})();

/* ---- Boot table ---- */
(function(){
  if(!boots.length){ $("bootTable").innerHTML = '<div class="empty">'+t("noData")+'</div>'; return; }
  const rows = boots.slice(-30).reverse();
  $("bootTable").innerHTML = `<table><thead><tr><th>${t("cTime")}</th><th class="num">${t("cTotal")}</th><th class="num">${t("cMain")}</th><th class="num">${t("cPost")}</th><th class="num">${t("cKernel")}</th><th class="num">${t("cDriver")}</th><th class="num">${t("cDevices")}</th><th class="num">${t("cProfile")}</th><th>${t("cLevel")}</th></tr></thead><tbody>` +
    rows.map(b=>`<tr><td>${fmtDate(b.time)}</td><td class="num">${sec(b.boot)}</td><td class="num">${sec(b.main)}</td><td class="num">${sec(b.post)}</td><td class="num">${sec(b.kernel)}</td><td class="num">${sec(b.driver)}</td><td class="num">${sec(b.devices)}</td><td class="num">${sec(b.profile)}</td><td><span class="tag ${esc(b.level)}">${esc(b.level)}</span></td></tr>`).join("") +
    `</tbody></table>`;
})();
</script>
</body>
</html>
'@

$html = $html.Replace('__DATA__', $json)
[System.IO.File]::WriteAllText($Out, $html, (New-Object System.Text.UTF8Encoding($true)))

Write-Host "$($M.done): $Out" -ForegroundColor Green
if (-not $NoOpen) { Start-Process $Out }
if ($Elevated) { Read-Host $M.enter | Out-Null }
