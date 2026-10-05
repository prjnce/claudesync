# 09 — Giao diện backend Drive + backend localfs

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M2
Blocked by: 05
Spec: SPEC §9.1, §15.3, §23.2

## Mục tiêu

Engine gọi Drive qua một giao diện hẹp; có backend giả `drive_backend=localfs` để test tích hợp không cần mạng.

## Phạm vi

- Giao diện (tên hàm `drv_*`): `generate_ids n`, `create_folder parent name props`, `upload parent name file props [file_id]` (trả fileId, md5), `update_content id file`, `download id out`, `get_meta id`, `list_children parent`, `find_by_props query`, `changes_start_token`, `changes_list token` (trả danh sách fileId đổi + token mới), `trash id`, `about_user`.
- Backend `localfs`: một thư mục giả lập Drive; mỗi object là `objects/<fileId>/{content,meta.json}`; meta có `name, parents, appProperties, md5Checksum, modifiedTime, createdTime, trashed`; log changes dạng append để `changes_list` hoạt động; header `Date` giả để test độ mới của live.json.
- Hỗ trợ tiêm lỗi (env): 404, 429, 5xx, timeout, mất file giữa chừng — để test #17/#23.

## Tiêu chí nghiệm thu

- [ ] Bộ test hợp đồng (contract test) cho giao diện chạy trên `localfs`; sau này #11 chạy cùng bộ test với Drive thật (job thủ công).
- [ ] `upload` với `file_id` đã cấp trước là idempotent (thử lại không sinh bản trùng).
- [ ] `trash` không bao giờ xoá vĩnh viễn; không có hàm `empty_trash`.
