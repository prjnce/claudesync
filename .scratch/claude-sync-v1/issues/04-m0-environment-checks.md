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
