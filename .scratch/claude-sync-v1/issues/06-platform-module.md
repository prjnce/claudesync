# 06 — Module platform: nat, cc_slug, realpath, khoá

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M1
Blocked by: 05
Spec: SPEC §3.3, §4.1, §4.6, §14 bước 1; code tham chiếu `docs/research/bash.md` (`cc_slug`), `docs/prototypes/cc_slug_iconv.sh`

## Phạm vi (`lib/platform.sh`)

- `nat()`: đặt `MSYS_NO_PATHCONV=1`, `MSYS2_ARG_CONV_EXCL='*'`; từ chối tham số là path POSIX bắt đầu bằng `/`; output qua `tr -d '\r'`. Helper `to_win_path` dùng `cygpath -m`.
- `cc_slug`: port slug của Claude (UTF-16 code unit, cắt 200 + `-base36(hash)`), hàm tự đặt `C.UTF-8` cục bộ.
- `realpath_disk`: Linux `realpath`; Windows tạm dùng PowerShell `GetFinalPathNameByHandle` (launcher thay thế ở #26).
- `pid_alive pid procStart`: Linux qua `/proc/<pid>/stat`; Windows qua `ps -W` (cột 4 là PID native) và so `procStart` (FILETIME).
- Khoá fd: `exec 9>>sync.lock`; Linux `flock -n 9`; Git Bash `perl -MFcntl=:flock`. Tiến trình con chạy lâu dùng `9>&-`. **Không** dùng khoá mkdir hoặc khoá PID.

## Tiêu chí nghiệm thu

- [ ] `cc_slug` pass 22/22 vector (Windows, WSL, Linux, tiếng Việt NFC/NFD, emoji, > 200 ký tự, chuỗi rỗng) trên cả 3 job CI.
- [ ] Test khoá: 20 tiến trình × 5 lần tăng một bộ đếm = đúng 100, trên Linux và Git Bash.
- [ ] Test khoá: tiến trình giữ khoá bị kill thì khoá được OS nhả (kịch bản **F3**: sleep giữa chu kỳ không để lại khoá kẹt).
- [ ] Test `nat()` từ chối `/c/Users/...` và chấp nhận `C:/Users/...`.

## Comments

**2026-10-05 — Claude:** Đã làm xong, chờ duyệt.
- `lib/platform.sh`: `nat` + `cs_nat_check_args`, `cs_to_win`, `cs_ps` (PowerShell qua `-EncodedCommand`, dữ liệu truyền qua biến môi trường), `cc_slug`, `cs_realpath_disk` (Windows: `GetFinalPathNameByHandle` qua PowerShell P/Invoke — chậm ~1 s/lần gọi, gom nhiều path một lần; #26 thay bằng launcher), `cs_live_pids`, `cs_pid_alive`, `cs_proc_start_ids`, `cs_lock_fd9`/`cs_lock_acquire` (flock hoặc perl, có tuỳ chọn chờ).
- Vector slug được dựng lại bằng oracle JS chép từ bundle Claude Code (`test/oracle/slug_oracle.js` → `test/fixtures/slug_vectors.tsv`, 22 vector): NFC/NFD tiếng Việt và hậu tố `zik0zk` khớp kết quả nghiên cứu. CI không cần node.
- Quy tắc `nat` chi tiết hơn SPEC §3.3: chỉ từ chối path POSIX có ≥ 2 thành phần (`/c/x/…`, `--f=/a/b`), vì `schtasks` dùng switch dạng `/TN`, `/Create`.
- 15 test mới; toàn bộ 44/44 pass trên Git Bash, WSL gawk, WSL mawk; shellcheck sạch.
