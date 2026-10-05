# 10 — OAuth login/logout và lưu token

Status: needs-triage
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
