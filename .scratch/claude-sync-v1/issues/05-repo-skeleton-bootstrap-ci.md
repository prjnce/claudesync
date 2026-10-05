# 05 — Repo skeleton, bootstrap, core, CI

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M1
Blocked by: —
Spec: SPEC §3, §5.1, §5.2, §20 (exit code), §23.1 (CI)

## Mục tiêu

Có khung repo chạy được `bin/claude-sync --version` và `claude-sync help` trên Git Bash, Ubuntu (gawk) và Ubuntu chỉ có mawk, với CI xanh.

## Phạm vi

- Cây thư mục: `bin/claude-sync`, `lib/{core,platform,claude,transform,drive,store,engine,scheduler,hooks,repair,ui}.sh` (file rỗng có header), `test/` (bats-core), `test/fixtures/`.
- `.gitattributes`: `*.sh *.awk *.bats text eol=lf`; fixture so byte thì `-text`.
- Bootstrap §3.2 cho mọi entrypoint: `set -Eeuo pipefail`, `inherit_errexit`, kiểm tra bash ≥ 4.4; nhận diện OS và WSL; sửa `PATH` trên Windows; `LC_ALL=C`; kiểm tra find/sort là GNU; kiểm tra công cụ bắt buộc (§3.1), in lệnh cài cho phần thiếu (Ubuntu: `sudo apt install curl jq`); chọn `CS_AWK`; nạp proxy đã lưu.
- `lib/core.sh`: log (chưa xoay vòng — xoay vòng ở #24), hàm lỗi với exit code §20, đọc/ghi `config` dạng `key=value`, ghi atomic (temp cùng thư mục rồi `mv`).
- Bộ phân lệnh CLI: lệnh chưa làm trả "not implemented" với exit 1; sai cú pháp exit 2.
- CI: 3 job (`ubuntu-latest`, `ubuntu-latest` đã gỡ gawk để chỉ còn mawk, `windows-latest` với shell bash = Git Bash). Chạy shellcheck + bats.

## Tiêu chí nghiệm thu

- [ ] `claude-sync --version` chạy trên cả 3 job CI.
- [ ] Test bootstrap: thiếu một công cụ thì báo đúng tên và lệnh cài; bash < 4.4 thì từ chối.
- [ ] Test ghi atomic: process bị kill giữa chừng không để lại file đích hỏng.
- [ ] shellcheck không cảnh báo.
- [ ] Comment code bằng tiếng Anh.

## Comments

**2026-10-05 — Claude:** Đã làm xong, chờ duyệt.
- Có: `bin/claude-sync`, `lib/core.sh` (bootstrap, log, config, ghi atomic), 10 module stub, `.gitattributes`, `.shellcheckrc`, `.github/workflows/test.yml`, bats-core 1.14.0 vendored trong `test/vendor/` (đã chuyển về LF), `test/run-all.sh` (Git Bash + WSL gawk + WSL mawk + shellcheck).
- `test/run-all.sh`: 26/26 test pass trên cả 3 cấu hình, shellcheck sạch.
- Đổi so với ticket: `cs_write_atomic TARGET CMD...` nhận lệnh thay vì stdin, để producer lỗi không bao giờ commit nội dung dở.
- Còn lại: CI trên GitHub chỉ kiểm chứng được sau khi push.
- Lưu ý: clone git trên máy này ra CRLF cho bats-core (do `.gitattributes` của repo đó); `grep -Uc $'\r'` trên MSYS đếm sai CR — dùng `tr -cd '\r' | wc -c` hoặc `od`.
