# 26 — Lập lịch Windows: launcher, task, WSL, kick

Status: needs-triage
Đề xuất: ready-for-agent (kiểm thật trên máy Windows cần người dùng)
Type: task
Mốc: M5
Blocked by: 02, 17
Spec: SPEC §17.2, §17.3, §6 (`realRoot` qua launcher); mẫu XML `docs/research/autostart-catchup.md`; đầu vào từ spike #02

## Phạm vi (`lib/scheduler.sh` phần Windows + `launcher/launcher.cs`)

- Biên dịch `launcher.exe` lúc cài bằng `csc.exe /target:winexe`: GUI subsystem, `CREATE_NO_WINDOW`, Job Object `KILL_ON_JOB_CLOSE`, chờ con và trả exit code; lệnh phụ `realpath <path>` dùng `GetFinalPathNameByHandle` (thay PowerShell trong `realpath_disk` của #06).
- Task XML **UTF-16LE có BOM**: một task `claude-sync`, Principal user + `InteractiveToken` + `LeastPrivilege`; trigger Logon, Time + Repetition `PT5M|PT10M`, EventTrigger Power-Troubleshooter EventID 1 (nếu #02 xác nhận đăng ký được), tuỳ chọn NetworkProfile 10000; settings `StartWhenAvailable`, `IgnoreNew`, không dừng khi dùng pin, `ExecutionTimeLimit=PT10M`.
- Đăng ký `schtasks /Create /TN claude-sync /XML task.xml /F` qua `nat()`.
- Action: `launcher.exe "<Git>\bin\bash.exe" --noprofile --norc "<app>\bin\claude-sync" run --trigger=task`; đường dẫn Git lấy bằng `cygpath -w /`. Không dùng `bash` trần.
- Fallback VBS `wscript.exe run-hidden.vbs` với `Run cmd, 0, True` khi launcher bị chặn (kịch bản **F4**: phải chờ con, không trả về ngay).
- WSL như một máy: action thứ 2 `launcher.exe wsl.exe -d <distro> --exec /home/<u>/.local/bin/claude-sync run --trigger=task`.
- `kick`: `touch pending` rồi `schtasks /Run /TN claude-sync`.
- Shim `~/bin/claude-sync` trong Git Bash.
- **Không** dùng `conhost --headless`, S4U, BootTrigger.

## Tiêu chí nghiệm thu

- [ ] Test: XML sinh ra có BOM `FF FE`, là UTF-16LE hợp lệ, đổi interval đổi `PT5M`→`PT10M`.
- [ ] Kiểm thật: chạy ẩn hoàn toàn, Last Run Result = exit code của engine, `IgnoreNew` ngăn chạy chồng, kill task dọn cả cây tiến trình.
- [ ] Kiểm thật: action WSL chạy được engine trong distro.
- [ ] `service uninstall` gỡ task, giữ dữ liệu.

## Comments

**2026-10-05 — Claude:** Tuỳ chọn: gắn `docs/logo.png` làm icon cho `launcher.exe` (`csc /win32icon:` cần file `.ico`; chuyển PNG → ICO bằng PowerShell `System.Drawing` lúc cài). Giá trị thấp vì launcher chạy ẩn (chỉ thấy trong Task Manager); làm nếu rẻ.
