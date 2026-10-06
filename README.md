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

Mở trực tiếp file `index.html` trên trình duyệt để tham khảo tài liệu kỹ thuật và hướng dẫn xử lý sự cố chi tiết.

---

## 📄 Bản quyền (License)

Dự án được phân phối dưới giấy phép [MIT License](LICENSE).
