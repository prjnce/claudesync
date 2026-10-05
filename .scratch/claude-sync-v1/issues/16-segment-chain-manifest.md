# 16 — Chuỗi segment và mô hình manifest

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 05
Spec: SPEC §9.2, §9.3, §10

## Mục tiêu

Thư viện thuần (không gọi Drive) cho version và manifest, để engine (#17+) chỉ việc gọi.

## Phạm vi (`lib/engine_model.sh` hoặc trong `lib/engine.sh`)

- `cum_0 = sha256("claude-sync:" + sid)`, `cum_k = sha256(cum_{k-1} ‖ sha256(seg_k))`; version_id = `cum` của segment cuối.
- Tạo segment nối thêm: cắt tại `\n` cuối cùng; segment tham chiếu chuỗi của máy khác qua field `m`.
- Viết lại: chuỗi mới, segment 0 = toàn bộ file, `from` = các version bị thay thế.
- Gộp chuỗi khi > 50 segment (nội dung giống hệt, version mới ghi vào `from`).
- `ancestor(a, v)` theo §10.
- Đọc/ghi `manifest.json.gz` (`gzip -n`) theo schema §9.2; đọc `live.json`. Ghi manifest bằng công cụ nào thì cũng phải ra JSON hợp lệ, không CR.
- So sánh "manifest có đổi không" để chỉ ghi khi có thay đổi (kịch bản **F9**).

## Tiêu chí nghiệm thu

- [ ] Test `cum` với vector cố định (giống nhau trên 3 job CI).
- [ ] Test `ancestor`: qua `segs`, qua `from` lồng nhiều tầng, sau khi gộp chuỗi.
- [ ] Test round-trip manifest: đọc → ghi → đọc giống nhau; jq trên Windows không để lọt CR.
- [ ] Ghi lại manifest không đổi nội dung thì không tạo upload.
