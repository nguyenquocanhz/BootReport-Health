# BootReport-Health 💻🔍

> **Kiểm tra sức khỏe laptop & Windows Boot Performance Diagnostic Tool**

Một công cụ mã nguồn mở viết bằng PowerShell giúp kiểm tra toàn diện hiệu năng khởi động, tình trạng phần cứng (Pin, SSD/NVMe, RAM) và lịch sử lỗi hệ thống (BSOD, Event Logs) của thiết bị Windows, tự động kết xuất ra báo cáo HTML trực quan, hiện đại.

---

## 🌟 Tính năng nổi bật

- ⚡ **Boot Performance Analysis**: Phân tích thời gian khởi động chi tiết (MainPathBootTime, BootPostBootTime), phát hiện tiến trình gây chậm quá trình boot.
- 🔋 **Battery Health & Capacity**: Đọc dung lượng thiết kế, dung lượng sạc tối đa hiện tại, độ chai pin (%) và chu kỳ sạc.
- 💾 **Disk Health & SMART**: Giám sát nhiệt độ, thời gian hoạt động (Power-On Hours), tỷ lệ sức khỏe SSD/NVMe và cảnh báo sector lỗi.
- 💥 **Crash & BSOD Diagnostics**: Thu thập và phân tích mã lỗi màn hình xanh (Bugcheck Code), log sự kiện Windows và crash dump gần nhất.
- 🌐 **Interactive HTML Report**: Giao diện báo cáo HTML đa ngôn ngữ (Tiếng Việt / English), hỗ trợ Dark Mode & Light Mode mượt mà.
- 🖥️ **Đa nền tảng**: Windows (`BootReport.ps1`) và **Linux / macOS / Android-Termux** (`BootReport.sh`) — cùng một phong cách báo cáo, chạy bằng một dòng lệnh, không cần cài thêm.

---

## 🚀 Hướng dẫn sử dụng

### ⚡ 1. Chạy nhanh 1 dòng lệnh (Không cần tải file)

Mở **PowerShell** (khuyến nghị Run as Administrator) và dán lệnh sau:

```powershell
irm https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.ps1 | iex
```
*(Nếu mở ở PowerShell thường, script sẽ tự động kích hoạt hộp thoại UAC để xin quyền Administrator)*

### 📁 2. Chạy từ file tải về (Offline / Local)

Mở PowerShell tại thư mục chứa file và chạy:

```powershell
powershell -ExecutionPolicy Bypass -File .\BootReport.ps1
```

### 2. Tùy chọn nâng cao

Bạn có thể truyền thêm tham số cấu hình:

```powershell
# Quét lịch sử 30 ngày gần nhất và lưu file báo cáo vào ổ D:
powershell -ExecutionPolicy Bypass -File .\BootReport.ps1 -Days 30 -Out "D:\BootReport.html"

# Chọn ngôn ngữ hiển thị (vi hoặc en)
powershell -ExecutionPolicy Bypass -File .\BootReport.ps1 -Lang vi
```

### 3. Xem tài liệu & hướng dẫn giao diện

Mở trực tiếp file `index.html` trên trình duyệt để tham khảo tài liệu kỹ thuật, giao diện song ngữ (Tiếng Việt / English) và hướng dẫn xử lý sự cố chi tiết.

---

## 🐧 Linux · 🍎 macOS · 🤖 Android (Termux)

Ngoài Windows, BootReport còn có bản **`BootReport.sh`** (POSIX shell) cho máy chủ/VPS Linux, máy Mac và điện thoại Android chạy Termux. Chỉ một dòng lệnh, **không cài thêm gì**, **chỉ đọc** thông tin — không sửa hệ thống, không gửi dữ liệu đi đâu (trừ khi bạn tự bật `--net`).

### ⚡ Chạy nhanh

```bash
curl -fsSL https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.sh | sh
```

Trên **Linux server/VPS** nên chạy bằng root để có đủ dữ liệu SMART, journal và firewall:

```bash
curl -fsSL https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.sh | sudo sh
```

Script tự nhận diện hệ điều hành, in tóm tắt ngay trên terminal (hữu ích cho VPS không có giao diện) và xuất báo cáo HTML độc lập (Desktop trên macOS, thư mục Download trên Termux, thư mục hiện tại trên Linux).

### 🎛️ Tham số

| Cờ | Ý nghĩa |
|---|---|
| `--lang vi\|en\|auto` | Ngôn ngữ báo cáo (mặc định theo hệ thống) |
| `--days N` | Số ngày quét log / sự cố (mặc định 30) |
| `--out FILE` | Nơi lưu báo cáo HTML |
| `--net` | Bật đo mạng (ping, mất gói, tốc độ tải) — **mặc định TẮT**, là thứ duy nhất gọi mạng |
| `--quick` | Bỏ qua các mục chậm (cập nhật gói, SMART) |
| `--no-compare` | Không so sánh / lưu snapshot của lần chạy trước (tắt phần "thay đổi so với lần trước") |
| `--no-html` / `--no-open` | Chỉ in terminal / không tự mở báo cáo |
| `--json` | In dữ liệu JSON thay cho bản tóm tắt |

Truyền tham số khi chạy một dòng lệnh (lưu ý dấu `-s --`):

```bash
curl -fsSL https://raw.githubusercontent.com/nguyenquocanhz/BootReport-Health/main/BootReport.sh | sh -s -- --lang vi --days 14 --net
```

### 🔎 Kiểm tra những gì

- **Linux (VPS / server / desktop):** thời gian boot (systemd), tải CPU · CPU steal · iowait, RAM/swap, dung lượng & inode ổ đĩa, SMART, software RAID, **nguồn điện (AC/pin)**, nhiệt độ, dịch vụ lỗi, sự cố kernel/OOM/lỗi I/O & ổ đĩa, cập nhật đang chờ & hệ điều hành hết hỗ trợ (EOL), cấu hình SSH/firewall/SELinux, **rà các cổng mạng rủi ro / dấu hiệu cửa hậu đang lắng nghe ngay trên máy** (Telnet, RAT/backdoor, dịch vụ phơi ra `0.0.0.0`…), và **kiểm kê container Docker + phiên bản phần mềm máy chủ** (cảnh báo bản đã hết hỗ trợ).
- **Theo dõi xu hướng:** mỗi lần chạy lưu một snapshot nhỏ và lần sau hiển thị **"thay đổi so với lần chạy trước"** (mục nào xấu đi / cải thiện / mới xuất hiện) — hợp để chạy định kỳ bằng cron trên server. Tắt bằng `--no-compare`.
- **macOS (Intel & Apple Silicon):** độ chai pin & chu kỳ, nguồn điện, SMART ổ đĩa, memory pressure, kernel panic, SIP/FileVault/Gatekeeper/firewall, cập nhật đang chờ, startup items.
- **Android (Termux, không cần root):** pin (mức / health / nhiệt độ / ước lượng chai), lưu trữ, RAM, **mức vá bảo mật (security patch)**, verified boot / bootloader / mã hoá, ADB qua mạng, gói Termux cần cập nhật.

> ⚠️ `--net` liên hệ tới một máy chủ đo tốc độ công cộng (speed.cloudflare.com) để ước lượng đường truyền. Mặc định tắt; chỉ bật khi bạn muốn.

---

## 💖 Ủng hộ tác giả (Donate)

Dự án BootReport hoàn toàn miễn phí & mã nguồn mở. Nếu công cụ hữu ích cho công việc của bạn, hãy gửi tặng một cốc cà phê ủng hộ tác giả nhé:

- **Ngân hàng:** Vietcombank (Ngoại thương Việt Nam)
- **Số tài khoản:** `nguyenquocanh1368`
- **Chủ tài khoản:** `NGUYEN QUOC ANH`
- **Nội dung:** `BootReport Donate`

<p align="center">
  <img src="https://api.vietqr.io/image/vietcombank-nguyenquocanh1368-compact2.png?amount=20000&addInfo=BootReport%20Donate&accountName=NGUYEN%20QUOC%20ANH" width="260" alt="VietQR Donate Vietcombank nguyenquocanh1368" />
</p>

---

## 📄 Bản quyền (License)

Dự án được phân phối dưới giấy phép [MIT License](LICENSE).

