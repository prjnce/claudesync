# 11 — Wrapper gd() cho Drive API thật

Status: needs-triage
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
