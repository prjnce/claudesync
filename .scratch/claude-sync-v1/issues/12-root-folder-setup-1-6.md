# 12 — Folder gốc, marker, setup bước 1–6

Status: done
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

## Comments

**2026-10-05 — Claude:** Code xong, chờ kiểm thật (điểm duyệt 3).
- `lib/root.sh`: tìm folder gốc qua **file marker** `.claude-sync-root` (`csRoot=1`, `csSchema=1`, SPEC §9.1) — folder cha phải còn và không ở thùng rác; nhiều kết quả → chọn marker cũ nhất; tạo root + marker + `machines/`; `cs_root_check` (ROOT_MISSING, không tự tạo lại); `machines/<machine_id>` với appProperties `csMachine/csName/csOs`; `machine_id` UUID v4; `.claude-sync-owner` (từ chối chiếm config dir của bản cài khác — F12); `state/drive.json`.
- `lib/setup.sh` + `lib/ui.sh`: wizard bước 0–6 (`lang deps client proxy login root machine`), chạy lại được, `setup --step <tên>`; câu hỏi ra stderr, trả lời từ stdin (test bằng câu trả lời pipe vào); proxy WinINET đọc qua `reg.exe query`. CLI: `setup`, `folder [show]`.
- 11 test (localfs, 2 "máy" dùng chung Drive giả): máy 2 tìm thấy root của máy 1 và tham gia, chạy lại setup không tạo root/máy mới (**F7**), owner file (**F12**), root bị trash → ROOT_MISSING.
- Còn lại: người dùng chạy `setup` thật trên Windows và WSL; chạy `CS_TEST_GDRIVE=1` contract test với Drive thật.

**2026-10-05 — Claude (kiểm thật, điểm duyệt 3):** Người dùng chạy `claude-sync setup` thật:
- Windows (Git Bash, tiếng Việt): đăng nhập qua trình duyệt tự mở, tạo "Claude Sync" (`1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`) + marker, máy `Frank-PC`.
- WSL (user `frank`, tiếng Anh): listener python3 trong WSL nhận callback từ trình duyệt Windows (không cần dán URL); bước 5 "Found the existing claude-sync folder" và liệt kê `Frank-PC (windows)`; máy `Frank-WSL-Officer`.
- → Tiêu chí xong M2 đạt. Lưu ý: WSL chạy bằng `frank`, trong khi Claude thật trong WSL chạy bằng `root` → máy thật cho E2E là `root` (cần setup riêng sau).
