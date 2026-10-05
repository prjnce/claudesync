# 29 — Setup hoàn chỉnh, doctor, config, uninstall

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M6
Blocked by: 12, 14, 15, 25, 26, 27, 31
Spec: SPEC §12.9 (retention), §14 (lần sync đầu), §16 bước 7–10, §20 (`config`, `doctor`, `uninstall`), §22 (cảnh báo bảo mật)

## Phạm vi

- `setup` bước 7–10, nối tiếp #12:
  7. `repair --dry-run`; có vấn đề thì đề nghị chạy `repair` và chặn sync các project cần repair.
  8. `projects select` (#14), rồi duyệt các mục chờ map bằng luồng xác nhận của #31.
  9. Retention: hỏi trước khi đặt `cleanupPeriodDays: 3650` (backup settings.json; jq + `tr -d '\r'`).
  10. Chọn chu kỳ 5|10 → `service install` → `hooks install` → `doctor` → **lần sync đầu** chạy ngay trên terminal, không giới hạn thời gian, có tiến độ (kịch bản **F11**).
- Cảnh báo một lần lúc setup: transcript là văn bản thường, có thể chứa secret.
- `claude-sync config get|set <key> <value>`: `interval=5|10` (cập nhật scheduler), `guard=block|warn|off`, `throttle_live_min`, `lang=en|vi` (SPEC §20.1).
- `doctor` đầy đủ: phụ thuộc, OAuth client, token, folder gốc (liệt kê nếu có nhiều root), task/timer, launcher (chạy thử, kiểm sentinel + exit code), hook, retention, ID trùng, thư mục rác, `.claude-sync-owner`, layout Claude lạ (rủi ro **R1**: version, `CLAUDE_CODE_HOVER_REST`, `*.compact.tmp.*` → `ERROR: unsupported layout`).
- `claude-sync uninstall [--purge]`: gỡ service + hook; `--purge` xoá `~/.claude-sync`; không đụng `~/.claude` và Drive.

## Tiêu chí nghiệm thu

- [ ] Chạy `setup` lần 2 trên máy đã cài: không đổi gì ngoài những gì người dùng chọn lại.
- [ ] Người dùng từ chối nâng retention → setup vẫn hoàn tất, status báo session bị bỏ qua theo retention.
- [ ] `uninstall --purge` rồi `setup` lại → máy nhận lại đúng vùng Drive cũ (hoặc tạo machine_id mới có cảnh báo).
- [ ] Test: phát hiện layout lạ thì engine dừng với `ERROR: unsupported layout`, không ghi gì.
