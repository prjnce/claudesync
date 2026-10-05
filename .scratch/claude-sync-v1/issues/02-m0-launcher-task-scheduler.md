# 02 — Spike: launcher.exe, task XML, EventTrigger

Status: needs-triage
Đề xuất: ready-for-human
Type: prototype
Mốc: M0
Blocked by: —
Spec: SPEC §17.2, §25 Q4, Q8; mẫu XML ở `docs/research/autostart-catchup.md`

## Câu hỏi cần trả lời

- **Q4**: Launcher C# biên dịch bằng `csc.exe /target:winexe` có bị AV/AppLocker chặn không? Chạy có nháy cửa sổ không?
- **Q8**: Task cấp user (không admin) có đăng ký được `EventTrigger` (Power-Troubleshooter EventID 1) qua `schtasks /Create /XML` không? Máy này (Modern Standby?) có phát EventID 1 khi thức dậy không?

## Việc cần làm

1. Viết launcher tối thiểu: GUI subsystem, `CreateProcess` + `CREATE_NO_WINDOW`, Job Object `KILL_ON_JOB_CLOSE`, `WaitForSingleObject`, trả exit code của con.
2. Biên dịch bằng `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`.
3. Sinh task XML UTF-16LE có BOM với đủ trigger (Logon, Time + Repetition PT5M, EventTrigger) và settings của §17.2; đăng ký qua `schtasks /Create /TN claude-sync-spike /XML … /F`.
4. Action chạy một script bash ghi sentinel + exit code 7. Kiểm tra: không nháy cửa sổ; Task Scheduler ghi Last Run Result = 7; kill task thì cây tiến trình bị dọn.
5. Cho máy sleep rồi thức, xem task có chạy và Event Viewer có EventID 1 không.
6. Thử fallback `wscript.exe run-hidden.vbs` (`Run cmd, 0, True`).

## Kết quả cần ghi lại

- [ ] Trả lời Q4, Q8 và cập nhật SPEC §25.
- [ ] Giữ lại source launcher và XML đã chạy được làm đầu vào cho #26.
- [ ] Gỡ task spike sau khi xong.

## Answer
