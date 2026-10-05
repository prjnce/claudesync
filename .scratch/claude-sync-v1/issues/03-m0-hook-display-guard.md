# 03 — Spike: hook hiển thị và chặn

Status: needs-triage
Đề xuất: ready-for-human
Type: research
Mốc: M0
Blocked by: —
Spec: SPEC §18, §25 Q3

## Câu hỏi cần trả lời

- **Q3a**: Hook `SessionStart` (matcher `startup|resume`) in field nào ra stdout thì **người dùng thấy** (không chỉ model): `systemMessage`? Cả trong CLI và panel VS Code?
- **Q3b**: `UserPromptSubmit` thoát với `exit 2` + stderr có chặn prompt và hiện thông báo cho người dùng không, ở cả CLI và VS Code?
- **Phụ**: hook có timeout 2 s có bị huỷ êm khi chạy quá giờ không? `nohup … &` trong `SessionEnd` có sống sau khi Claude thoát không (§4.8 mới test Node, chưa test Bun)?

## Việc cần làm

1. Thêm hook thử vào `~/.claude/settings.json` (backup trước), mỗi hook in một chuỗi nhận diện.
2. Thử trong CLI (Git Bash) và trong VS Code; ghi kết quả từng trường hợp.
3. `SessionEnd`: hook chạy `nohup sh -c 'sleep 10; touch /tmp/cs-alive' &`, thoát Claude, kiểm tra file.
4. Gỡ hook thử, khôi phục settings.

## Kết quả cần ghi lại

- [ ] Bảng: field / exit code → CLI thấy? VS Code thấy? model thấy?
- [ ] Nếu không có cách hiển thị cho người dùng: chốt phương án dự phòng (`additionalContext` để model nhắc, hoặc dựa vào wrapper #28) và sửa #27.
- [ ] Cập nhật SPEC §18, §25.

## Answer
