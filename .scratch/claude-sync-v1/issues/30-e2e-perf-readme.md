# 30 — E2E thật A1–A8, hiệu năng, README

Status: needs-triage
Đề xuất: ready-for-human
Type: task
Mốc: M6
Blocked by: 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 31
Spec: SPEC §1.4, §23.3, §24 (M6), §25 R2

## Phạm vi

Chạy trên 3 máy thật: Windows (máy này) ↔ WSL `Ubuntu2404` ↔ một máy Ubuntu.

### Checklist nghiệm thu

- [ ] **A1**: chat trên Windows `D:\Projects\X`, mở Ubuntu `~/work/X` sau ≤ 1 chu kỳ → `/resume` và danh sách VS Code thấy session; `claude --resume <id>` chạy; có memory, plan, subagent, tool-results.
- [ ] **A2**: Ubuntu viết tiếp → Windows nhận sau ≤ 1 chu kỳ.
- [ ] **A3**: tắt B trong lúc A làm việc, bật B → service tự chạy, sync bù; mở session khi chưa bù xong → Claude hiện cảnh báo.
- [ ] **A4**: hai máy cùng viết tiếp khi offline rồi online → không mất dòng, nhánh thắng giữ ID gốc, nhánh thua thành session tách mở được, không trùng.
- [ ] **A5**: mọi máy, mỗi session ID chỉ có một file trong `projects/*/`.
- [ ] **A6**: `/rewind` trên máy nhận khôi phục đúng chỗ khi path map được; không map được thì bỏ qua an toàn.
- [ ] **A7**: token hết hạn/thu hồi (myaccount.google.com), rút mạng khi boot, sleep giữa lúc upload, crash → không hỏng dữ liệu; `status` và Claude báo đúng.
- [ ] **A8**: `repair` trên máy Windows hiện tại (nếu chưa làm ở #15).
- [ ] Mở tab VS Code cũ rồi gõ → guard chặn.

### Hiệu năng (R2)

- [ ] Đo chu kỳ với transcript 58 MB trên Git Bash: lần đầu (canonicalize cả file) và lần sau (chỉ phần đuôi). Ghi số liệu vào README.

### README

- [ ] Hướng dẫn tiếng Việt: tạo OAuth client (§16.1), cài trên Windows/Ubuntu/WSL, `setup`, alias wrapper, các lệnh chính, gỡ cài đặt, giới hạn v1 (§1.3).

## Comments
- 2026-10-05: hiển thị `docs/logo.png` ở đầu README.
