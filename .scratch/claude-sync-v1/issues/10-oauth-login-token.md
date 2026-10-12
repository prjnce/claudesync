# 10 — OAuth login/logout và lưu token

Status: done
Đề xuất: ready-for-agent (bước kiểm thật cần người dùng mở trình duyệt)
Type: task
Mốc: M2
Blocked by: 01, 06
Spec: SPEC §2, §15.1, §15.2; code tham chiếu `docs/prototypes/cs_gdrive_proto.sh`

## Phạm vi (`lib/drive.sh`, phần auth)

- PKCE S256 + `state` + redirect `http://127.0.0.1:<port>/` với cổng do OS cấp (bind 0). Không cổng cố định.
- Listener: Windows dùng PowerShell `HttpListener` qua `-EncodedCommand` (không dùng `-File`); Linux dùng `python3`. Song song đọc stdin để người dùng dán URL đã redirect (SSH/headless). Hết hạn 5 phút.
- Mở trình duyệt: Windows `Start-Process`; Linux `xdg-open` khi có DISPLAY; WSL `wslview` hoặc chỉ in URL. Luôn in URL.
- Đổi code: kiểm tra `scope` chứa `drive.file` và có `refresh_token`; có `refresh_token_expires_in` thì cảnh báo "App đang ở chế độ Testing — hãy Publish".
- Lưu token: Windows DPAPI CurrentUser qua PowerShell; Linux `token.json` quyền 600, thư mục 700.
- Refresh khi còn < 60 s, dưới khoá riêng. `invalid_grant|invalid_client|deleted_client` → trạng thái `LOGIN_REQUIRED`.
- `claude-sync login [--device]` (device flow cần client loại "TVs and Limited Input" cùng project), `logout` gọi revoke. Hiện "Đăng nhập: <tên> <email>" qua `about?fields=user`.
- Proxy: dùng `HTTPS_PROXY` đã lưu.

## Tiêu chí nghiệm thu

- [ ] Test (localfs/mock HTTP): state sai bị từ chối; thiếu `refresh_token` bị từ chối; token hết hạn được refresh đúng một lần khi 2 tiến trình cùng cần.
- [ ] Log không bao giờ chứa token, code, secret (test grep log).
- [ ] Kiểm thật: đăng nhập được trên Windows và WSL (người dùng xác nhận).
- [ ] Kịch bản **F6**: token bị thu hồi → `LOGIN_REQUIRED`, không vòng lặp thử lại.

## Comments

**2026-10-05 — Claude:** Đã làm xong phần chính, chờ duyệt.
- `lib/auth.sh`: PKCE S256 (khớp vector RFC 7636), state, listener loopback cổng do OS cấp (Windows: PowerShell `HttpListener` qua `-EncodedCommand`; Linux: `python3`), dán URL thủ công, đổi code (bắt buộc có `refresh_token` + scope `drive.file`; cảnh báo chế độ Testing), lưu token (Windows DPAPI CurrentUser — secret truyền qua biến môi trường, không qua argv; Linux file 600 trong thư mục 700), refresh dưới khoá fd 8, `invalid_grant|invalid_client|deleted_client|unauthorized_client` → rc 3, revoke khi logout. Endpoint cấu hình được để test bằng `file://`.
- CLI: `login [--client FILE]`, `logout`. `platform.sh` có `cs_lock_fd FD [WAIT]` tổng quát (fd 9 = sync, fd 8 = token).
- Response có `error` hoặc thiếu `access_token` bị coi là thất bại, không chỉ dựa mã HTTP.
- **Hoãn:** `login --device` (cần client "TVs and Limited Input" — người dùng chưa có). "Đăng nhập: <tên> <email>" sẽ hiện khi #11 có `cs_drive_whoami`.
- 13 test, gồm luồng login đầy đủ không cần trình duyệt (một tiến trình đóng vai trình duyệt gọi lại listener 127.0.0.1) và kiểm tra log không chứa token/code/secret. Toàn bộ 144/144 pass trên 3 cấu hình.
- Còn lại: người dùng đăng nhập thật bằng tool trên Windows và WSL (điểm duyệt 3).
