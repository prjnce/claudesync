# 21 — Bundle, subagent, file-history

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 17
Spec: SPEC §4.3, §9.1 (`f/`, `sa/`), §12.7 bước 4, §13 (3 dòng đầu), §1.4 A1, A6

## Phạm vi

- Bundle `S/` (`subagents/*.meta.json`, `workflows/**`, `tool-results/*`, `mcp-tasks/*`, `remote-agents/**`, `custom-title.json`, `sent-prefix.json`), sidecar `S.cast`, `S.desktop-released.json`, `tasks/S/`, `uploads/S/`: immutable theo tên — chỉ upload file mới; trùng tên khác nội dung thì upload lại, manifest trỏ bản mới; cài cộng dồn (không xoá file local), mỗi file temp rồi `mv`.
- Danh sách không sync của §4.3 (dùng hàm lọc của #08).
- Transcript subagent `subagents/agent-*.jsonl`: chuỗi segment riêng cho mỗi agent (#16), dịch path như transcript chính.
- `file-history/S`: upload file `<hash16>@vN` mới; ghi `mode` vào manifest, khi cài thì `chmod`.
- **Giải nén bundle trước, đổi tên transcript sau** (§12.7 bước 4) để transcript không bao giờ trỏ tới file chưa có.
- Encode `relpath` an toàn cho tên object Drive.

## Tiêu chí nghiệm thu

- [ ] Session có subagent, tool-results, file-history từ A mở được trên B, có đủ dữ liệu (**A1** phần dữ liệu).
- [ ] Crash giữa lúc giải nén bundle và đổi tên transcript → chạy lại hoàn tất; Claude ở B đã dọn `tool-results` cũ → không tải lại trừ khi có version mới (**M7**).
- [ ] `/rewind` trên B: file-history có path đã dịch, mode thực thi được giữ (**A6**, kiểm thật ở #30).
- [ ] Test: không file nào trong danh sách cấm (§4.3) được upload.
