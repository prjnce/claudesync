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

2026-10-12 (chạy trên máy này, task `claude-sync-spike` đã gỡ):

- **Q4: không bị chặn.** Source là `launcher/launcher.cs`. `csc.exe -target:winexe` cho `launcher.exe` 7680 byte, không có chữ ký, chạy bình thường (AppIDSvc dừng, không có rule AppLocker).
- Qua Task Scheduler: `Last Result` = 7 (đúng exit code của con); không có cửa sổ nào (`MainWindowHandle` = 0 cho launcher, cmd, ping); `schtasks /End` giết cả cây (không còn `launcher`/`ping`), `Last Result` = 267014 (bị dừng).
- **Q8 (một phần): đăng ký được** bằng `schtasks /Create /XML` (UTF-16LE có BOM, user thường, không admin) với Logon + Time PT5M + EventTrigger Power-Troubleshooter 1 + EventTrigger NetworkProfile 10000. Lưu ý: `&`, `"`, `>` trong `<Arguments>` phải escape XML (nếu không `schtasks` báo "task XML is malformed"; `cs_xml_escape` trong `lib/sched_win.sh` đã làm việc này).
- Máy này là Dell Vostro 3671, chế độ ngủ S3 (không phải Modern Standby). Nhật ký System có Power-Troubleshooter EventID 1 (gần nhất 2026-09-23 10:24, "returned from a low power state").
- Fallback `wscript.exe run-hidden.vbs` (`Run cmd, 0, True` + `WScript.Quit rc`) trả exit code 7.
- **Chưa làm (cần người):** cho máy sleep rồi thức dậy, xem task có tự chạy qua EventTrigger không (bước 5). Không tự làm vì sẽ ngắt phiên đang chạy.
