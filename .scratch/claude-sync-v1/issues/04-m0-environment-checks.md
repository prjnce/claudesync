# 04 — Spike: linger, loader CRLF, bridge, WSL config dir

Status: needs-triage
Đề xuất: ready-for-human
Type: research
Mốc: M0
Blocked by: —
Spec: SPEC §25 Q5, Q6, Q7, Q9; §4.8; §19

Gom các kiểm chứng nhỏ còn lại của M0. Mỗi mục độc lập, làm theo thứ tự nào cũng được.

## Q5 — linger trên Ubuntu đích

- [ ] Trên máy Ubuntu thật: `loginctl enable-linger "$USER"` có cần sudo không (polkit)? Sau khi reboot mà chưa đăng nhập, `systemctl --user list-timers` có chạy không?

## Q6 — loader native với transcript CRLF hoặc JSON có dấu cách

- [ ] Chép một transcript TransFlow chưa sửa (CRLF, JSON có dấu cách) ra thư mục slug thử, chạy `claude --resume <id>`. Lịch sử hiện đủ, thiếu, hay không mở được? Có ghi lại file không?
- Ảnh hưởng: nếu loader đọc được thì repair (#15) vẫn cần (vì `--resume` tìm dòng dạng gọn), nhưng mức độ khẩn cấp giảm.

## Q7 — bridge-session khi resume trên máy khác cùng tài khoản

- [ ] Tìm một session có dòng `bridge-session`. Resume trên máy 2 cùng tài khoản trong khi máy 1 vẫn mở: hai máy có tranh một bridge Remote Control không?
- [ ] Chốt: giữ nguyên, cảnh báo, hay bỏ dòng `bridge-session` khi cài (ảnh hưởng #17/#18).

## Q9 — WSL dùng `CLAUDE_CONFIG_DIR=/mnt/c/...`

- [ ] Có ai trong setup của người dùng chạy Claude trong WSL trỏ vào config của Windows không? Nếu có: xác nhận phương án mặc định "cùng máy, root `/mnt/d/...` là alias" và `.claude-sync-owner` chặn bản cài thứ 2.

## Kết quả

- [ ] Cập nhật SPEC §25 cho từng câu hỏi.

## Answer

2026-10-12, làm phần không cần máy thứ hai:

- **Q5 (một phần):** trên WSL `Ubuntu2404` (systemd, user `frank` thuộc nhóm sudo), `loginctl enable-linger "$USER"` chạy **không cần sudo** (đã thử: `disable-linger` → `Linger=no`, `enable-linger` → `Linger=yes`; trạng thái cuối `yes` như ban đầu). Chưa đo: reboot mà chưa đăng nhập thì `systemctl --user list-timers` có chạy không, và polkit trên một Ubuntu desktop/server thật (cần người).
- **Q6: loader đọc được.** Chép nguyên bản chưa sửa `886eeca9-…` (từ `backups/repair-20261005T091656Z`: 91 dòng, CRLF, JSON có dấu cách, cwd `/mnt/d/Projects/TransFlow`, 500 KB) vào thư mục slug thử rồi chạy `claude -p --resume <id>`: Claude đọc đủ lịch sử và trích đúng tin nhắn đầu tiên. Không ghi lại phần cũ (500 KB đầu giống hệt từng byte); chỉ nối thêm 31 dòng gọn ở cuối (Claude trên Windows tự kết thúc dòng bằng CRLF). `repair` vẫn cần vì tìm theo `--resume` dựa trên dòng dạng gọn, nhưng mức khẩn cấp thấp hơn. Thử với một file; 11 session còn lại chưa thử.
- **Q7 (một phần):** resume không fork một session đã có `bridge-session` **ghi thêm một dòng `bridge-session` mới** (`bridgeSessionId` mới) vào cuối file. Chưa đo xung đột giữa hai máy cùng tài khoản (cần máy 2).
- **Q9: không áp dụng ở cấu hình này.** Trong WSL `Ubuntu2404` (cả `root` và `frank`) không đặt `CLAUDE_CONFIG_DIR`, `~/.claude` là thư mục thật, không phải symlink sang `/mnt/c`. Giữ mặc định "cùng máy" + `.claude-sync-owner`.
- Đã dọn: thư mục slug thử trong `~/.claude/projects`.
