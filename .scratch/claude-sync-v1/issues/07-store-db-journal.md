# 07 — DB local và journal

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M1
Blocked by: 05
Spec: SPEC §5.2, §11, §14.1

## Phạm vi (`lib/store.sh`)

- Tạo cây `~/.claude-sync/` (§5.2) với quyền đúng (thư mục 700 trên Linux).
- Đọc/ghi atomic các bảng TSV của §11: `sessions.tsv`, `objects.tsv`, `projects.tsv`, `forks.tsv`; `known/<sid>` (chỉ thêm); `drive.json`; `remote/<machine_id>.json`; `base/mem/...`.
- API theo từng dòng: get/upsert/delete theo khoá, không fork trong vòng lặp (đọc cả file bằng một lần awk).
- Journal §14.1: `journal_begin op json` → trả path; `journal_end path`; `journal_pending` liệt kê bản dở. Hàm dọn `*.csync-tmp` theo bản ghi journal.
- Kiểm tra `staging/` cùng ổ đĩa với `~/.claude` (`stat -c %d`).

## Ngoài phạm vi

- Logic khôi phục từng loại thao tác (mỗi ticket engine tự xử lý loại của mình).
- Quy tắc dựng lại DB khi mất (#18).

## Tiêu chí nghiệm thu

- [ ] Test: ghi đè song song (dưới khoá) không làm hỏng TSV.
- [ ] Test: giá trị có tab/newline bị từ chối hoặc escape rõ ràng.
- [ ] Test: journal dở dang được liệt kê sau khi process bị kill.
- [ ] Xoá toàn bộ `state/` thì lần gọi sau tự tạo lại cấu trúc rỗng, không lỗi.
