#!/bin/sh
# BootReport.sh - Bao cao suc khoe he thong cho Linux (VPS / server / desktop), macOS va Android (Termux)
#
# Cach dung / Usage:
#     curl -fsSL https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.sh | sh
#     curl -fsSL https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.sh | sh -s -- --lang vi --days 14
#     sh BootReport.sh --out /root/report.html
#
# Script chi doc du lieu (read-only): khong cai them goi, khong goi mang, khong sua he thong.
# Tren Linux nen chay bang root (sudo) de co du SMART, journal va firewall.
#
# POSIX sh + awk only: must run unchanged on dash, busybox ash, bash 3.2 (macOS) and Termux.
# shellcheck shell=sh disable=SC2059,SC2209

# Run the whole program inside one brace group, so sh reads through the matching "}" after the final
# main call before it executes anything: a truncated "curl | sh" download is then an incomplete
# command that runs nothing at all. This "{" is paired with the "}" at the very end of the script.
{

# Force a byte-wise, period-radix C locale for every awk / sort / tr in this run, so a comma-radix
# system locale can never turn "1.5" into "1,5" and corrupt the numbers in the report. UTF-8 text
# (incl. Vietnamese) still passes through byte-for-byte and renders fine in the terminal and HTML.
LC_ALL=C
export LC_ALL

BR_LANG=auto
BR_DAYS=30
BR_OUT=
BR_OPEN=1
BR_HTML=1
BR_JSON=0
BR_COLOR=auto
BR_QUICK=0
BR_NET=0
BR_EXITCODE=0
BR_PLATFORM=
BR_OS_LABEL=
BR_HOST=
BR_ROOT=0
BR_TMP=
BR_MODEL=
BR_NOW=0
BR_TIMEOUT_MODE=
# Test hook: prefix for /proc, /sys, /etc and /var reads (empty in normal use)
BR_FSROOT=${BOOTREPORT_FSROOT:-}

TAB=$(printf '\t')
CR=$(printf '\r')
ESC=$(printf '\033')
NL='
'

usage() {
    cat <<'BOOTREPORT_USAGE'
BootReport.sh - system health report for Linux, macOS and Android (Termux)

Usage: sh BootReport.sh [options]
       curl -fsSL <url>/BootReport.sh | sh -s -- [options]

  --lang auto|vi|en   Report language (default: auto, from the system locale)
  --days N            Look-back window for logs and crashes, 1-365 (default: 30)
  --out FILE          Where to write the HTML report
  --no-html           Terminal summary only, do not write the HTML report
  --no-open           Do not open the report when finished
  --net               Opt-in network test (latency, and download speed if curl/wget
                      is present). OFF by default; this is the only thing that uses
                      the network, and it contacts a public speed-test endpoint.
  --json              Print the report data as JSON on stdout instead of the summary
  --quick             Skip the slower checks (package updates, SMART, long log scans)
  --no-color          Plain terminal output
  --exit-code         Exit 1 if something needs watching, 2 if a problem was found
  -h, --help          Show this help
BOOTREPORT_USAGE
}

die() { printf 'BootReport: %s\n' "$1" >&2; exit "${2:-1}"; }

# Progress messages go to stderr so stdout stays clean for --json and pipes.
say() { printf '%s\n' "$1" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

is_int() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

# ---------- Ngon ngu / Language ----------
# t EN VI                    -> the text for the active language
# tf EN_FMT VI_FMT ARGS...   -> printf with the format of the active language
#                               (same argument order in both; a format must not start with "-")
t() { if [ "$BR_LANG" = vi ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
tf() {
    _tf_en=$1
    _tf_vi=$2
    shift 2
    if [ "$BR_LANG" = vi ]; then printf "$_tf_vi" "$@"; else printf "$_tf_en" "$@"; fi
}

# ---------- So hoc / Numbers (awk keeps large values and decimals safe) ----------
# pct PART TOTAL -> rounded integer percentage, 0 when TOTAL is 0
pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b + 0 > 0) printf "%d", a * 100 / b + 0.5; else printf "0" }'; }

# div A B [DECIMALS] -> A / B with DECIMALS digits (default 1), 0 when B is 0
div() { awk -v a="$1" -v b="$2" -v d="${3:-1}" 'BEGIN { if (b + 0 == 0) { printf "0"; exit } printf "%." d "f", a / b }'; }

# num_ge A B -> true when A >= B (decimals allowed)
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

# human_kb KIBIBYTES -> "512 MB" / "7.8 GB" / "1.8 TB"
human_kb() {
    awk -v k="$1" 'BEGIN {
        k += 0
        if (k >= 1073741824) printf "%.1f TB", k / 1073741824
        else if (k >= 1048576) printf "%.1f GB", k / 1048576
        else printf "%.0f MB", k / 1024
    }'
}

# fmt_ms MILLISECONDS -> "850 ms" / "12.3 s" / "2 min 5 s"
fmt_ms() {
    awk -v m="$1" 'BEGIN {
        m += 0
        if (m < 1000) printf "%d ms", m
        else if (m < 120000) printf "%.1f s", m / 1000
        else printf "%d min %d s", int(m / 60000), int((m % 60000) / 1000)
    }'
}

# grade VALUE WARN_AT BAD_AT     -> ok|warn|bad, higher is worse (integers)
# grade_low VALUE WARN_AT BAD_AT -> ok|warn|bad, lower is worse (integers)
grade() {
    if [ "$1" -ge "$3" ]; then printf bad; elif [ "$1" -ge "$2" ]; then printf warn; else printf ok; fi
}
grade_low() {
    if [ "$1" -lt "$3" ]; then printf bad; elif [ "$1" -lt "$2" ]; then printf warn; else printf ok; fi
}

# fmt_epoch EPOCH FORMAT -> local time text (GNU / busybox / toybox use -d @N, BSD uses -r N)
fmt_epoch() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }

# read_file PATH -> first line of a readable file, empty otherwise
read_file() {
    _rf=
    if [ -r "$1" ]; then IFS= read -r _rf <"$1" 2>/dev/null || :; fi
    printf '%s' "$_rf"
}

# ---------- Gioi han thoi gian / Timeouts ----------
# run_to SECONDS CMD [ARGS...] -> runs CMD, giving up after SECONDS (stderr is discarded).
# Nothing here may hang: a missing companion app or a cold package cache must not stall the report.
init_timeout() {
    BR_TIMEOUT_MODE=sh
    if have timeout; then
        if timeout 2 true >/dev/null 2>&1; then
            BR_TIMEOUT_MODE=new
        elif timeout -t 2 true >/dev/null 2>&1; then
            BR_TIMEOUT_MODE=old
        fi
    fi
}
run_to() {
    _rt_secs=$1
    shift
    case "$BR_TIMEOUT_MODE" in
        new) timeout "$_rt_secs" "$@" 2>/dev/null ;;
        old) timeout -t "$_rt_secs" "$@" 2>/dev/null ;;
        *)
            # No timeout(1), e.g. macOS: run in the background and let a watchdog kill it.
            # The watchdog writes nowhere, so a surrounding $(...) never waits for its sleep.
            "$@" 2>/dev/null &
            _rt_pid=$!
            (
                sleep "$_rt_secs"
                kill "$_rt_pid" 2>/dev/null
            ) >/dev/null 2>&1 &
            _rt_dog=$!
            wait "$_rt_pid" 2>/dev/null
            _rt_rc=$?
            kill "$_rt_dog" 2>/dev/null
            wait "$_rt_dog" 2>/dev/null
            return "$_rt_rc"
            ;;
    esac
}

# ---------- Mo hinh bao cao / Report model ----------
# Every record is one tab-separated line in $BR_MODEL; awk turns it into the terminal
# summary and the JSON inside the HTML report. Values are flattened to a single line.
sanitize() {
    _s=$1
    case "$_s" in
        *"$TAB"* | *"$NL"* | *"$CR"* | *"$ESC"*) _s=$(printf '%s' "$_s" | LC_ALL=C tr '\t\r\n\033' '    ') ;;
    esac
}

meta() {
    sanitize "$2"
    printf 'M\t%s\t%s\n' "$1" "$_s" >>"$BR_MODEL"
}
ui() {
    sanitize "$2"
    printf 'U\t%s\t%s\n' "$1" "$_s" >>"$BR_MODEL"
}
group() { printf 'G\t%s\t%s\n' "$1" "$2" >>"$BR_MODEL"; }

# add_info LABEL VALUE -> a row in "System information" (skipped when VALUE is empty)
add_info() {
    [ -n "$2" ] || return 0
    sanitize "$2"
    printf 'I\t%s\t%s\n' "$1" "$_s" >>"$BR_MODEL"
}

# add_stat VALUE LABEL -> a headline tile (keep it to four or so)
add_stat() {
    [ -n "$1" ] || return 0
    sanitize "$1"
    printf 'S\t%s\t%s\n' "$_s" "$2" >>"$BR_MODEL"
}

# add_verdict TEXT -> an extra remark under the headline
add_verdict() {
    [ -n "$1" ] || return 0
    sanitize "$1"
    printf 'V\t%s\n' "$_s" >>"$BR_MODEL"
}

# add_check GROUP NAME VALUE STATUS [NOTE]
#   GROUP  boot cpu memory storage battery hardware services crashes updates security network apps
#   STATUS ok | warn | bad | info     NOTE = one short sentence of advice, shown under the value
add_check() {
    _ac_status=$4
    case "$_ac_status" in ok | warn | bad | info) ;; *) _ac_status=info ;; esac
    sanitize "$2"
    _ac_name=$_s
    sanitize "$3"
    _ac_value=$_s
    sanitize "${5:-}"
    printf 'C\t%s\t%s\t%s\t%s\t%s\n' "$1" "$_ac_status" "$_ac_name" "$_ac_value" "$_s" >>"$BR_MODEL"
}

# bat_set KEY VALUE -> battery panel: ring (0-100 shown in the ring), ringlabel, status, message
# bat_row LABEL VALUE -> a detail row next to the ring (skipped when VALUE is empty)
bat_set() {
    sanitize "$2"
    printf 'B\t%s\t%s\n' "$1" "$_s" >>"$BR_MODEL"
}
bat_row() {
    [ -n "$2" ] || return 0
    sanitize "$2"
    printf 'B\trow\t%s\t%s\n' "$1" "$_s" >>"$BR_MODEL"
}

# boot_seg LABEL MILLISECONDS -> one phase of the boot bar, in order (at most five)
boot_seg() {
    is_int "$2" || return 0
    [ "$2" -gt 0 ] || return 0
    printf 'P\t%s\t%s\n' "$1" "$2" >>"$BR_MODEL"
}

# table_new ID TITLE COLUMNS [NOTE] -> a detail table; COLUMNS is "Name|#Count|~Time|%Share":
#   a "#" prefix right-aligns, "~" takes raw milliseconds, "%" takes a bare percentage number
# table_row ID CELL... -> one row; a table without rows is not shown
table_new() {
    sanitize "${4:-}"
    printf 'T\t%s\t%s\t%s\t%s\n' "$1" "$2" "$_s" "$3" >>"$BR_MODEL"
}
table_row() {
    _tr_line="R$TAB$1"
    shift
    for _tr_cell in "$@"; do
        sanitize "$_tr_cell"
        _tr_line="$_tr_line$TAB$_s"
    done
    printf '%s\n' "$_tr_line" >>"$BR_MODEL"
}

# ---------- Kiem tra mang (tuy chon) / Network test (opt-in, --net only) ----------
# This is the ONLY part of BootReport that uses the network, and it runs only with --net.
# It measures the machine's OWN connection: ICMP latency/loss to public anycast resolvers and,
# when curl or wget is present, download throughput from a public speed-test endpoint.
# It never scans, probes or connects to any host the user did not implicitly choose here.
# Everything is read-only and bounded by run_to so it can never hang the report.

# nt_ping HOST -> prints "AVG_MS LOSS_PCT" (either may be empty), parsed portably across
# iputils, busybox, toybox and BSD ping. HOST is a fixed public IP, so no name lookup is needed.
nt_ping() {
    run_to 8 ping -c 3 "$1" 2>/dev/null | LC_ALL=C awk '
        /packet loss/ {
            for (i = 1; i <= NF; i++) if ($i ~ /%$/) { loss = $i; sub(/%.*/, "", loss) }
        }
        /min\/avg\/max/ {
            eq = index($0, "=")
            if (eq > 0) { n = split(substr($0, eq + 1), a, "/"); if (n >= 2) { avg = a[2]; sub(/^[ \t]+/, "", avg) } }
        }
        END { printf "%s %s", (avg == "" ? "" : avg + 0), (loss == "" ? "" : loss + 0) }
    '
}

nt_latency() {
    _nt_host=1.1.1.1
    _nt_res=$(nt_ping "$_nt_host")
    if [ -z "$_nt_res" ] || [ "$_nt_res" = " " ]; then
        _nt_host=8.8.8.8
        _nt_res=$(nt_ping "$_nt_host")
    fi
    _nt_avg=${_nt_res% *}
    _nt_loss=${_nt_res#* }
    if [ -z "$_nt_avg" ] && [ -z "$_nt_loss" ]; then
        add_check network "$(t 'Network latency' 'Độ trễ mạng')" \
            "$(t 'could not reach a test host (ICMP may be blocked)' 'không ping được host kiểm tra (ICMP có thể bị chặn)')" info
        return 0
    fi

    if [ -n "$_nt_avg" ]; then
        # Anycast resolvers answer in a few ms in-region; grade gently so distant regions do not false-alarm.
        _nt_ms=$(awk -v v="$_nt_avg" 'BEGIN { printf "%d", v + 0.5 }')
        _nt_st=$(grade "$_nt_ms" 120 300)
        add_check network "$(t 'Network latency' 'Độ trễ mạng')" \
            "$(tf '%s ms to %s' '%s ms tới %s' "$(div "$_nt_avg" 1 1)" "$_nt_host")" "$_nt_st" \
            "$([ "$_nt_st" != ok ] && t 'High round-trip time; the link may be congested or far from the test host.' 'Độ trễ cao; đường truyền có thể đang nghẽn hoặc ở xa host kiểm tra.')"
        add_stat "$(div "$_nt_avg" 1 1) ms" "$(t 'latency' 'độ trễ')"
    fi

    if [ -n "$_nt_loss" ]; then
        if num_ge "$_nt_loss" 20; then _nt_lst=bad
        elif num_ge "$_nt_loss" 0.1; then _nt_lst=warn
        else _nt_lst=ok; fi
        add_check network "$(t 'Packet loss' 'Mất gói tin')" \
            "$(printf '%s%%' "$(div "$_nt_loss" 1 0)")" "$_nt_lst" \
            "$([ "$_nt_lst" != ok ] && t 'Packets are being dropped; expect unstable connections.' 'Đang mất gói tin; kết nối có thể chập chờn.')"
    fi
}

nt_throughput() {
    _nt_url='https://speed.cloudflare.com/__down?bytes=10000000'
    _nt_out=
    if have curl; then
        # speed_download is bytes/sec; time_namelookup and time_total are seconds.
        _nt_out=$(run_to 25 curl -fsS --max-time 20 -o /dev/null \
            -w '%{speed_download} %{time_namelookup} %{time_total}' "$_nt_url")
    elif have wget; then
        # wget cannot report the rate cleanly; time the transfer ourselves for a rough number.
        _nt_t0=$(date +%s 2>/dev/null)
        if run_to 25 wget -q -O /dev/null "$_nt_url"; then
            _nt_t1=$(date +%s 2>/dev/null)
            if is_int "$_nt_t0" && is_int "$_nt_t1" && [ "$_nt_t1" -gt "$_nt_t0" ]; then
                _nt_out=$(awk -v b=10000000 -v s="$((_nt_t1 - _nt_t0))" 'BEGIN { printf "%d 0 %d", b / s, s }')
            fi
        fi
    else
        add_check network "$(t 'Download speed' 'Tốc độ tải xuống')" \
            "$(t 'skipped (needs curl or wget)' 'bỏ qua (cần curl hoặc wget)')" info
        return 0
    fi

    if [ -z "$_nt_out" ]; then
        add_check network "$(t 'Download speed' 'Tốc độ tải xuống')" \
            "$(t 'the speed test did not complete' 'không hoàn tất được bài đo tốc độ')" info
        return 0
    fi

    # "bytes_per_sec namelookup_s total_s"
    _nt_bps=${_nt_out%% *}
    _nt_rest=${_nt_out#* }
    _nt_dns=${_nt_rest%% *}
    _nt_mbps=$(awk -v b="$_nt_bps" 'BEGIN { printf "%.1f", b * 8 / 1000000 }')
    add_check network "$(t 'Download speed' 'Tốc độ tải xuống')" \
        "$(tf '%s Mbps (downlink)' '%s Mbps (tải xuống)' "$_nt_mbps")" info \
        "$(t 'Measured against speed.cloudflare.com; a rough figure, not an ISP benchmark.' 'Đo qua speed.cloudflare.com; chỉ mang tính tham khảo, không phải chuẩn của nhà mạng.')"
    add_stat "$_nt_mbps Mbps" "$(t 'download' 'tải xuống')"

    _nt_dnsms=$(awk -v s="$_nt_dns" 'BEGIN { printf "%d", s * 1000 + 0.5 }')
    if is_int "$_nt_dnsms" && [ "$_nt_dnsms" -gt 0 ]; then
        add_check network "$(t 'DNS lookup time' 'Thời gian phân giải DNS')" \
            "$(tf '%s ms' '%s ms' "$_nt_dnsms")" "$(grade "$_nt_dnsms" 300 1000)" \
            "$([ "$_nt_dnsms" -ge 300 ] && t 'DNS resolution is slow; a faster resolver may help.' 'Phân giải DNS chậm; cân nhắc dùng DNS nhanh hơn.')"
    fi
}

net_collect() {
    nt_latency
    nt_throughput
}

# ---------- Linux (VPS / server / desktop) ----------
collect_linux() {
    lx_ident
    lx_boot
    lx_cpu
    lx_memory
    lx_storage
    lx_hardware
    lx_services
    lx_crashes
    lx_updates
    lx_security
    lx_network
    lx_limits
    if [ "$BR_ROOT" != 1 ]; then
        add_verdict "$(t 'Not running as root: SMART, some logs and firewall details may be missing. Re-run with sudo for the full picture.' 'Đang chạy không có quyền root: có thể thiếu SMART, một số log và chi tiết firewall. Chạy lại bằng sudo để có báo cáo đầy đủ.')"
    fi
}

# ---------- Linux system collector (hardware / resources half) ----------
# Defines: lx_ident lx_cpu lx_memory lx_storage lx_hardware lx_network lx_limits
# Private helpers are prefixed lxs_. Every /proc,/sys,/etc,/var read goes through
# "$BR_FSROOT" so fixtures work; external commands are never prefixed.

# osr KEY FILE -> value with surrounding quotes stripped (os-release style)
lxs_osr() {
    awk -v k="$1" -v q="'" '
        index($0, k "=") == 1 {
            v = substr($0, length(k) + 2)
            gsub(/"/, "", v)
            if (substr(v, 1, 1) == q) v = substr(v, 2)
            if (length(v) > 0 && substr(v, length(v), 1) == q) v = substr(v, 1, length(v) - 1)
            print v
            exit
        }' "$2" 2>/dev/null
}

# lxs_lc -> lower case a string via awk tolower (portable)
lxs_lc() { printf '%s' "$1" | awk '{ print tolower($0) }'; }

lxs_detect_virt() {
    # Sets LX_VIRT and LX_CONTAINER. Prefer systemd-detect-virt, then manual hints.
    LX_VIRT=none
    LX_CONTAINER=0
    _lxv_c=
    _lxv_v=
    if have systemd-detect-virt; then
        _lxv_c=$(run_to 5 systemd-detect-virt --container 2>/dev/null)
        _lxv_v=$(run_to 5 systemd-detect-virt --vm 2>/dev/null)
    fi
    case "$_lxv_c" in '' | none) ;; *) LX_VIRT=$_lxv_c; LX_CONTAINER=1; return 0 ;; esac
    case "$_lxv_v" in '' | none) ;; *) LX_VIRT=$_lxv_v; return 0 ;; esac

    # Manual container hints (world-readable only).
    if [ -e "$BR_FSROOT/proc/vz" ] && [ ! -e "$BR_FSROOT/proc/bc" ]; then LX_VIRT=openvz; LX_CONTAINER=1; return 0; fi
    if [ -e "$BR_FSROOT/run/.containerenv" ]; then LX_VIRT=podman; LX_CONTAINER=1; return 0; fi
    if [ -e "$BR_FSROOT/.dockerenv" ]; then LX_VIRT=docker; LX_CONTAINER=1; return 0; fi
    _lxv_cm=$(read_file "$BR_FSROOT/run/systemd/container")
    case "$_lxv_cm" in ?*) LX_VIRT=$_lxv_cm; LX_CONTAINER=1; return 0 ;; esac
    _lxv_osr=$(read_file "$BR_FSROOT/proc/sys/kernel/osrelease")
    case "$_lxv_osr" in *icrosoft* | *WSL*) LX_VIRT=wsl; LX_CONTAINER=1; return 0 ;; esac

    # Manual VM hints from DMI, gated by the x86 hypervisor flag where possible.
    _lxv_pn=$(read_file "$BR_FSROOT/sys/class/dmi/id/product_name")
    _lxv_sv=$(read_file "$BR_FSROOT/sys/class/dmi/id/sys_vendor")
    _lxv_hyp=0
    if grep -q '^flags.* hypervisor' "$BR_FSROOT/proc/cpuinfo" 2>/dev/null; then _lxv_hyp=1; fi
    _lxv_dmi=none
    case "$_lxv_sv$_lxv_pn" in
        KVM* | *KVM*) _lxv_dmi=kvm ;;
        *QEMU*) _lxv_dmi=qemu ;;
        VMware* | *VMware*) _lxv_dmi=vmware ;;
        *VirtualBox* | *innotek*) _lxv_dmi=oracle ;;
        *Xen*) _lxv_dmi=xen ;;
        *Bochs*) _lxv_dmi=bochs ;;
        *Parallels*) _lxv_dmi=parallels ;;
        *Amazon*) _lxv_dmi=amazon ;;
        *Google*) _lxv_dmi=google ;;
        Microsoft*Virtual* | *Hyper-V*) _lxv_dmi=microsoft ;;
    esac
    if [ -e "$BR_FSROOT/proc/xen" ]; then _lxv_dmi=xen; fi
    if [ "$_lxv_dmi" != none ]; then
        LX_VIRT=$_lxv_dmi
    elif [ "$_lxv_hyp" = 1 ]; then
        LX_VIRT=unknown
    else
        LX_VIRT=none
    fi
    return 0
}

lxs_ncpu() {
    # Logical CPUs, capped by a cgroup CPU quota when one is set.
    _lxn_c=$(grep -c '^processor' "$BR_FSROOT/proc/cpuinfo" 2>/dev/null)
    is_int "$_lxn_c" && [ "$_lxn_c" -ge 1 ] || _lxn_c=1
    _lxn_q=
    _lxn_max=$(read_file "$BR_FSROOT/sys/fs/cgroup/cpu.max")
    if [ -n "$_lxn_max" ]; then
        _lxn_q=$(printf '%s\n' "$_lxn_max" | awk '$1 != "max" && $2 + 0 > 0 { v = $1 / $2; printf "%d", (v == int(v) ? v : int(v) + 1) }')
    else
        _lxn_qu=$(read_file "$BR_FSROOT/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
        _lxn_pe=$(read_file "$BR_FSROOT/sys/fs/cgroup/cpu/cpu.cfs_period_us")
        if is_int "$_lxn_qu" && is_int "$_lxn_pe" && [ "$_lxn_qu" -gt 0 ] && [ "$_lxn_pe" -gt 0 ]; then
            _lxn_q=$(awk -v q="$_lxn_qu" -v p="$_lxn_pe" 'BEGIN { v = q / p; printf "%d", (v == int(v) ? v : int(v) + 1) }')
        fi
    fi
    if is_int "$_lxn_q" && [ "$_lxn_q" -ge 1 ] && [ "$_lxn_q" -lt "$_lxn_c" ]; then _lxn_c=$_lxn_q; fi
    LX_NCPU=$_lxn_c
}

lx_ident() {
    _lxid_osr="$BR_FSROOT/etc/os-release"
    [ -r "$_lxid_osr" ] || _lxid_osr="$BR_FSROOT/usr/lib/os-release"
    LX_ID=$(lxs_lc "$(lxs_osr ID "$_lxid_osr")")
    LX_ID_LIKE=$(lxs_lc "$(lxs_osr ID_LIKE "$_lxid_osr")")
    LX_VERSION_ID=$(lxs_osr VERSION_ID "$_lxid_osr")
    LX_PRETTY=$(lxs_osr PRETTY_NAME "$_lxid_osr")
    _lxid_name=$(lxs_osr NAME "$_lxid_osr")

    if [ -z "$LX_ID" ]; then
        # EL6 and other pre-os-release systems: parse a release file.
        for _lxid_f in oracle-release centos-release redhat-release system-release; do
            [ -r "$BR_FSROOT/etc/$_lxid_f" ] || continue
            LX_PRETTY=$(read_file "$BR_FSROOT/etc/$_lxid_f")
            LX_VERSION_ID=$(printf '%s\n' "$LX_PRETTY" | awk '{ v = $0; sub(/^.*release /, "", v); sub(/ .*$/, "", v); print v }')
            case "$LX_PRETTY" in
                Oracle*) LX_ID=ol ;;
                CentOS*) LX_ID=centos ;;
                Red\ Hat*) LX_ID=rhel ;;
                Amazon*) LX_ID=amzn ;;
                Alma*) LX_ID=almalinux ;;
                Rocky*) LX_ID=rocky ;;
            esac
            _lxid_name=$LX_PRETTY
            break
        done
    fi
    [ -n "$LX_PRETTY" ] || LX_PRETTY="$(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"
    LX_NAME=$_lxid_name

    case " $LX_ID $LX_ID_LIKE " in
        *" rhel "* | *" fedora "* | *" centos "* | *" almalinux "* | *" rocky "* | *" ol "* | *" amzn "*) LX_FAMILY=rhel ;;
        *" debian "* | *" ubuntu "*) LX_FAMILY=debian ;;
        *" alpine "*) LX_FAMILY=alpine ;;
        *" arch "*) LX_FAMILY=arch ;;
        *" suse "* | *" opensuse "* | *" sles "*) LX_FAMILY=suse ;;
        *) LX_FAMILY=other ;;
    esac

    lxs_detect_virt

    if [ -d "$BR_FSROOT/run/systemd/system" ]; then LX_INIT=systemd
    elif [ -d "$BR_FSROOT/run/openrc" ] || [ -e "$BR_FSROOT/run/openrc/softlevel" ]; then LX_INIT=openrc
    else LX_INIT=other; fi

    lxs_ncpu

    BR_OS_LABEL=$LX_PRETTY

    # ----- System information rows -----
    add_info "$(t 'Operating system' 'Hệ điều hành')" "$LX_PRETTY"
    add_info "$(t 'Kernel' 'Nhân (kernel)')" "$(uname -r 2>/dev/null)"
    add_info "$(t 'Architecture' 'Kiến trúc')" "$(uname -m 2>/dev/null)"

    # Virtualization label
    if [ "$LX_CONTAINER" = 1 ]; then
        _lxid_virt=$(tf 'container (%s)' 'container (%s)' "$LX_VIRT")
    else
        case "$LX_VIRT" in
            none) _lxid_virt=$(t 'bare metal' 'máy vật lý') ;;
            unknown) _lxid_virt=$(t 'virtual machine (unknown hypervisor)' 'máy ảo (không rõ hypervisor)') ;;
            *) _lxid_virt=$(tf 'virtual machine (%s)' 'máy ảo (%s)' "$LX_VIRT") ;;
        esac
    fi
    add_info "$(t 'Virtualization' 'Ảo hóa')" "$_lxid_virt"

    # Machine model (DMI, physical) or device-tree model (ARM). Not a serial number.
    _lxid_model=
    if [ "$LX_CONTAINER" != 1 ]; then
        _lxid_pn=$(read_file "$BR_FSROOT/sys/class/dmi/id/product_name")
        _lxid_sv=$(read_file "$BR_FSROOT/sys/class/dmi/id/sys_vendor")
        if [ -n "$_lxid_sv$_lxid_pn" ]; then
            _lxid_model=$(printf '%s %s' "$_lxid_sv" "$_lxid_pn" | awk '{ $1 = $1; print }')
        else
            _lxid_model=$(read_file "$BR_FSROOT/proc/device-tree/model" | LC_ALL=C tr -d '\000')
        fi
    fi
    add_info "$(t 'Machine model' 'Kiểu máy')" "$_lxid_model"

    _lxid_cpu=$(awk -F: '
        /^model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }
        /^Model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }
        /^Hardware/   { gsub(/^[ \t]+/, "", $2); h = $2 }
        END { if (h != "") print h }' "$BR_FSROOT/proc/cpuinfo" 2>/dev/null)
    add_info "$(t 'CPU model' 'Bộ xử lý (CPU)')" "$_lxid_cpu"
    add_info "$(t 'Logical CPUs' 'Số CPU logic')" "$LX_NCPU"

    _lxid_memkb=$(awk '/^MemTotal:/ { print $2; exit }' "$BR_FSROOT/proc/meminfo" 2>/dev/null)
    if is_int "$_lxid_memkb"; then add_info "$(t 'Memory (RAM)' 'Bộ nhớ (RAM)')" "$(human_kb "$_lxid_memkb")"; fi
    return 0
}

lx_cpu() {
    # Load average (15-minute) normalised by CPU count, floor 2.
    _lxcpu_l15=$(awk '{ print $3; exit }' "$BR_FSROOT/proc/loadavg" 2>/dev/null)
    if [ -n "$_lxcpu_l15" ]; then
        _lxcpu_n=$(awk -v l="$_lxcpu_l15" -v c="$LX_NCPU" 'BEGIN { if (c < 2) c = 2; printf "%.2f", l / c }')
        if num_ge "$_lxcpu_n" 4.0; then _lxcpu_ls=bad
        elif num_ge "$_lxcpu_n" 2.0; then _lxcpu_ls=warn
        else _lxcpu_ls=ok; fi
        if [ "$LX_CONTAINER" = 1 ] && [ "$_lxcpu_ls" = bad ]; then _lxcpu_ls=warn; fi
        add_stat "$_lxcpu_l15" "$(t 'load (15 min)' 'tải (15 phút)')"
        add_check cpu "$(t 'Load average' 'Tải trung bình')" \
            "$(tf '%s (15-min), %s per CPU on %s CPU(s)' '%s (15 phút), %s mỗi CPU trên %s CPU' "$_lxcpu_l15" "$_lxcpu_n" "$LX_NCPU")" "$_lxcpu_ls" \
            "$([ "$_lxcpu_ls" = warn ] && t 'More work is queued than the CPUs can run; check the top processes and waiting I/O.' 'Số tác vụ chờ nhiều hơn khả năng CPU; xem các tiến trình nặng và I/O đang chờ.'; [ "$_lxcpu_ls" = bad ] && t 'The system has been heavily overloaded for at least 15 minutes; reduce the workload or add CPU.' 'Hệ thống quá tải nặng suốt ít nhất 15 phút; giảm tải hoặc thêm CPU.')"
    fi

    # CPU steal / iowait: one 1-second /proc/stat sample pair. Reuse the sleep to snapshot
    # process tables for lx_limits (top CPU uses the tick delta).
    _lxcpu_a=$(awk '$1 == "cpu" { printf "%.0f %.0f %.0f", $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9, $6, $9; exit }' "$BR_FSROOT/proc/stat" 2>/dev/null)
    lxs_ps_snapshot >"$BR_TMP/lxps_a" 2>/dev/null
    sleep 1
    _lxcpu_b=$(awk '$1 == "cpu" { printf "%.0f %.0f %.0f", $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9, $6, $9; exit }' "$BR_FSROOT/proc/stat" 2>/dev/null)
    lxs_ps_snapshot >"$BR_TMP/lxps_b" 2>/dev/null

    if [ -n "$_lxcpu_a" ] && [ -n "$_lxcpu_b" ]; then
        # prints: steal_boot iowait_boot steal_now iowait_now dt
        _lxcpu_r=$(awk -v a="$_lxcpu_a" -v b="$_lxcpu_b" 'BEGIN {
            if (split(a, x, " ") < 3 || split(b, y, " ") < 3 || y[1] <= 0) { print "na"; exit }
            dt = y[1] - x[1]; ds = y[3] - x[3]; di = y[2] - x[2]
            if (ds < 0) ds = 0; if (di < 0) di = 0
            sn = (dt > 0) ? ds * 100 / dt : -1; inow = (dt > 0) ? di * 100 / dt : -1
            if (sn > 100) sn = 100; if (inow > 100) inow = 100
            printf "%.1f %.1f %.1f %.1f %.0f", y[3] * 100 / y[1], y[2] * 100 / y[1], sn, inow, dt }')
        printf '%s\n' "${_lxcpu_r##* }" >"$BR_TMP/lxcpu_dt"
        if [ "$_lxcpu_r" != na ]; then
            _lxcpu_sb=$(printf '%s' "$_lxcpu_r" | awk '{ print $1 }')
            _lxcpu_ib=$(printf '%s' "$_lxcpu_r" | awk '{ print $2 }')
            _lxcpu_sn=$(printf '%s' "$_lxcpu_r" | awk '{ print $3 }')
            _lxcpu_in=$(printf '%s' "$_lxcpu_r" | awk '{ print $4 }')
            _lxcpu_up=$(awk '{ print int($1); exit }' "$BR_FSROOT/proc/uptime" 2>/dev/null)
            is_int "$_lxcpu_up" || _lxcpu_up=0

            # Steal: only on a VM (named or unknown hypervisor), never bare metal or OS container.
            if [ "$LX_CONTAINER" != 1 ] && [ "$LX_VIRT" != none ]; then
                _lxcpu_st=ok
                if [ "$_lxcpu_up" -lt 3600 ]; then
                    # Too early for a since-boot average: grade the sample only, cap at warn.
                    if num_ge "$_lxcpu_sn" 15; then _lxcpu_st=warn; fi
                else
                    if num_ge "$_lxcpu_sb" 5 || { [ "${_lxcpu_sn%.*}" != -1 ] && num_ge "$_lxcpu_sn" 15; }; then _lxcpu_st=warn; fi
                    if num_ge "$_lxcpu_sb" 15 || { num_ge "$_lxcpu_sn" 30 && num_ge "$_lxcpu_sb" 5; }; then _lxcpu_st=bad; fi
                fi
                _lxcpu_sv="$(div "$_lxcpu_sb" 1 1)%"
                if [ "${_lxcpu_sn%.*}" != -1 ]; then _lxcpu_sv="$(tf 'since boot %s%%, now %s%%' 'từ lúc khởi động %s%%, hiện %s%%' "$(div "$_lxcpu_sb" 1 1)" "$(div "$_lxcpu_sn" 1 1)")"; fi
                add_check cpu "$(t 'CPU steal time' 'Thời gian CPU bị chiếm (steal)')" "$_lxcpu_sv" "$_lxcpu_st" \
                    "$([ "$_lxcpu_st" = warn ] && t 'The hypervisor is withholding CPU time; if it persists, ask the provider or move to a less crowded plan (burstable plans do this when CPU credits run out).' 'Hypervisor đang giữ bớt thời gian CPU; nếu kéo dài, hãy hỏi nhà cung cấp hoặc đổi gói ít chung đụng hơn (gói burstable bị vậy khi hết credit CPU).'; [ "$_lxcpu_st" = bad ] && t 'A large share of CPU time has been taken by the host since boot; contact the provider or migrate the server.' 'Máy chủ vật lý đã lấy phần lớn thời gian CPU từ lúc khởi động; liên hệ nhà cung cấp hoặc chuyển máy.')"
            fi

            # iowait: never bad; skip in OS containers.
            if [ "$LX_CONTAINER" != 1 ]; then
                _lxcpu_iw=ok
                if num_ge "$_lxcpu_ib" 10 || { [ "${_lxcpu_in%.*}" != -1 ] && num_ge "$_lxcpu_in" 40; }; then _lxcpu_iw=warn; fi
                _lxcpu_iv="$(div "$_lxcpu_ib" 1 1)%"
                if [ "${_lxcpu_in%.*}" != -1 ]; then _lxcpu_iv="$(tf 'since boot %s%%, now %s%%' 'từ lúc khởi động %s%%, hiện %s%%' "$(div "$_lxcpu_ib" 1 1)" "$(div "$_lxcpu_in" 1 1)")"; fi
                add_check cpu "$(t 'I/O wait' 'Chờ I/O (iowait)')" "$_lxcpu_iv" "$_lxcpu_iw" \
                    "$([ "$_lxcpu_iw" = warn ] && t 'Processes are waiting on storage; look for a heavy job (backup, database) or a slow or failing disk.' 'Tiến trình đang chờ ổ đĩa; tìm tác vụ nặng (sao lưu, cơ sở dữ liệu) hoặc ổ đĩa chậm/sắp hỏng.')"
            fi
        fi
    fi
    return 0
}

# One process snapshot line per PID: "pid state ticks comm"
lxs_ps_snapshot() {
    awk '{
        pid = $1; c = $0
        sub(/^[0-9]+ \(/, "", c); sub(/\) [A-Za-z] .*$/, "", c)
        r = $0; sub(/^.*\) /, "", r); n = split(r, f, " ")
        if (n >= 13) print pid, f[1], f[12] + f[13], c
    }' "$BR_FSROOT"/proc/[0-9]*/stat 2>/dev/null
}

lx_memory() {
    # total avail swap_total swap_free  (KiB); available uses MemAvailable or the fallback.
    _lxmem_r=$(awk '
        /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2; h = 1 } /^MemFree:/ { f = $2 }
        /^Buffers:/ { b = $2 } /^Cached:/ { c = $2 } /^SReclaimable:/ { s = $2 } /^Shmem:/ { m = $2 }
        /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
        END {
            if (!h) a = f + b + c + s - m
            if (a < 0) a = 0; if (t > 0 && a > t) a = t
            printf "%.0f %.0f %.0f %.0f %s", t, a, st, sf, (h ? "kernel" : "estimated")
        }' "$BR_FSROOT/proc/meminfo" 2>/dev/null)
    [ -n "$_lxmem_r" ] || return 0
    _lxmem_t=$(printf '%s' "$_lxmem_r" | awk '{ print $1 }')
    _lxmem_a=$(printf '%s' "$_lxmem_r" | awk '{ print $2 }')
    _lxmem_st=$(printf '%s' "$_lxmem_r" | awk '{ print $3 }')
    _lxmem_sf=$(printf '%s' "$_lxmem_r" | awk '{ print $4 }')
    is_int "$_lxmem_t" && [ "$_lxmem_t" -gt 0 ] || return 0

    # Container cgroup-v2 memory limit overrides a host /proc/meminfo view.
    _lxmem_src=RAM
    if [ "$LX_CONTAINER" = 1 ]; then
        _lxmem_max=$(read_file "$BR_FSROOT/sys/fs/cgroup/memory.max")
        _lxmem_cur=$(read_file "$BR_FSROOT/sys/fs/cgroup/memory.current")
        if is_int "$_lxmem_max" && is_int "$_lxmem_cur"; then
            _lxmem_tk=$(awk -v b="$_lxmem_max" 'BEGIN { printf "%.0f", b / 1024 }')
            if [ "$_lxmem_tk" -lt "$_lxmem_t" ]; then
                _lxmem_ia=$(awk '/^inactive_file / { print $2; exit }' "$BR_FSROOT/sys/fs/cgroup/memory.stat" 2>/dev/null)
                is_int "$_lxmem_ia" || _lxmem_ia=0
                _lxmem_t=$_lxmem_tk
                _lxmem_a=$(awk -v mx="$_lxmem_max" -v cur="$_lxmem_cur" -v inf="$_lxmem_ia" 'BEGIN { v = (mx - cur + inf) / 1024; if (v < 0) v = 0; printf "%.0f", v }')
                _lxmem_src="cgroup"
            fi
        fi
    fi

    _lxmem_pct=$(awk -v t="$_lxmem_t" -v a="$_lxmem_a" 'BEGIN { printf "%d", 100 - a * 100 / t + 0.5 }')
    _lxmem_ms=$(awk -v t="$_lxmem_t" -v a="$_lxmem_a" 'BEGIN { g = 1048576
        u = 100 - a * 100 / t; s = "ok"
        if (u >= 90) s = "warn"; if (u >= 97) s = "bad"
        if (s == "bad" && a >= g) s = "warn"
        if (a >= 4 * g) s = "ok"
        print s }')
    add_stat "$_lxmem_pct%" "$(t 'RAM used' 'RAM đã dùng')"
    add_check memory "$(t 'Memory used' 'Bộ nhớ đã dùng')" \
        "$(tf '%s%% used, %s of %s available' '%s%% đã dùng, còn %s trong %s' "$_lxmem_pct" "$(human_kb "$_lxmem_a")" "$(human_kb "$_lxmem_t")")" "$_lxmem_ms" \
        "$([ "$_lxmem_ms" = warn ] && t 'Less than 10% of RAM is available; review the largest processes or add memory.' 'Còn dưới 10% RAM; xem các tiến trình lớn nhất hoặc thêm bộ nhớ.'; [ "$_lxmem_ms" = bad ] && t 'RAM is almost exhausted and the kernel may start killing processes; free memory or add RAM or swap now.' 'RAM gần cạn, nhân có thể bắt đầu giết tiến trình; giải phóng bộ nhớ hoặc thêm RAM/swap ngay.')"

    # Swap. Detect zram-only swap from /proc/swaps.
    if is_int "$_lxmem_st" && [ "$_lxmem_st" -gt 0 ]; then
        _lxmem_zr=$(awk 'NR > 1 { tot++; if ($1 ~ /^\/dev\/zram/) z++ } END { print (tot > 0 && tot == z) ? 1 : 0 }' "$BR_FSROOT/proc/swaps" 2>/dev/null)
        is_int "$_lxmem_zr" || _lxmem_zr=0
        _lxmem_sp=$(awk -v st="$_lxmem_st" -v sf="$_lxmem_sf" 'BEGIN { printf "%d", (st - sf) * 100 / st + 0.5 }')
        _lxmem_ss=$(awk -v st="$_lxmem_st" -v sf="$_lxmem_sf" -v t="$_lxmem_t" -v a="$_lxmem_a" -v zr="$_lxmem_zr" 'BEGIN {
            if (st < 262144) { print "info"; exit }
            p = (st - sf) * 100 / st; low = (t > 0 && a * 100 / t < 10); s = "ok"
            if (zr) { if (p >= 90 && low) s = "warn"; print s; exit }
            if (p >= 80) s = "warn"; if (p >= 90 && low) s = "bad"
            print s }')
        _lxmem_slbl=$(t 'Swap used' 'Swap đã dùng')
        [ "$_lxmem_zr" = 1 ] && _lxmem_slbl=$(t 'Swap used (zram)' 'Swap đã dùng (zram)')
        add_check memory "$_lxmem_slbl" \
            "$(tf '%s%% of %s' '%s%% trong %s' "$_lxmem_sp" "$(human_kb "$_lxmem_st")")" "$_lxmem_ss" \
            "$([ "$_lxmem_ss" = warn ] && t 'Swap is mostly used; check whether memory is undersized for the workload.' 'Swap gần đầy; kiểm tra xem RAM có bị thiếu so với khối lượng công việc không.'; [ "$_lxmem_ss" = bad ] && t 'RAM and swap are both nearly full; an out-of-memory kill is imminent.' 'RAM và swap đều gần đầy; nguy cơ bị giết tiến trình do hết bộ nhớ.')"
    else
        add_check memory "$(t 'Swap' 'Swap')" "$(t 'none configured' 'chưa cấu hình')" info \
            "$(t 'No swap is configured; this is common on VPS and only matters if memory runs short.' 'Chưa có swap; điều này phổ biến trên VPS và chỉ quan trọng khi thiếu bộ nhớ.')"
    fi
    return 0
}

# ---------- storage ----------
# One candidate filesystem per device (shortest mountpoint), network/pseudo types skipped.
lxs_fs_list() {
    awk '
        function skip(ty, m) {
            if (ty ~ /^(proc|sysfs|devtmpfs|devpts|tmpfs|ramfs|rootfs|cgroup|cgroup2|pstore|bpf|debugfs|tracefs|securityfs|configfs|fusectl|hugetlbfs|mqueue|autofs|binfmt_misc|efivarfs|rpc_pipefs|nsfs|selinuxfs|squashfs|iso9660|udf|erofs|cramfs|romfs|nfs|nfs4|nfsd|cifs|smb3|smbfs|9p|ceph|glusterfs|afs|ncpfs|davfs|lustre|virtiofs|vboxsf|vmhgfs|aufs)$/) return 1
            if (ty ~ /^fuse\./) return 1
            if (ty == "fuse") return 1
            if (ty == "overlay" && m != "/") return 1
            if (m ~ /^\/(proc|sys|dev|run|snap)(\/|$)/) return 1
            if (m ~ /^\/var\/lib\/(docker|containers|kubelet)\//) return 1
            return 0
        }
        {
            dev = $1; m = $2; gsub(/\\040/, " ", m)
            if (skip($3, m)) next
            key = dev; if ($3 == "zfs") sub(/\/.*/, "", key)
            if (!(key in best) || length(m) < length(best[key])) { best[key] = m; typ[key] = $3; opt[key] = $4; d[key] = dev }
            if (!(key in seen)) { seen[key] = 1; order[++n] = key }
        }
        END { for (i = 1; i <= n; i++) { k = order[i]; printf "%s\t%s\t%s\t%s\n", best[k], d[k], typ[k], opt[k] } }
    ' "$BR_FSROOT/proc/mounts" 2>/dev/null
}

lx_storage() {
    lxs_fs_list >"$BR_TMP/lxfs" 2>/dev/null
    [ -s "$BR_TMP/lxfs" ] || return 0
    table_new storage "$(t 'Filesystem usage' 'Dung lượng ổ đĩa')" "Mount|Type|#Size|%Used"
    _lxst_rows=0
    while IFS="$TAB" read -r _lxst_mnt _lxst_dev _lxst_typ _lxst_opt; do
        [ -n "$_lxst_mnt" ] || continue
        [ -d "$_lxst_mnt" ] || continue
        # Space (-k) and inodes (-i). df is an external command, so no BR_FSROOT prefix.
        _lxst_k=$(run_to 5 df -P -k -- "$_lxst_mnt" 2>/dev/null | awk 'NR == 2 { p = $5; sub(/%/, "", p); if (p !~ /^[0-9]+$/) p = "na"; printf "%.0f|%.0f|%.0f|%s", $2, $3, $4, p }')
        [ -n "$_lxst_k" ] || continue
        _lxst_size=${_lxst_k%%|*}; _lxst_r=${_lxst_k#*|}
        _lxst_used=${_lxst_r%%|*}; _lxst_r=${_lxst_r#*|}
        _lxst_avail=${_lxst_r%%|*}
        is_int "$_lxst_size" && is_int "$_lxst_used" && is_int "$_lxst_avail" || continue
        _lxst_pct=$(awk -v u="$_lxst_used" -v a="$_lxst_avail" 'BEGIN { d = u + a; printf "%d", (d > 0 ? u * 100 / d + 0.5 : 0) }')
        if [ "$_lxst_rows" -lt 15 ]; then
            table_row storage "$_lxst_mnt" "$_lxst_typ" "$(human_kb "$_lxst_size")" "$_lxst_pct"
            _lxst_rows=$((_lxst_rows + 1))
        fi
        _lxst_ss=$(awk -v u="$_lxst_pct" -v a="$_lxst_avail" 'BEGIN { g = 1048576; s = "ok"
            if (u >= 90 || (u >= 80 && a < 20 * g)) s = "warn"
            if (u >= 90 && a < 5 * g) s = "bad"
            print s }')
        if [ "$_lxst_ss" != ok ] || [ "$_lxst_mnt" = / ]; then
            _lxst_nm=$(t 'Disk space' 'Dung lượng đĩa')
            [ "$_lxst_mnt" = / ] && _lxst_nm=$(t 'Root filesystem' 'Phân vùng gốc')
            add_check storage "$_lxst_nm ($_lxst_mnt)" \
                "$(tf '%s%% used, %s free of %s' '%s%% đã dùng, còn %s trong %s' "$_lxst_pct" "$(human_kb "$_lxst_avail")" "$(human_kb "$_lxst_size")")" "$_lxst_ss" \
                "$([ "$_lxst_ss" = warn ] && t 'This filesystem is getting full; clean up logs, caches and old backups or extend it.' 'Phân vùng sắp đầy; dọn log, cache, bản sao lưu cũ hoặc mở rộng dung lượng.'; [ "$_lxst_ss" = bad ] && t 'This filesystem is almost out of space and services may fail; free space or extend it now.' 'Phân vùng gần hết chỗ, dịch vụ có thể lỗi; giải phóng hoặc mở rộng ngay.')"
        fi
        # Inodes (skip filesystems with 0 total, e.g. btrfs/vfat).
        _lxst_i=$(run_to 5 df -P -i -- "$_lxst_mnt" 2>/dev/null | awk 'NR == 2 { printf "%.0f|%.0f|%.0f", $2, $3, $4 }')
        _lxst_it=${_lxst_i%%|*}; _lxst_ir=${_lxst_i#*|}
        _lxst_iu=${_lxst_ir%%|*}; _lxst_if=${_lxst_ir#*|}
        if is_int "$_lxst_it" && [ "$_lxst_it" -gt 0 ] && is_int "$_lxst_iu"; then
            _lxst_ip=$(awk -v u="$_lxst_iu" -v f="$_lxst_if" 'BEGIN { d = u + f; printf "%d", (d > 0 ? u * 100 / d + 0.5 : 0) }')
            _lxst_is=$(grade "$_lxst_ip" 80 95)
            if [ "$_lxst_is" != ok ]; then
                add_check storage "$(t 'Inode usage' 'Sử dụng inode') ($_lxst_mnt)" \
                    "$(tf '%s%% of inodes used' '%s%% inode đã dùng' "$_lxst_ip")" "$_lxst_is" \
                    "$([ "$_lxst_is" = warn ] && t 'Most inodes are used; look for directories holding huge numbers of small files (sessions, cache, mail queue).' 'Phần lớn inode đã dùng; tìm thư mục chứa rất nhiều tệp nhỏ (session, cache, hàng đợi mail).'; [ "$_lxst_is" = bad ] && t 'Inodes are nearly exhausted and new files cannot be created soon; delete small-file clutter now.' 'Inode gần cạn, sắp không tạo được tệp mới; xóa bớt các tệp nhỏ ngay.')"
            fi
        fi
        # Unexpectedly read-only (writable-type filesystem mounted ro and not ro in fstab).
        case ",$_lxst_opt," in
            *,ro,* | *,emergency_ro,* | *,shutdown,*)
                case "$_lxst_typ" in
                    ext2 | ext3 | ext4 | xfs | btrfs | f2fs | jfs | reiserfs)
                        _lxst_want=$(awk -v m="$_lxst_mnt" '$1 !~ /^#/ && $2 == m { print $4; exit }' "$BR_FSROOT/etc/fstab" 2>/dev/null)
                        _lxst_ro=warn
                        case ",$_lxst_want," in *,ro,*) _lxst_ro=skip ;; esac
                        if [ -z "$_lxst_want" ] && [ "$_lxst_mnt" != / ]; then _lxst_ro=skip; fi
                        if [ "$_lxst_ro" != skip ] && [ "$LX_CONTAINER" != 1 ]; then
                            add_check storage "$(t 'Read-only filesystem' 'Phân vùng chỉ đọc') ($_lxst_mnt)" \
                                "$(t 'mounted read-only' 'đang gắn ở chế độ chỉ đọc')" bad \
                                "$(t 'The kernel remounted this filesystem read-only, usually after I/O errors; back up, check the disk and run fsck.' 'Nhân đã chuyển phân vùng sang chỉ đọc, thường do lỗi I/O; sao lưu, kiểm tra ổ đĩa và chạy fsck.')"
                        fi
                        ;;
                esac
                ;;
        esac
        # ext4 errors recorded in the superblock (survives log rotation, no root needed).
        case "$_lxst_typ" in
            ext4)
                _lxst_bn=${_lxst_dev##*/}
                _lxst_ec=$(read_file "$BR_FSROOT/sys/fs/ext4/$_lxst_bn/errors_count")
                if is_int "$_lxst_ec" && [ "$_lxst_ec" -gt 0 ]; then
                    add_check storage "$(t 'Filesystem errors' 'Lỗi hệ thống tệp') ($_lxst_mnt)" \
                        "$(tf '%s error(s) recorded' 'ghi nhận %s lỗi' "$_lxst_ec")" warn \
                        "$(t 'The filesystem has logged errors; schedule a filesystem check and verify the disk.' 'Hệ thống tệp đã ghi nhận lỗi; lên lịch kiểm tra và xác minh ổ đĩa.')"
                fi
                ;;
        esac
    done <"$BR_TMP/lxfs"

    lxs_mdraid
    lxs_smart
    return 0
}

lxs_mdraid() {
    [ -r "$BR_FSROOT/proc/mdstat" ] || return 0
    awk '
        function flush() { if (name != "") printf "%s|%s|%s|%s|%s|%s|%s\n", name, state, want, have, map, failed, action }
        /^md[^ ]* : / { flush(); name = $1; state = $3; want = ""; have = ""; map = ""; failed = 0; action = ""
            for (i = 4; i <= NF; i++) { if ($i ~ /^\(.*\)$/) { state = state $i; continue } if ($i ~ /\[[0-9]+\]/) { if ($i ~ /\(F\)/) failed++; continue } }
            next }
        name != "" && /blocks/ {
            if (match($0, /\[[0-9]+\/[0-9]+\]/)) { s = substr($0, RSTART + 1, RLENGTH - 2); split(s, a, "/"); want = a[1]; have = a[2] }
            if (match($0, /\[[U_]+\]/)) map = substr($0, RSTART + 1, RLENGTH - 2)
            next }
        name != "" && match($0, /(resync|recovery|reshape|check) *= *[0-9.]+%/) { s = substr($0, RSTART, RLENGTH); action = s; sub(/ *=.*/, "", action); next }
        /^unused devices/ { flush(); name = "" }
        END { flush() }
    ' "$BR_FSROOT/proc/mdstat" 2>/dev/null >"$BR_TMP/lxmd"
    [ -s "$BR_TMP/lxmd" ] || return 0
    while IFS='|' read -r _lxmd_n _lxmd_st _lxmd_w _lxmd_h _lxmd_map _lxmd_f _lxmd_act; do
        [ -n "$_lxmd_n" ] || continue
        _lxmd_s=ok; _lxmd_msg=
        _lxmd_degraded=0
        case "$_lxmd_map" in *_*) _lxmd_degraded=1 ;; esac
        if is_int "$_lxmd_w" && is_int "$_lxmd_h" && [ "$_lxmd_h" -lt "$_lxmd_w" ]; then _lxmd_degraded=1; fi
        case "$_lxmd_st" in
            inactive* | broken*)
                _lxmd_s=bad; _lxmd_msg=$(t 'A RAID member is missing and the array has no redundancy; replace the disk and re-add it.' 'Thiếu thành viên RAID và mảng không còn dự phòng; thay ổ đĩa và thêm lại.') ;;
            *)
                if [ "$_lxmd_degraded" = 1 ]; then
                    if [ -n "$_lxmd_act" ] && [ "$_lxmd_act" != check ]; then
                        _lxmd_s=warn; _lxmd_msg=$(t 'The array is rebuilding; avoid heavy load and do not power off until it finishes.' 'Mảng đang tái tạo; tránh tải nặng và không tắt máy cho đến khi xong.')
                    else
                        _lxmd_s=bad; _lxmd_msg=$(t 'A RAID member is missing and the array has no redundancy; replace the disk and re-add it.' 'Thiếu thành viên RAID và mảng không còn dự phòng; thay ổ đĩa và thêm lại.')
                    fi
                fi
                ;;
        esac
        _lxmd_val="$_lxmd_st"
        [ -n "$_lxmd_map" ] && _lxmd_val="$_lxmd_st [$_lxmd_map]"
        [ -n "$_lxmd_act" ] && _lxmd_val="$_lxmd_val, $_lxmd_act"
        add_check storage "$(t 'Software RAID' 'RAID phần mềm') ($_lxmd_n)" "$_lxmd_val" "$_lxmd_s" "$_lxmd_msg"
    done <"$BR_TMP/lxmd"
    return 0
}

lxs_smart() {
    have smartctl || return 0
    if [ "$BR_ROOT" != 1 ]; then
        add_check storage "$(t 'Drive health (SMART)' 'Sức khỏe ổ đĩa (SMART)')" \
            "$(t 'not checked (needs root)' 'chưa kiểm tra (cần quyền root)')" info
        return 0
    fi
    [ "$BR_QUICK" = 1 ] && return 0
    [ "$LX_CONTAINER" = 1 ] && return 0
    run_to 8 smartctl --scan 2>/dev/null | awk '$2 == "-d" { print $1 " " $3 }' >"$BR_TMP/lxsmart_scan"
    [ -s "$BR_TMP/lxsmart_scan" ] || return 0
    _lxsm_n=0
    while read -r _lxsm_dev _lxsm_type; do
        [ -n "$_lxsm_dev" ] || continue
        _lxsm_n=$((_lxsm_n + 1))
        [ "$_lxsm_n" -gt 8 ] && break
        run_to 15 smartctl -n standby -H -A -d "$_lxsm_type" "$_lxsm_dev" >"$BR_TMP/lxsmart_out" 2>/dev/null
        _lxsm_rc=$?
        case "$_lxsm_rc" in 124 | 137 | 143) continue ;; esac
        grep -qE 'self-assessment test result:|SMART Health Status:' "$BR_TMP/lxsmart_out" 2>/dev/null || continue
        _lxsm_fail=$(( (_lxsm_rc / 8) % 2 ))
        _lxsm_pre=$(( (_lxsm_rc / 16) % 2 ))
        _lxsm_health=$(awk '/self-assessment test result:/ { print $NF } /^SMART Health Status:/ { print ($4 == "OK" ? "PASSED" : "FAILED") }' "$BR_TMP/lxsmart_out" | head -n 1)
        # Backblaze-predictive raw counters and NVMe fields.
        _lxsm_p=$(awk '
            $1 ~ /^[0-9]+$/ && NF >= 10 && $2 ~ /^[A-Za-z]/ { raw = $10; sub(/[^0-9].*$/, "", raw); r[$1] = raw }
            /^Critical Warning:/ { cw = $3 }
            /^Percentage Used:/ { pu = $3; sub(/%/, "", pu) }
            /^Media and Data Integrity Errors:/ { me = $6; gsub(/[^0-9]/, "", me) }
            END { printf "%s|%s|%s|%s|%s|%s|%s", r[5]+0, r[187]+0, r[197]+0, r[198]+0, (cw == "" ? "" : cw), (pu == "" ? "" : pu), me+0 }' "$BR_TMP/lxsmart_out")
        _lxsm_5=$(printf '%s' "$_lxsm_p" | cut -d'|' -f1)
        _lxsm_187=$(printf '%s' "$_lxsm_p" | cut -d'|' -f2)
        _lxsm_197=$(printf '%s' "$_lxsm_p" | cut -d'|' -f3)
        _lxsm_198=$(printf '%s' "$_lxsm_p" | cut -d'|' -f4)
        _lxsm_cw=$(printf '%s' "$_lxsm_p" | cut -d'|' -f5)
        _lxsm_pu=$(printf '%s' "$_lxsm_p" | cut -d'|' -f6)
        _lxsm_me=$(printf '%s' "$_lxsm_p" | cut -d'|' -f7)

        _lxsm_s=ok; _lxsm_note=
        case "$_lxsm_health" in FAILED*) _lxsm_s=bad ;; esac
        [ "$_lxsm_fail" = 1 ] && _lxsm_s=bad
        [ "$_lxsm_pre" = 1 ] && _lxsm_s=bad
        case "$_lxsm_cw" in '' | 0x00 | 0) ;; *) _lxsm_s=bad ;; esac
        if is_int "$_lxsm_pu" && [ "$_lxsm_pu" -ge 100 ]; then _lxsm_s=bad; fi
        if [ "$_lxsm_s" != bad ]; then
            for _lxsm_v in "$_lxsm_5" "$_lxsm_187" "$_lxsm_197" "$_lxsm_198" "$_lxsm_me"; do
                if is_int "$_lxsm_v" && [ "$_lxsm_v" -gt 0 ]; then _lxsm_s=warn; fi
            done
            if is_int "$_lxsm_pu" && [ "$_lxsm_pu" -ge 80 ]; then _lxsm_s=warn; fi
        fi
        case "$_lxsm_s" in
            bad) _lxsm_note=$(t 'The drive reports that it is failing; back up now and replace it.' 'Ổ đĩa báo đang hỏng; sao lưu ngay và thay ổ.') ;;
            warn) _lxsm_note=$(t 'The drive has reallocated, pending or uncorrectable sectors (or high wear); back up and plan a replacement if the numbers grow.' 'Ổ đĩa có sector hỏng/đang chờ/không sửa được (hoặc hao mòn cao); sao lưu và chuẩn bị thay nếu số liệu tăng.') ;;
        esac
        _lxsm_hv=${_lxsm_health:-?}
        [ -n "$_lxsm_pu" ] && _lxsm_hv="$_lxsm_hv, $(tf 'wear %s%%' 'hao mòn %s%%' "$_lxsm_pu")"
        add_check storage "$(t 'Drive health (SMART)' 'Sức khỏe ổ đĩa (SMART)') (${_lxsm_dev##*/})" "$_lxsm_hv" "$_lxsm_s" "$_lxsm_note"
    done <"$BR_TMP/lxsmart_scan"
    return 0
}

lx_hardware() {
    lxs_power_source
    lxs_battery
    lxs_temperature
    lxs_edac
    return 0
}

lxs_power_source() {
    # Classify AC/mains vs battery from /sys/class/power_supply.
    _lxps_dir="$BR_FSROOT/sys/class/power_supply"
    _lxps_bat=0; _lxps_mains=0; _lxps_online=0
    if [ -d "$_lxps_dir" ]; then
        for _lxps_e in "$_lxps_dir"/*; do
            [ -e "$_lxps_e" ] || continue
            _lxps_ty=$(read_file "$_lxps_e/type")
            _lxps_sc=$(read_file "$_lxps_e/scope")
            case "$_lxps_sc" in Device | device) continue ;; esac
            case "$_lxps_ty" in
                Battery)
                    _lxps_pr=$(read_file "$_lxps_e/present")
                    [ "$_lxps_pr" = 0 ] || _lxps_bat=1
                    ;;
                Mains | USB | USB_PD | USB_PD_DRP | USB_C)
                    _lxps_mains=1
                    _lxps_on=$(read_file "$_lxps_e/online")
                    [ "$_lxps_on" = 1 ] && _lxps_online=1
                    ;;
            esac
        done
    fi
    if [ "$_lxps_bat" = 1 ]; then
        if [ "$_lxps_online" = 1 ]; then
            add_check battery "$(t 'Power source' 'Nguồn điện')" "$(t 'on AC power (plugged in)' 'đang cắm điện (AC)')" info
        else
            add_check battery "$(t 'Power source' 'Nguồn điện')" "$(t 'running on battery' 'đang chạy bằng pin')" info
        fi
    elif [ "$_lxps_mains" = 1 ]; then
        add_check battery "$(t 'Power source' 'Nguồn điện')" "$(t 'direct AC power (desktop, no battery)' 'nguồn điện trực tiếp (máy bàn, không có pin)')" info
    else
        add_check battery "$(t 'Power source' 'Nguồn điện')" "$(t 'direct AC power (server/VPS, no battery)' 'nguồn điện trực tiếp (máy chủ/VPS, không có pin)')" info
    fi
    return 0
}

lxs_battery() {
    _lxbt_dir="$BR_FSROOT/sys/class/power_supply"
    [ -d "$_lxbt_dir" ] || return 0
    for _lxbt_e in "$_lxbt_dir"/*; do
        [ -e "$_lxbt_e/uevent" ] || continue
        _lxbt_ty=$(read_file "$_lxbt_e/type")
        [ "$_lxbt_ty" = Battery ] || continue
        _lxbt_sc=$(read_file "$_lxbt_e/scope")
        case "$_lxbt_sc" in Device | device) continue ;; esac
        _lxbt_pr=$(read_file "$_lxbt_e/present")
        [ "$_lxbt_pr" = 0 ] && continue

        _lxbt_r=$(awk -F= '{ sub(/^POWER_SUPPLY_/, "", $1); v[$1] = $2 }
            END {
                fd = ("ENERGY_FULL_DESIGN" in v) ? v["ENERGY_FULL_DESIGN"] : v["CHARGE_FULL_DESIGN"]
                f  = ("ENERGY_FULL" in v) ? v["ENERGY_FULL"] : v["CHARGE_FULL"]
                h = (fd + 0 > 0 && f + 0 > 0) ? sprintf("%.0f", f * 100 / fd) : "na"
                cyc = (v["CYCLE_COUNT"] + 0 > 0) ? v["CYCLE_COUNT"] : "na"
                printf "%s|%s|%s|%s|%s", v["NAME"], v["STATUS"], v["CAPACITY"], h, cyc
            }' "$_lxbt_e/uevent" 2>/dev/null)
        _lxbt_name=$(printf '%s' "$_lxbt_r" | cut -d'|' -f1)
        _lxbt_status=$(printf '%s' "$_lxbt_r" | cut -d'|' -f2)
        _lxbt_cap=$(printf '%s' "$_lxbt_r" | cut -d'|' -f3)
        _lxbt_health=$(printf '%s' "$_lxbt_r" | cut -d'|' -f4)
        _lxbt_cyc=$(printf '%s' "$_lxbt_r" | cut -d'|' -f5)

        _lxbt_s=info
        if is_int "$_lxbt_health"; then
            if [ "$_lxbt_health" -ge 80 ]; then _lxbt_s=ok
            elif [ "$_lxbt_health" -ge 60 ]; then _lxbt_s=warn
            else _lxbt_s=bad; fi
        fi
        # Battery panel (ring = charge, status = wear verdict).
        if is_int "$_lxbt_cap"; then bat_set ring "$_lxbt_cap"; fi
        bat_set ringlabel "$(t 'charge' 'mức pin')"
        bat_set status "$_lxbt_s"
        if is_int "$_lxbt_health"; then
            bat_set message "$(tf 'battery health %s%% of design capacity' 'pin còn %s%% so với thiết kế' "$_lxbt_health")"
            bat_row "$(t 'Health' 'Độ chai')" "$_lxbt_health%"
        fi
        bat_row "$(t 'Status' 'Trạng thái')" "$_lxbt_status"
        [ -n "$_lxbt_cap" ] && bat_row "$(t 'Charge' 'Mức pin')" "$_lxbt_cap%"
        is_int "$_lxbt_cyc" && bat_row "$(t 'Cycles' 'Số chu kỳ sạc')" "$_lxbt_cyc"

        if is_int "$_lxbt_health"; then
            add_check battery "$(t 'Battery wear' 'Độ chai pin') ($_lxbt_name)" \
                "$(tf '%s%% of design capacity' 'còn %s%% so với thiết kế' "$_lxbt_health")" "$_lxbt_s" \
                "$([ "$_lxbt_s" = warn ] && t 'The battery holds noticeably less than when new; runtime is reduced.' 'Pin chứa ít điện hơn hẳn so với lúc mới; thời lượng dùng giảm.'; [ "$_lxbt_s" = bad ] && t 'The battery is heavily worn; replace it if runtime is not enough.' 'Pin chai nặng; thay pin nếu thời lượng không đủ dùng.')"
        fi
    done
    return 0
}

lxs_temperature() {
    if [ "$LX_CONTAINER" = 1 ] || { [ "$LX_VIRT" != none ] && [ "$LX_VIRT" != unknown ]; }; then
        return 0
    fi
    _lxtm_dir="$BR_FSROOT/sys/class/hwmon"
    [ -d "$_lxtm_dir" ] || return 0
    : >"$BR_TMP/lxtemp"
    for _lxtm_h in "$_lxtm_dir"/hwmon*; do
        [ -r "$_lxtm_h/name" ] || continue
        _lxtm_nm=$(read_file "$_lxtm_h/name")
        for _lxtm_f in "$_lxtm_h"/temp*_input; do
            [ -r "$_lxtm_f" ] || continue
            _lxtm_v=$(read_file "$_lxtm_f")
            is_int "$_lxtm_v" || continue
            _lxtm_lb=$(read_file "${_lxtm_f%_input}_label")
            _lxtm_cr=$(read_file "${_lxtm_f%_input}_crit")
            printf '%s|%s|%s|%s\n' "$_lxtm_nm" "$_lxtm_lb" "$_lxtm_v" "$_lxtm_cr" >>"$BR_TMP/lxtemp"
        done
    done
    [ -s "$BR_TMP/lxtemp" ] || return 0
    # Pick a CPU-package reading: coretemp "Package id 0" / k10temp Tdie|Tctl / else hottest plausible.
    _lxtm_pick=$(awk -F'|' '
        $3 + 0 > 0 && $3 + 0 < 125000 {
            score = 1; if ($1 == "coretemp" && $2 ~ /Package/) score = 5
            else if ($1 ~ /k10temp|zenpower/ && $2 ~ /Tdie/) score = 5
            else if ($1 ~ /k10temp|zenpower/ && $2 ~ /Tctl/) score = 4
            else if ($1 == "coretemp") score = 3
            else if ($1 ~ /cpu|soc|pkg|x86_pkg/) score = 3
            if (score > bs || (score == bs && $3 + 0 > bv)) { bs = score; bv = $3 + 0; bc = $4 }
        }
        END { if (bs > 0) printf "%d|%s", bv, bc }' "$BR_TMP/lxtemp")
    [ -n "$_lxtm_pick" ] || return 0
    _lxtm_mc=${_lxtm_pick%%|*}
    _lxtm_crit=${_lxtm_pick#*|}
    _lxtm_c=$(awk -v m="$_lxtm_mc" 'BEGIN { printf "%d", m / 1000 + 0.5 }')
    _lxtm_s=ok
    if is_int "$_lxtm_crit" && [ "$_lxtm_crit" -gt 0 ]; then
        _lxtm_critc=$(awk -v m="$_lxtm_crit" 'BEGIN { printf "%d", m / 1000 }')
        if [ "$_lxtm_c" -ge $((_lxtm_critc - 2)) ]; then _lxtm_s=bad
        elif [ "$_lxtm_c" -ge $((_lxtm_critc - 10)) ]; then _lxtm_s=warn; fi
    else
        if [ "$_lxtm_c" -ge 90 ]; then _lxtm_s=warn; fi
    fi
    add_check hardware "$(t 'CPU temperature' 'Nhiệt độ CPU')" "$(tf '%s °C' '%s °C' "$_lxtm_c")" "$_lxtm_s" \
        "$([ "$_lxtm_s" = warn ] && t 'The CPU is close to its thermal limit; check fans, dust and airflow.' 'CPU gần tới ngưỡng nhiệt; kiểm tra quạt, bụi và luồng gió.'; [ "$_lxtm_s" = bad ] && t 'The CPU is at its critical temperature and may throttle or shut down; fix cooling now.' 'CPU đạt nhiệt độ tới hạn, có thể giảm xung hoặc tắt; xử lý tản nhiệt ngay.')"
    return 0
}

lxs_edac() {
    _lxed_dir="$BR_FSROOT/sys/devices/system/edac/mc"
    [ -d "$_lxed_dir" ] || return 0
    _lxed_ce=0; _lxed_ue=0; _lxed_any=0
    for _lxed_m in "$_lxed_dir"/mc*; do
        [ -d "$_lxed_m" ] || continue
        _lxed_c=$(read_file "$_lxed_m/ce_count")
        _lxed_u=$(read_file "$_lxed_m/ue_count")
        if is_int "$_lxed_c"; then _lxed_ce=$((_lxed_ce + _lxed_c)); _lxed_any=1; fi
        if is_int "$_lxed_u"; then _lxed_ue=$((_lxed_ue + _lxed_u)); _lxed_any=1; fi
    done
    [ "$_lxed_any" = 1 ] || return 0
    if [ "$_lxed_ue" -gt 0 ]; then
        add_check hardware "$(t 'Memory ECC errors' 'Lỗi ECC bộ nhớ')" \
            "$(tf '%s uncorrectable, %s corrected' '%s không sửa được, %s đã sửa' "$_lxed_ue" "$_lxed_ce")" bad \
            "$(t 'Memory reported uncorrectable errors; data may be corrupted, so test and replace the faulty module.' 'Bộ nhớ báo lỗi không sửa được; dữ liệu có thể hỏng, hãy kiểm tra và thay thanh RAM lỗi.')"
    elif [ "$_lxed_ce" -ge 100 ]; then
        add_check hardware "$(t 'Memory ECC errors' 'Lỗi ECC bộ nhớ')" "$(tf '%s corrected' '%s đã sửa' "$_lxed_ce")" warn \
            "$(t 'Memory corrected many errors; watch the count and replace the module if it keeps rising.' 'Bộ nhớ đã sửa nhiều lỗi; theo dõi và thay thanh RAM nếu số lỗi tiếp tục tăng.')"
    elif [ "$_lxed_ce" -gt 0 ]; then
        add_check hardware "$(t 'Memory ECC errors' 'Lỗi ECC bộ nhớ')" "$(tf '%s corrected' '%s đã sửa' "$_lxed_ce")" info \
            "$(t 'Memory corrected some errors; watch the count and replace the module if it keeps rising.' 'Bộ nhớ đã sửa một số lỗi; theo dõi và thay thanh RAM nếu số lỗi tiếp tục tăng.')"
    fi
    return 0
}

# ---------- network: listening sockets + risky/backdoor audit (LOCAL only) ----------
lxs_port_info() {
    # $1 = port -> "sev<TAB>name"; sev in ssh|bad|warn|none
    case "$1" in
        22) printf 'ssh\tSSH' ;;
        23) printf 'bad\tTelnet (cleartext remote login)' ;;
        512 | 513 | 514) printf 'bad\trlogin/rsh (cleartext remote login)' ;;
        1337 | 4444 | 5555 | 31337 | 12345 | 9001) printf 'bad\tpossible backdoor/RAT port' ;;
        6667) printf 'bad\tIRC (often malware command-and-control)' ;;
        6379) printf 'warn\tRedis (frequently unauthenticated)' ;;
        11211) printf 'warn\tMemcached (no authentication)' ;;
        27017) printf 'warn\tMongoDB' ;;
        9200) printf 'warn\tElasticsearch' ;;
        5432) printf 'warn\tPostgreSQL' ;;
        3306) printf 'warn\tMySQL/MariaDB' ;;
        2375) printf 'warn\tDocker API (unauthenticated)' ;;
        5984) printf 'warn\tCouchDB' ;;
        8086) printf 'warn\tInfluxDB' ;;
        9000) printf 'warn\tphp-fpm/other service' ;;
        21) printf 'warn\tFTP' ;;
        5900 | 5901 | 5902 | 5903) printf 'warn\tVNC' ;;
        3389) printf 'warn\tRDP' ;;
        6000 | 6001) printf 'warn\tX11' ;;
        445) printf 'warn\tSMB/CIFS' ;;
        111) printf 'warn\trpcbind/portmapper' ;;
        873) printf 'warn\trsync' ;;
        9090 | 9100) printf 'warn\tmetrics exporter (often unauthenticated)' ;;
        *) printf 'none\t' ;;
    esac
}

lx_network() {
    _lxnw_src=
    if have ss; then
        ss -H -tulpn 2>/dev/null >"$BR_TMP/lxnet_raw"
        [ -s "$BR_TMP/lxnet_raw" ] || ss -tulpn 2>/dev/null >"$BR_TMP/lxnet_raw"
        _lxnw_src=ss
    elif have netstat; then
        netstat -tulpn 2>/dev/null >"$BR_TMP/lxnet_raw"
        _lxnw_src=netstat
    fi
    if [ -z "$_lxnw_src" ] || [ ! -s "$BR_TMP/lxnet_raw" ]; then
        add_check network "$(t 'Listening sockets' 'Cổng đang lắng nghe')" \
            "$(t 'could not be listed (ss/netstat unavailable)' 'không liệt kê được (thiếu ss/netstat)')" info
        return 0
    fi

    # Emit: proto|port|scope|procname|pid  (listening sockets only).
    awk -v src="$_lxnw_src" '
        function classify(a) {
            if (a == "*" || a == "0.0.0.0") return "all4"
            if (a == "::" || a == "[::]") return "all6"
            if (a ~ /^127\./) return "local"
            if (a == "[::1]" || a == "::1") return "local"
            return "addr"
        }
        {
            proto = ""; la = ""; proc = ""; pid = ""
            if (src == "ss") {
                if ($1 == "Netid" || $1 == "State") next
                if ($1 !~ /^(tcp|udp)$/) next
                st = $2
                if (st != "LISTEN" && st != "UNCONN") next
                proto = $1; la = $5
            } else {
                if ($1 !~ /^(tcp|tcp6|udp|udp6)$/) next
                if ($1 ~ /^tcp/ && $0 !~ /LISTEN/) next
                proto = $1; sub(/6$/, "", proto); la = $4
            }
            port = la; sub(/^.*:/, "", port)
            addr = la; sub(/:[^:]*$/, "", addr); sub(/%[^]]*/, "", addr)
            if (port !~ /^[0-9]+$/) next
            scope = classify(addr)
            if (match($0, /users:\(\("[^"]+"/)) { s = substr($0, RSTART, RLENGTH); sub(/users:\(\("/, "", s); sub(/"$/, "", s); proc = s }
            else if (src == "netstat" && match($0, /[0-9]+\/[^ ]+/)) { s = substr($0, RSTART, RLENGTH); sub(/^[0-9]+\//, "", s); proc = s }
            if (match($0, /pid=[0-9]+/)) { p = substr($0, RSTART, RLENGTH); sub(/pid=/, "", p); pid = p }
            else if (src == "netstat" && match($0, /[0-9]+\/[^ ]+/)) { p = substr($0, RSTART, RLENGTH); sub(/\/.*/, "", p); pid = p }
            print proto "|" port "|" scope "|" proc "|" pid
        }' "$BR_TMP/lxnet_raw" 2>/dev/null | sort -u >"$BR_TMP/lxnet" 2>/dev/null

    table_new listen "$(t 'Listening sockets' 'Cổng đang lắng nghe')" "Proto|#Port|Address|Process"
    _lxnw_rows=0; _lxnw_risky=0; _lxnw_ssh=0
    while IFS='|' read -r _lxnw_proto _lxnw_port _lxnw_scope _lxnw_proc _lxnw_pid; do
        [ -n "$_lxnw_port" ] || continue
        case "$_lxnw_scope" in
            all4) _lxnw_addr="0.0.0.0 ($(t 'all' 'tất cả'))" ;;
            all6) _lxnw_addr=":: ($(t 'all' 'tất cả'))" ;;
            local) _lxnw_addr=$(t 'localhost' 'localhost') ;;
            *) _lxnw_addr=$(t 'specific address' 'địa chỉ cụ thể') ;;
        esac
        if [ "$_lxnw_rows" -lt 15 ]; then
            table_row listen "$_lxnw_proto" "$_lxnw_port" "$_lxnw_addr" "${_lxnw_proc:--}"
            _lxnw_rows=$((_lxnw_rows + 1))
        fi
        # Audit: loopback binds are always ok, even on risky ports.
        [ "$_lxnw_scope" = local ] && continue
        _lxnw_pi=$(lxs_port_info "$_lxnw_port")
        _lxnw_sev=${_lxnw_pi%%	*}
        _lxnw_svc=${_lxnw_pi#*	}
        _lxnw_pn=$(printf '%s' "$_lxnw_proc" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
        case "$_lxnw_sev" in
            ssh) _lxnw_ssh=1 ;;
            bad)
                _lxnw_risky=1
                add_check network "$(tf 'Exposed port %s' 'Cổng mở %s' "$_lxnw_port")" \
                    "$(tf '%s on a public address (%s)' '%s trên địa chỉ công khai (%s)' "$_lxnw_svc" "${_lxnw_pn:-?}")" bad \
                    "$(tf 'A high-risk service (%s) is reachable from any address; bind it to localhost or firewall it, and if you did not start it, investigate for compromise.' 'Dịch vụ rủi ro cao (%s) có thể truy cập từ mọi địa chỉ; hãy chỉ cho nghe localhost hoặc chặn bằng firewall, và nếu bạn không mở nó thì cần kiểm tra khả năng bị xâm nhập.' "$_lxnw_svc")"
                ;;
            warn)
                _lxnw_risky=1
                add_check network "$(tf 'Exposed port %s' 'Cổng mở %s' "$_lxnw_port")" \
                    "$(tf '%s on a public address (%s)' '%s trên địa chỉ công khai (%s)' "$_lxnw_svc" "${_lxnw_pn:-?}")" warn \
                    "$(tf 'This service (%s) accepts connections from any address; bind it to localhost or restrict it with a firewall (a provider firewall may already block it).' 'Dịch vụ này (%s) nhận kết nối từ mọi địa chỉ; hãy chỉ cho nghe localhost hoặc chặn bằng firewall (firewall của nhà cung cấp có thể đã chặn).' "$_lxnw_svc")"
                ;;
        esac
        # Executable in a temp dir or deleted -> likely malware (needs root to see other users).
        if [ "$BR_ROOT" = 1 ] && is_int "$_lxnw_pid"; then
            _lxnw_exe=$(readlink "$BR_FSROOT/proc/$_lxnw_pid/exe" 2>/dev/null)
            case "$_lxnw_exe" in
                *'(deleted)' | /tmp/* | /dev/shm/* | /var/tmp/*)
                    _lxnw_risky=1
                    add_check network "$(tf 'Suspicious listener on port %s' 'Tiến trình đáng ngờ ở cổng %s' "$_lxnw_port")" \
                        "$(tf 'process %s runs from a temporary or deleted path' 'tiến trình %s chạy từ đường dẫn tạm hoặc đã bị xóa' "${_lxnw_pn:-?}")" bad \
                        "$(tf 'A listening program (PID %s) runs from a temporary or deleted executable, a common malware trait; investigate this process.' 'Chương trình đang lắng nghe (PID %s) chạy từ tệp tạm hoặc đã xóa — dấu hiệu thường gặp của mã độc; hãy kiểm tra tiến trình này.' "$_lxnw_pid")"
                    ;;
            esac
        fi
    done <"$BR_TMP/lxnet"

    if [ "$_lxnw_risky" = 0 ]; then
        if [ "$_lxnw_ssh" = 1 ]; then
            add_check network "$(t 'Exposed services' 'Dịch vụ mở ra ngoài')" "$(t 'only SSH is exposed; nothing risky found' 'chỉ SSH mở ra ngoài; không thấy gì rủi ro')" ok
        else
            add_check network "$(t 'Exposed services' 'Dịch vụ mở ra ngoài')" "$(t 'no risky service is exposed' 'không có dịch vụ rủi ro nào mở ra ngoài')" ok
        fi
    fi
    if [ "$BR_ROOT" != 1 ]; then
        add_check network "$(t 'Listening-port executable audit' 'Kiểm tra tệp của tiến trình lắng nghe')" \
            "$(t 'partial (needs root to inspect other users'"'"' processes)' 'chưa đầy đủ (cần root để xem tiến trình của người dùng khác)')" info
    fi

    lxs_iferrors
    return 0
}

lxs_iferrors() {
    [ -r "$BR_FSROOT/proc/net/dev" ] || return 0
    awk -F'[: ]+' '
        NR > 2 {
            # A regex FS leaves an empty $1 before the leading spaces, so the iface is $2
            # and the Receive/Transmit counters start at $3 (rx bytes).
            iface = $2
            if (iface == "lo") next
            rxp = $4; rxe = $5; txp = $12; txe = $13
            terr = rxe + txe; tpkt = rxp + txp
            if (terr >= 1000 && tpkt > 0 && terr * 100 / tpkt > 1) print iface "|" terr "|" tpkt
        }' "$BR_FSROOT/proc/net/dev" 2>/dev/null >"$BR_TMP/lxif"
    while IFS='|' read -r _lxif_i _lxif_e _lxif_p; do
        [ -n "$_lxif_i" ] || continue
        add_check network "$(tf 'Interface errors (%s)' 'Lỗi giao tiếp mạng (%s)' "$_lxif_i")" \
            "$(tf '%s errors / %s packets' '%s lỗi / %s gói' "$_lxif_e" "$_lxif_p")" warn \
            "$(t 'This network interface shows a high error rate; check the cable, port or virtual NIC driver.' 'Giao tiếp mạng này có tỉ lệ lỗi cao; kiểm tra cáp, cổng hoặc trình điều khiển NIC ảo.')"
    done <"$BR_TMP/lxif"
    return 0
}

lx_limits() {
    # File descriptors (system-wide).
    _lxl_fnr=$(read_file "$BR_FSROOT/proc/sys/fs/file-nr")
    if [ -n "$_lxl_fnr" ]; then
        _lxl_fp=$(printf '%s\n' "$_lxl_fnr" | awk '{ if ($3 > 0) printf "%.1f", $1 * 100 / $3 }')
        if [ -n "$_lxl_fp" ]; then
            _lxl_fpi=$(printf '%s' "$_lxl_fp" | awk '{ printf "%d", $1 + 0.5 }')
            _lxl_fs=$(grade "$_lxl_fpi" 80 90)
            if [ "$_lxl_fs" != ok ]; then
                add_check memory "$(t 'File descriptors' 'Số file descriptor')" "$(tf '%s%% of the system limit' '%s%% giới hạn hệ thống' "$_lxl_fp")" "$_lxl_fs" \
                    "$([ "$_lxl_fs" = warn ] && t 'The system is using most of its file-handle limit; find the process leaking files or raise fs.file-max.' 'Hệ thống dùng gần hết giới hạn file handle; tìm tiến trình rò rỉ hoặc tăng fs.file-max.'; [ "$_lxl_fs" = bad ] && t 'File handles are almost exhausted and new connections will fail; restart the leaking service or raise the limit now.' 'File handle gần cạn, kết nối mới sẽ lỗi; khởi động lại dịch vụ rò rỉ hoặc tăng giới hạn ngay.')"
            fi
        fi
    fi

    # Conntrack table (only when the module is loaded).
    _lxl_cc=$(read_file "$BR_FSROOT/proc/sys/net/netfilter/nf_conntrack_count")
    _lxl_cm=$(read_file "$BR_FSROOT/proc/sys/net/netfilter/nf_conntrack_max")
    if is_int "$_lxl_cc" && is_int "$_lxl_cm" && [ "$_lxl_cm" -gt 0 ]; then
        _lxl_cp=$(pct "$_lxl_cc" "$_lxl_cm")
        _lxl_cs=$(grade "$_lxl_cp" 80 95)
        if [ "$_lxl_cs" != ok ]; then
            add_check network "$(t 'Connection tracking table' 'Bảng theo dõi kết nối (conntrack)')" "$(tf '%s%% full (%s of %s)' '%s%% đầy (%s trong %s)' "$_lxl_cp" "$_lxl_cc" "$_lxl_cm")" "$_lxl_cs" \
                "$([ "$_lxl_cs" = warn ] && t 'The connection-tracking table is filling up; raise net.netfilter.nf_conntrack_max or reduce tracked traffic.' 'Bảng conntrack đang đầy dần; tăng net.netfilter.nf_conntrack_max hoặc giảm lưu lượng bị theo dõi.'; [ "$_lxl_cs" = bad ] && t 'The connection-tracking table is nearly full and new connections will be dropped; raise the limit now.' 'Bảng conntrack gần đầy, kết nối mới sẽ bị rớt; tăng giới hạn ngay.')"
        fi
    fi

    # Zombies, from the second process snapshot (or a fresh one).
    _lxl_snap="$BR_TMP/lxps_b"
    [ -s "$_lxl_snap" ] || { lxs_ps_snapshot >"$BR_TMP/lxps_now" 2>/dev/null; _lxl_snap="$BR_TMP/lxps_now"; }
    if [ -s "$_lxl_snap" ]; then
        _lxl_z=$(awk '$2 == "Z" { z++ } END { print z + 0 }' "$_lxl_snap")
        if is_int "$_lxl_z" && [ "$_lxl_z" -ge 5 ]; then
            add_check memory "$(t 'Zombie processes' 'Tiến trình xác sống (zombie)')" "$(tf '%s zombie process(es)' '%s tiến trình zombie' "$_lxl_z")" warn \
                "$(t 'Several finished processes were never collected; restart the parent program shown in the process list.' 'Một số tiến trình đã kết thúc nhưng chưa được thu dọn; khởi động lại chương trình cha trong danh sách tiến trình.')"
        fi
    fi

    lxs_topproc
    return 0
}

lxs_topproc() {
    [ -s "$BR_TMP/lxps_b" ] || return 0
    _lxtp_dt=$(read_file "$BR_TMP/lxcpu_dt")
    is_int "$_lxtp_dt" || _lxtp_dt=0
    # Merge CPU-tick delta (lxps_a vs lxps_b) with RSS from /proc/*/status.
    awk -v dt="$_lxtp_dt" -v nc="$LX_NCPU" '
        function base(p) { b = p; sub(/^.*\//, "", b); return b }
        FILENAME ~ /lxps_a$/ { a[$1] = $3; next }
        FILENAME ~ /lxps_b$/ {
            pid = $1; tk = $3; c = $4; for (i = 5; i <= NF; i++) c = c " " $i
            comm[pid] = c; tb[pid] = tk; next
        }
        /^Name:/ { nm = $2 }
        /^Pid:/ { spid = $2 }
        /^VmRSS:/ { rss[spid] = $2 }
        END {
            for (p in tb) {
                cpu = 0
                if (dt > 0 && (p in a)) { d = tb[p] - a[p]; if (d > 0) cpu = d * 100 * nc / dt }
                r = (p in rss) ? rss[p] : 0
                printf "%.1f\t%.0f\t%s\t%s\n", cpu, r, p, comm[p]
            }
        }' "$BR_TMP/lxps_a" "$BR_TMP/lxps_b" "$BR_FSROOT"/proc/[0-9]*/status 2>/dev/null |
        sort -t"$TAB" -k1,1nr -k2,2nr 2>/dev/null | head -n 5 >"$BR_TMP/lxtop" 2>/dev/null
    [ -s "$BR_TMP/lxtop" ] || return 0
    table_new procs "$(t 'Top processes' 'Tiến trình nổi bật')" "Command|#CPU %|#Memory|#PID"
    while IFS="$TAB" read -r _lxtp_cpu _lxtp_rss _lxtp_pid _lxtp_comm; do
        [ -n "$_lxtp_pid" ] || continue
        table_row procs "$_lxtp_comm" "$_lxtp_cpu" "$(human_kb "$_lxtp_rss")" "$_lxtp_pid"
    done <"$BR_TMP/lxtop"
    return 0
}

# ---------- Linux system collector (OS / services / logs half) ----------
# Defines: lx_boot lx_services lx_crashes lx_updates lx_security
# Private helpers are prefixed lxo_. Reads of /proc,/sys,/etc,/var go through "$BR_FSROOT";
# external commands (systemctl, journalctl, rpm, ...) are never prefixed and go through run_to.

lxo_human_dur() {
    # seconds -> "Xd Yh" / "Yh Zm" / "Zm" (compact uptime text)
    awk -v s="$1" 'BEGIN {
        s = int(s + 0)
        d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
        if (d > 0) printf "%dd %dh", d, h
        else if (h > 0) printf "%dh %dm", h, m
        else printf "%dm", m
    }'
}

lx_boot() {
    if [ "$LX_INIT" = systemd ] && have systemd-analyze; then
        run_to 10 systemd-analyze time 2>/dev/null >"$BR_TMP/lxboot_t"
        _lxb_p=$(awk '
            function dur_ms(s,   n, i, a, v, u, t) {
                t = 0; n = split(s, a, " ")
                for (i = 1; i <= n; i++) {
                    v = a[i]; u = a[i]; sub(/[^0-9.].*$/, "", v); sub(/^[0-9.]+/, "", u)
                    if (v == "") continue
                    if (u == "ms") t += v
                    else if (u == "s") t += v * 1000
                    else if (u == "min") t += v * 60000
                    else if (u == "h") t += v * 3600000
                    else if (u == "d") t += v * 86400000
                    else if (u ~ /s$/) t += v / 1000
                }
                return t
            }
            /^Startup finished in / {
                line = $0; sub(/^Startup finished in /, "", line)
                i = index(line, "= ")
                if (i > 0) { tot = dur_ms(substr(line, i + 2)); line = substr(line, 1, i - 1) }
                n = split(line, p, /\+/)
                for (k = 1; k <= n; k++) if (match(p[k], /\([a-z-]+\)/)) { nm = substr(p[k], RSTART + 1, RLENGTH - 2); ms[nm] = dur_ms(substr(p[k], 1, RSTART - 1)) }
                found = 1
            }
            /not yet finished/ { notfin = 1 }
            END {
                if (notfin) { print "starting"; exit }
                if (!found) { print "unknown"; exit }
                os = ms["kernel"] + ms["initrd"] + ms["userspace"]
                if (tot <= 0) tot = os
                printf "ok %d %d %d %d %d %d %d", ms["firmware"], ms["loader"], ms["kernel"], ms["initrd"], ms["userspace"], os, tot
            }' "$BR_TMP/lxboot_t")
        case "$_lxb_p" in
            ok\ *)
                set -- $_lxb_p
                _lxb_fw=$2; _lxb_ld=$3; _lxb_k=$4; _lxb_i=$5; _lxb_u=$6; _lxb_os=$7; _lxb_tot=$8
                boot_seg "$(t 'firmware' 'firmware')" "$_lxb_fw"
                boot_seg "$(t 'loader' 'bộ nạp')" "$_lxb_ld"
                boot_seg "$(t 'kernel' 'nhân')" "$_lxb_k"
                boot_seg "$(t 'initrd' 'initrd')" "$_lxb_i"
                boot_seg "$(t 'userspace' 'userspace')" "$_lxb_u"
                add_stat "$(fmt_ms "$_lxb_tot")" "$(t 'boot time' 'thời gian khởi động')"
                if is_int "$_lxb_os"; then
                    _lxb_bs=ok
                    [ "$_lxb_os" -gt 90000 ] && _lxb_bs=warn
                    add_check boot "$(t 'Boot time' 'Thời gian khởi động')" "$(fmt_ms "$_lxb_os")" "$_lxb_bs" \
                        "$([ "$_lxb_bs" = warn ] && t 'Boot took longer than 90 seconds; see the slowest units below and fix or disable the one that waits or times out.' 'Khởi động mất hơn 90 giây; xem các dịch vụ chậm nhất bên dưới và sửa hoặc tắt dịch vụ đang chờ/hết giờ.')"
                fi
                ;;
            starting)
                _lxb_up=$(awk '{ print int($1); exit }' "$BR_FSROOT/proc/uptime" 2>/dev/null)
                if is_int "$_lxb_up" && [ "$_lxb_up" -gt 600 ]; then
                    add_check boot "$(t 'Boot state' 'Trạng thái khởi động')" "$(t 'startup jobs still running' 'vẫn còn tác vụ khởi động')" warn \
                        "$(t 'Startup jobs are still running long after boot; run systemctl list-jobs to see what is stuck.' 'Vẫn còn tác vụ khởi động chạy lâu sau khi bật máy; chạy systemctl list-jobs để xem đang kẹt ở đâu.')"
                fi
                ;;
        esac
        # Slowest units.
        run_to 10 systemd-analyze blame --no-pager 2>/dev/null | head -n 15 |
            awk '{ u = $NF; $NF = ""; sub(/ +$/, ""); sub(/^ +/, ""); print u "|" $0 }' >"$BR_TMP/lxblame"
        if [ -s "$BR_TMP/lxblame" ]; then
            table_new bootblame "$(t 'Slowest boot units' 'Dịch vụ khởi động chậm nhất')" "Unit|~Time"
            while IFS='|' read -r _lxb_un _lxb_d; do
                [ -n "$_lxb_un" ] || continue
                _lxb_dms=$(awk -v s="$_lxb_d" '
                    function dur_ms(x,   n, i, a, v, u, t) { t = 0; n = split(x, a, " ")
                        for (i = 1; i <= n; i++) { v = a[i]; u = a[i]; sub(/[^0-9.].*$/, "", v); sub(/^[0-9.]+/, "", u)
                            if (v == "") continue
                            if (u == "ms") t += v; else if (u == "s") t += v * 1000; else if (u == "min") t += v * 60000
                            else if (u == "h") t += v * 3600000; else if (u ~ /s$/) t += v / 1000 }
                        return t }
                    BEGIN { printf "%d", dur_ms(s) }')
                table_row bootblame "$_lxb_un" "$_lxb_dms"
            done <"$BR_TMP/lxblame"
        fi
    fi

    # Uptime (tile + check).
    _lxb_ups=$(awk '{ print int($1); exit }' "$BR_FSROOT/proc/uptime" 2>/dev/null)
    if is_int "$_lxb_ups"; then
        add_stat "$(lxo_human_dur "$_lxb_ups")" "$(t 'uptime' 'thời gian chạy')"
        _lxb_upd=$((_lxb_ups / 86400))
        _lxb_us=info
        _lxb_un2=
        if [ "$_lxb_upd" -gt 365 ] && [ ! -d "$BR_FSROOT/sys/kernel/livepatch" ]; then
            _lxb_us=warn
            _lxb_un2=$(t 'The running kernel is over a year old; reboot into the current kernel or enable live patching.' 'Nhân đang chạy đã hơn một năm; khởi động lại vào nhân mới hoặc bật live patching.')
        elif [ "$_lxb_upd" -gt 365 ]; then
            _lxb_us=info
        fi
        add_check boot "$(t 'Uptime' 'Thời gian chạy')" "$(tf '%s days' '%s ngày' "$_lxb_upd")" "$_lxb_us" "$_lxb_un2"
    fi

    lxo_reboot_required
    lxo_reboot_history
    return 0
}

lxo_reboot_required() {
    [ "$LX_CONTAINER" = 1 ] && return 0
    _lxr_need=0; _lxr_why=
    if [ "$LX_FAMILY" = debian ]; then
        if [ -e "$BR_FSROOT/run/reboot-required" ]; then _lxr_need=1; fi
    elif [ "$LX_FAMILY" = rhel ] && have rpm && [ "$BR_QUICK" != 1 ]; then
        _lxr_boot=$(awk '$1 == "btime" { print $2; exit }' "$BR_FSROOT/proc/stat" 2>/dev/null)
        if is_int "$_lxr_boot"; then
            _lxr_upd=$(run_to 20 rpm -q --qf '%{INSTALLTIME} %{NAME}\n' kernel kernel-core kernel-rt kernel-rt-core kernel-uek kernel-uek-core glibc linux-firmware systemd dbus dbus-broker dbus-daemon microcode_ctl openssl-libs 2>/dev/null |
                awk -v b="$_lxr_boot" '$1 ~ /^[0-9]+$/ && $1 + 0 > b + 0 { print $2 }' | sort -u | awk 'BEGIN { ORS = " " } { print }')
            case "$_lxr_upd" in *kernel* | *glibc* | *systemd* | *dbus* | *openssl*) _lxr_need=1; _lxr_why=$_lxr_upd ;; esac
        fi
        _lxr_run=$(uname -r 2>/dev/null)
        case "$_lxr_run" in *uek*) _lxr_kp="kernel-uek-core kernel-uek" ;; *) _lxr_kp="kernel-core kernel" ;; esac
        _lxr_new=$(run_to 20 rpm -q --qf '%{INSTALLTIME} %{VERSION}-%{RELEASE}.%{ARCH}\n' $_lxr_kp 2>/dev/null | awk '$1 ~ /^[0-9]+$/' | sort -n | tail -n 1 | awk '{ print $2 }')
        if [ -n "$_lxr_new" ] && [ -n "$_lxr_run" ] && [ "$_lxr_new" != "$_lxr_run" ]; then _lxr_need=1; fi
    elif [ "$LX_FAMILY" = suse ]; then
        if [ -e "$BR_FSROOT/run/reboot-needed" ]; then _lxr_need=1; fi
    else
        # Arch / Alpine: running kernel's module tree gone after an upgrade.
        _lxr_run=$(uname -r 2>/dev/null)
        if [ -n "$_lxr_run" ] && [ -d "$BR_FSROOT/lib/modules" ] && [ ! -d "$BR_FSROOT/lib/modules/$_lxr_run" ]; then
            if [ -n "$(ls "$BR_FSROOT/lib/modules" 2>/dev/null)" ]; then _lxr_need=1; fi
        fi
    fi
    if [ "$_lxr_need" = 1 ]; then
        add_check boot "$(t 'Reboot required' 'Cần khởi động lại')" "$(t 'yes' 'có')" warn \
            "$(t 'Installed kernel or core library updates are not active yet; schedule a reboot.' 'Các bản cập nhật nhân hoặc thư viện lõi chưa có hiệu lực; hãy lên lịch khởi động lại.')"
    fi
    return 0
}

lxo_reboot_history() {
    have last || return 0
    _lxh_cut=$(fmt_epoch "$((BR_NOW - BR_DAYS * 86400))" '%Y%m%d')
    is_int "$_lxh_cut" || return 0
    _lxh_r=$(run_to 10 last -x -F 2>/dev/null | awk -v cut="$_lxh_cut" '
        BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) mon[m[i]] = i }
        $1 == "reboot" && $2 == "system" && $3 == "boot" {
            d = sprintf("%04d%02d%02d", $9, mon[$6], $7)
            if (prev == "reboot" && prevd >= cut) unclean++
            if (d >= cut) boots++
            prev = "reboot"; prevd = d; seen = 1; next
        }
        $1 == "shutdown" && $2 == "system" && $3 == "down" { prev = "shutdown"; next }
        END { if (!seen) print "unknown"; else print boots + 0, unclean + 0 }')
    if [ "$_lxh_r" = unknown ] || [ -z "$_lxh_r" ]; then
        add_check boot "$(t 'Unclean shutdowns' 'Lần tắt máy bất thường')" "$(t 'history too short to tell' 'lịch sử quá ngắn để xác định')" info
        return 0
    fi
    _lxh_boots=$(printf '%s' "$_lxh_r" | awk '{ print $1 }')
    _lxh_unc=$(printf '%s' "$_lxh_r" | awk '{ print $2 }')
    is_int "$_lxh_unc" || _lxh_unc=0
    _lxh_s=ok
    if [ "$_lxh_unc" -ge 3 ]; then _lxh_s=bad
    elif [ "$_lxh_unc" -ge 1 ]; then _lxh_s=warn; fi
    [ "$LX_CONTAINER" = 1 ] && _lxh_s=info
    add_check boot "$(t 'Unclean shutdowns' 'Lần tắt máy bất thường')" \
        "$(tf '%s in the last %s days (%s boots)' '%s lần trong %s ngày qua (%s lần khởi động)' "$_lxh_unc" "$BR_DAYS" "$_lxh_boots")" "$_lxh_s" \
        "$([ "$_lxh_s" = warn ] && t 'The system went down without a clean shutdown; check power, the provider maintenance log and filesystem integrity.' 'Máy đã tắt mà không shutdown đúng cách; kiểm tra nguồn điện, nhật ký bảo trì của nhà cung cấp và tính toàn vẹn hệ thống tệp.'; [ "$_lxh_s" = bad ] && t 'Repeated hard stops risk data corruption; find the cause (power, host node, kernel panic) before it happens again.' 'Tắt đột ngột lặp lại gây nguy cơ hỏng dữ liệu; tìm nguyên nhân (nguồn điện, máy chủ vật lý, kernel panic) trước khi tái diễn.')"
    return 0
}

lx_services() {
    if [ "$LX_INIT" = systemd ] && have systemctl; then
        run_to 10 systemctl list-units --state=failed --no-legend --plain --no-pager --full 2>/dev/null |
            awk '{ i = 1; if ($1 !~ /\./) i = 2; if ($i ~ /\./) print $i }' >"$BR_TMP/lxsvc"
        _lxsv_state=$(run_to 5 systemctl is-system-running 2>/dev/null)
        _lxsv_n=$(awk 'END { print NR + 0 }' "$BR_TMP/lxsvc")
        if [ "$_lxsv_n" -ge 1 ]; then
            table_new failed "$(t 'Failed units' 'Dịch vụ lỗi')" "Unit"
            _lxsv_bad=0
            while IFS= read -r _lxsv_u; do
                [ -n "$_lxsv_u" ] || continue
                table_row failed "$_lxsv_u"
                _lxsv_base=${_lxsv_u%.*}
                case "$_lxsv_base" in
                    sshd | ssh | nginx | apache2 | httpd | *-fpm | mysql | mysqld | mariadb | postgresql* | redis* | mongod | docker | containerd | postfix | dovecot | named | haproxy | cron | crond | NetworkManager | systemd-networkd | networking | network)
                        _lxsv_bad=1 ;;
                esac
            done <"$BR_TMP/lxsvc"
            [ "$_lxsv_state" = maintenance ] && _lxsv_bad=1
            _lxsv_s=warn
            [ "$_lxsv_bad" = 1 ] && _lxsv_s=bad
            add_check services "$(t 'Failed systemd units' 'Dịch vụ systemd bị lỗi')" \
                "$(tf '%s failed' '%s dịch vụ lỗi' "$_lxsv_n")" "$_lxsv_s" \
                "$([ "$_lxsv_s" = warn ] && t 'Review each failed unit with systemctl status NAME and clear fixed ones with systemctl reset-failed.' 'Xem từng dịch vụ lỗi bằng systemctl status TÊN và xóa trạng thái lỗi đã khắc phục bằng systemctl reset-failed.'; [ "$_lxsv_s" = bad ] && t 'A core service is down; check journalctl -u NAME -b and restart it once the cause is fixed.' 'Một dịch vụ cốt lõi đang dừng; kiểm tra journalctl -u TÊN -b và khởi động lại sau khi khắc phục.')"
        else
            add_check services "$(t 'Failed systemd units' 'Dịch vụ systemd bị lỗi')" "$(t 'none' 'không có')" ok
        fi
    elif [ "$LX_INIT" = openrc ] && have rc-status; then
        _lxsv_cr=$(run_to 5 rc-status -c 2>/dev/null)
        _lxsv_crc=$?
        run_to 5 rc-status -a 2>/dev/null | awk '
            /Runlevel: / { lvl = $NF; next }
            /\[/ { name = $1; st = $0; sub(/^.*\[[ \t]*/, "", st); sub(/[] \t].*$/, "", st); print lvl "|" name "|" st }' >"$BR_TMP/lxrc"
        _lxsv_crash=$(awk -F'|' '$3 == "crashed" { c++ } END { print c + 0 }' "$BR_TMP/lxrc")
        _lxsv_stop=$(awk -F'|' '($1 == "boot" || $1 == "default") && ($3 == "stopped" || $3 == "inactive" || $3 == "failed") { s++ } END { print s + 0 }' "$BR_TMP/lxrc")
        is_int "$_lxsv_crash" || _lxsv_crash=0
        is_int "$_lxsv_stop" || _lxsv_stop=0
        if [ "$_lxsv_crash" -ge 1 ]; then
            table_new failed "$(t 'Crashed services' 'Dịch vụ bị treo')" "Service"
            awk -F'|' '$3 == "crashed" { print $2 }' "$BR_TMP/lxrc" | while IFS= read -r _lxsv_c; do table_row failed "$_lxsv_c"; done
            add_check services "$(t 'OpenRC services' 'Dịch vụ OpenRC')" "$(tf '%s crashed' '%s dịch vụ bị treo' "$_lxsv_crash")" bad \
                "$(t 'An OpenRC service crashed; check its log and restart it with rc-service NAME restart.' 'Một dịch vụ OpenRC bị treo; kiểm tra log và khởi động lại bằng rc-service TÊN restart.')"
        elif [ "$_lxsv_stop" -ge 1 ]; then
            add_check services "$(t 'OpenRC services' 'Dịch vụ OpenRC')" "$(tf '%s not started in boot/default' '%s chưa chạy ở runlevel boot/default' "$_lxsv_stop")" warn \
                "$(t 'A service in the boot or default runlevel is not running; start it or remove it from the runlevel.' 'Một dịch vụ ở runlevel boot hoặc default không chạy; khởi động hoặc gỡ khỏi runlevel.')"
        else
            add_check services "$(t 'OpenRC services' 'Dịch vụ OpenRC')" "$(t 'all tracked services running' 'tất cả dịch vụ theo dõi đang chạy')" ok
        fi
    else
        add_check services "$(t 'Services' 'Dịch vụ')" "$(tf 'init is %s; service enumeration skipped' 'init là %s; bỏ qua liệt kê dịch vụ' "${LX_INIT:-other}")" info
    fi
    return 0
}

lxo_journal_ok() {
    # Sets _lxc_jok=1 when the system journal is readable (not just the caller's own entries).
    _lxc_jok=0
    [ "$LX_INIT" = systemd ] || return 0
    have journalctl || return 0
    for _lxc_jf in "$BR_FSROOT"/var/log/journal/*/system.journal "$BR_FSROOT"/run/log/journal/*/system.journal; do
        [ -r "$_lxc_jf" ] && _lxc_jok=1
    done
    [ "$BR_ROOT" = 1 ] && _lxc_jok=1
    return 0
}

lx_crashes() {
    lxo_journal_ok
    _lxc_since="$BR_DAYS days ago"
    : >"$BR_TMP/lxkern"
    _lxc_have=0
    if [ "$_lxc_jok" = 1 ]; then
        run_to 20 journalctl -q --no-pager -o short-iso _TRANSPORT=kernel -p 0..4 --since "$_lxc_since" 2>/dev/null | head -n 20000 >"$BR_TMP/lxkern"
        # Segfaults / GP-faults are logged at KERN_INFO (priority 6), which -p 0..4 excludes; pull just those
        # lines, filtered and bounded so the extra journal scan stays cheap (and skip it under --quick).
        [ "$BR_QUICK" = 1 ] || run_to 10 journalctl -q --no-pager -o cat _TRANSPORT=kernel -p 6..6 --since "$_lxc_since" 2>/dev/null | grep -E 'segfault at|traps: ' | head -n 2000 >>"$BR_TMP/lxkern"
        _lxc_have=1
        _lxc_cov=$(tf 'last %s days of the journal' '%s ngày gần nhất trong journal' "$BR_DAYS")
    elif [ "$BR_ROOT" = 1 ] && [ -r "$BR_FSROOT/var/log/messages" ]; then
        _lxc_cy=$(date +%Y 2>/dev/null); _lxc_cm=$(date +%m 2>/dev/null)
        _lxc_cut=$(fmt_epoch "$((BR_NOW - BR_DAYS * 86400))" '%Y-%m-%d')
        tail -n 300000 "$BR_FSROOT/var/log/messages" 2>/dev/null | grep ' kernel: ' |
            awk -v cy="$_lxc_cy" -v cm="$_lxc_cm" -v cut="$_lxc_cut" '
                BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) mon[m[i]] = i }
                $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-/ { if (substr($1, 1, 10) >= cut) print; next }
                ($1 in mon) && $3 ~ /^[0-9][0-9]:/ { y = cy; if (mon[$1] > cm + 0) y = cy - 1
                    d = sprintf("%04d-%02d-%02d", y, mon[$1], $2); if (d < cut) next
                    rest = $0; sub(/^[A-Za-z]+ +[0-9]+ +[0-9:]+ /, "", rest); print d "T" $3 " " rest }' >"$BR_TMP/lxkern"
        _lxc_have=1
        _lxc_cov=$(tf 'last %s days of /var/log/messages' '%s ngày gần nhất trong /var/log/messages' "$BR_DAYS")
    elif have dmesg; then
        run_to 5 dmesg 2>/dev/null >"$BR_TMP/lxkern"
        if [ -s "$BR_TMP/lxkern" ]; then _lxc_have=1; _lxc_cov=$(t 'current boot only (dmesg)' 'chỉ lần khởi động hiện tại (dmesg)'); fi
    fi

    # OOM counter since boot (always, world-readable). Inside a container /proc/vmstat oom_kill is
    # host-wide, so prefer this cgroup's own counter when we are containerized.
    _lxc_oomsb=$(awk '$1 == "oom_kill" { print $2; exit }' "$BR_FSROOT/proc/vmstat" 2>/dev/null)
    _lxc_oomcg=$(awk '$1 == "oom_kill" { print $2; exit }' "$BR_FSROOT/sys/fs/cgroup/memory.events" 2>/dev/null)
    if [ "$LX_CONTAINER" = 1 ] && is_int "$_lxc_oomcg"; then _lxc_oomsb=$_lxc_oomcg; fi

    if [ "$_lxc_have" != 1 ]; then
        if is_int "$_lxc_oomsb" && [ "$_lxc_oomsb" -gt 0 ]; then
            add_check crashes "$(t 'Out-of-memory kills' 'Bị giết do hết bộ nhớ (OOM)')" "$(tf '%s since boot' '%s từ lúc khởi động' "$_lxc_oomsb")" warn \
                "$(t 'The kernel killed a process for lack of memory; find which one in the log and lower its usage or add RAM.' 'Nhân đã giết tiến trình do thiếu bộ nhớ; tìm trong log và giảm mức dùng hoặc thêm RAM.')"
        else
            add_check crashes "$(t 'Kernel & hardware errors' 'Lỗi nhân & phần cứng')" "$(t 'could not be checked (needs root or journal access)' 'không kiểm tra được (cần root hoặc quyền đọc journal)')" info
        fi
        return 0
    fi

    _lxc_r=$(awk '
        function hit(k) { n[k]++ }
        /Killed process [0-9]+/ { hit("oom"); next }
        / error, dev [^ ,]+, sector / { d = $0; sub(/.* error, dev /, "", d); sub(/,.*/, "", d); if (d ~ /^(fd|sr|loop|zram)[0-9]/) { next } hit("io"); next }
        /Buffer I\/O error on dev/ { hit("io"); next }
        /EXT4-fs error/ || /EXT4-fs \([^)]*\): Remounting filesystem read-only/ || /Aborting journal on device/ || /XFS \([^)]*\): .*(I\/O [Ee]rror|[Cc]orruption|xfs_do_force_shutdown|[Ss]hutting down|Internal error)/ || /BTRFS (error|critical)/ || /JBD2: .*(error|abort)/ { hit("fs"); next }
        /EDAC .*MC[0-9]+: [0-9]+ UE / || /Machine Check Exception/ || /\[Hardware Error\]: .*([Uu]ncorrected|[Ff]atal)/ || /event severity: fatal/ { hit("hwf"); next }
        /\[Hardware Error\]/ || /EDAC .*MC[0-9]+: [0-9]+ CE / { hit("hw"); next }
        /Kernel panic - not syncing/ { hit("panic"); next }
        /BUG: soft lockup/ || /hard LOCKUP/ || /blocked for more than [0-9]+ seconds/ || /self-detected stall/ || /detected stalls on CPUs/ { hit("stall"); next }
        /Oops: / || /BUG: unable to handle/ || /BUG: kernel NULL pointer dereference/ || (/general protection fault/ && !/traps: /) { hit("oops"); next }
        /segfault at / || /traps: .* general protection/ { hit("segv"); next }
        END { printf "oom=%d io=%d fs=%d hw=%d hwf=%d panic=%d stall=%d oops=%d segv=%d", n["oom"], n["io"], n["fs"], n["hw"], n["hwf"], n["panic"], n["stall"], n["oops"], n["segv"] }
    ' "$BR_TMP/lxkern")
    _lxc_oom=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["oom"] + 0 }')
    _lxc_io=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["io"] + 0 }')
    _lxc_fs=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["fs"] + 0 }')
    _lxc_hw=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["hw"] + 0 }')
    _lxc_hwf=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["hwf"] + 0 }')
    _lxc_pan=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["panic"] + 0 }')
    _lxc_stall=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["stall"] + 0 }')
    _lxc_oops=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["oops"] + 0 }')
    _lxc_segv=$(printf '%s ' "$_lxc_r" | awk '{ for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] } print v["segv"] + 0 }')

    _lxc_any=0
    # OOM
    if [ "$_lxc_oom" -ge 1 ]; then
        _lxc_any=1
        _lxc_s=warn; [ "$_lxc_oom" -ge 3 ] && _lxc_s=bad
        add_check crashes "$(t 'Out-of-memory kills' 'Bị giết do hết bộ nhớ (OOM)')" "$(tf '%s in the window' '%s trong khoảng thời gian xét' "$_lxc_oom")" "$_lxc_s" \
            "$([ "$_lxc_s" = warn ] && t 'The kernel killed a process for lack of memory; find which one in the log and lower its usage or add RAM.' 'Nhân đã giết tiến trình do thiếu bộ nhớ; tìm trong log và giảm mức dùng hoặc thêm RAM.'; [ "$_lxc_s" = bad ] && t 'Processes are being killed for lack of memory repeatedly; the server needs more RAM, swap or lower limits.' 'Tiến trình liên tục bị giết do thiếu bộ nhớ; máy chủ cần thêm RAM, swap hoặc giảm giới hạn.')"
    elif is_int "$_lxc_oomsb" && [ "$_lxc_oomsb" -gt 0 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Out-of-memory kills' 'Bị giết do hết bộ nhớ (OOM)')" "$(tf 'none in window, %s since boot' 'không có trong khoảng xét, %s từ lúc khởi động' "$_lxc_oomsb")" info
    fi
    # Disk I/O
    if [ "$_lxc_io" -ge 1 ]; then
        _lxc_any=1
        _lxc_s=warn; [ "$_lxc_io" -ge 5 ] && _lxc_s=bad
        add_check crashes "$(t 'Disk I/O errors' 'Lỗi I/O ổ đĩa')" "$(tf '%s line(s)' '%s dòng lỗi' "$_lxc_io")" "$_lxc_s" \
            "$([ "$_lxc_s" = warn ] && t 'The kernel logged I/O errors on a device; check cables, SMART data and the provider storage status.' 'Nhân ghi nhận lỗi I/O trên thiết bị; kiểm tra cáp, dữ liệu SMART và tình trạng lưu trữ của nhà cung cấp.'; [ "$_lxc_s" = bad ] && t 'Repeated I/O errors point to failing storage; back up and replace or migrate the disk.' 'Lỗi I/O lặp lại cho thấy ổ đĩa sắp hỏng; sao lưu và thay hoặc chuyển ổ.')"
    fi
    # Filesystem
    if [ "$_lxc_fs" -ge 1 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Filesystem errors' 'Lỗi hệ thống tệp')" "$(tf '%s line(s)' '%s dòng lỗi' "$_lxc_fs")" bad \
            "$(t 'The kernel logged filesystem errors; back up, check the disk and run fsck.' 'Nhân ghi nhận lỗi hệ thống tệp; sao lưu, kiểm tra ổ đĩa và chạy fsck.')"
    fi
    # Hardware
    if [ "$_lxc_hwf" -ge 1 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Hardware errors (MCE)' 'Lỗi phần cứng (MCE)')" "$(tf '%s uncorrected event(s)' '%s sự kiện không sửa được' "$_lxc_hwf")" bad \
            "$(t 'The CPU reported uncorrected hardware errors; have the hardware checked or ask the provider to move the server.' 'CPU báo lỗi phần cứng không sửa được; kiểm tra phần cứng hoặc yêu cầu nhà cung cấp chuyển máy.')"
    elif [ "$_lxc_hw" -ge 1 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Hardware errors (MCE)' 'Lỗi phần cứng (MCE)')" "$(tf '%s corrected event(s)' '%s sự kiện đã sửa' "$_lxc_hw")" warn \
            "$(t 'The CPU reported corrected hardware errors; watch for more and check cooling, memory and firmware.' 'CPU báo lỗi phần cứng đã sửa; theo dõi thêm và kiểm tra tản nhiệt, bộ nhớ và firmware.')"
    fi
    # Panic / oops
    _lxc_po=$((_lxc_pan + _lxc_oops))
    if [ "$_lxc_po" -ge 1 ]; then
        _lxc_any=1
        _lxc_s=warn; [ "$_lxc_po" -ge 3 ] && _lxc_s=bad
        add_check crashes "$(t 'Kernel oops / panic' 'Kernel oops / panic')" "$(tf '%s event(s)' '%s sự kiện' "$_lxc_po")" "$_lxc_s" \
            "$([ "$_lxc_s" = warn ] && t 'The kernel hit an internal error; update the kernel and check the hardware if it repeats.' 'Nhân gặp lỗi nội bộ; cập nhật nhân và kiểm tra phần cứng nếu tái diễn.'; [ "$_lxc_s" = bad ] && t 'The kernel is crashing repeatedly; treat it as a hardware or driver fault and fix it before relying on this machine.' 'Nhân liên tục gặp sự cố; hãy coi là lỗi phần cứng hoặc driver và khắc phục trước khi tin dùng máy này.')"
    fi
    # Soft lockups / hung tasks
    if [ "$_lxc_stall" -ge 1 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Soft lockups / hung tasks' 'Treo CPU / tác vụ kẹt')" "$(tf '%s event(s)' '%s sự kiện' "$_lxc_stall")" warn \
            "$(t 'The kernel reported stalled CPUs or tasks; on a VPS this usually means the host is overloaded.' 'Nhân báo CPU hoặc tác vụ bị kẹt; trên VPS thường là do máy chủ vật lý quá tải.')"
    fi
    # Segfaults
    if [ "$_lxc_segv" -ge 10 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Program crashes (segfault)' 'Chương trình sập (segfault)')" "$(tf '%s segfault(s)' '%s lần segfault' "$_lxc_segv")" warn \
            "$(t 'A program crashed many times; update or reconfigure the one named in the log.' 'Một chương trình sập nhiều lần; cập nhật hoặc cấu hình lại chương trình nêu trong log.')"
    elif [ "$_lxc_segv" -ge 1 ]; then
        _lxc_any=1
        add_check crashes "$(t 'Program crashes (segfault)' 'Chương trình sập (segfault)')" "$(tf '%s segfault(s)' '%s lần segfault' "$_lxc_segv")" info
    fi

    if [ "$_lxc_any" = 0 ]; then
        add_check crashes "$(t 'Kernel & hardware errors' 'Lỗi nhân & phần cứng')" "$(tf 'none found (%s)' 'không phát hiện (%s)' "$_lxc_cov")" ok
    fi
    return 0
}

# ---------- updates & support ----------
lxo_eol_lookup() {
    # $1 id, $2 version_id, $3 NAME -> prints "YYYY-MM-DD" or empty
    _le_key=$1
    case "$1" in centos) case "$3" in *Stream*) _le_key=centos-stream ;; esac ;; esac
    case "$1" in
        ubuntu | alpine | opensuse-leap) _le_mver=$(printf '%s' "$2" | awk -F. '{ print $1 "." $2 }') ;;
        amzn) _le_mver=$2 ;;
        *) _le_mver=${2%%.*} ;;
    esac
    awk -F'|' -v id="$_le_key" -v ver="$_le_mver" '$1 == id && $2 == ver { print $3; exit }' <<'LXEOF'
almalinux|8|2029-05-31
almalinux|9|2032-05-31
almalinux|10|2035-05-31
rocky|8|2029-05-31
rocky|9|2032-05-31
rocky|10|2035-05-31
rhel|6|2020-11-30
rhel|7|2024-06-30
rhel|8|2029-05-31
rhel|9|2032-05-31
rhel|10|2035-05-31
centos|6|2020-11-30
centos|7|2024-06-30
centos|8|2021-12-31
centos-stream|8|2024-05-31
centos-stream|9|2027-05-31
centos-stream|10|2030-05-31
ol|6|2021-03-31
ol|7|2024-12-31
ol|8|2029-07-31
ol|9|2032-06-30
ol|10|2035-06-30
amzn|2018.03|2023-12-31
amzn|2|2026-06-30
amzn|2023|2029-06-30
ubuntu|14.04|2019-04-02
ubuntu|16.04|2021-04-02
ubuntu|18.04|2023-05-31
ubuntu|20.04|2025-05-31
ubuntu|22.04|2027-06-01
ubuntu|24.04|2029-05-31
ubuntu|24.10|2025-07-10
ubuntu|25.04|2026-01-17
ubuntu|25.10|2026-07-01
ubuntu|26.04|2031-05-29
debian|8|2020-06-30
debian|9|2022-07-01
debian|10|2024-06-30
debian|11|2026-08-31
debian|12|2028-06-30
debian|13|2030-06-30
fedora|41|2025-12-15
fedora|42|2026-05-27
fedora|43|2026-12-09
fedora|44|2027-06-02
alpine|3.18|2025-05-09
alpine|3.19|2025-11-01
alpine|3.20|2026-04-01
alpine|3.21|2026-11-01
alpine|3.22|2027-05-01
alpine|3.23|2027-11-01
alpine|3.24|2028-06-01
opensuse-leap|15.5|2024-12-31
opensuse-leap|15.6|2026-04-30
opensuse-leap|16.0|2027-10-31
LXEOF
}

lxo_days_until() {
    # $1 = YYYY-MM-DD -> days from today to that date (negative = past)
    awk -v d="$1" -v now="$BR_NOW" 'BEGIN {
        if (split(d, p, "-") != 3) exit
        y = p[1] + 0; m = p[2] + 0; dd = p[3] + 0
        if (m <= 2) { y--; m += 12 }
        n = 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + dd - 719469
        printf "%d", n - int(now / 86400)
    }'
}

lxo_eol() {
    # os-release SUPPORT_END overrides the table (Fedora, Amazon).
    _leo_end=
    _leo_osr="$BR_FSROOT/etc/os-release"
    [ -r "$_leo_osr" ] || _leo_osr="$BR_FSROOT/usr/lib/os-release"
    _leo_end=$(lxs_osr SUPPORT_END "$_leo_osr")
    case "$_leo_end" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) _leo_end= ;; esac
    [ -n "$_leo_end" ] || _leo_end=$(lxo_eol_lookup "$LX_ID" "$LX_VERSION_ID" "$LX_NAME")
    if [ -z "$_leo_end" ]; then
        add_check updates "$(t 'End of life' 'Hết vòng đời hỗ trợ')" "$(t 'not in the built-in table (assumed supported)' 'không có trong bảng tích hợp (giả định còn hỗ trợ)')" info
        return 0
    fi
    _leo_days=$(lxo_days_until "$_leo_end")
    is_int "${_leo_days#-}" || { add_check updates "$(t 'End of life' 'Hết vòng đời hỗ trợ')" "$_leo_end" info; return 0; }
    _leo_s=ok; _leo_note=
    if [ "$_leo_days" -lt 0 ]; then
        _leo_s=bad
        # Ubuntu with active ESM subscription downgrades to info.
        if [ "$LX_ID" = ubuntu ] && grep -q '"esm-infra"' "$BR_FSROOT/var/lib/ubuntu-advantage/status.json" 2>/dev/null && grep -q '"enabled": *true' "$BR_FSROOT/var/lib/ubuntu-advantage/status.json" 2>/dev/null; then
            _leo_s=info
            _leo_note=$(t 'Standard support has ended; security fixes now depend on the extended-maintenance subscription staying active.' 'Hỗ trợ tiêu chuẩn đã kết thúc; các bản vá bảo mật hiện phụ thuộc vào gói bảo trì mở rộng còn hiệu lực.')
        else
            _leo_note=$(t 'This release no longer receives security updates; upgrade or migrate to a supported release.' 'Phiên bản này không còn nhận cập nhật bảo mật; nâng cấp hoặc chuyển sang phiên bản còn hỗ trợ.')
        fi
        add_check updates "$(t 'End of life' 'Hết vòng đời hỗ trợ')" "$(tf 'reached EOL on %s' 'đã hết hỗ trợ ngày %s' "$_leo_end")" "$_leo_s" "$_leo_note"
    elif [ "$_leo_days" -le 90 ]; then
        add_check updates "$(t 'End of life' 'Hết vòng đời hỗ trợ')" "$(tf 'EOL on %s (%s days)' 'hết hỗ trợ ngày %s (%s ngày nữa)' "$_leo_end" "$_leo_days")" warn \
            "$(t 'This release reaches end of life within 90 days; plan the upgrade.' 'Phiên bản này sẽ hết hỗ trợ trong vòng 90 ngày; hãy lên kế hoạch nâng cấp.')"
    else
        add_check updates "$(t 'End of life' 'Hết vòng đời hỗ trợ')" "$(tf 'supported until %s' 'được hỗ trợ đến %s' "$_leo_end")" ok
    fi
    return 0
}

lx_updates() {
    lxo_eol
    lxo_update_age

    # Pending updates (cache-only, bounded). The slow managers are skipped in quick mode.
    _lxu_sec=0; _lxu_cnt=-1; _lxu_err=0
    if [ "$LX_FAMILY" = debian ] && have apt-get; then
        [ "$BR_QUICK" = 1 ] && return 0
        LC_ALL=C run_to 60 apt-get -s -o Debug::NoLocking=true dist-upgrade >"$BR_TMP/lxapt" 2>&1
        _lxu_r=$(awk '
            /^E: / { err = 1 }
            /^Inst / { if ($3 ~ /^\[/) { up++; if ($0 ~ /Debian-Security:|-security[] ,]/) sec++ } }
            / upgraded, .* newly installed, / { ok = 1 }
            END { printf "%d|%d|%d", (ok ? up + 0 : -1), sec + 0, err }' "$BR_TMP/lxapt")
        _lxu_cnt=${_lxu_r%%|*}; _lxu_rest=${_lxu_r#*|}
        _lxu_sec=${_lxu_rest%%|*}; _lxu_err=${_lxu_rest#*|}
    elif [ "$LX_FAMILY" = rhel ] && { have dnf || have yum; }; then
        [ "$BR_QUICK" = 1 ] && return 0
        _lxu_pm=yum; have dnf && _lxu_pm=dnf
        run_to 45 "$_lxu_pm" -C -q check-update >"$BR_TMP/lxrpmu" 2>/dev/null
        _lxu_rc=$?
        if [ "$_lxu_rc" = 100 ]; then
            _lxu_cnt=$(awk '/^Obsoleting Packages/ { exit } /^[^ \t]/ && $1 ~ /\.(x86_64|i686|i386|noarch|aarch64|ppc64le|s390x|armv7hl|riscv64|src)$/ { n++ } END { print n + 0 }' "$BR_TMP/lxrpmu")
        elif [ "$_lxu_rc" = 0 ]; then
            _lxu_cnt=0
        fi
        run_to 45 "$_lxu_pm" -C -q updateinfo list --security >"$BR_TMP/lxrpmsec" 2>/dev/null
        [ -s "$BR_TMP/lxrpmsec" ] || run_to 45 "$_lxu_pm" -C -q updateinfo list security >"$BR_TMP/lxrpmsec" 2>/dev/null
        _lxu_sec=$(awk '
            $2 ~ /\/Sec\.$/ { pkg = $3 } $2 == "security" { pkg = $4 }
            pkg != "" { if (!(pkg in seen)) { seen[pkg] = 1; total++ } pkg = "" }
            END { print total + 0 }' "$BR_TMP/lxrpmsec")
    elif [ "$LX_FAMILY" = alpine ] && have apk; then
        _lxu_cnt=$(run_to 15 apk --no-network version -l '<' 2>/dev/null | awk '$2 == "<" { n++ } END { print n + 0 }')
    elif [ "$LX_FAMILY" = arch ] && have pacman; then
        _lxu_cnt=$(run_to 15 pacman -Qu 2>/dev/null | awk '$3 == "->" { n++ } END { print n + 0 }')
    elif [ "$LX_FAMILY" = suse ] && have zypper; then
        [ "$BR_QUICK" = 1 ] && return 0
        _lxu_r=$(run_to 30 zypper --no-refresh --non-interactive patch-check 2>/dev/null | awk '/patch(es)? needed/ { s = $4; sub(/^\(/, "", s); print $1 + 0 "|" s + 0 }')
        _lxu_cnt=${_lxu_r%%|*}; _lxu_sec=${_lxu_r#*|}
        case "$_lxu_cnt" in '' | *[!0-9]*) _lxu_cnt=-1 ;; esac
        case "$_lxu_sec" in '' | *[!0-9]*) _lxu_sec=0 ;; esac
    fi

    is_int "$_lxu_sec" || _lxu_sec=0
    if [ "$_lxu_err" = 1 ]; then
        add_check updates "$(t 'Package database' 'Cơ sở dữ liệu gói')" "$(t 'apt reported an error (interrupted dpkg or unmet dependencies)' 'apt báo lỗi (dpkg bị gián đoạn hoặc thiếu phụ thuộc)')" bad \
            "$(t 'Run dpkg --configure -a or apt-get -f install to repair the package system.' 'Chạy dpkg --configure -a hoặc apt-get -f install để sửa hệ thống gói.')"
    fi
    if [ "$_lxu_cnt" = -1 ] && [ "$_lxu_err" != 1 ]; then
        add_check updates "$(t 'Pending updates' 'Bản cập nhật đang chờ')" "$(t 'could not be determined' 'không xác định được')" info
    elif [ "$_lxu_sec" -ge 1 ]; then
        add_check updates "$(t 'Pending updates' 'Bản cập nhật đang chờ')" \
            "$(tf '%s security, %s total' '%s bảo mật, %s tổng cộng' "$_lxu_sec" "$([ "$_lxu_cnt" -ge 0 ] 2>/dev/null && printf '%s' "$_lxu_cnt" || printf '?')")" warn \
            "$(t 'Security updates are waiting; install them with the package manager and reboot if a kernel is included.' 'Có bản vá bảo mật đang chờ; cài bằng trình quản lý gói và khởi động lại nếu có nhân mới.')"
    elif [ "$_lxu_cnt" -ge 1 ] 2>/dev/null; then
        add_check updates "$(t 'Pending updates' 'Bản cập nhật đang chờ')" "$(tf '%s update(s) available' 'có %s bản cập nhật' "$_lxu_cnt")" info
    elif [ "$_lxu_cnt" = 0 ]; then
        add_check updates "$(t 'Pending updates' 'Bản cập nhật đang chờ')" "$(t 'up to date (from cache)' 'đã cập nhật (theo cache)')" ok
    fi
    return 0
}

lxo_update_age() {
    case "$LX_FAMILY" in
        debian) _lua_f="$BR_FSROOT/var/lib/dpkg/status" ;;
        rhel | suse) _lua_f="$BR_FSROOT/var/lib/rpm" ;;
        alpine) _lua_f="$BR_FSROOT/lib/apk/db/installed" ;;
        arch) _lua_f="$BR_FSROOT/var/log/pacman.log" ;;
        *) return 0 ;;
    esac
    [ -e "$_lua_f" ] || return 0
    _lua_m=$(stat -c %Y "$_lua_f" 2>/dev/null) || _lua_m=$(date -r "$_lua_f" +%s 2>/dev/null)
    is_int "$_lua_m" || return 0
    _lua_days=$(( (BR_NOW - _lua_m) / 86400 ))
    [ "$_lua_days" -lt 0 ] && return 0
    _lua_s=ok
    if [ "$_lua_days" -gt 365 ]; then _lua_s=bad
    elif [ "$_lua_days" -gt 90 ]; then _lua_s=warn; fi
    if [ "$_lua_s" = ok ]; then return 0; fi
    add_check updates "$(t 'Time since last update' 'Thời gian từ lần cập nhật cuối')" \
        "$(tf 'about %s days ago' 'khoảng %s ngày trước' "$_lua_days")" "$_lua_s" \
        "$([ "$_lua_s" = warn ] && t 'No package has been updated for over 90 days; check that updates still work and are being applied.' 'Hơn 90 ngày chưa cập nhật gói nào; kiểm tra xem cập nhật còn hoạt động và đang được áp dụng không.'; [ "$_lua_s" = bad ] && t 'Security updates have not been applied for months; update the system now.' 'Đã nhiều tháng chưa áp dụng cập nhật bảo mật; hãy cập nhật hệ thống ngay.')"
    return 0
}

# ---------- security ----------
lx_security() {
    lxo_sshd
    lxo_ssh_logins
    lxo_firewall
    lxo_selinux
    lxo_clocksync
    lxo_accounts
    return 0
}

lxo_sshd_src() {
    # Emit effective sshd settings as "key value" lines from sshd -T or the config files.
    if [ "$BR_ROOT" = 1 ]; then
        _lss_bin=$(command -v sshd 2>/dev/null)
        for _lss_c in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd; do
            [ -n "$_lss_bin" ] && break
            [ -x "$_lss_c" ] && _lss_bin=$_lss_c
        done
        if [ -n "$_lss_bin" ]; then
            run_to 5 "$_lss_bin" -T 2>/dev/null
            return 0
        fi
    fi
    # File fallback (one level of Include expansion).
    _lss_dir="$BR_FSROOT/etc/ssh"
    [ -r "$_lss_dir/sshd_config" ] || return 0
    lxo_sshd_flatten "$_lss_dir/sshd_config" 0
    return 0
}

lxo_sshd_flatten() {
    [ "${2:-0}" -le 3 ] || return 0
    [ -r "$1" ] || return 0
    while IFS= read -r _lsf_l || [ -n "$_lsf_l" ]; do
        case "$_lsf_l" in
            *[Ii]nclude*)
                _lsf_g=$(printf '%s\n' "$_lsf_l" | awk -v dir="$_lss_dir" '{ k = tolower($1); if (k != "include") { print; exit } sub(/^[ \t]*[^ \t]+[ \t]+/, ""); gsub(/"/, ""); n = split($0, a, /[ \t]+/); for (i = 1; i <= n; i++) if (a[i] != "") print (a[i] ~ /^\// ? a[i] : dir "/" a[i]) }')
                case "$_lsf_g" in
                    "$_lsf_l") printf '%s\n' "$_lsf_l" ;;
                    *) for _lsf_i in $_lsf_g; do [ -f "$_lsf_i" ] && lxo_sshd_flatten "$_lsf_i" "$(( ${2:-0} + 1 ))"; done ;;
                esac
                ;;
            *) printf '%s\n' "$_lsf_l" ;;
        esac
    done <"$1"
}

lxo_sshd() {
    lxo_sshd_src >"$BR_TMP/lxssh" 2>/dev/null
    if [ ! -s "$BR_TMP/lxssh" ]; then
        add_check security "$(t 'SSH configuration' 'Cấu hình SSH')" "$(t 'could not be read (needs root)' 'không đọc được (cần root)')" info
        return 0
    fi
    _lxs_r=$(awk '
        { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
          if (line == "" || line ~ /^#/) next
          k = line; sub(/[ \t=].*$/, "", k); k = tolower(k)
          v = line; sub(/^[^ \t=]+[ \t]*=?[ \t]*/, "", v); gsub(/"/, "", v); sub(/[ \t].*$/, "", v)
          if (k == "match") { inmatch = 1; next }
          if (inmatch) next
          if (k == "challengeresponseauthentication") k = "kbdinteractiveauthentication"
          if (!(k in val)) val[k] = tolower(v)
        }
        END {
            # Apply OpenSSH compiled defaults to keys not set in the file. "sshd -T" always prints every
            # setting, so this only fills gaps on the non-root config-parse path, where an unset
            # PasswordAuthentication means "yes" (enabled) - not "off".
            r = val["permitrootlogin"]; if (r == "") r = "prohibit-password"; if (r == "without-password") r = "prohibit-password"
            pw = val["passwordauthentication"]; if (pw == "") pw = "yes"
            em = val["permitemptypasswords"]; if (em == "") em = "no"
            printf "%s|%s|%s", r, pw, em
        }' "$BR_TMP/lxssh")
    _lxs_root=${_lxs_r%%|*}; _lxs_rest=${_lxs_r#*|}
    _lxs_pw=${_lxs_rest%%|*}; _lxs_empty=${_lxs_rest#*|}
    _lxs_s=ok; _lxs_val=
    if [ "$_lxs_empty" = yes ]; then
        _lxs_s=bad
        _lxs_val=$(t 'empty passwords allowed' 'cho phép mật khẩu rỗng')
    elif [ "$_lxs_root" = yes ] && [ "$_lxs_pw" = yes ]; then
        _lxs_s=warn
        _lxs_val=$(t 'root may log in with a password' 'root có thể đăng nhập bằng mật khẩu')
    elif [ "$_lxs_pw" = yes ]; then
        _lxs_s=info
        _lxs_val=$(t 'password login enabled, root restricted' 'cho phép đăng nhập mật khẩu, root bị hạn chế')
    else
        _lxs_s=ok
        _lxs_val=$(t 'key-based login (password login off)' 'đăng nhập bằng khóa (tắt mật khẩu)')
    fi
    add_check security "$(t 'SSH configuration' 'Cấu hình SSH')" "$_lxs_val" "$_lxs_s" \
        "$([ "$_lxs_s" = warn ] && t 'Root can log in with a password; switch to SSH keys and set PermitRootLogin prohibit-password.' 'Root có thể đăng nhập bằng mật khẩu; chuyển sang khóa SSH và đặt PermitRootLogin prohibit-password.'; [ "$_lxs_s" = bad ] && t 'SSH accepts empty passwords; set PermitEmptyPasswords no and give every account a password or lock it.' 'SSH chấp nhận mật khẩu rỗng; đặt PermitEmptyPasswords no và đặt mật khẩu hoặc khóa mọi tài khoản.'; [ "$_lxs_s" = info ] && t 'Password logins are allowed and nothing blocks repeated failures; prefer keys or install fail2ban.' 'Cho phép đăng nhập bằng mật khẩu và không có gì chặn thử sai liên tục; nên dùng khóa hoặc cài fail2ban.')"
    return 0
}

lxo_ssh_logins() {
    [ "$LX_INIT" = systemd ] && have journalctl || return 0
    lxo_journal_ok 2>/dev/null
    [ "$_lxc_jok" = 1 ] || { _lxc_jok=0; }
    if [ "$_lxc_jok" != 1 ]; then
        add_check security "$(t 'Failed SSH logins' 'Đăng nhập SSH thất bại')" "$(t 'not checked (needs root or journal access)' 'chưa kiểm tra (cần root hoặc quyền đọc journal)')" info
        return 0
    fi
    _lxsl_n=$(run_to 20 journalctl -q --no-pager -o short-iso -t sshd -t sshd-session -t sshd-auth --since "$BR_DAYS days ago" 2>/dev/null | head -n 200000 |
        awk '/Failed password for / || /Invalid user .* from / { n++ } END { print n + 0 }')
    is_int "$_lxsl_n" || _lxsl_n=0
    add_check security "$(t 'Failed SSH logins' 'Đăng nhập SSH thất bại')" \
        "$(tf '%s attempts in the last %s days' '%s lượt thử trong %s ngày qua' "$_lxsl_n" "$BR_DAYS")" info \
        "$(t 'Automated login attempts are normal on a public server; they matter only if password login is enabled.' 'Các lượt thử đăng nhập tự động là bình thường trên máy chủ công khai; chỉ đáng lo khi còn cho đăng nhập bằng mật khẩu.')"
    return 0
}

lxo_firewall() {
    _lxf_active=
    if [ "$LX_INIT" = systemd ] && have systemctl; then
        _lxf_active=$(run_to 5 systemctl is-active firewalld nftables iptables ip6tables ufw csf 2>/dev/null | grep -c '^active')
    fi
    if [ -n "$_lxf_active" ] && [ "$_lxf_active" -ge 1 ] 2>/dev/null; then
        add_check security "$(t 'Firewall' 'Tường lửa')" "$(t 'active' 'đang bật')" ok
    elif [ "$BR_ROOT" = 1 ]; then
        add_check security "$(t 'Firewall' 'Tường lửa')" "$(t 'no host firewall detected' 'không phát hiện tường lửa trên máy')" info \
            "$(t 'No host firewall is active; a provider security group may still protect this machine. Enable firewalld, ufw or nftables and allow only what you need.' 'Không có tường lửa nào đang bật trên máy; nhóm bảo mật của nhà cung cấp vẫn có thể đang bảo vệ. Bật firewalld, ufw hoặc nftables và chỉ mở những gì cần.')"
    else
        add_check security "$(t 'Firewall' 'Tường lửa')" "$(t 'could not be read without root' 'không đọc được nếu không có root')" info
    fi
    return 0
}

lxo_selinux() {
    _lxse_mode=
    if [ -r "$BR_FSROOT/sys/fs/selinux/enforce" ]; then
        case "$(read_file "$BR_FSROOT/sys/fs/selinux/enforce")" in 1) _lxse_mode=Enforcing ;; 0) _lxse_mode=Permissive ;; esac
    elif have getenforce; then
        _lxse_mode=$(run_to 5 getenforce 2>/dev/null)
    fi
    if [ -n "$_lxse_mode" ]; then
        add_check security "SELinux" "$_lxse_mode" info
    else
        # AppArmor (Debian family and others).
        _lxse_aa=$(read_file "$BR_FSROOT/sys/module/apparmor/parameters/enabled")
        case "$_lxse_aa" in
            Y | 1) add_check security "AppArmor" "$(t 'enabled' 'đang bật')" info ;;
            N | 0) add_check security "AppArmor" "$(t 'disabled' 'đang tắt')" info ;;
        esac
    fi
    return 0
}

lxo_clocksync() {
    _lxck_sync=
    if [ "$LX_INIT" = systemd ] && have timedatectl; then
        _lxck_sync=$(run_to 5 timedatectl 2>/dev/null | awk -F': *' '/NTP synchronized:|System clock synchronized:/ { print $2; exit }')
    fi
    if [ -z "$_lxck_sync" ] && have chronyc; then
        _lxck_leap=$(run_to 5 chronyc -n tracking 2>/dev/null | awk -F' *: *' '/^Leap status/ { print $2; exit }')
        case "$_lxck_leap" in Normal) _lxck_sync=yes ;; "") ;; *) _lxck_sync=no ;; esac
    fi
    [ -n "$_lxck_sync" ] || return 0
    _lxck_up=$(awk '{ print int($1); exit }' "$BR_FSROOT/proc/uptime" 2>/dev/null)
    is_int "$_lxck_up" || _lxck_up=0
    case "$_lxck_sync" in
        yes | Yes | YES)
            add_check security "$(t 'Clock synchronization' 'Đồng bộ đồng hồ')" "$(t 'synchronized' 'đã đồng bộ')" ok ;;
        *)
            if [ "$LX_CONTAINER" != 1 ] && [ "$_lxck_up" -gt 1200 ]; then
                add_check security "$(t 'Clock synchronization' 'Đồng bộ đồng hồ')" "$(t 'not synchronized' 'chưa đồng bộ')" warn \
                    "$(t 'The clock is not synchronized; enable chrony or systemd-timesyncd.' 'Đồng hồ chưa được đồng bộ; bật chrony hoặc systemd-timesyncd.')"
            else
                add_check security "$(t 'Clock synchronization' 'Đồng bộ đồng hồ')" "$(t 'not synchronized (recently booted or container)' 'chưa đồng bộ (vừa khởi động hoặc trong container)')" info
            fi
            ;;
    esac
    return 0
}

lxo_accounts() {
    # Extra UID 0 accounts (world-readable passwd).
    if [ -r "$BR_FSROOT/etc/passwd" ]; then
        _lxa_u=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' "$BR_FSROOT/etc/passwd" 2>/dev/null | awk 'BEGIN { ORS = " " } { print }')
        if [ -n "$_lxa_u" ]; then
            add_check security "$(t 'Extra root accounts' 'Tài khoản root thừa')" "$(tf 'UID 0 also used by: %s' 'UID 0 còn dùng bởi: %s' "$_lxa_u")" bad \
                "$(t 'Another account has root user ID; remove it or change its UID unless you created it on purpose.' 'Một tài khoản khác có UID của root; xóa hoặc đổi UID trừ khi bạn cố ý tạo.')"
        fi
    fi
    # Empty-password accounts (root only; shadow is root-readable).
    if [ "$BR_ROOT" = 1 ] && [ -r "$BR_FSROOT/etc/shadow" ]; then
        _lxa_e=$(awk -F: '($2 == "" ) { print $1 }' "$BR_FSROOT/etc/shadow" 2>/dev/null | awk 'BEGIN { ORS = " " } { print }')
        if [ -n "$_lxa_e" ]; then
            add_check security "$(t 'Empty-password accounts' 'Tài khoản mật khẩu rỗng')" "$(tf 'no password set: %s' 'chưa đặt mật khẩu: %s' "$_lxa_e")" bad \
                "$(t 'An account has no password; lock it or set one.' 'Một tài khoản không có mật khẩu; khóa lại hoặc đặt mật khẩu.')"
        fi
    fi
    return 0
}

# ---------- macOS collector / Bo thu thap macOS ----------
# Darwin 11 (Big Sur) .. 27 (Golden Gate), Intel and Apple Silicon. Strictly read-only, no network,
# no command that can prompt (no sudo / tmutil latestbackup / log show by default). BSD userland,
# bash 3.2 /bin/sh, no timeout(1) -> everything slow goes through run_to (core's pure-sh watchdog).
# Private helpers are prefixed mc_ ; every function returns 0 and is safe to call on its own.
# All ioreg battery keys are private API and optional (see research/macos.md); a missing probe or a
# TCC/permission denial becomes an info check or is skipped, never an error and never a false "ok".

# Shared state set by mc_ident and read by the later functions.
MC_ARCH=
MC_IS_AS=0
MC_OS_VER=
MC_OS_BUILD=
MC_OS_MAJOR=
MC_NCPU=
MC_MEM_KB=
MC_HAS_BATTERY=0
# Firewall helper lives in a sub-directory, so it is reached by full path, not PATH. BR_FSROOT lets
# the fixtures place a shim there in tests; it is empty in normal use (real /usr/libexec binary).
MC_ALF=/usr/libexec/ApplicationFirewall/socketfilterfw

# mc_kv KEY FILE -> the value column of a "KEY VALUE" line (first match), empty otherwise.
mc_kv() { awk -v k="$1" '$1 == k { print $2; exit }' "$2" 2>/dev/null; }

# mc_str2epoch "YYYY-MM-DD HH:MM:SS" -> epoch seconds (UTC). BSD date needs -j (never set the clock).
mc_str2epoch() { date -j -u -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null; }

collect_macos() {
    # sysctl prints locale decimals and Apple awk aborts on invalid UTF-8 in a UTF-8 locale; force C.
    LC_ALL=C
    LANG=C
    export LC_ALL LANG
    # Big Sur under SYSTEM_VERSION_COMPAT reports 10.16; drop it so sw_vers is truthful.
    unset SYSTEM_VERSION_COMPAT 2>/dev/null || :
    # Put Apple's own tools first, but only in production: in tests BR_FSROOT is set and the mock PATH
    # (BSD date/find/stat/uname shims) must stay in front, so skip the reorder then.
    if [ -z "$BR_FSROOT" ]; then
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec:$PATH
        export PATH
    fi

    mc_ident
    mc_battery
    mc_disk
    mc_memory
    mc_cpu
    mc_crashes
    mc_security
    mc_updates
    mc_apps
    return 0
}

# ---------- Identification, architecture, uptime ----------
mc_ident() {
    _mci_sw=$(run_to 5 sw_vers 2>/dev/null)
    MC_OS_VER=$(printf '%s\n' "$_mci_sw" | awk -F: '$1 == "ProductVersion" { v = $0; sub(/^[^:]*:[ \t]*/, "", v); print v; exit }')
    MC_OS_BUILD=$(printf '%s\n' "$_mci_sw" | awk -F: '$1 == "BuildVersion" { v = $0; sub(/^[^:]*:[ \t]*/, "", v); print v; exit }')
    _mci_extra=$(printf '%s\n' "$_mci_sw" | awk -F: '$1 == "ProductVersionExtra" { v = $0; sub(/^[^:]*:[ \t]*/, "", v); print v; exit }')
    # Fallbacks when sw_vers is unavailable.
    [ -n "$MC_OS_VER" ] || MC_OS_VER=$(sysctl -n kern.osproductversion 2>/dev/null)
    [ -n "$MC_OS_BUILD" ] || MC_OS_BUILD=$(sysctl -n kern.osversion 2>/dev/null)

    _mci_darwin=$(uname -r 2>/dev/null)
    MC_OS_MAJOR=${MC_OS_VER%%.*}
    # Majors are NOT contiguous (15 -> 26). Map the known compat quirks, then the Darwin fallback.
    case "$MC_OS_VER" in
        10.16*) MC_OS_MAJOR=11 ;;
        16.*) MC_OS_MAJOR=26 ;;
    esac
    if ! is_int "$MC_OS_MAJOR"; then
        _mci_dmaj=${_mci_darwin%%.*}
        if is_int "$_mci_dmaj"; then
            if [ "$_mci_dmaj" -ge 25 ]; then MC_OS_MAJOR=$((_mci_dmaj + 1))
            elif [ "$_mci_dmaj" -ge 20 ]; then MC_OS_MAJOR=$((_mci_dmaj - 9)); fi
        fi
    fi

    MC_ARCH=$(uname -m 2>/dev/null)
    _mci_arm=$(sysctl -n hw.optional.arm64 2>/dev/null)
    # arm64 even under Rosetta (uname -m may lie as x86_64); hw.optional.arm64 is authoritative.
    if [ "$_mci_arm" = 1 ] || [ "$MC_ARCH" = arm64 ]; then MC_IS_AS=1; fi

    if [ -n "$MC_OS_VER" ]; then
        BR_OS_LABEL="macOS $MC_OS_VER${_mci_extra:+ $_mci_extra}${MC_OS_BUILD:+ ($MC_OS_BUILD)}"
    else
        BR_OS_LABEL="macOS"
    fi

    # Marketing model name without a slow system_profiler call (Apple Silicon only carries it here;
    # on Intel this is just the identifier, so fall back to hw.model).
    _mci_model=$(run_to 5 ioreg -p IODeviceTree -r -d 1 -n product -w 0 2>/dev/null |
        sed -n 's/.*"product-name" = <"\([^"]*\)">.*/\1/p' | head -n 1)
    _mci_hwmodel=$(sysctl -n hw.model 2>/dev/null)
    # A model identifier (MacBookPro12,1 / Mac14,2) has no space; a marketing name always does
    # (and may contain a comma, e.g. "MacBook Pro (14-inch, 2023)"). Keep anything with a space;
    # fall back to hw.model only when empty or a bare identifier.
    case "$_mci_model" in *' '*) ;; *) _mci_model=$_mci_hwmodel ;; esac
    _mci_chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    MC_NCPU=$(sysctl -n hw.logicalcpu 2>/dev/null)
    is_int "$MC_NCPU" || MC_NCPU=1
    _mci_phys=$(sysctl -n hw.physicalcpu 2>/dev/null)
    _mci_memb=$(sysctl -n hw.memsize 2>/dev/null)
    if is_int "$_mci_memb"; then MC_MEM_KB=$((_mci_memb / 1024)); else MC_MEM_KB=; fi

    add_info "$(t 'Operating system' 'Hệ điều hành')" "$BR_OS_LABEL"
    [ -n "$_mci_darwin" ] && add_info "$(t 'Kernel' 'Nhân (kernel)')" "Darwin $_mci_darwin"
    if [ "$MC_IS_AS" = 1 ]; then
        add_info "$(t 'Architecture' 'Kiến trúc')" "$(t 'Apple Silicon' 'Apple Silicon') (${MC_ARCH:-arm64})"
    else
        add_info "$(t 'Architecture' 'Kiến trúc')" "Intel (${MC_ARCH:-x86_64})"
    fi
    add_info "$(t 'Model' 'Dòng máy')" "$_mci_model"
    add_info "$(t 'Chip / CPU' 'Chip / CPU')" "$_mci_chip"
    # P/E core split on Apple Silicon (OID is absent on Intel).
    _mci_pcore=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)
    _mci_ecore=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null)
    if is_int "$_mci_pcore" && is_int "$_mci_ecore"; then
        add_info "$(t 'CPU cores' 'Số nhân CPU')" "$(tf '%s logical (%sP + %sE)' '%s luồng (%sP + %sE)' "$MC_NCPU" "$_mci_pcore" "$_mci_ecore")"
    elif is_int "$_mci_phys"; then
        add_info "$(t 'CPU cores' 'Số nhân CPU')" "$(tf '%s logical, %s physical' '%s luồng, %s nhân vật lý' "$MC_NCPU" "$_mci_phys")"
    fi
    [ -n "$MC_MEM_KB" ] && add_info "$(t 'Memory' 'Bộ nhớ')" "$(human_kb "$MC_MEM_KB")"

    # Uptime from kern.boottime (wall-clock based; includes sleep). Days since restart is info only.
    _mci_boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9][0-9]*\),.*/\1/p')
    if is_int "$_mci_boot" && is_int "$BR_NOW" && [ "$BR_NOW" -gt "$_mci_boot" ]; then
        _mci_up=$((BR_NOW - _mci_boot))
        _mci_days=$((_mci_up / 86400))
        _mci_hrs=$(((_mci_up % 86400) / 3600))
        if [ "$_mci_days" -ge 1 ]; then
            _mci_uptxt="$(tf '%s day(s), %s h' '%s ngày, %s giờ' "$_mci_days" "$_mci_hrs")"
            _mci_tile="$(tf '%sd' '%s ngày' "$_mci_days")"
        else
            _mci_mins=$(((_mci_up % 3600) / 60))
            _mci_uptxt="$(tf '%s h %s min' '%s giờ %s phút' "$_mci_hrs" "$_mci_mins")"
            _mci_tile="$(tf '%sh' '%s giờ' "$_mci_hrs")"
        fi
        _mci_bootstr=$(fmt_epoch "$_mci_boot" '%Y-%m-%d %H:%M')
        add_check boot "$(t 'Days since restart' 'Thời gian kể từ lần khởi động lại')" \
            "$_mci_uptxt${_mci_bootstr:+ ($(t 'since' 'từ') $_mci_bootstr)}" info
        add_stat "$_mci_tile" "$(t 'uptime' 'thời gian chạy')"
    fi

    # macOS release support window (data-driven; update yearly). On 2026-10-08: 27, 26, 15 supported.
    if is_int "$MC_OS_MAJOR"; then
        if [ "$MC_OS_MAJOR" -ge 26 ] || [ "$MC_OS_MAJOR" = 15 ]; then
            add_check updates "$(t 'macOS release supported' 'Phiên bản macOS còn hỗ trợ')" \
                "$(tf 'macOS %s (current)' 'macOS %s (còn hỗ trợ)' "$MC_OS_MAJOR")" ok
        elif [ "$MC_OS_MAJOR" = 14 ]; then
            add_check updates "$(t 'macOS release supported' 'Phiên bản macOS còn hỗ trợ')" \
                "$(tf 'macOS %s (one release behind)' 'macOS %s (cũ hơn một đời)' "$MC_OS_MAJOR")" warn \
                "$(t 'This macOS version has just left Apple security updates; upgrade if the Mac supports a newer one.' 'Phiên bản macOS này vừa hết hạn nhận bản vá bảo mật của Apple; nâng cấp nếu máy hỗ trợ đời mới hơn.')"
        else
            add_check updates "$(t 'macOS release supported' 'Phiên bản macOS còn hỗ trợ')" \
                "$(tf 'macOS %s (unsupported)' 'macOS %s (hết hỗ trợ)' "$MC_OS_MAJOR")" bad \
                "$(t 'This macOS version no longer receives security updates; upgrade, or avoid sensitive use on this Mac.' 'Phiên bản macOS này không còn nhận bản vá bảo mật; hãy nâng cấp, hoặc tránh dùng cho việc nhạy cảm trên máy này.')"
        fi
    fi
    return 0
}

# ---------- Battery panel, health, power source ----------
mc_battery() {
    _mcb_kv=$BR_TMP/mc_batt.kv
    : >"$_mcb_kv"
    # ioreg is the no-root source. -w 0 stops clipping; AppleSmartBattery lines can be 8 KB long.
    run_to 5 ioreg -r -l -w 0 -n AppleSmartBattery 2>/dev/null >"$BR_TMP/mc_batt.raw"
    # Parse only the top-level AppleSmartBattery node. macOS 27 adds child nodes with a "  |   " tree
    # prefix and duplicate keys, and nested dicts use "key"=value (no spaces) which we must ignore.
    # ioreg prints negative ints as unsigned 64-bit; recover small negatives with the digit-tail trick.
    awk '
        BEGIN {
            n = split("CurrentCapacity MaxCapacity AppleRawCurrentCapacity AppleRawMaxCapacity DesignCapacity NominalChargeCapacity CycleCount DesignCycleCount9C Temperature VirtualTemperature IsCharging ExternalConnected BatteryInstalled PermanentFailureStatus", w, " ")
            for (i = 1; i <= n; i++) want[w[i]] = 1
            node = 0
        }
        /\+-o AppleSmartBattery  </ { node++; next }
        node == 1 {
            line = $0
            sub(/^[ |]*/, "", line)
            if (substr(line, 1, 1) != "\"") next
            rest = substr(line, 2); q = index(rest, "\"")
            if (q == 0) next
            key = substr(rest, 1, q - 1)
            if (!(key in want) || (key in seen)) next
            val = substr(rest, q + 1)
            if (substr(val, 1, 3) != " = ") next
            val = substr(val, 4); gsub(/^"|"$/, "", val)
            if (val ~ /^18446744073709[0-9][0-9][0-9][0-9][0-9][0-9]$/) val = "-" (551616 - substr(val, 15) + 0)
            seen[key] = 1; print key " " val
        }
    ' "$BR_TMP/mc_batt.raw" >"$_mcb_kv" 2>/dev/null

    _mcb_installed=$(mc_kv BatteryInstalled "$_mcb_kv")
    _mcb_design=$(mc_kv DesignCapacity "$_mcb_kv")
    if [ "$_mcb_installed" = Yes ] || is_int "$_mcb_design"; then MC_HAS_BATTERY=1; fi

    # Power source line (pmset -g ps). Neutral info check, required on every platform.
    _mcb_ps=$(run_to 5 pmset -g ps 2>/dev/null | sed -n "s/^Now drawing from '\(.*\)'.*/\1/p" | head -n 1)
    if [ "$MC_HAS_BATTERY" = 1 ]; then
        case "$_mcb_ps" in
            *Battery*) add_check battery "$(t 'Power source' 'Nguồn điện')" "$(t 'Running on battery' 'Đang chạy bằng pin')" info ;;
            *) add_check battery "$(t 'Power source' 'Nguồn điện')" "$(t 'On AC power (plugged in)' 'Đang cắm điện (AC)')" info ;;
        esac
    else
        # No battery node + AC source = a desktop Mac. Say so rather than leaving the panel blank.
        add_check battery "$(t 'Power source' 'Nguồn điện')" \
            "$(t 'Direct AC power (desktop, no battery)' 'Nguồn điện trực tiếp (máy bàn, không có pin)')" info
        add_stat "AC" "$(t 'power' 'nguồn điện')"
        return 0
    fi

    _mcb_rawmax=$(mc_kv AppleRawMaxCapacity "$_mcb_kv")
    _mcb_maxcap=$(mc_kv MaxCapacity "$_mcb_kv")
    # rawmax (mAh) on both arches; on Intel MaxCapacity is also mAh (> 100), on AS MaxCapacity is 100.
    if ! is_int "$_mcb_rawmax"; then
        if is_int "$_mcb_maxcap" && [ "$_mcb_maxcap" -gt 100 ]; then _mcb_rawmax=$_mcb_maxcap; else _mcb_rawmax=; fi
    fi

    _mcb_st=ok
    _mcb_health=
    if is_int "$_mcb_rawmax" && is_int "$_mcb_design" && [ "$_mcb_design" -gt 0 ]; then
        _mcb_health=$(pct "$_mcb_rawmax" "$_mcb_design")
    fi
    # Cycles, condition and permanent failure fold into ONE composite status (never triple-count).
    _mcb_cycles=$(mc_kv CycleCount "$_mcb_kv")
    _mcb_dcyc=$(mc_kv DesignCycleCount9C "$_mcb_kv")
    is_int "$_mcb_dcyc" || _mcb_dcyc=1000
    _mcb_pf=$(mc_kv PermanentFailureStatus "$_mcb_kv")

    _mcb_note=
    if is_int "$_mcb_health"; then
        _mcb_capst=$(grade_low "$_mcb_health" 80 60)
        case "$_mcb_capst" in
            bad) _mcb_st=bad; _mcb_note=$(t 'The battery is heavily worn; have it serviced.' 'Pin đã chai nặng; nên mang đi bảo hành/thay thế.') ;;
            warn) _mcb_st=warn; _mcb_note=$(t 'The battery holds less charge than when new; it is safe to use and Apple can replace it if runtime is too short.' 'Pin giữ điện kém hơn lúc mới; vẫn dùng an toàn, có thể thay nếu thời lượng quá ngắn.') ;;
        esac
    fi
    if is_int "$_mcb_cycles" && [ "$_mcb_cycles" -ge "$_mcb_dcyc" ]; then
        [ "$_mcb_st" = bad ] || _mcb_st=warn
        [ -n "$_mcb_note" ] || _mcb_note=$(t 'The battery has reached its designed cycle count; expect capacity to keep dropping.' 'Pin đã đạt số chu kỳ thiết kế; dung lượng sẽ tiếp tục giảm.')
    fi
    if is_int "$_mcb_pf" && [ "$_mcb_pf" -ne 0 ]; then
        _mcb_st=bad
        _mcb_note=$(t 'The battery reports a permanent failure; have it serviced.' 'Pin báo lỗi vĩnh viễn; cần mang đi bảo hành.')
    fi

    # Display health is capped at 100 (a new pack can read > 100).
    _mcb_disp=$_mcb_health
    if is_int "$_mcb_health" && [ "$_mcb_health" -gt 100 ]; then _mcb_disp=100; fi

    # Charge state and SoC for display come from pmset (what the UI shows).
    _mcb_pm=$(run_to 5 pmset -g batt 2>/dev/null | awk '
        BEGIN { FS = "\t" }
        /-InternalBattery/ {
            s = $2
            pct = s; sub(/%.*/, "", pct)
            sub(/^[0-9]+%; /, "", s); sub(/ present: (true|false).*$/, "", s)
            rem = ""
            if (match(s, /; [0-9]+:[0-9][0-9] remaining/)) { rem = substr(s, RSTART + 2, RLENGTH - 12); s = substr(s, 1, RSTART - 1) }
            else if (match(s, /; \(no estimate\)/)) { rem = "?"; s = substr(s, 1, RSTART - 1) }
            printf "%s|%s|%s\n", pct, s, rem; exit
        }')
    _mcb_soc=$(printf '%s' "$_mcb_pm" | awk -F'|' '{print $1}')
    _mcb_state=$(printf '%s' "$_mcb_pm" | awk -F'|' '{print $2}')
    _mcb_rem=$(printf '%s' "$_mcb_pm" | awk -F'|' '{print $3}')

    # Battery panel.
    if is_int "$_mcb_disp"; then
        bat_set ring "$_mcb_disp"
    fi
    bat_set ringlabel "$(t 'health' 'sức khỏe')"
    bat_set status "$_mcb_st"
    case "$_mcb_st" in
        ok) bat_set message "$(t 'Battery health is good.' 'Pin còn khỏe.')" ;;
        *) [ -n "$_mcb_note" ] && bat_set message "$_mcb_note" ;;
    esac
    if is_int "$_mcb_soc"; then
        _mcb_chg="$_mcb_soc%"
        [ -n "$_mcb_state" ] && _mcb_chg="$_mcb_chg ($_mcb_state$([ -n "$_mcb_rem" ] && [ "$_mcb_rem" != "?" ] && printf ', %s' "$_mcb_rem"))"
        bat_row "$(t 'Charge' 'Mức sạc')" "$_mcb_chg"
    fi
    if is_int "$_mcb_cycles"; then
        bat_row "$(t 'Cycle count' 'Số chu kỳ sạc')" "$(tf '%s of %s' '%s / %s' "$_mcb_cycles" "$_mcb_dcyc")"
    fi
    if is_int "$_mcb_rawmax" && is_int "$_mcb_design"; then
        bat_row "$(t 'Capacity' 'Dung lượng')" "$(tf '%s of %s mAh' '%s / %s mAh' "$_mcb_rawmax" "$_mcb_design")"
    fi
    # Temperature: Temperature is 0.1 K; VirtualTemperature (AS) is centi-C. Shown only (single snapshot).
    _mcb_temp=$(mc_kv Temperature "$_mcb_kv")
    _mcb_vtemp=$(mc_kv VirtualTemperature "$_mcb_kv")
    _mcb_tc=
    if is_int "$_mcb_temp" && [ "$_mcb_temp" -gt 0 ]; then
        _mcb_tc=$(awk -v t="$_mcb_temp" 'BEGIN { printf "%.1f", t / 10 - 273.15 }')
    elif is_int "$_mcb_vtemp" && [ "$_mcb_vtemp" -gt 0 ]; then
        _mcb_tc=$(awk -v t="$_mcb_vtemp" 'BEGIN { printf "%.1f", t / 100 }')
    fi
    [ -n "$_mcb_tc" ] && bat_row "$(t 'Temperature' 'Nhiệt độ')" "$_mcb_tc C"

    # Composite battery health check.
    if is_int "$_mcb_disp"; then
        add_check battery "$(t 'Battery health' 'Sức khỏe pin')" \
            "$(tf '%s%% of design' '%s%% so với thiết kế' "$_mcb_disp")" "$_mcb_st" "$_mcb_note"
        add_stat "$_mcb_disp%" "$(t 'battery health' 'sức khỏe pin')"
    else
        add_check battery "$(t 'Battery health' 'Sức khỏe pin')" \
            "$(t 'present, health could not be read' 'có pin, chưa đọc được tình trạng')" info
    fi
    return 0
}

# ---------- Disk: data-volume fullness, SMART, external volumes ----------
mc_disk() {
    # df with an operand does one statfs and cannot hang on network mounts. / is only the sealed
    # system snapshot, so measure the Data volume and compute container fullness from it.
    _mcd_line=$(run_to 5 df -Pk /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { print $2, $4 }')
    [ -n "$_mcd_line" ] || _mcd_line=$(run_to 5 df -Pk / 2>/dev/null | awk 'NR == 2 { print $2, $4 }')
    _mcd_total=$(printf '%s' "$_mcd_line" | awk '{print $1}')
    _mcd_avail=$(printf '%s' "$_mcd_line" | awk '{print $2}')
    if is_int "$_mcd_total" && is_int "$_mcd_avail" && [ "$_mcd_total" -gt 0 ]; then
        _mcd_usedpct=$(awk -v t="$_mcd_total" -v a="$_mcd_avail" 'BEGIN { printf "%d", (t - a) * 100 / t + 0.5 }')
        _mcd_freepct=$((100 - _mcd_usedpct))
        _mcd_freegib=$(awk -v a="$_mcd_avail" 'BEGIN { printf "%d", a / 1048576 }')
        # Thresholds (thresholds-prior-art M3): bad < 5% or < 10 GiB; warn < 10% or < 25 GiB.
        if [ "$_mcd_freepct" -lt 5 ] || [ "$_mcd_freegib" -lt 10 ]; then _mcd_st=bad
        elif [ "$_mcd_freepct" -lt 10 ] || [ "$_mcd_freegib" -lt 25 ]; then _mcd_st=warn
        else _mcd_st=ok; fi
        _mcd_val="$(tf '%s%% used, %s free' '%s%% đã dùng, còn trống %s' "$_mcd_usedpct" "$(human_kb "$_mcd_avail")")"
        case "$_mcd_st" in
            bad) _mcd_note=$(t 'The startup disk is almost full and macOS may stall or fail to update; free space now (free space excludes purgeable).' 'Ổ khởi động gần đầy, macOS có thể treo hoặc không cập nhật được; hãy giải phóng ngay (chưa tính dung lượng có thể xóa tạm).') ;;
            warn) _mcd_note=$(t 'The startup disk is getting full; clear large files, old downloads and unused apps (free space excludes purgeable).' 'Ổ khởi động đang đầy dần; xóa bớt tệp lớn, tải cũ và ứng dụng không dùng (chưa tính dung lượng có thể xóa tạm).') ;;
            *) _mcd_note= ;;
        esac
        add_check storage "$(t 'Startup disk free space' 'Dung lượng trống ổ khởi động')" "$_mcd_val" "$_mcd_st" "$_mcd_note"
        add_stat "$(human_kb "$_mcd_avail")" "$(t 'disk free' 'ổ trống')"
    fi

    # SMART verdict of the internal drive. diskutil can stall when diskarbitrationd is busy -> timeout.
    _mcd_smart=$(run_to 15 diskutil info / 2>/dev/null | sed -n 's/^ *SMART Status: *//p' | head -n 1)
    if [ -z "$_mcd_smart" ] || [ "$_mcd_smart" = "Not Supported" ]; then
        _mcd_store=$(run_to 15 diskutil info / 2>/dev/null | sed -n 's/^ *APFS Physical Store: *\(disk[0-9]*\).*/\1/p' | head -n 1)
        if [ -n "$_mcd_store" ]; then
            _mcd_smart=$(run_to 15 diskutil info "$_mcd_store" 2>/dev/null | sed -n 's/^ *SMART Status: *//p' | head -n 1)
        fi
    fi
    case "$_mcd_smart" in
        Verified) add_check storage "$(t 'Disk SMART status' 'Trạng thái SMART của ổ đĩa')" "$(t 'Verified' 'Đã xác minh (Verified)')" ok ;;
        Failing) add_check storage "$(t 'Disk SMART status' 'Trạng thái SMART của ổ đĩa')" "$(t 'Failing' 'Đang hỏng (Failing)')" bad \
            "$(t 'The disk reports that it is failing; back up now and have it replaced.' 'Ổ đĩa báo sắp hỏng; hãy sao lưu ngay và thay ổ.')" ;;
        '' | "Not Supported") add_check storage "$(t 'Disk SMART status' 'Trạng thái SMART của ổ đĩa')" "$(t 'not reported' 'không có thông tin')" info ;;
        *) add_check storage "$(t 'Disk SMART status' 'Trạng thái SMART của ổ đĩa')" "$_mcd_smart" info ;;
    esac

    # External / extra local volumes that are nearly full (user data, so warn only). Parse from the
    # capacity column outward because mount points and device names contain spaces. This is the one
    # probe without a df operand (getmntinfo can briefly block), so skip it under --quick.
    [ "$BR_QUICK" = 1 ] && return 0
    run_to 5 df -Pkl 2>/dev/null | awk 'NR > 1 {
        c = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { c = i; break }
        if (c < 5) next
        mnt = $(c + 1); for (i = c + 2; i <= NF; i++) mnt = mnt " " $i
        fs = $1
        if (fs !~ /^\/dev\//) next
        if (mnt == "/" || mnt ~ /^\/System\/Volumes\//) next
        if (mnt ~ /^\/Library\/Developer\/CoreSimulator\// || mnt ~ /^\/private\/var\/folders\//) next
        if ($(c - 3) + 0 < 1048576) next
        cap = $c; sub(/%$/, "", cap)
        if (cap + 0 >= 95) printf "%s\t%s\n", mnt, cap
    }' >"$BR_TMP/mc_vols" 2>/dev/null
    if [ -s "$BR_TMP/mc_vols" ]; then
        while IFS="$TAB" read -r _mcd_mnt _mcd_cap; do
            [ -n "$_mcd_mnt" ] || continue
            add_check storage "$(t 'External volume' 'Ổ ngoài')" \
                "$(tf '%s%% full: %s' '%s%% đã đầy: %s' "$_mcd_cap" "$_mcd_mnt")" warn \
                "$(t 'This volume is nearly full; free space on it or move data off.' 'Ổ này gần đầy; hãy giải phóng hoặc chuyển bớt dữ liệu.')"
        done <"$BR_TMP/mc_vols"
    fi
    return 0
}

# ---------- Memory: pressure, swap ----------
mc_memory() {
    # Memory pressure is the one meaningful verdict; "used %" is not a health metric on macOS.
    _mcm_pl=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
    case "$_mcm_pl" in
        1) _mcm_st=ok; _mcm_word=$(t 'Normal' 'Bình thường') ;;
        2) _mcm_st=warn; _mcm_word=$(t 'Warning' 'Cảnh báo') ;;
        4) _mcm_st=bad; _mcm_word=$(t 'Critical' 'Nghiêm trọng') ;;
        *) _mcm_st=info; _mcm_word=$(t 'unknown' 'không rõ') ;;
    esac
    case "$_mcm_st" in
        warn) _mcm_note=$(t 'macOS is compressing and swapping to keep up; close heavy apps or browser tabs.' 'macOS đang nén và tráo bộ nhớ để theo kịp; hãy đóng bớt ứng dụng nặng hoặc tab trình duyệt.') ;;
        bad) _mcm_note=$(t 'Memory is exhausted; quit the largest apps now, and consider more RAM if this is routine.' 'Bộ nhớ đã cạn; hãy thoát các ứng dụng ngốn RAM nhất ngay, và cân nhắc nâng RAM nếu thường xuyên như vậy.') ;;
        *) _mcm_note= ;;
    esac
    add_check memory "$(t 'Memory pressure' 'Áp lực bộ nhớ')" "$_mcm_word" "$_mcm_st" "$_mcm_note"
    add_stat "$_mcm_word" "$(t 'memory pressure' 'áp lực bộ nhớ')"

    # Used-memory breakdown (App + Wired + Compressed, mirroring Activity Monitor). Informational.
    _mcm_memb=$(sysctl -n hw.memsize 2>/dev/null)
    if is_int "$_mcm_memb"; then
        _mcm_used=$(run_to 5 vm_stat 2>/dev/null | awk -v memsize="$_mcm_memb" '
            NR == 1 { ps = $0; sub(/.*page size of /, "", ps); sub(/ bytes.*/, "", ps); next }
            { k = $0; sub(/:.*/, "", k); gsub(/"/, "", k); v = $0; sub(/.*:[ ]*/, "", v); sub(/\.$/, "", v); m[k] = v + 0 }
            END {
                app = (m["Anonymous pages"] - m["Pages purgeable"]) * ps
                wired = m["Pages wired down"] * ps
                comp = m["Pages occupied by compressor"] * ps
                used = app + wired + comp
                printf "%.0f %.0f", used / 1048576, comp / 1048576
            }')
        _mcm_usedmib=$(printf '%s' "$_mcm_used" | awk '{print $1}')
        _mcm_compmib=$(printf '%s' "$_mcm_used" | awk '{print $2}')
        is_int "$_mcm_compmib" || _mcm_compmib=0
        if is_int "$_mcm_usedmib"; then
            add_check memory "$(t 'Memory in use' 'Bộ nhớ đang dùng')" \
                "$(tf '%s of %s (%s compressed)' '%s / %s (nén %s)' \
                    "$(human_kb "$((_mcm_usedmib * 1024))")" "$(human_kb "$((_mcm_memb / 1024))")" "$(human_kb "$((_mcm_compmib * 1024))")")" info
        fi
    fi

    # Swap: info, warn only when swapped data exceeds physical RAM (macOS grows swap on demand).
    _mcm_swap=$(sysctl -n vm.swapusage 2>/dev/null | tr ',' '.' | awk '{
        t = $3; u = $6
        tu = t; sub(/[0-9.]+/, "", tu); sub(/[KMGT].*/, "", t)
        uu = u; sub(/[0-9.]+/, "", uu); sub(/[KMGT].*/, "", u)
        mul = "M"; tm = t; um = u
        if (tu ~ /^G/) tm = t * 1024; else if (tu ~ /^K/) tm = t / 1024; else if (tu ~ /^T/) tm = t * 1048576
        if (uu ~ /^G/) um = u * 1024; else if (uu ~ /^K/) um = u / 1024; else if (uu ~ /^T/) um = u * 1048576
        printf "%.0f %.0f", tm, um
    }')
    _mcm_swtot=$(printf '%s' "$_mcm_swap" | awk '{print $1}')
    _mcm_swused=$(printf '%s' "$_mcm_swap" | awk '{print $2}')
    if is_int "$_mcm_swtot" && [ "$_mcm_swtot" -gt 0 ]; then
        _mcm_rammib=0
        if is_int "$_mcm_memb"; then _mcm_rammib=$((_mcm_memb / 1048576)); fi
        if is_int "$_mcm_swused" && [ "$_mcm_rammib" -gt 0 ] && [ "$_mcm_swused" -gt "$_mcm_rammib" ]; then _mcm_swst=warn
        else _mcm_swst=info; fi
        add_check memory "$(t 'Swap in use' 'Bộ nhớ tráo đổi (swap)')" \
            "$(tf '%s of %s' '%s / %s' "$(human_kb "$((_mcm_swused * 1024))")" "$(human_kb "$((_mcm_swtot * 1024))")")" "$_mcm_swst" \
            "$([ "$_mcm_swst" = warn ] && t 'More data is swapped out than fits in RAM; the workload needs more memory than this Mac has.' 'Dữ liệu tráo ra nhiều hơn RAM; khối lượng công việc cần nhiều bộ nhớ hơn máy này có.')"
    fi
    return 0
}

# ---------- CPU load and thermal state ----------
mc_cpu() {
    _mcc_la=$(sysctl -n vm.loadavg 2>/dev/null | tr ',' '.' | awk '{ g = $0; gsub(/[{}]/, "", g); n = split(g, a, " "); print a[3] }')
    if [ -n "$_mcc_la" ] && is_int "$MC_NCPU" && [ "$MC_NCPU" -gt 0 ]; then
        _mcc_ratio=$(div "$_mcc_la" "$MC_NCPU" 2)
        # thresholds-prior-art M6: 15-min load / cores >= 2.0 = warn; never bad on macOS.
        if num_ge "$_mcc_ratio" 2.0; then _mcc_st=warn; else _mcc_st=ok; fi
        add_check cpu "$(t 'CPU load (15-min)' 'Tải CPU (15 phút)')" \
            "$(tf '%s over %s CPUs (%s per core)' '%s trên %s CPU (%s mỗi nhân)' "$_mcc_la" "$MC_NCPU" "$_mcc_ratio")" "$_mcc_st" \
            "$([ "$_mcc_st" = warn ] && t 'The CPU has been busy for a while; check Activity Monitor for the process responsible.' 'CPU bận cao một thời gian; hãy mở Activity Monitor để xem tiến trình gây tải.')"
    fi

    # Thermal pressure works on both architectures and needs no root (primary on Apple Silicon).
    _mcc_tp=$(run_to 5 notifyutil -g com.apple.system.thermalpressurelevel 2>/dev/null | awk 'NF { print $NF; exit }')
    if is_int "$_mcc_tp"; then
        case "$_mcc_tp" in
            0) _mcc_tpst=ok; _mcc_tpw=$(t 'Nominal' 'Bình thường') ;;
            1) _mcc_tpst=warn; _mcc_tpw=$(t 'Moderate' 'Vừa') ;;
            *) _mcc_tpst=bad; _mcc_tpw=$(t 'Heavy' 'Cao') ;;
        esac
        add_check cpu "$(t 'Thermal pressure' 'Áp lực nhiệt')" "$_mcc_tpw" "$_mcc_tpst" \
            "$([ "$_mcc_tpst" != ok ] && t 'The system is under thermal pressure; check ventilation and runaway processes.' 'Hệ thống đang chịu áp lực nhiệt; kiểm tra thông gió và tiến trình chạy quá mức.')"
    fi

    # Intel-only CPU speed limit (Apple Silicon prints only "No ... recorded" notes).
    if [ "$MC_IS_AS" != 1 ]; then
        _mcc_spd=$(run_to 5 pmset -g therm 2>/dev/null | sed -n 's/.*CPU_Speed_Limit[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
        if is_int "$_mcc_spd" && [ "$_mcc_spd" -lt 100 ]; then
            add_check cpu "$(t 'CPU throttling' 'CPU bị giảm tốc')" \
                "$(tf 'running at %s%% of nominal speed' 'đang chạy ở %s%% tốc độ danh định' "$_mcc_spd")" warn \
                "$(t 'The CPU is being slowed to control heat; check ventilation and runaway processes.' 'CPU đang bị giảm tốc để hạ nhiệt; kiểm tra thông gió và tiến trình chạy quá mức.')"
        fi
    fi
    return 0
}

# ---------- Kernel panics, app crashes, last shutdown (Apple Silicon fault tokens) ----------
mc_crashes() {
    _mcx_sys=$BR_FSROOT/Library/Logs/DiagnosticReports
    _mcx_usr=$HOME/Library/Logs/DiagnosticReports

    # Kernel panics within the window. BSD find -mtime -Nd is "< N*24h" (units disable the round-up).
    _mcx_panics=0
    _mcx_sysna=0
    _mcx_any=0
    for _mcx_d in "$_mcx_sys" "$_mcx_usr"; do
        if [ -d "$_mcx_d" ] && [ -r "$_mcx_d" ] && [ -x "$_mcx_d" ]; then
            _mcx_any=1
            _mcx_n=$(run_to 15 find "$_mcx_d" -maxdepth 2 -type f ! -name '.*' '(' -name '*.panic' -o -name 'panic-*.ips' ')' -mtime -"${BR_DAYS}d" 2>/dev/null | wc -l | tr -d ' ')
            is_int "$_mcx_n" && _mcx_panics=$((_mcx_panics + _mcx_n))
        elif [ "$_mcx_d" = "$_mcx_sys" ]; then
            _mcx_sysna=1
        fi
    done
    if [ "$_mcx_any" = 1 ]; then
        # thresholds-prior-art M8: 1-2 warn, >= 3 bad.
        if [ "$_mcx_panics" -ge 3 ]; then _mcx_pst=bad
        elif [ "$_mcx_panics" -ge 1 ]; then _mcx_pst=warn
        else _mcx_pst=ok; fi
        _mcx_pnote=
        case "$_mcx_pst" in
            warn) _mcx_pnote=$(t 'macOS crashed and restarted; note any new hardware or drivers and keep the panic report.' 'macOS đã sập và khởi động lại; ghi lại phần cứng/driver mới cài và giữ báo cáo panic.') ;;
            bad) _mcx_pnote=$(t 'macOS is crashing repeatedly; remove recent kernel extensions or peripherals and have the hardware tested.' 'macOS sập nhiều lần; gỡ kernel extension/thiết bị ngoại vi mới và kiểm tra phần cứng.') ;;
        esac
        [ "$_mcx_sysna" = 1 ] && _mcx_pnote="${_mcx_pnote:+$_mcx_pnote }$(t '(system reports need admin; counted user reports only)' '(báo cáo hệ thống cần quyền admin; chỉ đếm báo cáo của người dùng)')"
        add_check crashes "$(t 'Kernel panics' 'Sự cố nhân (kernel panic)')" \
            "$(tf '%s in %s day(s)' '%s trong %s ngày' "$_mcx_panics" "$BR_DAYS")" "$_mcx_pst" "$_mcx_pnote"
    else
        add_check crashes "$(t 'Kernel panics' 'Sự cố nhân (kernel panic)')" \
            "$(t 'not available (needs admin)' 'không đọc được (cần quyền admin)')" info
    fi

    # App crash reports in the window. Tally by file-name app prefix (cheap, no per-file reads, no
    # UTF-8 risk); exclude panics, jetsam, stackshots and spindumps that are not app crashes.
    : >"$BR_TMP/mc_crash"
    for _mcx_d in "$_mcx_sys" "$_mcx_usr"; do
        if [ -d "$_mcx_d" ] && [ -r "$_mcx_d" ] && [ -x "$_mcx_d" ]; then
            run_to 15 find "$_mcx_d" -maxdepth 2 -type f ! -name '.*' '(' -name '*.ips' -o -name '*.crash' ')' -mtime -"${BR_DAYS}d" 2>/dev/null >>"$BR_TMP/mc_crash"
        fi
    done
    if [ -s "$BR_TMP/mc_crash" ]; then
        _mcx_crep=$(awk '
            { n = split($0, p, "/"); b = p[n]
              if (b ~ /^panic/ || b ~ /^Kernel_/ || b ~ /^JetsamEvent/ || b ~ /[Ss]tackshot/ || b ~ /^Spindump/) next
              app = b; sub(/-20[0-9][0-9]-.*/, "", app); if (app == "") app = b
              c[app]++; total++
            }
            END { mx = ""; mc = 0; for (a in c) if (c[a] > mc) { mc = c[a]; mx = a }
                  printf "%d %d %s", total, mc, mx }' "$BR_TMP/mc_crash")
        _mcx_ctot=$(printf '%s' "$_mcx_crep" | awk '{print $1}')
        _mcx_cmax=$(printf '%s' "$_mcx_crep" | awk '{print $2}')
        _mcx_capp=$(printf '%s' "$_mcx_crep" | awk '{print $3}')
        if is_int "$_mcx_ctot" && [ "$_mcx_ctot" -gt 0 ]; then
            # thresholds-prior-art M9: info unless one process crashed >= 10 times in the window.
            if is_int "$_mcx_cmax" && [ "$_mcx_cmax" -ge 10 ]; then
                add_check crashes "$(t 'App crash reports' 'Báo cáo lỗi ứng dụng')" \
                    "$(tf '%s in %s day(s); %s crashed %s times' '%s trong %s ngày; %s lỗi %s lần' "$_mcx_ctot" "$BR_DAYS" "$_mcx_capp" "$_mcx_cmax")" warn \
                    "$(t 'One app is crashing often; update or reinstall it.' 'Một ứng dụng lỗi liên tục; hãy cập nhật hoặc cài lại.')"
            else
                add_check crashes "$(t 'App crash reports' 'Báo cáo lỗi ứng dụng')" \
                    "$(tf '%s in %s day(s)' '%s trong %s ngày' "$_mcx_ctot" "$BR_DAYS")" info
            fi
        fi
    fi

    # Last-shutdown cause. On Apple Silicon this is the unprivileged, fast IOPMUBootFaultInfo token
    # array (classification is EXPERIMENTAL, one measured source). Intel's log-show path is dropped by
    # default (slow, admin-only, undocumented codes) per thresholds-prior-art M10.
    if [ "$MC_IS_AS" = 1 ]; then
        run_to 5 ioreg -r -k IOPMUBootFaultInfo -d 1 -w 0 2>/dev/null |
            awk '/"IOPMUBootFaultInfo" = \(/ { s = $0; sub(/.*"IOPMUBootFaultInfo" = \(/, "", s); sub(/\).*$/, "", s)
                n = split(s, a, "\""); for (i = 2; i <= n; i += 2) if (!(a[i] in seen)) { seen[a[i]] = 1; print a[i] } }' >"$BR_TMP/mc_fault" 2>/dev/null
        if [ -s "$BR_TMP/mc_fault" ]; then
            _mcx_fv=$(awk '
                function fam(tok,   p) { p = index(tok, ","); return (p > 0) ? substr(tok, 1, p - 1) : tok }
                { f = fam($0)
                  if (f == "ot" || f == "sochot" || f == "ntc_shdn") { thermal = 1; next }
                  if (f == "uv" || f == "ov" || f == "oc" || f == "pgood" || f == "vddio" || f == "emerg_shdn" || (f == "buck" && $0 !~ /buck_boot_charge/)) { power = 1; next }
                  if ($0 ~ /crash/) { crash = 1; next }
                  if ($0 ~ /timeout/ && $0 !~ /dblclick_timeout/) { wdog = 1; next }
                  if (f == "spmi" || f == "sgpio" || f == "fault" || f == "otp_crc") { hw = 1; next }
                }
                END {
                    if (thermal) print "bad thermal"
                    else if (power) print "bad power"
                    else if (crash) print "warn crash"
                    else if (wdog) print "warn watchdog"
                    else if (hw) print "warn hardware"
                    else print "ok clean"
                }' "$BR_TMP/mc_fault")
            _mcx_fst=$(printf '%s' "$_mcx_fv" | awk '{print $1}')
            _mcx_fcat=$(printf '%s' "$_mcx_fv" | awk '{print $2}')
            case "$_mcx_fst" in
                ok) add_check crashes "$(t 'Last shutdown' 'Lần tắt máy gần nhất')" "$(t 'normal' 'bình thường')" ok ;;
                warn) add_check crashes "$(t 'Last shutdown' 'Lần tắt máy gần nhất')" \
                    "$(tf 'ended with a %s event' 'kết thúc do sự kiện %s' "$_mcx_fcat")" warn \
                    "$(t 'The last shutdown was not clean (experimental reading); watch for repeats.' 'Lần tắt gần nhất không sạch (đọc thử nghiệm); theo dõi nếu lặp lại.')" ;;
                bad) add_check crashes "$(t 'Last shutdown' 'Lần tắt máy gần nhất')" \
                    "$(tf 'forced by a %s fault' 'bị buộc tắt do lỗi %s' "$_mcx_fcat")" bad \
                    "$(t 'The last shutdown was forced by a thermal or power fault (experimental reading); check cooling and the power adapter.' 'Lần tắt gần nhất bị buộc do lỗi nhiệt hoặc nguồn (đọc thử nghiệm); kiểm tra tản nhiệt và bộ sạc.')" ;;
            esac
        fi
    fi
    return 0
}

# ---------- Security posture (no prompts, no root) ----------
mc_security() {
    # SIP. disabled/custom -> warn (thresholds-prior-art M11); conservative vs the spec's "bad".
    _mcs_sip=$(run_to 5 csrutil status 2>/dev/null | sed -n 's/^System Integrity Protection status: *\([a-z]*\).*/\1/p' | head -n 1)
    case "$_mcs_sip" in
        enabled) add_check security "$(t 'System Integrity Protection' 'Bảo vệ toàn vẹn hệ thống (SIP)')" "$(t 'enabled' 'đang bật')" ok ;;
        disabled) add_check security "$(t 'System Integrity Protection' 'Bảo vệ toàn vẹn hệ thống (SIP)')" "$(t 'disabled' 'đang tắt')" warn \
            "$(t 'System Integrity Protection is off; turn it back on from Recovery with csrutil enable.' 'SIP đang tắt; bật lại từ Recovery bằng lệnh csrutil enable.')" ;;
        unknown) add_check security "$(t 'System Integrity Protection' 'Bảo vệ toàn vẹn hệ thống (SIP)')" "$(t 'custom configuration' 'cấu hình tùy chỉnh')" warn \
            "$(t 'SIP is partly disabled (custom configuration); re-enable it fully from Recovery.' 'SIP bị tắt một phần (cấu hình tùy chỉnh); bật lại đầy đủ từ Recovery.')" ;;
        *) add_check security "$(t 'System Integrity Protection' 'Bảo vệ toàn vẹn hệ thống (SIP)')" "$(t 'could not be read' 'không đọc được')" info ;;
    esac

    # FileVault. Off: warn on laptops (theft risk), info on desktops (thresholds-prior-art M12).
    _mcs_fv=$(run_to 5 fdesetup status 2>/dev/null | sed -n 's/^FileVault is \([A-Za-z]*\)\..*/\1/p' | head -n 1)
    case "$_mcs_fv" in
        On) add_check security "$(t 'FileVault disk encryption' 'Mã hóa ổ đĩa FileVault')" "$(t 'On' 'đang bật')" ok ;;
        Off)
            if [ "$MC_HAS_BATTERY" = 1 ]; then
                add_check security "$(t 'FileVault disk encryption' 'Mã hóa ổ đĩa FileVault')" "$(t 'Off' 'đang tắt')" warn \
                    "$(t 'The disk is not encrypted; turn on FileVault so a lost or stolen Mac cannot be read.' 'Ổ đĩa chưa mã hóa; bật FileVault để máy mất/bị trộm không đọc được dữ liệu.')"
            else
                add_check security "$(t 'FileVault disk encryption' 'Mã hóa ổ đĩa FileVault')" "$(t 'Off' 'đang tắt')" info \
                    "$(t 'The disk is not encrypted; consider FileVault if the Mac holds sensitive data.' 'Ổ đĩa chưa mã hóa; cân nhắc bật FileVault nếu máy chứa dữ liệu nhạy cảm.')"
            fi
            ;;
        *) add_check security "$(t 'FileVault disk encryption' 'Mã hóa ổ đĩa FileVault')" "$(t 'could not be read' 'không đọc được')" info ;;
    esac

    # Gatekeeper. spctl writes to stdout but may also report on stderr; capture both.
    _mcs_gk=$(run_to 5 spctl --status 2>&1 | sed -n 's/^assessments \([a-z]*\).*/\1/p' | head -n 1)
    case "$_mcs_gk" in
        enabled) add_check security "$(t 'Gatekeeper' 'Gatekeeper')" "$(t 'enabled' 'đang bật')" ok ;;
        disabled) add_check security "$(t 'Gatekeeper' 'Gatekeeper')" "$(t 'disabled' 'đang tắt')" warn \
            "$(t 'Gatekeeper is disabled, so unsigned apps run without checks; re-enable it in Privacy and Security.' 'Gatekeeper đang tắt nên ứng dụng chưa ký chạy không bị kiểm tra; bật lại trong Quyền riêng tư & Bảo mật.')" ;;
        *) add_check security "$(t 'Gatekeeper' 'Gatekeeper')" "$(t 'could not be read' 'không đọc được')" info ;;
    esac

    # Application firewall. Off is the factory default, so report it as info (thresholds-prior-art M14).
    _mcs_fw=
    if [ -x "$BR_FSROOT$MC_ALF" ]; then
        _mcs_fw=$(run_to 5 "$BR_FSROOT$MC_ALF" --getglobalstate 2>/dev/null | sed -n 's/.*(State = \([0-9]\)).*/\1/p' | head -n 1)
    fi
    case "$_mcs_fw" in
        1 | 2) add_check security "$(t 'Application firewall' 'Tường lửa ứng dụng')" "$(t 'enabled' 'đang bật')" ok ;;
        0) add_check security "$(t 'Application firewall' 'Tường lửa ứng dụng')" "$(t 'off (macOS default)' 'đang tắt (mặc định của macOS)')" info \
            "$(t 'The built-in firewall is off (the default); turn it on if you use untrusted networks.' 'Tường lửa tích hợp đang tắt (mặc định); bật nếu bạn dùng mạng không tin cậy.')" ;;
        *) ;;
    esac
    return 0
}

# ---------- Pending updates and update settings (offline, no network) ----------
mc_updates() {
    # SoftwareUpdate preferences hold the last background scan's results; no network is used.
    run_to 5 defaults read /Library/Preferences/com.apple.SoftwareUpdate 2>/dev/null >"$BR_TMP/mc_su"
    [ -s "$BR_TMP/mc_su" ] || return 0

    _mcu_cnt=$(sed -n 's/^ *LastRecommendedUpdatesAvailable = \([0-9][0-9]*\);.*/\1/p' "$BR_TMP/mc_su" | head -n 1)
    [ -n "$_mcu_cnt" ] || _mcu_cnt=$(sed -n 's/^ *LastUpdatesAvailable = \([0-9][0-9]*\);.*/\1/p' "$BR_TMP/mc_su" | head -n 1)
    _mcu_lastver=$(sed -n 's/^ *LastAttemptSystemVersion = "\(.*\)";.*/\1/p' "$BR_TMP/mc_su" | head -n 1)
    _mcu_names=$(sed -n 's/^ *"Display Name" = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' "$BR_TMP/mc_su" | awk 'NR <= 3 { if (NR > 1) printf ", "; printf "%s", $0 } END { print "" }')

    # Staleness guard: counts predate the running OS if the last attempt was on another version/build.
    _mcu_cur="$MC_OS_VER ($MC_OS_BUILD)"
    if [ -n "$_mcu_lastver" ] && [ -n "$MC_OS_VER" ] && [ "$_mcu_lastver" != "$_mcu_cur" ]; then
        add_check updates "$(t 'Pending updates' 'Cập nhật đang chờ')" \
            "$(t 'update status unknown (stale cache)' 'chưa rõ trạng thái cập nhật (bộ nhớ đệm cũ)')" info \
            "$(t 'macOS has not checked for updates since the last OS change; open Software Update to refresh.' 'macOS chưa kiểm tra cập nhật kể từ lần đổi hệ điều hành; mở Software Update để làm mới.')"
    elif is_int "$_mcu_cnt" && [ "$_mcu_cnt" -gt 0 ]; then
        add_check updates "$(t 'Pending updates' 'Cập nhật đang chờ')" \
            "$(tf '%s available%s' '%s bản%s' "$_mcu_cnt" "$([ -n "$_mcu_names" ] && printf ': %s' "$_mcu_names")")" warn \
            "$(t 'macOS updates are available; install them from Software Update.' 'Có bản cập nhật macOS; hãy cài từ Software Update.')"
    else
        # Nothing pending: check how fresh the last successful scan is.
        _mcu_last=$(sed -n 's/^ *LastSuccessfulDate = "\(.*\)";.*/\1/p' "$BR_TMP/mc_su" | head -n 1)
        _mcu_lastclean=${_mcu_last% *}
        _mcu_ep=$(mc_str2epoch "$_mcu_lastclean")
        if is_int "$_mcu_ep" && is_int "$BR_NOW" && [ "$BR_NOW" -gt "$_mcu_ep" ]; then
            _mcu_age=$(((BR_NOW - _mcu_ep) / 86400))
            if [ "$_mcu_age" -gt 30 ]; then
                add_check updates "$(t 'Pending updates' 'Cập nhật đang chờ')" \
                    "$(tf 'no check in %s days' 'chưa kiểm tra trong %s ngày' "$_mcu_age")" info \
                    "$(t 'macOS has not checked for updates recently; open Software Update to refresh.' 'macOS lâu rồi chưa kiểm tra cập nhật; mở Software Update để làm mới.')"
            else
                add_check updates "$(t 'Pending updates' 'Cập nhật đang chờ')" "$(t 'up to date' 'đã cập nhật')" ok
            fi
        else
            add_check updates "$(t 'Pending updates' 'Cập nhật đang chờ')" "$(t 'none listed' 'không có bản nào')" ok
        fi
    fi

    # Automatic update settings. A key is ABSENT by default (= Apple default, enabled); only an
    # explicit 0 is a finding.
    _mcu_autocheck=$(sed -n 's/^ *AutomaticCheckEnabled = \([0-9]\);.*/\1/p' "$BR_TMP/mc_su" | head -n 1)
    _mcu_crit=$(sed -n 's/^ *CriticalUpdateInstall = \([0-9]\);.*/\1/p' "$BR_TMP/mc_su" | head -n 1)
    if [ "$_mcu_autocheck" = 0 ] || [ "$_mcu_crit" = 0 ]; then
        add_check updates "$(t 'Automatic updates' 'Cập nhật tự động')" "$(t 'disabled' 'đang tắt')" warn \
            "$(t 'Automatic update checks or security responses are disabled; turn them on in Software Update.' 'Kiểm tra cập nhật tự động hoặc bản vá bảo mật đang tắt; bật lại trong Software Update.')"
    fi
    return 0
}

# ---------- Third-party launch agents / daemons ----------
mc_apps() {
    table_new mc_launch "$(t 'Launch agents & daemons' 'Launch agent & daemon')" \
        "$(t 'Label' 'Nhãn')|$(t 'Type' 'Loại')|$(t 'Program' 'Chương trình')" \
        "$(t 'Third-party items that run at login or boot. Apple items are not listed.' 'Các mục bên thứ ba chạy khi đăng nhập hoặc khởi động. Không liệt kê mục của Apple.')"

    _mca_count=0
    _mca_orphans=0
    _mca_rows=0
    for _mca_spec in "$BR_FSROOT/Library/LaunchDaemons:daemon" "$BR_FSROOT/Library/LaunchAgents:agent" "$HOME/Library/LaunchAgents:user"; do
        _mca_dir=${_mca_spec%:*}
        _mca_type=${_mca_spec##*:}
        [ -d "$_mca_dir" ] && [ -r "$_mca_dir" ] || continue
        for _mca_f in "$_mca_dir"/*.plist; do
            [ -e "$_mca_f" ] || continue
            # plutil normalises binary or XML plists to XML on stdout (-o - ; never rewrite in place).
            _mca_info=$(plutil -convert xml1 -o - -- "$_mca_f" 2>/dev/null | awk '
                /<key>Label<\/key>/ { want = "label"; next }
                /<key>Program<\/key>/ { want = "prog"; next }
                /<key>ProgramArguments<\/key>/ { inargs = 1; next }
                want != "" && /<string>/ { v = $0; sub(/.*<string>/, "", v); sub(/<\/string>.*/, "", v); val[want] = v; want = ""; next }
                inargs && /<string>/ { v = $0; sub(/.*<string>/, "", v); sub(/<\/string>.*/, "", v); if (!("prog" in val)) val["prog"] = v; inargs = 0; next }
                END { printf "%s\t%s", val["label"], val["prog"] }')
            _mca_label=${_mca_info%%"$TAB"*}
            _mca_prog=${_mca_info#*"$TAB"}
            [ -n "$_mca_label" ] || _mca_label=${_mca_f##*/}
            # Apple's own items are not third-party; note but do not count or flag them.
            case "$_mca_label" in com.apple.*) continue ;; esac
            _mca_count=$((_mca_count + 1))
            if [ "$_mca_rows" -lt 15 ]; then
                table_row mc_launch "$_mca_label" "$_mca_type" "${_mca_prog:-?}"
                _mca_rows=$((_mca_rows + 1))
            fi
            # Orphaned launch item: the referenced program is gone (typical uninstall leftover).
            case "$_mca_prog" in
                /*) [ -e "$BR_FSROOT$_mca_prog" ] || _mca_orphans=$((_mca_orphans + 1)) ;;
            esac
        done
    done

    if [ "$_mca_orphans" -gt 0 ]; then
        add_check apps "$(t 'Orphaned launch items' 'Mục khởi động mồ côi')" \
            "$(tf '%s item(s) point to a missing program' '%s mục trỏ tới chương trình không còn tồn tại' "$_mca_orphans")" warn \
            "$(t 'These are usually leftovers of uninstalled apps; remove the matching .plist files.' 'Thường là tàn dư của ứng dụng đã gỡ; hãy xóa các tệp .plist tương ứng.')"
    fi
    if [ "$_mca_count" -gt 15 ]; then
        add_check apps "$(t 'Launch items' 'Mục khởi động')" \
            "$(tf '%s third-party launch items' '%s mục khởi động bên thứ ba' "$_mca_count")" warn \
            "$(t 'A lot of third-party software runs at login or boot; review the list and remove what you do not use.' 'Nhiều phần mềm bên thứ ba chạy khi đăng nhập/khởi động; xem lại và gỡ những gì không dùng.')"
    elif [ "$_mca_count" -gt 0 ]; then
        add_check apps "$(t 'Launch items' 'Mục khởi động')" \
            "$(tf '%s third-party launch items' '%s mục khởi động bên thứ ba' "$_mca_count")" info
    fi
    return 0
}

# ---------- Android / Termux collector ----------
# Runs WITHOUT root. Every /proc and /sys read goes through $BR_FSROOT so tests can redirect
# it; every external and termux-* command goes through run_to so nothing can hang; a denied read
# becomes an "info" check, never a false "ok" and never an abort. Numbers that can exceed 2^31
# (storage KiB, charge counters) stay in awk, never in $(( )). Private helpers are prefixed an_.

# an_load_props: dump getprop ONCE into a KEY<TAB>VALUE file. One fork, not one per key.
an_load_props() {
    : >"$BR_TMP/an_props"
    run_to 5 getprop >"$BR_TMP/an_getprop.raw" 2>/dev/null
    # getprop prints "[name]: [value]" per line, sorted. The sub() recipe keeps values that
    # themselves contain [ or ]; a multi-line value is truncated to its first line.
    LC_ALL=C awk '
        /^\[[^]]*\]: \[/ {
            k = $0; sub(/^\[/, "", k); sub(/\]: \[.*$/, "", k)
            v = $0; sub(/^\[[^]]*\]: \[/, "", v); sub(/\]$/, "", v)
            print k "\t" v
        }' "$BR_TMP/an_getprop.raw" >"$BR_TMP/an_props" 2>/dev/null
    return 0
}

# an_prop KEY -> value of one property, empty when missing or unreadable (never guess "0"/"false").
an_prop() {
    [ -f "$BR_TMP/an_props" ] || return 0
    LC_ALL=C awk -F "$TAB" -v k="$1" '$1 == k { print $2; exit }' "$BR_TMP/an_props" 2>/dev/null
}

# an_is_termux -> 0 when this is a real Termux shell (not adb/rish/su), else 1.
an_is_termux() {
    [ -n "${TERMUX_VERSION:-}" ] && return 0
    case "${PREFIX:-}" in
        */files/usr) { [ -d "$PREFIX/etc/apt" ] || [ -x "$PREFIX/bin/pkg" ]; } && return 0 ;;
    esac
    return 1
}

# an_worse A B -> the worse of two statuses (bad > warn > info > ok).
an_worse() {
    for _anw_s in bad warn info ok; do
        if [ "$1" = "$_anw_s" ] || [ "$2" = "$_anw_s" ]; then printf '%s' "$_anw_s"; return 0; fi
    done
    printf ok
}

# an_sysrun SECS TOOL [ARGS...] -> run a /system/bin tool through run_to. Prefer a PATH entry
# (Termux wrapper or test shim); else the absolute path with the Termux loader vars cleared so a
# system binary links. rc 127 when the tool is nowhere. stderr is dropped (run_to).
an_sysrun() {
    _ansr_s=$1
    _ansr_t=$2
    shift 2
    if have "$_ansr_t"; then
        run_to "$_ansr_s" "$_ansr_t" "$@"
    elif [ -x "/system/bin/$_ansr_t" ]; then
        run_to "$_ansr_s" sh -c 'unset LD_PRELOAD LD_LIBRARY_PATH; PATH=/system/bin:$PATH; export PATH; _t=$1; shift; exec "/system/bin/$_t" "$@"' sh "$_ansr_t" "$@"
    else
        return 127
    fi
}

# an_getenforce -> SELinux mode text WITH stderr folded in (the denial message is the signal).
an_getenforce() {
    if have getenforce; then
        run_to 3 sh -c 'getenforce 2>&1'
    elif [ -x /system/bin/getenforce ]; then
        run_to 3 sh -c 'unset LD_PRELOAD LD_LIBRARY_PATH; /system/bin/getenforce 2>&1'
    fi
    return 0
}

# an_days_since YYYY-MM-DD -> whole days from that date to BR_NOW (negative = future), empty when
# malformed. POSIX awk day-number arithmetic (no mktime); validated by hand against known dates.
an_days_since() {
    case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac
    LC_ALL=C awk -v d="$1" -v now="$BR_NOW" 'BEGIN {
        split(d, p, "-"); y = p[1] + 0; m = p[2] + 0; dd = p[3] + 0
        if (y < 1990 || m < 1 || m > 12 || dd < 1 || dd > 31) exit
        if (m <= 2) { y--; m += 12 }
        n = 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + dd - 719469
        printf "%d\n", int(now / 86400) - n
    }'
}

# an_json_get KEY -> scalar value (unquoted) from the tier-A battery JSON file; empty for null/missing.
# Splits on commas (battery values never contain one) and anchors on "key": so "current" never
# matches "current_average".
an_json_get() {
    [ -f "$BR_TMP/an_bat.json" ] || return 0
    LC_ALL=C awk -v k="$1" 'BEGIN { RS = "," }
        { line = $0; gsub(/[{}\r\n]/, "", line); sub(/^[ \t]+/, "", line) }
        index(line, "\"" k "\":") == 1 {
            v = substr(line, length(k) + 4)
            gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
            if (v != "null") print v
            exit
        }' "$BR_TMP/an_bat.json" 2>/dev/null
}

# an_bp_get ID -> signed integer from `service call batteryproperties 1 i32 ID`, empty on any anomaly.
# Validates the first three Parcel words before trusting the value; the ASCII column (which can hold
# hex-looking text) is cut first. Only valid on API >= 28 (transaction 1 is registerListener on 8.x).
an_bp_get() {
    _anbp_o=$(an_sysrun 3 service call batteryproperties 1 i32 "$1" 2>/dev/null) || return 0
    _anbp_w=$(printf '%s\n' "$_anbp_o" | sed -e "s/'.*\$//" -e 's/^.*Parcel(//' -e 's/^ *0x[0-9a-fA-F]*: *//' | LC_ALL=C tr -s ' \n\t)' ' ')
    # shellcheck disable=SC2086
    set -- $_anbp_w
    [ $# -ge 5 ] || return 0
    [ "$1" = 00000000 ] && [ "$2" = 00000000 ] && [ "$3" = 00000001 ] || return 0
    case "$4$5" in *[!0-9a-fA-F]*) return 0 ;; esac
    [ "$4" = 00000000 ] && [ "$5" = 80000000 ] && return 0
    _anbp_lo=$((0x$4))
    case "$5" in
        00000000) printf '%s\n' "$_anbp_lo" ;;
        ffffffff | FFFFFFFF) printf '%s\n' "$((_anbp_lo - 4294967296))" ;;
        *) return 0 ;;
    esac
}

# ---------- device identity ----------
an_ident() {
    _ani_rel=$(an_prop ro.build.version.release)
    _ani_sdk=$(an_prop ro.build.version.sdk)
    _ani_mkt=$(an_prop ro.product.marketname)
    _ani_mfr=$(an_prop ro.product.manufacturer)
    _ani_model=$(an_prop ro.product.model)

    # Device label: prefer the Xiaomi-style marketing name; else "Manufacturer Model" with the
    # manufacturer capitalised and no duplication when the model already starts with it.
    if [ -n "$_ani_mkt" ]; then
        _ani_dev=$_ani_mkt
    elif [ -n "$_ani_model" ]; then
        _ani_dev=$(LC_ALL=C awk -v mfr="$_ani_mfr" -v model="$_ani_model" 'BEGIN {
            if (mfr == "") { print model; exit }
            lm = tolower(model); lf = tolower(mfr)
            if (substr(lm, 1, length(lf)) == lf) { print model; exit }
            print toupper(substr(mfr, 1, 1)) substr(mfr, 2) " " model
        }')
    else
        _ani_dev=$_ani_mfr
    fi

    if [ -n "$_ani_rel" ]; then
        if [ -n "$_ani_dev" ]; then
            BR_OS_LABEL="Android $_ani_rel ($_ani_dev)"
        else
            BR_OS_LABEL="Android $_ani_rel"
        fi
    else
        BR_OS_LABEL="Android"
    fi
    # hostname is "localhost" in Termux; the device name reads far better in the report subtitle.
    [ -n "$_ani_dev" ] && BR_HOST=$_ani_dev

    add_info "$(t 'Operating system' 'Hệ điều hành')" "$BR_OS_LABEL"
    if [ -n "$_ani_sdk" ]; then
        add_info "$(t 'Android version' 'Phiên bản Android')" "$(tf '%s (API %s)' '%s (API %s)' "${_ani_rel:-?}" "$_ani_sdk")"
    fi

    # SoC / chipset
    _ani_socm=$(an_prop ro.soc.manufacturer)
    _ani_socn=$(an_prop ro.soc.model)
    _ani_soc=
    if [ -n "$_ani_socn" ]; then
        _ani_soc=$_ani_socn
        [ -n "$_ani_socm" ] && _ani_soc="$_ani_socm $_ani_socn"
    else
        _ani_soc=$(an_prop ro.board.platform)
    fi
    add_info "$(t 'Chipset' 'Chipset')" "$_ani_soc"

    _ani_kern=$(uname -r 2>/dev/null)
    add_info "$(t 'Kernel' 'Nhân (kernel)')" "$_ani_kern"
    _ani_abi=$(an_prop ro.product.cpu.abi)
    [ -n "$_ani_abi" ] || _ani_abi=$(uname -m 2>/dev/null)
    add_info "$(t 'Architecture' 'Kiến trúc')" "$_ani_abi"
    add_info "$(t 'Build number' 'Số hiệu bản dựng')" "$(an_prop ro.build.display.id)"

    # SELinux domain of this shell (free, always readable) — strip the category suffix (privacy).
    _ani_ctx=$(LC_ALL=C tr -d '\000' <"$BR_FSROOT/proc/self/attr/current" 2>/dev/null)
    if [ -n "$_ani_ctx" ]; then
        _ani_ctx=$(printf '%s' "$_ani_ctx" | LC_ALL=C awk -F: '{ printf "%s:%s:%s:%s", $1, $2, $3, $4 }')
        add_info "$(t 'Security context' 'Ngữ cảnh bảo mật')" "$_ani_ctx"
    fi

    # Execution environment
    if an_is_termux; then
        _ani_apk=${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}}
        case "${TERMUX_VERSION:-}" in googleplay.*) _ani_apk=GOOGLE_PLAY_STORE ;; esac
        case "$_ani_apk" in
            F_DROID) _ani_src="F-Droid" ;;
            GITHUB) _ani_src="GitHub" ;;
            GOOGLE_PLAY_STORE) _ani_src="Google Play" ;;
            TERMUX_DEVS) _ani_src="termux.dev" ;;
            *) _ani_src= ;;
        esac
        if [ -n "$_ani_src" ]; then
            add_info "Termux" "$(tf '%s (%s)' '%s (%s)' "${TERMUX_VERSION:-?}" "$_ani_src")"
        else
            add_info "Termux" "${TERMUX_VERSION:-?}"
        fi
    else
        _ani_uid=$(id -u 2>/dev/null)
        case "$_ani_uid" in
            0) add_info "$(t 'Shell' 'Trình vỏ')" "$(t 'root shell' 'trình vỏ root')" ;;
            2000) add_info "$(t 'Shell' 'Trình vỏ')" "$(t 'adb / Shizuku shell (uid 2000)' 'trình vỏ adb / Shizuku (uid 2000)')" ;;
        esac
    fi
    return 0
}

# ---------- battery (tiers A->B->C->D->E, stop at the first that gives a level) ----------
an_battery() {
    _anb_sdk=$(an_prop ro.build.version.sdk)
    _anb_pct=
    _anb_status=
    _anb_health=
    _anb_plug=
    _anb_temp=
    _anb_volt=
    _anb_cur=
    _anb_cc=
    _anb_cycle=
    _anb_tech=
    _anb_soh=
    _anb_src=

    # Tier A: termux-battery-status. No internal timeout exists and it can hang forever, so run_to
    # is mandatory; stdin is already /dev/null (main wrapper) so it cannot swallow a piped script.
    if have termux-battery-status; then
        _anb_to=8
        [ "$BR_QUICK" = 1 ] && _anb_to=3
        run_to "$_anb_to" termux-battery-status >"$BR_TMP/an_bat.json" 2>/dev/null
        if grep -qE '"(percentage|status)"' "$BR_TMP/an_bat.json" 2>/dev/null; then
            _anb_src=api
            _anb_pct=$(an_json_get percentage)
            [ -n "$_anb_pct" ] || _anb_pct=$(an_json_get level)
            _anb_status=$(an_json_get status)
            _anb_health=$(an_json_get health)
            _anb_plug=$(an_json_get plugged)
            _anb_temp=$(an_json_get temperature)
            _anb_volt=$(an_json_get voltage)
            _anb_cur=$(an_json_get current)
            _anb_cc=$(an_json_get charge_counter)
            _anb_cycle=$(an_json_get cycle)
            _anb_tech=$(an_json_get technology)
        fi
    fi

    # Tier B: binder getter (no root, no Termux:API). API >= 28 only (transaction 1 differs on 8.x).
    if [ -z "$_anb_pct" ] && is_int "$_anb_sdk" && [ "$_anb_sdk" -ge 28 ]; then
        _anb_v=$(an_bp_get 4)
        if is_int "$_anb_v" && [ "$_anb_v" -ge 0 ] && [ "$_anb_v" -le 100 ]; then
            _anb_pct=$_anb_v
            _anb_src=service
            _anb_s6=$(an_bp_get 6)
            case "$_anb_s6" in
                2) _anb_status=CHARGING ;; 3) _anb_status=DISCHARGING ;;
                4) _anb_status=NOT_CHARGING ;; 5) _anb_status=FULL ;; 1) _anb_status=UNKNOWN ;;
            esac
            _anb_cc=$(an_bp_get 1)
            case "$_anb_cc" in '' | *[!0-9]*) _anb_cc= ;; esac
            _anb_cur=$(an_bp_get 2)
        fi
    fi

    # Tier C: debug.tracing.* (already in the getprop dump) — status/plug only, no level.
    _anb_dbgstat=$(an_prop debug.tracing.battery_status)
    _anb_dbgplug=$(an_prop debug.tracing.plug_type)
    if [ -z "$_anb_status" ] && is_int "$_anb_dbgstat"; then
        case "$_anb_dbgstat" in
            2) _anb_status=CHARGING ;; 3) _anb_status=DISCHARGING ;;
            4) _anb_status=NOT_CHARGING ;; 5) _anb_status=FULL ;;
        esac
    fi

    # Tier D: sysfs (root / adb / lenient ROM). Usually denied for apps -> loop simply finds nothing.
    # Only here can state of health be computed (charge_full vs charge_full_design).
    if [ -z "$_anb_pct" ]; then
        for _anb_d in "$BR_FSROOT"/sys/class/power_supply/*; do
            [ -e "$_anb_d" ] || continue
            [ "$(read_file "$_anb_d/type")" = Battery ] || continue
            _anb_cap=$(read_file "$_anb_d/capacity")
            is_int "$_anb_cap" || continue
            _anb_pct=$_anb_cap
            _anb_src=sysfs
            [ -z "$_anb_status" ] && _anb_status=$(read_file "$_anb_d/status" | LC_ALL=C tr 'a-z ' 'A-Z_')
            [ -z "$_anb_health" ] && _anb_health=$(read_file "$_anb_d/health" | LC_ALL=C tr 'a-z ' 'A-Z_')
            _anb_rawt=$(read_file "$_anb_d/temp")
            if is_int "$_anb_rawt" && [ -z "$_anb_temp" ]; then
                _anb_temp=$(div "$_anb_rawt" 10 1)
            fi
            _anb_cyc2=$(read_file "$_anb_d/cycle_count")
            [ -z "$_anb_cycle" ] && _anb_cycle=$_anb_cyc2
            _anb_cf=$(read_file "$_anb_d/charge_full")
            _anb_cfd=$(read_file "$_anb_d/charge_full_design")
            if is_int "$_anb_cf" && is_int "$_anb_cfd" && [ "$_anb_cfd" -gt 0 ]; then
                _anb_soh=$(pct "$_anb_cf" "$_anb_cfd")
            fi
            [ -z "$_anb_cc" ] && _anb_cc=$(read_file "$_anb_d/charge_counter")
            [ -z "$_anb_tech" ] && _anb_tech=$(read_file "$_anb_d/technology")
            break
        done
    fi

    # Tier E: dumpsys battery (uid 0 or 2000 only). From an app UID it is denied -> rejected below.
    if [ -z "$_anb_pct" ] && { [ "$BR_ROOT" = 1 ] || [ "$(id -u 2>/dev/null)" = 2000 ]; }; then
        an_sysrun 5 dumpsys battery >"$BR_TMP/an_dumpsys.txt" 2>/dev/null
        if grep -qE '^ *level: [0-9]+' "$BR_TMP/an_dumpsys.txt" 2>/dev/null; then
            _anb_src=dumpsys
            _anb_pct=$(LC_ALL=C awk -F': ' '{ k = $1; sub(/^ +/, "", k) } k == "level" { print $2; exit }' "$BR_TMP/an_dumpsys.txt")
            _anb_ds=$(LC_ALL=C awk -F': ' '{ k = $1; sub(/^ +/, "", k) } k == "status" { print $2; exit }' "$BR_TMP/an_dumpsys.txt")
            case "$_anb_ds" in
                2) [ -z "$_anb_status" ] && _anb_status=CHARGING ;;
                3) [ -z "$_anb_status" ] && _anb_status=DISCHARGING ;;
                4) [ -z "$_anb_status" ] && _anb_status=NOT_CHARGING ;;
                5) [ -z "$_anb_status" ] && _anb_status=FULL ;;
            esac
            _anb_dh=$(LC_ALL=C awk -F': ' '{ k = $1; sub(/^ +/, "", k) } k == "health" { print $2; exit }' "$BR_TMP/an_dumpsys.txt")
            case "$_anb_dh" in
                2) [ -z "$_anb_health" ] && _anb_health=GOOD ;;
                3) [ -z "$_anb_health" ] && _anb_health=OVERHEAT ;;
                4) [ -z "$_anb_health" ] && _anb_health=DEAD ;;
                5) [ -z "$_anb_health" ] && _anb_health=OVER_VOLTAGE ;;
                6) [ -z "$_anb_health" ] && _anb_health=UNSPECIFIED_FAILURE ;;
                7) [ -z "$_anb_health" ] && _anb_health=COLD ;;
            esac
            _anb_dt=$(LC_ALL=C awk -F': ' '{ k = $1; sub(/^ +/, "", k) } k == "temperature" { print $2; exit }' "$BR_TMP/an_dumpsys.txt")
            if is_int "$_anb_dt" && [ -z "$_anb_temp" ]; then _anb_temp=$(div "$_anb_dt" 10 1); fi
        fi
    fi

    # Sanitise the level and temperature (0.51.0 prints -0.1, older a huge negative, for "missing").
    case "$_anb_pct" in '' | *[!0-9]*) _anb_pct= ;; esac
    if [ -n "$_anb_pct" ] && { [ "$_anb_pct" -lt 0 ] || [ "$_anb_pct" -gt 100 ]; }; then _anb_pct=; fi
    if [ -n "$_anb_temp" ]; then
        # Reject the "missing" sentinels (0.51.0 prints -0.1, older builds a huge negative) and absurd
        # highs; any non-positive reading is treated as missing, not as a real sub-zero battery.
        if num_ge "$_anb_temp" 100 || num_ge 0 "$_anb_temp"; then _anb_temp=; fi
    fi

    # Power source (battery group, always info — phones report charging state, not a desktop concept).
    _anb_plugged=0
    case "$_anb_status" in CHARGING | FULL) _anb_plugged=1 ;; esac
    case "$_anb_plug" in PLUGGED_*) _anb_plugged=1 ;; esac
    if is_int "$_anb_dbgplug" && [ "$_anb_dbgplug" -gt 0 ]; then _anb_plugged=1; fi
    _anb_havestate=0
    [ -n "$_anb_status" ] && _anb_havestate=1
    [ -n "$_anb_plug" ] && _anb_havestate=1
    is_int "$_anb_dbgplug" && _anb_havestate=1
    if [ "$_anb_havestate" = 1 ]; then
        if [ "$_anb_plugged" = 1 ]; then
            _anb_psrc=$(t 'Charging (plugged in)' 'Đang cắm điện (đang sạc)')
        else
            _anb_psrc=$(t 'On battery' 'Đang chạy bằng pin')
        fi
        add_check battery "$(t 'Power source' 'Nguồn điện')" "$_anb_psrc" info
    fi

    # No source answered at all -> one honest info check, no panel.
    if [ -z "$_anb_pct" ] && [ -z "$_anb_health" ] && [ -z "$_anb_temp" ]; then
        if have termux-battery-status; then
            add_check battery "$(t 'Battery' 'Pin')" \
                "$(t 'could not be read' 'không đọc được')" info \
                "$(t 'The Termux:API companion app did not answer; open it once and allow it to run in the background.' 'Ứng dụng Termux:API không phản hồi; hãy mở nó một lần và cho phép chạy nền.')"
        else
            add_check battery "$(t 'Battery' 'Pin')" \
                "$(t 'data not available to apps on this device' 'thiết bị không cho ứng dụng đọc dữ liệu pin')" info \
                "$(t 'Install the Termux:API app and the termux-api package (from the same source as Termux) to report battery health and temperature.' 'Cài ứng dụng Termux:API và gói termux-api (cùng nguồn với Termux) để xem sức khỏe và nhiệt độ pin.')"
        fi
        return 0
    fi

    # Grade health and temperature.
    _anb_hst=info
    case "$_anb_health" in
        GOOD) _anb_hst=ok ;;
        OVERHEAT | DEAD | OVER_VOLTAGE) _anb_hst=bad ;;
        COLD | UNSPECIFIED_FAILURE) _anb_hst=warn ;;
        *) _anb_hst=info ;;
    esac
    _anb_tst=info
    if [ -n "$_anb_temp" ]; then
        if num_ge "$_anb_temp" 50; then _anb_tst=bad
        elif num_ge "$_anb_temp" 45; then _anb_tst=warn
        else _anb_tst=ok; fi
    fi

    # Battery panel.
    _anb_panelst=$(an_worse "$_anb_hst" "$_anb_tst")
    [ -n "$_anb_pct" ] && bat_set ring "$_anb_pct"
    bat_set ringlabel "$(t 'battery' 'pin')"
    bat_set status "$_anb_panelst"
    _anb_msg=
    if [ -n "$_anb_pct" ]; then _anb_msg="$_anb_pct%"; fi
    if [ -n "$_anb_temp" ]; then _anb_msg="${_anb_msg:+$_anb_msg · }$_anb_temp °C"; fi
    [ -n "$_anb_health" ] && _anb_msg="${_anb_msg:+$_anb_msg · }$_anb_health"
    bat_set message "$_anb_msg"

    # Panel detail rows.
    if [ -n "$_anb_status" ]; then
        bat_row "$(t 'Status' 'Trạng thái')" "$_anb_status"
    fi
    [ -n "$_anb_health" ] && bat_row "$(t 'Health' 'Tình trạng')" "$_anb_health"
    [ -n "$_anb_temp" ] && bat_row "$(t 'Temperature' 'Nhiệt độ')" "$_anb_temp °C"
    if is_int "$_anb_volt" && [ "$_anb_volt" -gt 0 ]; then
        bat_row "$(t 'Voltage' 'Điện áp')" "$(div "$_anb_volt" 1000 2) V"
    fi
    # Current: unit and sign are unreliable across OEMs, so show magnitude only and take the
    # direction from status, never from the sign.
    if [ -n "$_anb_cur" ]; then
        _anb_cma=$(LC_ALL=C awk -v c="$_anb_cur" 'BEGIN { c = c + 0; if (c < 0) c = -c; if (c <= 12000) printf "%d", c; else printf "%d", c / 1000 + 0.5 }')
        if is_int "$_anb_cma" && [ "$_anb_cma" -gt 0 ]; then
            bat_row "$(t 'Current' 'Dòng điện')" "$(tf 'about %s mA' 'khoảng %s mA' "$_anb_cma")"
        fi
    fi
    if is_int "$_anb_soh" && [ "$_anb_soh" -gt 0 ]; then
        bat_row "$(t 'State of health' 'Độ chai pin')" "$_anb_soh%"
    fi
    _anb_estmah=
    if is_int "$_anb_cc" && [ -n "$_anb_pct" ] && [ "$_anb_pct" -ge 50 ] && [ "$_anb_cc" -ge 100000 ]; then
        _anb_estmah=$(LC_ALL=C awk -v cc="$_anb_cc" -v p="$_anb_pct" 'BEGIN { printf "%d", cc / p / 10 + 0.5 }')
        bat_row "$(t 'Capacity (estimated)' 'Dung lượng (ước tính)')" "$(tf '~%s mAh' '~%s mAh' "$_anb_estmah")"
    fi
    [ -n "$_anb_tech" ] && bat_row "$(t 'Technology' 'Công nghệ')" "$_anb_tech"

    # Battery checks.
    if [ -n "$_anb_pct" ]; then
        add_check battery "$(t 'Charge level' 'Mức pin')" "$_anb_pct%" info
        add_stat "$_anb_pct%" "$(t 'battery' 'pin')"
    fi
    if [ -n "$_anb_health" ]; then
        _anb_hnote=
        case "$_anb_hst" in
            bad) _anb_hnote=$(t 'The battery reports a fault; stop charging and have the battery or charger checked.' 'Pin báo lỗi; ngừng sạc và kiểm tra pin hoặc bộ sạc.') ;;
            warn) _anb_hnote=$(t 'The battery reports an abnormal state; bring the phone to room temperature and try another charger.' 'Pin ở trạng thái bất thường; đưa máy về nhiệt độ phòng và thử bộ sạc khác.') ;;
        esac
        add_check battery "$(t 'Battery health' 'Sức khỏe pin')" "$_anb_health" "$_anb_hst" "$_anb_hnote"
    fi
    if [ -n "$_anb_temp" ]; then
        _anb_tnote=
        case "$_anb_tst" in
            bad) _anb_tnote=$(t 'The battery is at or above 50 C, which damages it; unplug and cool the phone now.' 'Pin đang ở mức từ 50 độ C trở lên, gây hại pin; rút sạc và làm mát máy ngay.') ;;
            warn) _anb_tnote=$(t 'The battery is at or above 45 C; stop charging or heavy use until it cools.' 'Pin đang ở mức từ 45 độ C trở lên; ngừng sạc hoặc dùng nặng cho tới khi nguội.') ;;
        esac
        add_check battery "$(t 'Battery temperature' 'Nhiệt độ pin')" "$_anb_temp °C" "$_anb_tst" "$_anb_tnote"
    fi
    if is_int "$_anb_cycle" && [ "$_anb_cycle" -gt 0 ]; then
        if [ "$_anb_cycle" -ge 800 ]; then
            add_check battery "$(t 'Charge cycles' 'Số lần sạc')" "$_anb_cycle" warn \
                "$(t 'The battery has been through many charge cycles; expect shorter runtime.' 'Pin đã trải qua nhiều lần sạc; thời lượng dùng sẽ ngắn hơn.')"
        else
            add_check battery "$(t 'Charge cycles' 'Số lần sạc')" "$_anb_cycle" info
        fi
    fi
    if is_int "$_anb_soh" && [ "$_anb_soh" -gt 0 ]; then
        add_check battery "$(t 'State of health' 'Độ chai pin')" "$_anb_soh%" info
    fi
    if [ -n "$_anb_estmah" ]; then
        add_check battery "$(t 'Capacity (estimated)' 'Dung lượng (ước tính)')" "$(tf '~%s mAh' '~%s mAh' "$_anb_estmah")" info \
            "$(t 'Estimated from the charge counter; a rough figure, not a wear measurement.' 'Ước tính từ bộ đếm sạc; chỉ mang tính tham khảo, không phải mức chai pin.')"
    fi
    return 0
}

# ---------- storage ----------
an_storage() {
    # Grade internal userdata once (shared storage is the same filesystem); never grade read-only
    # system partitions. df in Termux is toybox, where -P alone means 512-byte blocks, so pass -Pk.
    _ans_seen=
    _ans_primary=1
    for _ans_path in "$HOME" /storage/emulated/0 "$HOME/storage/external-1"; do
        [ -n "$_ans_path" ] || continue
        case "$_ans_path" in
            "$HOME") ;;
            *) [ -e "$_ans_path" ] || continue ;;
        esac
        _ans_line=$(run_to 5 df -Pk "$_ans_path" 2>/dev/null | LC_ALL=C awk 'NR > 1 && $2 ~ /^[0-9]+$/ {
            print $2 "\t" $3 "\t" $4 "\t" $5; exit }')
        # A failed / duplicate / invalid probe must NOT consume the primary (internal) slot - otherwise a
        # failing $HOME probe would demote the real internal volume to an ungraded "External" row. The
        # slot is only released after the internal check is actually emitted (below).
        [ -n "$_ans_line" ] || continue
        _ans_total=$(printf '%s' "$_ans_line" | cut -f1)
        _ans_avail=$(printf '%s' "$_ans_line" | cut -f3)
        _ans_cap=$(printf '%s' "$_ans_line" | cut -f4 | tr -d '%')
        case "$_ans_seen" in *"|$_ans_total|"*) continue ;; esac
        _ans_seen="$_ans_seen|$_ans_total|"
        is_int "$_ans_total" || continue
        # Keep the arithmetic in awk: Android storage can exceed what 32-bit $(( )) holds.
        is_int "$_ans_cap" || _ans_cap=$(LC_ALL=C awk -v t="$_ans_total" -v a="$_ans_avail" 'BEGIN { if (t > 0) printf "%d", (t - a) * 100 / t + 0.5; else printf "0" }')

        if [ "$_ans_primary" = 1 ]; then
            # userdata: bad free<5% or <1GiB; warn free<10% or <3GiB; else ok.
            _ans_st=$(LC_ALL=C awk -v total="$_ans_total" -v avail="$_ans_avail" -v cap="$_ans_cap" 'BEGIN {
                g = 1048576; fp = (total > 0) ? avail * 100 / total : 100; s = "ok"
                if (fp < 10 || avail < 3 * g) s = "warn"
                if (fp < 5 || avail < g) s = "bad"
                print s }')
            _ans_note=
            case "$_ans_st" in
                warn) _ans_note=$(t 'Internal storage is getting full; remove unused apps, downloads and media.' 'Bộ nhớ trong sắp đầy; xóa bớt ứng dụng, tệp tải về và media không dùng.') ;;
                bad) _ans_note=$(t 'Internal storage is almost full; apps and updates may fail, so free space now.' 'Bộ nhớ trong gần đầy; ứng dụng và cập nhật có thể lỗi, hãy giải phóng ngay.') ;;
            esac
            add_check storage "$(t 'Internal storage' 'Bộ nhớ trong')" \
                "$(tf '%s%% used, %s of %s free' 'đã dùng %s%%, còn %s trên %s' "$_ans_cap" "$(human_kb "$_ans_avail")" "$(human_kb "$_ans_total")")" \
                "$_ans_st" "$_ans_note"
            add_stat "$(human_kb "$_ans_avail")" "$(t 'storage free' 'bộ nhớ trống')"
            _ans_primary=0
        else
            # removable / SD card: information only.
            add_check storage "$(t 'External storage' 'Bộ nhớ ngoài')" \
                "$(tf '%s%% used, %s of %s free' 'đã dùng %s%%, còn %s trên %s' "$_ans_cap" "$(human_kb "$_ans_avail")" "$(human_kb "$_ans_total")")" info
        fi
    done
    return 0
}

# ---------- memory ----------
an_memory() {
    [ -r "$BR_FSROOT/proc/meminfo" ] || return 0
    _anm_p=$(LC_ALL=C awk '
        /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2; h = 1 } /^MemFree:/ { f = $2 }
        /^Buffers:/ { b = $2 } /^Cached:/ { c = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
        END { if (!t) exit; if (!h) a = f + b + c; if (a > t) a = t
              printf "%d %d %d %d\n", t, a, st, sf }' "$BR_FSROOT/proc/meminfo" 2>/dev/null)
    [ -n "$_anm_p" ] || return 0
    # shellcheck disable=SC2086
    set -- $_anm_p
    _anm_total=$1
    _anm_avail=$2
    _anm_st=$3
    _anm_sf=$4
    is_int "$_anm_total" && [ "$_anm_total" -gt 0 ] || return 0

    _anm_ap=$(pct "$_anm_avail" "$_anm_total")
    add_check memory "$(t 'Memory available' 'Bộ nhớ trống')" \
        "$(tf '%s of %s free (%s%%)' '%s trên %s còn trống (%s%%)' "$(human_kb "$_anm_avail")" "$(human_kb "$_anm_total")" "$_anm_ap")" info \
        "$(t 'Android keeps RAM full on purpose and frees it as needed; low free memory is normal.' 'Android cố tình dùng gần hết RAM và tự giải phóng khi cần; RAM trống thấp là bình thường.')"
    add_stat "$(an_market_gb "$_anm_total")" "RAM"

    if is_int "$_anm_st" && [ "$_anm_st" -gt 0 ]; then
        _anm_sup=$(pct "$((_anm_st - _anm_sf))" "$_anm_st")
        add_check memory "$(t 'Swap / zram' 'Swap / zram')" \
            "$(tf '%s of %s used (%s%%)' 'đã dùng %s trên %s (%s%%)' "$(human_kb "$((_anm_st - _anm_sf))")" "$(human_kb "$_anm_st")" "$_anm_sup")" info \
            "$(t 'Android compresses memory into zram; high usage here is expected.' 'Android nén bộ nhớ vào zram; mức dùng cao ở đây là bình thường.')"
    fi
    return 0
}

# an_market_gb KIBIBYTES -> the marketing RAM size (MemTotal is always a little lower).
an_market_gb() {
    LC_ALL=C awk -v k="$1" 'BEGIN {
        g = k / 1048576; n = split("1 2 3 4 6 8 12 16 24 32 48 64", a, " ")
        for (i = 1; i <= n; i++) if (g <= a[i] + 0.05) { printf "%s GB", a[i]; exit }
        printf "%d GB", int(g + 0.999)
    }'
}

# ---------- uptime and load ----------
an_uptime() {
    _anu_secs=
    _anu_l1=
    _anu_l5=
    _anu_l15=
    # /proc/uptime and /proc/loadavg are denied to apps; the uptime command uses the sysinfo()
    # syscall instead. Force LC_ALL=C because procps translates "day"/"user".
    if [ -r "$BR_FSROOT/proc/uptime" ] && [ -r "$BR_FSROOT/proc/loadavg" ]; then
        _anu_secs=$(LC_ALL=C awk '{ printf "%d", $1 + 0; exit }' "$BR_FSROOT/proc/uptime" 2>/dev/null)
        _anu_lp=$(LC_ALL=C awk '{ print $1, $2, $3; exit }' "$BR_FSROOT/proc/loadavg" 2>/dev/null)
        # shellcheck disable=SC2086
        set -- $_anu_lp
        _anu_l1=$1
        _anu_l5=$2
        _anu_l15=$3
    fi
    if [ -z "$_anu_secs" ] || [ "$_anu_secs" = 0 ]; then
        _anu_out=$(run_to 3 sh -c 'LC_ALL=C uptime 2>/dev/null' 2>/dev/null)
        [ -n "$_anu_out" ] || _anu_out=$(an_sysrun 3 uptime)
        _anu_parsed=$(printf '%s\n' "$_anu_out" | LC_ALL=C awk '{
            la = $0; sub(/^.*load average: */, "", la); gsub(/,/, "", la)
            s = $0; sub(/^.* up +/, "", s); sub(/, *load average.*$/, "", s); sub(/, *[0-9?]+ +users?$/, "", s)
            d = 0; h = 0; m = 0
            if (match(s, /[0-9]+ +days?/)) { d = substr(s, RSTART, RLENGTH) + 0; s = substr(s, RSTART + RLENGTH) }
            if (match(s, /[0-9]+:[0-9]+/)) { split(substr(s, RSTART, RLENGTH), a, ":"); h = a[1] + 0; m = a[2] + 0 }
            else if (match(s, /[0-9]+ +min/)) { m = substr(s, RSTART, RLENGTH) + 0 }
            print d * 86400 + h * 3600 + m * 60, la }')
        # shellcheck disable=SC2086
        set -- $_anu_parsed
        _anu_secs=$1
        _anu_l1=$2
        _anu_l5=$3
        _anu_l15=$4
    fi

    if is_int "$_anu_secs" && [ "$_anu_secs" -gt 0 ]; then
        add_check boot "$(t 'Uptime' 'Thời gian chạy')" \
            "$(an_dur "$_anu_secs")" info
        add_stat "$(an_dur_short "$_anu_secs")" "$(t 'uptime' 'chạy liên tục')"
    fi
    # Load average is info-only on Android: it counts uninterruptible tasks and idle phones show high.
    if [ -n "$_anu_l15" ]; then
        add_check cpu "$(t 'Load average' 'Tải trung bình')" \
            "$(tf '%s / %s / %s (1 / 5 / 15 min)' '%s / %s / %s (1 / 5 / 15 phút)' "$_anu_l1" "$_anu_l5" "$_anu_l15")" info
    fi
    return 0
}

an_dur() {
    LC_ALL=C awk -v s="$1" 'BEGIN { s = int(s + 0); d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
        if (d > 0) printf "%d days %d h", d, h
        else if (h > 0) printf "%d h %d min", h, m
        else printf "%d min", m }'
}
an_dur_short() {
    LC_ALL=C awk -v s="$1" 'BEGIN { s = int(s + 0); d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
        if (d > 0) printf "%dd %dh", d, h
        else if (h > 0) printf "%dh %dm", h, m
        else printf "%dm", m }'
}

# ---------- security, integrity, patch level ----------
an_security() {
    # Security patch age -> the one number Google publishes. ok <= 183d, warn 184-365d, bad > 365d.
    _ansec_patch=$(an_prop ro.build.version.security_patch)
    if [ -n "$_ansec_patch" ]; then
        _ansec_days=$(an_days_since "$_ansec_patch")
        if is_int "$_ansec_days"; then
            if [ "$_ansec_days" -gt 365 ]; then
                add_check updates "$(t 'Security patch level' 'Mức vá bảo mật')" \
                    "$(tf '%s (%s days old)' '%s (cũ %s ngày)' "$_ansec_patch" "$_ansec_days")" bad \
                    "$(t 'The phone has not had a security update for over a year; install updates if any exist, otherwise avoid sensitive use or move to a supported device.' 'Máy đã hơn một năm không được vá bảo mật; cài cập nhật nếu có, nếu không hãy tránh dùng cho việc nhạy cảm hoặc chuyển sang thiết bị được hỗ trợ.')"
            elif [ "$_ansec_days" -gt 183 ]; then
                add_check updates "$(t 'Security patch level' 'Mức vá bảo mật')" \
                    "$(tf '%s (%s days old)' '%s (cũ %s ngày)' "$_ansec_patch" "$_ansec_days")" warn \
                    "$(t 'The security patch level is more than six months old; check for a system update.' 'Mức vá bảo mật đã cũ hơn sáu tháng; hãy kiểm tra cập nhật hệ thống.')"
            else
                add_check updates "$(t 'Security patch level' 'Mức vá bảo mật')" \
                    "$(tf '%s (%s days old)' '%s (cũ %s ngày)' "$_ansec_patch" "$_ansec_days")" ok
            fi
        else
            add_check updates "$(t 'Security patch level' 'Mức vá bảo mật')" "$_ansec_patch" info
        fi
    fi

    # Android version / upstream support — informational (the patch level above measures exposure).
    _ansec_rel=$(an_prop ro.build.version.release)
    if [ -n "$_ansec_rel" ]; then
        add_check updates "$(t 'Android version' 'Phiên bản Android')" \
            "$(tf 'Android %s' 'Android %s' "$_ansec_rel")" info \
            "$(t 'Security fixes for an Android version depend on the manufacturer continuing to ship updates.' 'Các bản vá bảo mật cho phiên bản Android phụ thuộc vào việc nhà sản xuất tiếp tục phát hành cập nhật.')"
    fi

    # Device integrity: ONE composite check (verified boot + bootloader lock + build keys + root).
    _ansec_vbs=$(an_prop ro.boot.verifiedbootstate)
    _ansec_flash=$(an_prop ro.boot.flash.locked)
    _ansec_vbmeta=$(an_prop ro.boot.vbmeta.device_state)
    _ansec_slock=$(an_prop ro.secureboot.lockstate)
    _ansec_btype=$(an_prop ro.build.type)
    _ansec_btags=$(an_prop ro.build.tags)
    _ansec_ist=info
    _ansec_parts=
    case "$_ansec_vbs" in
        green) _ansec_ist=ok; _ansec_parts=$(t 'verified boot: green' 'khởi động xác minh: green') ;;
        yellow) _ansec_ist=info; _ansec_parts=$(t 'verified boot: yellow (locked, custom key)' 'khởi động xác minh: yellow (khóa, chứng chỉ tùy chỉnh)') ;;
        orange) _ansec_ist=warn; _ansec_parts=$(t 'bootloader unlocked (orange)' 'bootloader đã mở khóa (orange)') ;;
        red) _ansec_ist=bad; _ansec_parts=$(t 'verified boot FAILED (red)' 'khởi động xác minh THẤT BẠI (red)') ;;
    esac
    _ansec_unlocked=0
    [ "$_ansec_flash" = 0 ] && _ansec_unlocked=1
    [ "$_ansec_vbmeta" = unlocked ] && _ansec_unlocked=1
    [ "$_ansec_slock" = unlocked ] && _ansec_unlocked=1
    if [ "$_ansec_unlocked" = 1 ]; then
        case "$_ansec_vbs" in orange | red) ;; *) _ansec_ist=$(an_worse "$_ansec_ist" warn); _ansec_parts="${_ansec_parts:+$_ansec_parts; }$(t 'bootloader unlocked' 'bootloader đã mở khóa')" ;; esac
    fi
    case "$_ansec_btype" in
        userdebug | eng) _ansec_ist=$(an_worse "$_ansec_ist" warn); _ansec_parts="${_ansec_parts:+$_ansec_parts; }$(tf '%s build' 'bản dựng %s' "$_ansec_btype")" ;;
    esac
    case "$_ansec_btags" in
        *test-keys* | *dev-keys*) _ansec_ist=$(an_worse "$_ansec_ist" warn); _ansec_parts="${_ansec_parts:+$_ansec_parts; }$(t 'test-keys build' 'bản dựng test-keys')" ;;
    esac
    # Root: id -u ONLY (never run su; command -v su is always true in Termux). File probes via
    # $BR_FSROOT so a denied/absent path simply does not match.
    _ansec_root=
    if [ "$BR_ROOT" = 1 ]; then
        _ansec_root=$(t 'running as root' 'đang chạy quyền root')
    else
        for _ansec_p in /system/bin/su /system/xbin/su /sbin/su /system/sbin/su /debug_ramdisk/su /su/bin/su /magisk/.core/bin/su; do
            if [ -e "$BR_FSROOT$_ansec_p" ]; then _ansec_root=$(t 'root (su) binary present' 'có tệp su (root)'); break; fi
        done
    fi
    if [ -n "$_ansec_root" ]; then
        _ansec_parts="${_ansec_parts:+$_ansec_parts; }$_ansec_root"
        [ "$_ansec_ist" = ok ] && _ansec_ist=info
    fi
    if [ -n "$_ansec_parts" ]; then
        _ansec_inote=
        case "$_ansec_ist" in
            bad) _ansec_inote=$(t 'The system failed verification at boot; it may be corrupted or tampered with, so reflash official firmware.' 'Hệ thống không qua xác minh khi khởi động; có thể bị hỏng hoặc can thiệp, hãy nạp lại firmware chính hãng.') ;;
            warn) _ansec_inote=$(t 'The bootloader is unlocked or the system is signed with public test keys; relock it or keep the phone physically safe.' 'Bootloader đang mở khóa hoặc hệ thống ký bằng test-keys công khai; hãy khóa lại hoặc giữ máy an toàn về mặt vật lý.') ;;
        esac
        add_check security "$(t 'Device integrity' 'Tính toàn vẹn thiết bị')" "$_ansec_parts" "$_ansec_ist" "$_ansec_inote"
    fi

    # Encryption (its own check — distinct advice).
    _ansec_crypto=$(an_prop ro.crypto.state)
    case "$_ansec_crypto" in
        encrypted) add_check security "$(t 'Storage encryption' 'Mã hóa bộ nhớ')" "$(t 'on' 'bật')" ok ;;
        unencrypted) add_check security "$(t 'Storage encryption' 'Mã hóa bộ nhớ')" "$(t 'off' 'tắt')" warn \
            "$(t 'Storage is not encrypted; data can be read if the phone is lost.' 'Bộ nhớ chưa mã hóa; dữ liệu có thể bị đọc nếu mất máy.')" ;;
        unsupported) add_check security "$(t 'Storage encryption' 'Mã hóa bộ nhớ')" "$(t 'not supported' 'không hỗ trợ')" info ;;
    esac

    # SELinux. A denied read is itself proof of enforcing (only an enforcing policy denies it).
    _ansec_se=$(an_getenforce)
    case "$_ansec_se" in
        *Enforcing*) add_check security "SELinux" "$(t 'Enforcing' 'Enforcing')" ok ;;
        *"Permission denied"*) add_check security "SELinux" "$(t 'Enforcing (inferred)' 'Enforcing (suy ra)')" ok \
            "$(t 'The mode could not be read, which on stock Android only an enforcing policy does.' 'Không đọc được chế độ, điều mà trên Android gốc chỉ xảy ra khi SELinux đang Enforcing.')" ;;
        *Permissive*) add_check security "SELinux" "$(t 'Permissive' 'Permissive')" bad \
            "$(t 'SELinux is not enforcing, which removes Android app isolation; use a kernel or ROM that enforces it.' 'SELinux không ở chế độ enforcing, làm mất cách ly ứng dụng của Android; hãy dùng kernel hoặc ROM bật enforcing.')" ;;
        *Disabled*) add_check security "SELinux" "$(t 'Disabled' 'Đã tắt')" bad \
            "$(t 'SELinux is disabled, which removes Android app isolation.' 'SELinux đã tắt, làm mất cách ly ứng dụng của Android.')" ;;
    esac

    # ADB over the network. warn by default; bad only when ADB authentication is off.
    _ansec_tcp=$(an_prop service.adb.tcp.port)
    [ -n "$_ansec_tcp" ] || _ansec_tcp=$(an_prop persist.adb.tcp.port)
    _ansec_adbsecure=$(an_prop ro.adb.secure)
    _ansec_adbd=$(an_prop init.svc.adbd)
    if is_int "$_ansec_tcp" && [ "$_ansec_tcp" -gt 0 ]; then
        if [ "$_ansec_adbsecure" = 0 ]; then
            add_check security "$(t 'ADB over network' 'ADB qua mạng')" \
                "$(tf 'port %s, no authentication' 'cổng %s, không xác thực' "$_ansec_tcp")" bad \
                "$(t 'ADB is open on the network without authentication; anyone nearby can control the phone, so disable it now.' 'ADB mở trên mạng mà không xác thực; người ở gần có thể điều khiển máy, hãy tắt ngay.')"
        else
            add_check security "$(t 'ADB over network' 'ADB qua mạng')" \
                "$(tf 'port %s' 'cổng %s' "$_ansec_tcp")" warn \
                "$(t 'ADB is listening on the network; turn it off when not in use (adb usb or reboot).' 'ADB đang lắng nghe trên mạng; hãy tắt khi không dùng (adb usb hoặc khởi động lại).')"
        fi
    elif [ "$_ansec_adbd" = running ]; then
        add_check security "$(t 'USB debugging' 'Gỡ lỗi USB')" "$(t 'enabled' 'đang bật')" info \
            "$(t 'USB debugging is on; turn it off when you are not developing.' 'Gỡ lỗi USB đang bật; hãy tắt khi bạn không lập trình.')"
    fi
    return 0
}

# ---------- Termux package state (local only; nothing here touches the network) ----------
an_packages() {
    if ! an_is_termux; then
        add_check apps "Termux" "$(t 'not a Termux shell (adb/root); package checks skipped' 'không phải trình vỏ Termux (adb/root); bỏ qua kiểm tra gói')" info
        return 0
    fi

    # Experimental Google Play build.
    _anp_apk=${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}}
    case "${TERMUX_VERSION:-}" in googleplay.*) _anp_apk=GOOGLE_PLAY_STORE ;; esac
    if [ "$_anp_apk" = GOOGLE_PLAY_STORE ]; then
        add_check apps "$(t 'Termux build' 'Bản dựng Termux')" "$(t 'Google Play (experimental)' 'Google Play (thử nghiệm)')" info \
            "$(t 'This is the Google Play build of Termux, which differs from the F-Droid build and has its own package set.' 'Đây là bản Termux trên Google Play, khác với bản F-Droid và có bộ gói riêng.')"
    fi

    # Termux:API presence.
    if ! have termux-battery-status; then
        add_check apps "Termux:API" "$(t 'not installed' 'chưa cài')" info \
            "$(t 'Install the Termux:API app and the termux-api package to report battery health and temperature.' 'Cài ứng dụng Termux:API và gói termux-api để xem sức khỏe và nhiệt độ pin.')"
    fi

    # Broken package state (fast, offline).
    if have dpkg; then
        run_to 10 dpkg --audit >"$BR_TMP/an_audit.txt" 2>/dev/null
        if [ -s "$BR_TMP/an_audit.txt" ]; then
            add_check apps "$(t 'Package state' 'Trạng thái gói')" "$(t 'some packages are half-configured' 'một số gói cài dở dang')" warn \
                "$(t 'Finish the interrupted install with dpkg --configure -a, then pkg upgrade.' 'Hoàn tất cài đặt dang dở bằng dpkg --configure -a, sau đó pkg upgrade.')"
        fi
    fi

    # Package list age -> only this makes an upgradable count meaningful (Termux is rolling).
    _anp_stale=0
    if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/var/lib/apt/lists" ]; then
        if [ -n "$(find "$PREFIX/var/lib/apt/lists" -name '*Packages*' 2>/dev/null)" ] &&
            [ -z "$(find "$PREFIX/var/lib/apt/lists" -name '*Packages*' -mtime -90 2>/dev/null)" ]; then
            _anp_stale=1
        fi
    fi

    # Upgradable count (cache only; the two -o options stop apt rewriting pkgcache.bin). Slow step.
    if [ "$BR_QUICK" != 1 ] && have apt; then
        _anp_up=$(run_to 20 apt list --upgradable -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= 2>/dev/null | LC_ALL=C grep -c 'upgradable from:')
        is_int "$_anp_up" || _anp_up=0
        if [ "$_anp_stale" = 1 ]; then
            add_check apps "$(t 'Package updates' 'Cập nhật gói')" \
                "$(tf '%s upgradable (list over 90 days old)' '%s gói có thể nâng cấp (danh sách cũ hơn 90 ngày)' "$_anp_up")" warn \
                "$(t 'Package lists are over 90 days old; run pkg upgrade to avoid broken installs.' 'Danh sách gói đã cũ hơn 90 ngày; chạy pkg upgrade để tránh cài hỏng.')"
        else
            add_check apps "$(t 'Package updates' 'Cập nhật gói')" \
                "$(tf '%s upgradable' '%s gói có thể nâng cấp' "$_anp_up")" info \
                "$(t 'Termux is a rolling release; run pkg upgrade to update.' 'Termux cập nhật liên tục; chạy pkg upgrade để nâng cấp.')"
        fi
    elif [ "$_anp_stale" = 1 ]; then
        add_check apps "$(t 'Package lists' 'Danh sách gói')" "$(t 'over 90 days old' 'cũ hơn 90 ngày')" warn \
            "$(t 'Package lists are over 90 days old; run pkg upgrade to avoid broken installs.' 'Danh sách gói đã cũ hơn 90 ngày; chạy pkg upgrade để tránh cài hỏng.')"
    fi
    return 0
}

collect_android() {
    an_load_props
    an_ident
    an_battery
    an_storage
    an_memory
    an_uptime
    an_security
    an_packages
    return 0
}

# ---------- Khung bao cao / Report skeleton ----------
init_model() {
    meta lang "$BR_LANG"
    meta platform "$BR_PLATFORM"
    meta days "$BR_DAYS"
    meta root "$BR_ROOT"

    # Display order of the check groups
    group boot "$(t 'Boot & uptime' 'Khởi động & thời gian chạy')"
    group cpu "$(t 'CPU & load' 'CPU & tải hệ thống')"
    group memory "$(t 'Memory' 'Bộ nhớ')"
    group storage "$(t 'Storage' 'Lưu trữ')"
    group battery "$(t 'Battery' 'Pin')"
    group hardware "$(t 'Hardware & temperature' 'Phần cứng & nhiệt độ')"
    group services "$(t 'Services' 'Dịch vụ')"
    group crashes "$(t 'Crashes & errors' 'Sự cố & lỗi hệ thống')"
    group updates "$(t 'Updates & support' 'Cập nhật & hỗ trợ')"
    group security "$(t 'Security' 'Bảo mật')"
    group network "$(t 'Network' 'Mạng')"
    group apps "$(t 'Apps & packages' 'Ứng dụng & gói phần mềm')"

    case "$BR_PLATFORM" in
        macos) ui title "$(t 'macOS health report' 'Báo cáo sức khỏe macOS')" ;;
        android) ui title "$(t 'Android device health report' 'Báo cáo sức khỏe thiết bị Android')" ;;
        *) ui title "$(t 'Linux system health report' 'Báo cáo sức khỏe hệ thống Linux')" ;;
    esac
    ui lvOk "$(t 'Good' 'Tốt')"
    ui lvWarn "$(t 'Watch' 'Cần theo dõi')"
    ui lvBad "$(t 'Problem' 'Có vấn đề')"
    ui lvInfo "$(t 'Info' 'Thông tin')"
    ui hBattery "$(t 'Battery health' 'Sức khỏe pin')"
    ui hBoot "$(t 'Boot time by phase' 'Thời gian khởi động theo giai đoạn')"
    ui bootTotal "$(t 'Total' 'Tổng')"
    ui hChecks "$(t 'Health checks' 'Kiểm tra sức khỏe')"
    ui hInfo "$(t 'System information' 'Thông tin hệ thống')"
    ui hdrItem "$(t 'Item' 'Hạng mục')"
    ui hdrValue "$(t 'Value' 'Giá trị')"
    ui hdrRating "$(t 'Rating' 'Đánh giá')"
    ui more "$(t '%s more row(s) in the HTML report' 'còn %s dòng nữa trong báo cáo HTML')"
    ui footer "$(t '© 2026 BootReport · Developed by NGUYEN QUOC ANH · Open-source under MIT License' '© 2026 BootReport · Phát triển bởi NGUYỄN QUỐC ANH · Mã nguồn mở (MIT License)')"
}

finish_model() {
    _fm=$(awk -F "$TAB" '$1 == "C" { c[$3]++ } END { printf "%d %d %d %d", c["ok"], c["warn"], c["bad"], c["info"] }' "$BR_MODEL")
    # shellcheck disable=SC2086
    set -- $_fm
    BR_N_OK=${1:-0}
    BR_N_WARN=${2:-0}
    BR_N_BAD=${3:-0}

    if [ "$BR_N_BAD" -gt 0 ]; then
        meta status bad
        meta headline "$(tf '%s problem(s) need attention' 'Phát hiện %s vấn đề cần xử lý' "$BR_N_BAD")"
    elif [ "$BR_N_WARN" -gt 0 ]; then
        meta status warn
        meta headline "$(tf 'No serious problems, %s item(s) to watch' 'Không có lỗi nghiêm trọng, %s mục cần theo dõi' "$BR_N_WARN")"
    else
        meta status ok
        meta headline "$(t 'Everything checked looks healthy' 'Mọi hạng mục kiểm tra đều ổn')"
    fi
    ui summary "$(tf '%s good, %s to watch, %s with problems' '%s tốt, %s cần theo dõi, %s có vấn đề' "$BR_N_OK" "$BR_N_WARN" "$BR_N_BAD")"
    ui subtitle "$(tf '%s · %s · generated %s' '%s · %s · tạo lúc %s' "$BR_HOST" "${BR_OS_LABEL:-$BR_PLATFORM}" "$(date '+%Y-%m-%d %H:%M')")"
}

# ---------- Xuat ra terminal / Terminal summary ----------
render_terminal() {
    _rt_color=0
    case "$BR_COLOR" in
        always) _rt_color=1 ;;
        auto) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then _rt_color=1; fi ;;
    esac
    LC_ALL=C awk -v color="$_rt_color" '
    BEGIN { FS = "\t" }
    function fmtms(m) {
        m += 0
        if (m < 1000) return sprintf("%d ms", m)
        if (m < 120000) return sprintf("%.1f s", m / 1000)
        return sprintf("%d min %d s", int(m / 60000), int((m % 60000) / 1000))
    }
    function cellfmt(kind, v) {
        if (kind == "~" && v ~ /^[0-9.]+$/) return fmtms(v)
        if (kind == "%" && v ~ /^[0-9.]+$/) return v "%"
        return v
    }
    $1 == "U" { u[$2] = $3; next }
    $1 == "M" { m[$2] = $3; next }
    $1 == "V" { vl[++nv] = $2; next }
    $1 == "G" { gid[++ng] = $2; gt[$2] = $3; next }
    $1 == "C" {
        if (!($2 in gt)) { gid[++ng] = $2; gt[$2] = $2 }
        n = ++cn[$2]; cs[$2, n] = $3; cnm[$2, n] = $4; cv[$2, n] = $5; cno[$2, n] = $6
        next
    }
    $1 == "T" { tid[++nt] = $2; tt[$2] = $3; tc[$2] = $5; next }
    $1 == "R" { n = ++rn[$2]; rnf[$2, n] = NF - 2; for (i = 3; i <= NF; i++) cell[$2, n, i - 2] = $i; next }
    END {
        if (color) {
            B = "\033[1m"; DIM = "\033[2m"; Z = "\033[0m"
            col["ok"] = "\033[32m"; col["warn"] = "\033[33m"; col["bad"] = "\033[31m"; col["info"] = "\033[36m"
        }
        tag["ok"] = "[ OK ]"; tag["warn"] = "[WARN]"; tag["bad"] = "[FAIL]"; tag["info"] = "[INFO]"

        printf "\n%sBootReport%s - %s\n", B, Z, u["title"]
        printf "%s%s%s\n\n", DIM, u["subtitle"], Z
        printf "%s%s%s%s\n", B, col[m["status"]], m["headline"], Z
        printf "%s\n", u["summary"]
        for (i = 1; i <= nv; i++) printf "  %s\n", vl[i]

        for (g = 1; g <= ng; g++) {
            id = gid[g]
            if (!(id in cn)) continue
            printf "\n%s%s%s\n", B, gt[id], Z
            for (i = 1; i <= cn[id]; i++) {
                s = cs[id, i]
                if (!(s in tag)) s = "info"
                printf "  %s%s%s %s: %s\n", col[s], tag[s], Z, cnm[id, i], cv[id, i]
                if (cno[id, i] != "") printf "         %s%s%s\n", DIM, cno[id, i], Z
            }
        }

        maxrows = 8
        for (k = 1; k <= nt; k++) {
            id = tid[k]
            if (!(id in rn)) continue
            nc = split(tc[id], hdr, "|")
            for (c = 1; c <= nc; c++) {
                kind[c] = ""
                ch = substr(hdr[c], 1, 1)
                if (ch == "#" || ch == "~" || ch == "%") { kind[c] = ch; hdr[c] = substr(hdr[c], 2) }
                w[c] = length(hdr[c])
            }
            shown = rn[id] < maxrows ? rn[id] : maxrows
            for (r = 1; r <= shown; r++)
                for (c = 1; c <= nc; c++) {
                    out[r, c] = cellfmt(kind[c], cell[id, r, c])
                    if (length(out[r, c]) > w[c]) w[c] = length(out[r, c])
                }
            printf "\n%s%s%s\n", B, tt[id], Z
            line = " "
            for (c = 1; c <= nc; c++) line = line sprintf(" %-" (w[c] > 48 ? 48 : w[c]) "s ", hdr[c])
            printf "%s%s%s\n", DIM, line, Z
            for (r = 1; r <= shown; r++) {
                line = " "
                for (c = 1; c <= nc; c++) line = line sprintf(" %-" (w[c] > 48 ? 48 : w[c]) "s ", out[r, c])
                printf "%s\n", line
            }
            if (rn[id] > shown) {
                more = u["more"]
                sub(/%s/, rn[id] - shown, more)
                printf "  %s(%s)%s\n", DIM, more, Z
            }
        }
        printf "\n"
    }' "$BR_MODEL"
}

# ---------- Du lieu JSON / JSON document ----------
render_json() {
    LC_ALL=C awk '
    BEGIN { FS = "\t" }
    # Escape one value for JSON embedded in <script>: no gsub() backslash tricks,
    # "<" becomes < so nothing can close the script block, control bytes become spaces.
    function jesc(s,    o, i, c, n) {
        o = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "\\") o = o "\\\\"
            else if (c == "\"") o = o "\\\""
            else if (c == "<") o = o "\\u003c"
            else if (c < " " || c == "\177") o = o " "
            else o = o c
        }
        return o
    }
    function q(s) { return "\"" jesc(s) "\"" }
    $1 == "M" { mk[++nm] = $2; mv[nm] = $3; next }
    $1 == "U" { uk[++nu] = $2; uv[nu] = $3; next }
    $1 == "V" { vl[++nv] = $2; next }
    $1 == "S" { sv[++ns] = $2; sl[ns] = $3; next }
    $1 == "I" { il[++ni] = $2; iv[ni] = $3; next }
    $1 == "B" { if ($2 == "row") { bl[++nbr] = $3; bv[nbr] = $4 } else { bk[++nb] = $2; bx[nb] = $3 } hasbat = 1; next }
    $1 == "P" { pl[++np] = $2; pm[np] = $3 + 0; next }
    $1 == "G" { gid[++ng] = $2; gt[$2] = $3; next }
    $1 == "C" {
        if (!($2 in gt)) { gid[++ng] = $2; gt[$2] = $2 }
        n = ++cn[$2]; cs[$2, n] = $3; cnm[$2, n] = $4; cv[$2, n] = $5; cno[$2, n] = $6
        cnt[$3]++
        next
    }
    $1 == "T" { tid[++nt] = $2; tt[$2] = $3; tno[$2] = $4; tc[$2] = $5; next }
    $1 == "R" {
        n = ++rn[$2]; line = ""
        for (i = 3; i <= NF; i++) line = line (i > 3 ? "," : "") q($i)
        rrow[$2, n] = line
        next
    }
    END {
        printf "{\"meta\":{"
        for (i = 1; i <= nm; i++) printf "%s%s:%s", (i > 1 ? "," : ""), q(mk[i]), q(mv[i])
        printf "},\"ui\":{"
        for (i = 1; i <= nu; i++) printf "%s%s:%s", (i > 1 ? "," : ""), q(uk[i]), q(uv[i])
        printf "},\"counts\":{\"ok\":%d,\"warn\":%d,\"bad\":%d,\"info\":%d}", cnt["ok"], cnt["warn"], cnt["bad"], cnt["info"]

        printf ",\"verdict\":["
        for (i = 1; i <= nv; i++) printf "%s%s", (i > 1 ? "," : ""), q(vl[i])
        printf "],\"stats\":["
        for (i = 1; i <= ns; i++) printf "%s{\"v\":%s,\"l\":%s}", (i > 1 ? "," : ""), q(sv[i]), q(sl[i])
        printf "],\"info\":["
        for (i = 1; i <= ni; i++) printf "%s[%s,%s]", (i > 1 ? "," : ""), q(il[i]), q(iv[i])
        printf "]"

        if (hasbat) {
            printf ",\"battery\":{"
            for (i = 1; i <= nb; i++) printf "%s:%s,", q(bk[i]), q(bx[i])
            printf "\"rows\":["
            for (i = 1; i <= nbr; i++) printf "%s[%s,%s]", (i > 1 ? "," : ""), q(bl[i]), q(bv[i])
            printf "]}"
        } else printf ",\"battery\":null"

        printf ",\"boot\":["
        for (i = 1; i <= np; i++) printf "%s{\"l\":%s,\"ms\":%.0f}", (i > 1 ? "," : ""), q(pl[i]), pm[i]
        printf "]"

        printf ",\"groups\":["
        first = 1
        for (g = 1; g <= ng; g++) {
            id = gid[g]
            if (!(id in cn)) continue
            printf "%s{\"id\":%s,\"title\":%s,\"checks\":[", (first ? "" : ","), q(id), q(gt[id])
            first = 0
            for (i = 1; i <= cn[id]; i++)
                printf "%s{\"s\":%s,\"n\":%s,\"v\":%s,\"note\":%s}", (i > 1 ? "," : ""), q(cs[id, i]), q(cnm[id, i]), q(cv[id, i]), q(cno[id, i])
            printf "]}"
        }
        printf "]"

        printf ",\"tables\":["
        first = 1
        for (k = 1; k <= nt; k++) {
            id = tid[k]
            if (!(id in rn)) continue
            printf "%s{\"id\":%s,\"title\":%s,\"note\":%s,\"cols\":[", (first ? "" : ","), q(id), q(tt[id]), q(tno[id])
            first = 0
            nc = split(tc[id], hdr, "|")
            for (c = 1; c <= nc; c++) printf "%s%s", (c > 1 ? "," : ""), q(hdr[c])
            printf "],\"rows\":["
            for (r = 1; r <= rn[id]; r++) printf "%s[%s]", (r > 1 ? "," : ""), rrow[id, r]
            printf "]}"
        }
        printf "]}\n"
    }' "$BR_MODEL"
}

# ---------- Bao cao HTML / HTML report ----------
render_html() {
    cat <<'BOOTREPORT_HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BootReport</title>
<style>
:root{
  --bg:#eef1f4; --panel:#ffffff; --ink:#14202b; --muted:#5d6b78; --line:#d9dfe5;
  --accent:#0f6e6e; --warn:#c98a00; --bad:#c23b32; --ok:#2f8a57; --info:#6b7a88;
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#eda100; --s5:#e87ba4;
}
@media (prefers-color-scheme:dark){
  :root{ --bg:#0f1519; --panel:#172027; --ink:#e6edf2; --muted:#8fa0ad; --line:#27343e;
         --accent:#4fc1c1; --warn:#e3a82b; --bad:#ef6a60; --ok:#5cc489; --info:#8fa0ad;
         --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 "Segoe UI Variable","Segoe UI",system-ui,-apple-system,Roboto,sans-serif}
main{max-width:1080px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:26px;margin:0 0 4px;font-weight:650;letter-spacing:-.01em}
h2{font-size:17px;margin:34px 0 12px;font-weight:650}
.sub{color:var(--muted);margin:0 0 22px;overflow-wrap:anywhere}
.verdict{background:var(--panel);border:1px solid var(--line);border-left:5px solid var(--accent);border-radius:6px;padding:16px 20px}
.verdict.ok{border-left-color:var(--ok)} .verdict.warn{border-left-color:var(--warn)} .verdict.bad{border-left-color:var(--bad)}
.verdict h2{margin:0 0 6px;font-size:18px}
.verdict p{margin:0 0 6px;color:var(--muted)}
.verdict ul{margin:8px 0 0;padding:0;list-style:none}
.verdict li{margin:3px 0;overflow-wrap:anywhere}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin-top:14px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:12px 16px}
.stat b{display:block;font-size:24px;font-weight:650;overflow-wrap:anywhere}
.stat span{color:var(--muted);font-size:13px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:16px;overflow-x:auto}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap;vertical-align:top}
th{font-weight:600;color:var(--muted);font-size:13px}
td.num,th.num{text-align:right}
td.name{white-space:normal;max-width:460px;overflow-wrap:anywhere}
tr.grp th{padding-top:18px;color:var(--ink);font-size:14px;border-bottom:2px solid var(--line)}
tbody tr:last-child td{border-bottom:0}
.meter{display:inline-block;height:8px;border-radius:4px;background:var(--accent);vertical-align:middle;margin-right:8px;min-width:2px}
.small{color:var(--muted);font-size:13px;margin-top:8px}
.hwrap{display:flex;gap:28px;align-items:center;flex-wrap:wrap}
.hwrap svg{width:140px;flex:none}
.ring-bg{fill:none;stroke:var(--line);stroke-width:12}
.ring-fg{fill:none;stroke-width:12;stroke-linecap:round;transform:rotate(-90deg);transform-origin:70px 70px}
.ring-fg.ok{stroke:var(--ok)} .ring-fg.warn{stroke:var(--warn)} .ring-fg.bad{stroke:var(--bad)} .ring-fg.info{stroke:var(--info)}
.ring-num{font-size:30px;font-weight:650;fill:var(--ink);text-anchor:middle}
.ring-lbl{font-size:12px;fill:var(--muted);text-anchor:middle}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 20px;margin:0}
.kv dt{color:var(--muted)} .kv dd{margin:0;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px}
.dot.ok{background:var(--ok)} .dot.warn{background:var(--warn)} .dot.bad{background:var(--bad)} .dot.info{background:var(--info)}
td .note{display:block;color:var(--muted);font-size:12px;white-space:normal}
.phases{display:flex;gap:2px;height:20px}
.phases i{display:block;min-width:3px}
.phases i:first-child{border-radius:4px 0 0 4px} .phases i:last-child{border-radius:0 4px 4px 0}
.phases i:only-child{border-radius:4px}
.legend{display:flex;gap:6px 18px;color:var(--muted);font-size:13px;margin-top:10px;flex-wrap:wrap}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
.legend b{color:var(--ink);font-weight:600}
.footer{margin-top:36px;padding-top:16px;border-top:1px solid var(--line);text-align:center;color:var(--muted);font-size:13px}
</style>
</head>
<body>
<main>
  <h1 id="title">BootReport</h1>
  <p class="sub" id="sub"></p>
  <section class="verdict" id="verdict"></section>
  <div class="stats" id="stats"></div>
  <div id="sections"></div>
  <footer class="footer"><p id="footer"></p></footer>
</main>
<script>
const D =
BOOTREPORT_HTML_HEAD
    render_json
    cat <<'BOOTREPORT_HTML_TAIL'
;
(function(){
"use strict";
const U = D.ui || {}, M = D.meta || {};
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const LOC = M.lang === "vi" ? "vi-VN" : "en-US";
const LV = {ok: U.lvOk, warn: U.lvWarn, bad: U.lvBad, info: U.lvInfo};
const st = s => Object.prototype.hasOwnProperty.call(LV, s) ? s : "info";
const dot = s => `<span class="dot ${st(s)}" aria-hidden="true"></span>${esc(LV[st(s)])}`;
const fmtMs = ms => ms < 1000 ? Math.round(ms) + " ms" : ms < 120000 ? (ms / 1000).toFixed(1) + " s" : Math.floor(ms / 60000) + " min " + Math.floor(ms % 60000 / 1000) + " s";

document.documentElement.lang = M.lang === "vi" ? "vi" : "en";
document.title = U.title || "BootReport";
$("title").textContent = U.title || "BootReport";
$("sub").textContent = U.subtitle || "";
$("footer").textContent = U.footer || "";

const groups = D.groups || [];

/* ---- Verdict: headline, collector remarks, then the items that need attention ---- */
(function(){
  const issues = [];
  ["bad", "warn"].forEach(s => groups.forEach(g => g.checks.forEach(c => { if (c.s === s) issues.push(c); })));
  const box = $("verdict");
  box.className = "verdict " + st(M.status);
  box.innerHTML = `<h2>${esc(M.headline)}</h2>` +
    (D.verdict || []).map(l => `<p>${esc(l)}</p>`).join("") +
    (issues.length ? "<ul>" + issues.slice(0, 8).map(c => `<li>${dot(c.s)} · <b>${esc(c.n)}</b>: ${esc(c.v)}</li>`).join("") + "</ul>" : "");
})();

$("stats").innerHTML = (D.stats || []).map(s => `<div class="stat"><b>${esc(s.v)}</b><span>${esc(s.l)}</span></div>`).join("");

const out = [];
const section = (title, body, note) => out.push(`<h2>${esc(title)}</h2><div class="panel">${body}</div>` + (note ? `<p class="small">${esc(note)}</p>` : ""));

/* ---- Battery ---- */
(function(){
  const b = D.battery;
  if (!b) return;
  const p = parseFloat(b.ring), has = !isNaN(p), s = st(b.status);
  const C = 2 * Math.PI * 52, arc = (has ? Math.max(0, Math.min(p, 100)) : 0) / 100 * C;
  const shown = has ? Math.round(p) + "%" : "?";
  const ring = `<svg viewBox="0 0 140 140" width="140" height="140" role="img" aria-label="${esc((b.ringlabel || "") + ": " + shown)}">
    <circle class="ring-bg" cx="70" cy="70" r="52"/>
    <circle class="ring-fg ${s}" cx="70" cy="70" r="52" stroke-dasharray="${arc} ${C}"/>
    <text class="ring-num" x="70" y="76">${shown}</text>
    <text class="ring-lbl" x="70" y="96">${esc(b.ringlabel || "")}</text></svg>`;
  const rows = (b.rows || []).map(r => `<dt>${esc(r[0])}</dt><dd>${esc(r[1])}</dd>`).join("");
  section(U.hBattery, `<div class="hwrap">${ring}<div><p style="margin:0 0 10px"><b>${dot(s)}</b>${b.message ? " · " + esc(b.message) : ""}</p><dl class="kv">${rows}</dl></div></div>`);
})();

/* ---- Boot phases: one stacked bar, legend carries every value ---- */
(function(){
  const P = (D.boot || []).filter(p => p.ms > 0).slice(0, 5);
  if (!P.length) return;
  const total = P.reduce((a, p) => a + p.ms, 0);
  const bar = P.map((p, i) => `<i style="flex:${p.ms} 1 0;background:var(--s${i + 1})" title="${esc(p.l)}: ${fmtMs(p.ms)}"></i>`).join("");
  const leg = P.map((p, i) => `<span><i style="background:var(--s${i + 1})"></i>${esc(p.l)} <b>${fmtMs(p.ms)}</b></span>`).join("");
  section(U.hBoot, `<p style="margin:0 0 10px">${esc(U.bootTotal)}: <b>${fmtMs(total)}</b></p><div class="phases" role="img" aria-label="${esc(U.hBoot)}">${bar}</div><div class="legend">${leg}</div>`, U.bootNote);
})();

/* ---- Health checks ---- */
(function(){
  if (!groups.length) return;
  let h = `<p style="margin:0 0 10px">${esc(U.summary)}</p><table><thead><tr><th scope="col">${esc(U.hdrItem)}</th><th scope="col">${esc(U.hdrValue)}</th><th scope="col">${esc(U.hdrRating)}</th></tr></thead><tbody>`;
  groups.forEach(g => {
    h += `<tr class="grp"><th colspan="3" scope="colgroup">${esc(g.title)}</th></tr>`;
    g.checks.forEach(c => {
      h += `<tr><td class="name">${esc(c.n)}</td><td class="name">${esc(c.v)}${c.note ? `<span class="note">${esc(c.note)}</span>` : ""}</td><td>${dot(c.s)}</td></tr>`;
    });
  });
  section(U.hChecks, h + "</tbody></table>");
})();

/* ---- Detail tables: a column title starting with # is numeric, ~ is a duration in ms, % is a percentage ---- */
(D.tables || []).forEach(T => {
  if (!T.rows || !T.rows.length) return;
  const cols = T.cols.map(c => { const k = "#~%".indexOf(c.charAt(0)) >= 0 ? c.charAt(0) : ""; return {k, t: k ? c.slice(1) : c}; });
  const max = cols.map((c, i) => c.k === "~" ? Math.max(1, ...T.rows.map(r => parseFloat(r[i]) || 0)) : 100);
  let h = "<table><thead><tr>" + cols.map(c => `<th scope="col"${c.k === "#" ? ' class="num"' : ""}>${esc(c.t)}</th>`).join("") + "</tr></thead><tbody>";
  T.rows.forEach(r => {
    h += "<tr>" + cols.map((c, i) => {
      const v = r[i] == null ? "" : r[i];
      if (c.k === "~" || c.k === "%") {
        const n = parseFloat(v);
        if (isNaN(n)) return `<td>${esc(v)}</td>`;
        const w = Math.max(2, Math.min(1, n / max[i]) * 120);
        return `<td><span class="meter" style="width:${w.toFixed(0)}px"></span>${c.k === "~" ? fmtMs(n) : n.toLocaleString(LOC, {maximumFractionDigits: 1}) + "%"}</td>`;
      }
      return `<td class="${c.k === "#" ? "num" : "name"}">${esc(v)}</td>`;
    }).join("") + "</tr>";
  });
  section(T.title, h + "</tbody></table>", T.note);
});

/* ---- System information ---- */
(function(){
  const I = D.info || [];
  if (!I.length) return;
  section(U.hInfo, `<dl class="kv">${I.map(r => `<dt>${esc(r[0])}</dt><dd>${esc(r[1])}</dd>`).join("")}</dl>`);
})();

$("sections").innerHTML = out.join("");
})();
</script>
</body>
</html>
BOOTREPORT_HTML_TAIL
}

# ---------- Noi luu va mo bao cao / Output path and opening ----------
resolve_out() {
    _ro_name=$(printf '%s' "$BR_HOST" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
    case "$BR_PLATFORM" in
        linux) _ro_file="BootReport-${_ro_name:-linux}.html" ;;
        *) _ro_file=BootReport.html ;;
    esac
    if [ -n "$BR_OUT" ]; then
        if [ -d "$BR_OUT" ]; then BR_OUT=${BR_OUT%/}/$_ro_file; fi
        return 0
    fi
    case "$BR_PLATFORM" in
        macos) set -- "$HOME/Desktop" "$HOME" "${TMPDIR:-/tmp}" ;;
        android) set -- "$HOME/storage/downloads" "$HOME" "${TMPDIR:-/tmp}" ;;
        *) set -- "$PWD" "$HOME" "${TMPDIR:-/tmp}" ;;
    esac
    for _ro_dir in "$@"; do
        if [ -n "$_ro_dir" ] && [ -d "$_ro_dir" ] && [ -w "$_ro_dir" ]; then
            BR_OUT=${_ro_dir%/}/$_ro_file
            return 0
        fi
    done
    BR_OUT=$_ro_file
}

open_report() {
    [ "$BR_OPEN" = 1 ] || return 0
    case "$BR_PLATFORM" in
        macos) have open && open "$BR_OUT" >/dev/null 2>&1 ;;
        android) have termux-open && termux-open "$BR_OUT" >/dev/null 2>&1 ;;
        *)
            # Only on a local desktop session; a VPS over SSH has no browser to open.
            if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -z "${SSH_CONNECTION:-}" ] && have xdg-open; then
                xdg-open "$BR_OUT" >/dev/null 2>&1 &
            fi
            ;;
    esac
    return 0
}

# ---------- Tham so & khoi dong / Arguments and startup ----------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --lang | --days | --out)
                [ $# -ge 2 ] || die "option $1 needs a value (see --help)" 2
                case "$1" in
                    --lang) BR_LANG=$2 ;;
                    --days) BR_DAYS=$2 ;;
                    --out) BR_OUT=$2 ;;
                esac
                shift
                ;;
            --lang=*) BR_LANG=${1#*=} ;;
            --days=*) BR_DAYS=${1#*=} ;;
            --out=*) BR_OUT=${1#*=} ;;
            --no-html) BR_HTML=0 ;;
            --no-open) BR_OPEN=0 ;;
            --json) BR_JSON=1 ;;
            --quick) BR_QUICK=1 ;;
            --net | --speedtest) BR_NET=1 ;;
            --no-color) BR_COLOR=never ;;
            --exit-code) BR_EXITCODE=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "unknown option: $1 (see --help)" 2 ;;
        esac
        shift
    done
    case "$BR_LANG" in auto | vi | en) ;; *) die "--lang must be auto, vi or en" 2 ;; esac
    is_int "$BR_DAYS" || die "--days must be a whole number" 2
    # Normalize through awk so a leading-zero value (08, 09) is read as decimal, not octal -
    # bare $(( 08 )) aborts the whole script under dash/ash.
    BR_DAYS=$(awk -v d="$BR_DAYS" 'BEGIN { printf "%d", d + 0 }')
    if [ "$BR_DAYS" -lt 1 ] || [ "$BR_DAYS" -gt 365 ]; then die "--days must be between 1 and 365" 2; fi
}

detect_platform() {
    case "$(uname -s 2>/dev/null)" in
        Darwin) BR_PLATFORM=macos ;;
        Linux)
            if [ -n "${TERMUX_VERSION:-}" ] || { [ -x /system/bin/app_process ] && have getprop; }; then
                BR_PLATFORM=android
            else
                BR_PLATFORM=linux
            fi
            ;;
        *) die "unsupported system: $(uname -s 2>/dev/null). BootReport.sh supports Linux, macOS and Android (Termux); on Windows use BootReport.ps1." ;;
    esac
}

# auto = Vietnamese when the system language is Vietnamese, English otherwise
detect_lang() {
    case "$BR_LANG" in vi | en) return 0 ;; esac
    _dl=
    case "$BR_PLATFORM" in
        android) _dl=$(getprop persist.sys.locale 2>/dev/null) ;;
        macos) _dl=$(defaults read -g AppleLocale 2>/dev/null) ;;
    esac
    [ -n "$_dl" ] || _dl=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
    case "$_dl" in vi*) BR_LANG=vi ;; *) BR_LANG=en ;; esac
}

make_tmp() {
    BR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootreport.XXXXXX" 2>/dev/null) || BR_TMP=
    if [ -z "$BR_TMP" ] || [ ! -d "$BR_TMP" ]; then
        BR_TMP="${TMPDIR:-/tmp}/bootreport.$$"
        (umask 077 && mkdir "$BR_TMP") 2>/dev/null || die "cannot create a temporary directory in ${TMPDIR:-/tmp}"
    fi
    BR_MODEL=$BR_TMP/model.tsv
    : >"$BR_MODEL"
    trap 'rm -rf "$BR_TMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}

main() {
    parse_args "$@"
    detect_platform
    detect_lang
    make_tmp
    init_timeout
    if [ "$(id -u 2>/dev/null)" = 0 ]; then BR_ROOT=1; fi
    BR_NOW=$(date +%s)
    BR_HOST=$(hostname 2>/dev/null) || BR_HOST=
    [ -n "$BR_HOST" ] || BR_HOST=$(uname -n 2>/dev/null)

    say "$(t 'BootReport: collecting system health data...' 'BootReport: đang thu thập thông tin sức khỏe hệ thống...')"
    init_model
    case "$BR_PLATFORM" in
        macos) collect_macos ;;
        android) collect_android ;;
        *) collect_linux ;;
    esac
    if [ "$BR_NET" = 1 ]; then
        say "$(t 'Running the network test (--net)...' 'Đang chạy kiểm tra mạng (--net)...')"
        net_collect
    fi
    finish_model

    if [ "$BR_JSON" = 1 ]; then render_json; else render_terminal; fi

    if [ "$BR_HTML" = 1 ]; then
        resolve_out
        if render_html >"$BR_OUT" 2>/dev/null; then
            _mn_msg="$(t 'HTML report saved' 'Đã xuất báo cáo HTML'): $BR_OUT"
            if [ "$BR_JSON" = 1 ]; then say "$_mn_msg"; else printf '%s\n' "$_mn_msg"; fi
            if [ "$BR_PLATFORM" = linux ] && [ -n "${SSH_CONNECTION:-}" ] && [ "$BR_JSON" != 1 ]; then
                printf '%s\n' "$(t 'Copy it to your computer to view it, for example:' 'Tải về máy tính để xem, ví dụ:') scp $(id -un 2>/dev/null)@$BR_HOST:$BR_OUT ."
            fi
            open_report
        else
            say "$(t 'Could not write the HTML report to' 'Không ghi được báo cáo HTML vào'): $BR_OUT"
        fi
    fi

    if [ "$BR_EXITCODE" = 1 ]; then
        if [ "$BR_N_BAD" -gt 0 ]; then exit 2; fi
        if [ "$BR_N_WARN" -gt 0 ]; then exit 1; fi
    fi
    exit 0
}

# Everything above is inside the brace group opened at the top of the script, so sh reads through the
# closing "}" below before running anything: a truncated "curl | sh" download is an incomplete group
# and executes nothing. stdin is detached so no child process can swallow the rest of the script.
main "$@" </dev/null
}
