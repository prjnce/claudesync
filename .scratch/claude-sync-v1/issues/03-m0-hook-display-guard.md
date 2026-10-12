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

2026-10-12. Chạy bằng `claude -p … --output-format stream-json --verbose --settings <file tạm>` (Claude Code 2.1.289, `~/.claude/settings.json` không bị sửa), script thử nằm ở thư mục scratchpad. Trong headless chỉ đọc được những gì harness phát ra, không thấy giao diện tương tác.

| Thử | Kết quả (headless) |
|---|---|
| `SessionStart` in `{"systemMessage":…,"hookSpecificOutput":{"additionalContext":…}}` | exit 0, `hook_response` mang nguyên JSON. Hook thật của claude-sync (đã có trong `~/.claude/settings.json`) cũng in `systemMessage` và chạy được |
| `UserPromptSubmit` `exit 2` + stderr | Prompt bị chặn (`num_turns` 0, không gọi model); harness phát `informational`, `level: warning`: `UserPromptSubmit operation blocked by hook: [cmd]: <stderr> … Original prompt: <prompt>` |
| `SessionStart` ngủ 20 s với `timeout: 2` | `outcome: cancelled`, không có lỗi, session vẫn trả lời bình thường |
| `SessionEnd` chạy `nohup sh -c 'sleep 10; touch /tmp/cs-alive' &` | Claude thoát, 13 s sau file `/tmp/cs-alive` có mặt: tiến trình nền sống sau khi Claude thoát (Bun 2.1.289; §4.8 trước đây mới thử Node) |

- Kết luận cho #27: giữ `systemMessage` cho `SessionStart` và `exit 2` + stderr cho `UserPromptSubmit`; không cần đổi sang `additionalContext` trừ khi bước dưới cho thấy UI không hiện.
- **Chưa làm (cần người):** xác nhận bằng mắt thông điệp `systemMessage` và thông báo chặn có hiện cho người dùng trong CLI tương tác (Git Bash) và trong panel VS Code. Cách thử: thêm hook `SessionStart` in `systemMessage` vào settings, mở Claude ở hai nơi, gõ một prompt bị `exit 2`.
