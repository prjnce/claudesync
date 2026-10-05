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
