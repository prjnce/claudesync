# 01 — Spike: publish OAuth app, đăng nhập 2 máy

Status: needs-triage
Đề xuất: ready-for-human
Type: research
Mốc: M0
Blocked by: —
Spec: SPEC §2 (OAuth), §15.1, §16.1, §25 Q1–Q2

## Câu hỏi cần trả lời

- **Q1**: Publish app loại External chỉ dùng scope `drive.file` có bị đòi URL trang chủ, chính sách riêng tư, domain không? Có hiện màn hình "unverified app" không?
- **Q2**: Máy thứ 2 (WSL `Ubuntu2404`) đăng nhập bằng **cùng** OAuth client có thấy folder `Claude Sync` và marker `.claude-sync-root` do máy 1 tạo không (tìm bằng `appProperties has {key='csRoot' and value='1'}`)?

## Việc cần làm

1. Làm theo §16.1: tạo project `claude-sync`, bật Drive API, Branding, Audience External, thêm scope `drive.file`, **PUBLISH APP**, tạo client Desktop và tải JSON.
2. Chạy `docs/prototypes/cs_gdrive_proto.sh` trên Windows: đăng nhập, tạo folder + marker.
3. Chép file JSON sang WSL, đăng nhập, chạy truy vấn tìm marker.
4. Kiểm tra response đổi code **không** có `refresh_token_expires_in` (nếu có nghĩa là app vẫn ở Testing).

## Kết quả cần ghi lại

- [ ] Trả lời Q1, kèm ảnh chụp màn hình consent nếu có cảnh báo.
- [ ] Trả lời Q2. Nếu không thấy marker thì chốt phương án `folder set <id>` và sửa #12.
- [ ] Cập nhật bảng §25 của SPEC.

## Answer
