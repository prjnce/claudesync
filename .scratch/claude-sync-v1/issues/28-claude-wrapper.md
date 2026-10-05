# 28 — Wrapper `claude-sync claude`

Status: needs-triage
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

- [ ] Test giả lập: A viết thêm, B chạy wrapper → khi `claude` được exec thì file đã có phần mới.
- [ ] Test: wrapper không bao giờ chặn việc mở Claude quá 60 s.
- [ ] Chạy wrapper trong `~/projects/TransFlowX` khi `TransFlow` đang chờ map → hỏi; trả lời `y` → session của A có ngay khi Claude mở. Chạy qua pipe (không TTY) → không hỏi.
- [ ] Đối số có dấu cách, `--resume <id>` được truyền nguyên vẹn.
