# 18 — Hội tụ đầy đủ: khởi tạo, viết lại, relocate, retention

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 17
Spec: SPEC §6 (thành viên cố định), §8 bước 3 và 5, §12.2, §12.3, §12.6, §12.9, §20 (`restore`)

## Phạm vi

- **Khởi tạo** §12.2 khi `base` rỗng (máy mới, mất DB): 4 quy tắc so version/prefix; không công bố khi project `needs_repair`.
- **Bảng quyết định** §12.3 đầy đủ, gồm trường hợp ứng viên không có quan hệ với B nhưng được `from`/`ancestor` xác nhận. Trường hợp "đổi + có ứng viên" chuyển cho #20 (trong ticket này: đánh dấu `conflict` và bỏ qua).
- **Viết lại** §12.6: không còn là prefix → chuỗi mới với `from`; chỉ đổi mtime → cập nhật DB, không công bố.
- **Relocate** (`/cd`, EnterWorktree): dòng `relocated` mới → tính lại `dir`; chuyển file theo §8.5 (chép, kiểm hash, đổi tên, chỉ xoá bản cũ khi `! [ new -ef old ]`). Thành viên cố định: đã sync thì sync tiếp; máy gốc công bố `project_id` mới hoặc `unmapped`; máy nhận chưa dịch được thì giữ vị trí cũ và báo.
- **Retention** §12.9: đọc `cleanupPeriodDays` mỗi chu kỳ; cài với mtime gốc (tương lai thì now); cũ hơn ngưỡng thì không cài, đếm vào `retention_skipped`; file đã cài biến mất → `local_absent_retention` / `local_absent_user`, **không lan truyền**.
- `claude-sync restore <sid>`: cài với mtime = now − 1 ngày.

## Tiêu chí nghiệm thu

- [x] Mọi tổ hợp của bảng §12.3 có test.
- [x] Máy B cài lại claude-sync (mất `~/.claude-sync`, còn `~/.claude`) đã có bản copy cũ của cùng sid → không fork giả, không công bố trùng (**F2**).
- [x] Relocate sang project khác và ra ngoài mọi project (**M11**, **P8** phần b).
- [x] B không nâng retention, session 45 ngày tuổi → không cài, status báo, `restore` cài được (**L12**).
- [x] Người dùng xoá session trên B → A không mất gì, B không tải lại.

## Comments

- 2026-10-07: xong theo 4 lát (commit riêng): (1) khởi tạo §12.2 (`cs_eng_init`), (2) viết lại/bảng §12.3/mtime-only/guard ≤3 uuid, (3) retention + `local_absent_*` + `restore`, (4) relocate hai phía (`cs_eng_reloc_target`, `cs_eng_move`). Test: F2, M11, P8b, L12 + các ca bảng quyết định trong `test/engine.bats`. Ca "đổi + có ứng viên" đánh dấu `conflict`, chuyển cho #20. `status.json`/`retention_skipped` hiện là file `state/retention_skipped` (sid, mtime) để #24 đọc.
