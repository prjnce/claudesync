# 29 — Setup hoàn chỉnh, doctor, config, uninstall

Status: ready-for-human
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

- [x] Chạy `setup` lần 2 trên máy đã cài: không đổi gì ngoài những gì người dùng chọn lại.
- [x] Người dùng từ chối nâng retention → setup vẫn hoàn tất, status báo session bị bỏ qua theo retention.
- [x] `uninstall --purge` rồi `setup` lại → máy nhận lại đúng vùng Drive cũ (hoặc tạo machine_id mới có cảnh báo).
- [x] Test: phát hiện layout lạ thì engine dừng với `ERROR: unsupported layout`, không ghi gì.

## Comments

- 2026-10-11: `setup` bước 7-10 (`repair`, `projects`, `retention`, `finish`) trong `lib/setup.sh`, cảnh báo secret một lần, `CS_SETUP_ONLY_STEPS` để chạy một phần; `lib/doctor.sh` (kiểm tra đầy đủ: client, token, root + nhiều root, service/timer, launcher chạy thử trên Windows, hook, retention thấp, ID trùng, thư mục rác, owner, layout lạ R1); `claude-sync uninstall [--purge] [--yes]` (`lib/uninstall.sh`: gỡ service + hook, purge chỉ xoá `~/.claude-sync`, giữ owner file nên setup lại nhận đúng machine_id và vùng Drive cũ); engine dừng với `ERROR: unsupported layout` (CLAUDE_CODE_HOVER_REST hoặc `*.compact.tmp.*`) trước khi ghi gì; sửa repair: dọn trạng thái `needs_repair` sau khi repair xong. Test: `test/setup2.bats` (6 ca). `config` đã làm ở #25. Còn lại cho người (#30): chạy setup thật trên máy thật, kiểm `service install` thật, giá trị tối thiểu/tối đa version Claude cho R1 (hiện chỉ kiểm HOVER_REST và `*.compact.tmp.*`).
