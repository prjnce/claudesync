# 28 — Wrapper `claude-sync claude`

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M5
Blocked by: 17, 31
Spec: SPEC §17.4, §20 (`sync --pull-only --project`)

## Phạm vi

- `claude-sync run --pull-only --project <cwd>`: chỉ chạy phần cài cho project chứa `cwd`, giới hạn 60 s, hiện tiến độ ra terminal.
- `claude-sync claude [args…]`: chạy pull-only như trên, rồi `exec claude "$@"`. Offline, cần đăng nhập, hoặc hết 60 s → in cảnh báo một dòng rồi vẫn mở Claude.
- Có TTY và `cwd` chưa thuộc project nào nhưng là ứng viên của một mục chờ map (#31): hỏi "Thư mục này có phải project <alias> trên <máy> không? [y/N/skip]" trước khi pull; `y` → map (qua hàm kiểm tra của #31) rồi pull project đó; `skip` → ghi `skipped`. Không có TTY thì không hỏi.
- Tôn trọng khoá: nếu một lần `run` khác đang giữ khoá thì chờ nó (tối đa trong 60 s) thay vì thoát ngay.
- In gợi ý alias (`alias claude='claude-sync claude'`) trong `setup`/README, không tự sửa rc file.

## Tiêu chí nghiệm thu

- [x] Test giả lập: A viết thêm, B chạy wrapper → khi `claude` được exec thì file đã có phần mới.
- [x] Test: wrapper không bao giờ chặn việc mở Claude quá 60 s.
- [x] Chạy wrapper trong `~/projects/TransFlowX` khi `TransFlow` đang chờ map → hỏi; trả lời `y` → session của A có ngay khi Claude mở. Chạy qua pipe (không TTY) → không hỏi.
- [x] Đối số có dấu cách, `--resume <id>` được truyền nguyên vẹn.

## Comments

- 2026-10-11: `lib/wrapper.sh` + `claude-sync run --pull-only --project <folder|alias|id>` (engine: chỉ cài, một project, hạn mềm 60 s, không công bố, không ghi `last_ok_push`) + `test/wrapper.bats` (5 ca: file đã có dòng mới khi claude được exec, đối số có dấu cách/`--resume` giữ nguyên, không công bố gì, khoá bận không chặn quá `CS_WRAPPER_BUDGET`, offline chỉ cảnh báo, hỏi map khi có TTY và không hỏi khi không có). Hook test: `CS_WRAPPER_ASSUME_TTY`, `CS_WRAPPER_CWD`, `CS_CLAUDE_BIN`. Chưa làm: in gợi ý `alias claude='claude-sync claude'` trong `setup`/README (#29/#30). Kiểm thật trên máy có Claude + `~/projects/TransFlowX` ở #30.
