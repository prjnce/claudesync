# 15 — Repair dữ liệu cũ (§19)

Status: needs-triage
Đề xuất: ready-for-agent (chạy thật trên máy này cần người dùng xác nhận từng bước)
Type: task
Mốc: M3
Blocked by: 04, 08, 13, 14
Spec: SPEC §19, §1.4 A8; xem thêm memory "TransFlow migration hazards"

## Phạm vi (`lib/repair.sh`, `claude-sync repair [--dry-run] [--project X]`)

Theo đúng thứ tự §19:

1. Thư mục rác trong `projects/` (`*.bak-*`…): dùng làm nguồn bản gốc cho bước 4 **trước**, sau đó (xác nhận) chuyển vào `~/.claude-sync/backups/`.
2. ID trùng giữa các thư mục slug hợp lệ: giống nhau → giữ bản ở thư mục đúng; khác → bản chứa bản kia làm phần đầu là bản chính; không thì giữ bản mới hơn, bản kia vào backups.
3. CRLF: bỏ `\r` cuối dòng. Phát hiện bằng `od`/`tr`/`grep -U`, không dùng `grep` thường.
4. JSON có dấu cách → dạng gọn đúng như `JSON.stringify`, ưu tiên: (a) nguyên byte dòng gốc trong `.bak` nếu giống về JSON; (b) `node`; (c) `python3` với `separators=(',',':'), ensure_ascii=False`. **Không dùng jq.** Dòng không parse được thì giữ nguyên và báo.
5. cwd lạ (`/mnt/d/...`, `D:\...` trên Linux) → root local qua transform #13, với danh sách alias cũ người dùng xác nhận.
6. Giữ mtime (`touch -r`); backup mọi file trước khi sửa; báo cáo số file, số dòng đổi, số dòng không parse được.
7. Bỏ cờ `needs_repair` của project. Mỗi thao tác có journal.

- `--dry-run` chỉ báo cáo, không ghi gì.
- Engine không công bố project đang `needs_repair`.

## Tiêu chí nghiệm thu

- [ ] Fixture tái hiện dữ liệu TransFlow: 12 transcript (CRLF, JSON có dấu cách, cwd `/mnt/d`), thư mục `.bak` chứa bản gốc, 4 session native không cần sửa.
- [ ] Sau repair: không còn CRLF, mọi dòng ở dạng gọn, cwd đã dịch, `.bak` ra khỏi `projects/`, không còn ID trùng; 4 session native không đổi byte nào.
- [ ] Test: dòng có ký tự `0x7F` và surrogate lẻ được giữ đúng byte.
- [ ] Kill giữa chừng rồi chạy lại → kết quả giống chạy một lần.
- [ ] **A8** pass trên máy này (người dùng chạy `repair --dry-run` rồi `repair`, kiểm tra `claude --resume <id>` mở đúng bản).

## Comments

**2026-10-05 — Claude:** Code xong; chờ người dùng duyệt chạy thật (điểm duyệt 4).
- `lib/repair.sh` + `claude-sync repair [--dry-run] [--yes] [--project X]`: xét mọi `*.jsonl` (cả subagent) trong thư mục slug hợp lệ; phát hiện CR / JSON có dấu cách / cwd lạ; với mỗi dòng: (a) byte gốc từ thư mục rác nếu bằng nhau về JSON, (b) node, (c) python3, dòng đã gọn sẵn thì giữ nguyên byte; dịch cwd lạ qua transform (alias `/mnt/d/...` → root project của máy này, người dùng xác nhận); ghi file một lần, đếm dòng/CR trong luồng; backup + giữ mtime + journal; bỏ qua session đang mở; chuyển thư mục rác vào `~/.claude-sync/backups/repair-<ts>/junk/`.
- **Hai lỗi tìm được nhờ dry-run trên dữ liệu thật:**
  1. Nhận nhầm file native: cwd dạng Git Bash `/d/Projects/...` (trong `wireIngestContext`) bị coi là path lạ → đã loại trừ dạng ổ đĩa MSYS.
  2. **jq 1.6 `-R` làm hỏng ký tự UTF-8 nhiều byte ở ranh giới bộ đệm trên dòng dài** (121 dòng của `1cafbcb6`) → so khớp dùng node/python, không dùng `jq -R`. Có test hồi quy tái hiện lỗi.
- **Dry-run thật (sau sửa):** 23 transcript (12 chính + 11 subagent), 19.884 dòng: tất cả lấy byte gốc từ `.bak` trừ 115 dòng của `0c49cf5c` ghi lại bằng node; 0 dòng lỗi; 0 lỗi kiểm tra; thư mục `.bak` sẽ được chuyển ra backup. Đã kiểm chứng dry-run không thay đổi file nào trong `~/.claude/projects`.
- Project `TransFlow` (`34a928c6`, root `d:\Projects\TransFlow`) đã được map trong `~/.claude-sync` để có alias dịch path.
- 12 test.
- Bổ sung: so khớp chạy qua `/bin/sh` của awk (dash trên Ubuntu) → chương trình node/python và path truyền qua biến môi trường, không nhúng vào chuỗi lệnh; `repair` dọn journal dở dang khi khởi động; test 0x7F + surrogate lẻ và kill giữa chừng. 14 test; toàn bộ pass trên 3 cấu hình; shellcheck sạch.
