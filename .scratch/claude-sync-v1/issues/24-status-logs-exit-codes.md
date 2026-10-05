# 24 — status.json, status, log, exit code

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 17
Spec: SPEC §14 bước 3–5, §20 (`status`, `logs`, exit code), §21

## Phạm vi

- `status.json` (ghi atomic cuối mỗi chu kỳ và khi dừng sớm): `state ∈ OK|OFFLINE|LOGIN_REQUIRED|ROOT_MISSING|NEEDS_REPAIR|ERROR`; `last_run`, `last_ok_pull`, `last_ok_push`, `boot_time`; `behind{}`, `live_elsewhere{}`, `conflicts[]`, `waiting_map{}`, `retention_skipped`. Định nghĩa API ghi từng phần để #19, #20, #22 dùng.
- Cổng offline: `curl -m 3 https://clients3.google.com/generate_204`; backoff 5 s→30 s trong 5 phút đầu sau boot/resume, sau đó tối đa 300 s, hạn 30 phút → `OFFLINE`.
- `claude-sync status [--json]`: bảng tóm tắt + lần chạy kế tiếp (hỏi scheduler nếu có).
- Log `logs/claude-sync.log`: xoay vòng 5 MB × 5; mỗi dòng: thời gian ISO, trigger, cấp độ, thông điệp. **Không bao giờ** ghi token, secret, nội dung transcript. `claude-sync logs [-f]`.
- Exit code thống nhất: 0 OK, 1 lỗi, 2 sai cú pháp, 3 cần đăng nhập, 4 offline, 5 bận, 6 cần repair.

## Tiêu chí nghiệm thu

- [ ] Mỗi trạng thái của `state` có test sinh ra nó và exit code tương ứng.
- [ ] Test: log không chứa chuỗi token giả và nội dung transcript giả đã chèn vào fixture.
- [ ] Mất mạng giữa chu kỳ, crash, token thu hồi → không hỏng dữ liệu local/remote, `status` báo đúng (**A7** phần giả lập).
