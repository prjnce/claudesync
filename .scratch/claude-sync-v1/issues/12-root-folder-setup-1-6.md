# 12 — Folder gốc, marker, setup bước 1–6

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M2
Blocked by: 07, 10, 11, 32
Spec: SPEC §5.2 (`.claude-sync-owner`), §6 (machine_id), §9.1, §16 bước 1–6

## Phạm vi

- `claude-sync setup` khung wizard chạy lại được, mỗi bước chạy riêng được; trong ticket này làm bước 0–6:
  0. Chọn ngôn ngữ English (mặc định) / Tiếng Việt → ghi `lang` vào config (SPEC §20.1, #32).
  1. Kiểm tra phụ thuộc (dùng bootstrap #05).
  2. OAuth client: in hướng dẫn §16.1 nếu chưa có, hỏi đường dẫn JSON, chép vào `~/.claude-sync/oauth-client.json` (600).
  3. Proxy: lưu `HTTPS_PROXY` (Windows đọc thêm proxy WinINET).
  4. Đăng nhập (#10).
  5. Folder gốc: tìm theo `appProperties csRoot=1`. 1 kết quả → dùng; 0 → hỏi tên (mặc định "Claude Sync"), tạo trong My Drive + marker `{csRoot:"1", csSchema:"1"}`; nhiều → chọn `createdTime` cũ nhất, cảnh báo. Màn hình xác nhận: tài khoản, tên folder, link, các máy đã tham gia.
  6. Đặt tên máy (mặc định hostname, WSL thêm `-wsl`); sinh `machine_id`; tạo `machines/<machine_id>/`; ghi `<claude-config>/.claude-sync-owner`.
- Engine từ chối chạy khi `.claude-sync-owner` ghi machine_id khác.
- `claude-sync folder [show]`.
- Mất root (`ROOT_MISSING`): báo, **không** tự tạo lại.

## Tiêu chí nghiệm thu

- [ ] Test localfs: máy 2 tìm thấy root của máy 1; không bao giờ tạo 2 root (kịch bản **F7**).
- [ ] Test: chạy lại setup không đổi machine_id, không tạo folder mới.
- [ ] Test `.claude-sync-owner` chặn bản cài thứ 2 (kịch bản **F12** phần config dir dùng chung).
- [ ] Kiểm thật (tiêu chí xong M2): đăng nhập + tìm hoặc tạo root trên Windows và WSL.
