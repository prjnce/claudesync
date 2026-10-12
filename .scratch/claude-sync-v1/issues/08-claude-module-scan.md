# 08 — Module claude: quét session, registry, retention

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M1
Blocked by: 06
Spec: SPEC §4.1–§4.6, §6 (`launchCwd`), §12.9 (đọc retention), §20 (`doctor`)

## Phạm vi (`lib/claude.sh`)

- Tìm thư mục config: `CLAUDE_CONFIG_DIR` hoặc `<home>/.claude`; tôn trọng `CLAUDE_CODE_PROJECT_DIR_NAME`.
- Quét bằng **một lần** `find -printf` trên `projects/*/`: liệt kê session (`<sid>.jsonl`), size, mtime; phát hiện thư mục rác (tên không khớp `^[A-Za-z0-9-]+$`) và ID trùng giữa các thư mục.
- `launchCwd(S)`: `relocatedCwd` của dòng `relocated` cuối; nếu không có thì `.cwd` **cấp trên cùng** của dòng parse được đầu tiên trong toàn file (không giới hạn 64 KB, không lấy `cwd` lồng nhau). Đọc bằng jq (chỉ đọc), output qua `tr -d '\r'`.
- Registry `sessions/<pid>.json`: đọc, chỉ tin bản có `pidDomain` khớp máy này, kiểm tra sống bằng `pid_alive` (#06). Trả danh sách `sid` đang mở.
- Đọc `cleanupPeriodDays` hiệu lực (settings user, rồi project; mặc định 30).
- Danh sách "không bao giờ sync" của §4.3 thành một hàm lọc dùng chung.
- `claude-sync projects list` dạng thô (theo thư mục slug + launchCwd, chưa có project_id — #14 nâng cấp).
- `claude-sync doctor` cơ bản: phụ thuộc, thư mục config, số session, thư mục rác, ID trùng.

## Tiêu chí nghiệm thu

- [ ] Test `launchCwd`: dòng đầu là assistant có tool_use; transcript subagent; file có dòng hỏng ở đầu; có `relocated` (kịch bản **P9**).
- [ ] Test registry: bản ghi bỏ lại sau crash (PID chết hoặc `procStart` lệch) không được coi là đang mở; `pidDomain` máy khác bị bỏ qua.
- [ ] Test lọc §4.3: không file nào trong danh sách cấm lọt qua.
- [ ] `doctor` trên máy này báo đúng thư mục `D--Projects-TransFlow.bak-*` và 12 ID trùng.

## Comments

**2026-10-05 — Claude:** Đã làm xong, chờ duyệt.
- `lib/claude.sh`: `cs_claude_dir` (CS_CLAUDE_DIR > CLAUDE_CONFIG_DIR > home), `cs_claude_project_dir_name`, `cs_claude_slug`, `cs_claude_scan` (một lần `find -printf`), `cs_claude_junk_dirs`, `cs_claude_dup_ids`, `cs_launch_cwd`, `cs_claude_pid_domain`, `cs_claude_registry`, `cs_claude_live_sessions`, `cs_proc_start_same`, `cs_claude_retention_days`, `cs_claude_settings_set` (backup + jq + bỏ CR), `cs_claude_never_sync`, `cs_claude_projects_report`. CLI: `doctor`, `projects list`.
- **Sửa SPEC §4.6 theo dữ liệu thật**: trên Linux/WSL `pidDomain` = `linux:<machine-id>:pid:[…]` (không phải `win32:…`), `procStart` = trường 22 của `/proc/<pid>/stat` (không phải `ps lstart` như nghiên cứu) → đã sửa `cs_proc_start_ids` của #06.
- Chạy trên dữ liệu thật của máy này: `doctor` báo `projects/D--Projects-TransFlow.bak-20260925-170208` và 12 ID trùng, retention hiện là 30 ngày (mặc định).
- Bẫy đã gặp: (1) jq 1.6 để `fromjson?` nuốt `break` của `first()` → không dùng `first()` cùng `?`; (2) `read` với `IFS=$'\t'` gộp các tab liên tiếp → field rỗng làm lệch cột; registry dùng `\x1f`.
- 22 test mới; toàn bộ 81/81 pass trên 3 cấu hình; shellcheck sạch.
