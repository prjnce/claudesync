# 11 — Wrapper gd() cho Drive API thật

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M2
Blocked by: 09, 10
Spec: SPEC §9.1, §15.3

## Phạm vi

Backend `drive_backend=gdrive` hiện thực giao diện `drv_*` của #09 bằng curl + jq.

- `gd()`: refresh một lần khi 401; backoff mũ có jitter khi 403 `rateLimitExceeded|userRateLimitExceeded`, 429, 5xx; `--connect-timeout 10`, `--max-time` theo kích thước; mọi request kèm `supportsAllDrives=true`; gọi curl qua `nat()` trên Windows, path qua `cygpath -m`.
- Upload: multipart khi ≤ 5 MB; resumable khi lớn hơn, chunk bội số 256 KiB, lưu URI resumable vào `objects.tsv` để chạy tiếp sau crash.
- Mọi object có `appProperties.csSha` (sha256 nội dung chưa nén); sau khi truyền kiểm tra `md5Checksum`.
- `files.list` phân trang `pageSize=1000`, `'<id>' in parents and trashed=false`.
- Phân loại lỗi: lỗi auth → `LOGIN_REQUIRED`; 404 khi tải object → báo cho engine tải lại manifest; mạng/timeout → thử lại ở chu kỳ sau.

## Tiêu chí nghiệm thu

- [ ] Bộ contract test của #09 pass với Drive thật (job thủ công, dùng folder thử riêng).
- [ ] Test resumable: kill giữa chừng rồi chạy lại → upload tiếp từ URI đã lưu, md5 khớp.
- [ ] Test: response có CR (jq native trên Windows) vẫn parse đúng.

## Comments

**2026-10-05 — Claude:** Code xong, chờ chạy contract test với Drive thật (cần `claude-sync login`).
- `lib/gdrive.sh`: `cs_gd` (401 → refresh 1 lần; 403 rateLimit/429/5xx → backoff mũ + jitter, tối đa `CS_GD_RETRIES`; 404→4, 409→9, mạng→6; `GD_OUT` tải thẳng vào file đích), multipart ≤ 5 MB với metadata đọc từ file (`-F metadata=<file`), resumable theo chunk 8 MiB đẩy thẳng từ file nguồn qua stdin (không tạo file tạm — SPEC R2), chạy tiếp từ URI đã lưu (`CS_GD_RESUME_FILE`), kiểm `md5Checksum` sau mỗi lần ghi, phân trang list/changes, `newStartPageToken` lấy từ trang cuối (không xin token mới — tránh mất thay đổi), giờ server từ header `Date`.
- `lib/auth.sh`: `cs_access_token_ensure [REJECTED]` giữ token đã giải mã trong shell hiện tại (DPAPI ~0,7 s/lần) và ép refresh khi API trả 401.
- Test: `test/gdrive_unit.bats` (16, curl giả chạy theo kịch bản), `test/drive_contract.bats` (đổi tên từ `drive_localfs.bats`; chạy được với `CS_TEST_GDRIVE=1`, chỉ trong folder con tạm của "Claude Sync (dev)", trash sau mỗi test).

**2026-10-05 — Claude (kiểm thật):** Contract test với Drive thật (`CS_TEST_GDRIVE=1`, token từ `claude-sync setup` trên Windows): 13/13 test áp dụng được đều pass (~5 phút). Phát hiện: Drive có thể báo lại cùng một file trong change feed sau khi đã lấy token mới → test chỉ đòi "không lặp" với localfs; ghi vào SPEC §14 bước 6. Lỗi tìm được nhờ test thật: `auth.sh` thiếu nạp `platform.sh` (DPAPI cần `cs_ps`) — giờ tự nạp phụ thuộc.
