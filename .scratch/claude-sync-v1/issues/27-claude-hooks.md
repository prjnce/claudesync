# 27 — Hook Claude Code

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M5
Blocked by: 03, 19, 24, 25, 26, 31
Spec: SPEC §18, §1.4 A3; kết quả spike #03 quyết định field hiển thị

## Phạm vi (`lib/hooks.sh`)

- `claude-sync hooks install|uninstall`: sửa `~/.claude/settings.json` (backup trước; ghi bằng jq rồi `tr -d '\r'`); mỗi entry có dấu `#claude-sync` để gỡ chính xác. Lệnh hook tự vô hiệu khi tool đã gỡ: `command -v claude-sync >/dev/null 2>&1 && claude-sync hook … ; exit 0`.
- `hook session-start` (matcher `startup|resume`, timeout 2 s): **chỉ đọc local** (`status.json`, DB), không gọi mạng. In thông báo hiển thị cho người dùng (field theo #03) khi: lần pull thành công cuối cũ hơn lúc boot/đăng nhập hoặc > 2 × interval; session này `behind`; đang mở trên máy khác (`live_elsewhere`); `LOGIN_REQUIRED|OFFLINE|ROOT_MISSING|NEEDS_REPAIR`; có project chờ map (§6.1, đọc `waiting_map` do #31 ghi) — `cwd` hiện tại là ứng viên thì gợi ý đúng lệnh `claude-sync projects map <alias> "<cwd>"`, không thì nhắc `claude-sync projects map`; mỗi mục tối đa một lần mỗi ngày (ghi mốc vào `state/hook-notified`). Sau đó kick.
- `hook prompt-guard` (`UserPromptSubmit`, 2 s): session hiện tại `behind` → `exit 2` + "Session đã được tiếp tục trên <máy> lúc <t>. Đóng tab này và mở lại session (đã kick sync)". `config guard=block|warn|off`, mặc định `block`.
- `SessionEnd`: `nohup claude-sync kick >/dev/null 2>&1 &`, exit 0, timeout 5 s.
- Không dùng hook `Stop` (kịch bản **F10**).

## Tiêu chí nghiệm thu

- [ ] Test: install chạy 2 lần không nhân đôi entry; uninstall chỉ gỡ entry của claude-sync, giữ hook khác của người dùng; settings.json không có CR.
- [ ] Test: `session-start` xong < 2 s trên Git Bash với DB 500 session.
- [ ] Mở session khi chưa sync bù → Claude hiện cảnh báo rõ (**A3**, **F5**; kiểm thật ở #30).
- [ ] Mở Claude trong `~/projects/TransFlowX` khi `TransFlow` đang chờ map → thông báo gợi ý đúng lệnh map với path hiện tại; mở lần 2 trong ngày thì không nhắc lại.
- [ ] Gõ vào tab VS Code cũ của session đã được viết tiếp ở máy khác → bị chặn với thông báo đúng.
