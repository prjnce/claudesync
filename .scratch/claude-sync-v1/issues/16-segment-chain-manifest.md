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

## Comments

**2026-10-05 — Claude:** Đã làm xong, chờ duyệt.
- `lib/version.sh`: `cs_sha256_hex`, `cs_sha256_range`, `cs_cum0`, `cs_cum_next`, `cs_chain_cums`, `cs_entry_new/append/restart/needs_compaction/is_ancestor/verify`, `cs_jq` (bỏ CR, giữ mã thoát của jq kể cả khi không có pipefail).
- `lib/manifest.sh`: `cs_manifest_new/read/normal/same/write/put_session/session`, `cs_live_json`. Ghi bằng key đã sort + `gzip -n` → cùng nội dung thì cùng byte; `cs_manifest_write` trả rc 3 và không ghi khi chỉ khác `updated` (**F9**).
- Chốt 2 chi tiết SPEC §10 chưa nói rõ: (1) `cum_k = sha256(hex(cum_{k-1}) + hex(sha256(seg_k)))` — nối chuỗi hex ASCII; (2) `from[]` tích luỹ mọi version id bị viết lại / gộp chuỗi thay thế, nên "closure" chỉ là kiểm tra thuộc tập; giới hạn 500 phần tử.
- Vector chuẩn tính độc lập bằng node và ghi cứng trong test.
- Bẫy: hàm bọc `jq | tr` mất mã thoát của jq khi không có pipefail → `jq -e` luôn "đúng". Đã sửa bằng `PIPESTATUS`.
- 11 test mới; toàn bộ 119/119 pass trên 3 cấu hình; shellcheck sạch.
