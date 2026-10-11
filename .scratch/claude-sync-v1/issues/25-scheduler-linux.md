# 25 — Lập lịch Linux: systemd, linger, kick

Status: ready-for-human
Đề xuất: ready-for-agent
Type: task
Mốc: M5
Blocked by: 04, 17
Spec: SPEC §17.1, §17.3, §2 (Khởi động)

## Phạm vi (`lib/scheduler.sh`, phần Linux)

- `claude-sync service install|uninstall|status` trên Ubuntu: sinh `~/.config/systemd/user/claude-sync.{service,timer}` đúng mẫu §17.1 (`Type=oneshot`, `TimeoutStartSec=600`, `Nice=10`, `IOSchedulingClass=idle`, `OnCalendar=*:0/5`, `Persistent=true`, `OnStartupSec=30`, `AccuracySec=30s`).
- `daemon-reload` + `enable --now claude-sync.timer`.
- `loginctl enable-linger "$USER"`; polkit từ chối thì hỏi chạy với sudo (theo kết quả Q5 của #04). Không thêm độ trễ ngẫu nhiên.
- `config set interval 10` → sửa `OnCalendar=*:0/10` + reload.
- Không có systemd user (container, WSL không bật systemd): không cài cron; `doctor` cảnh báo; dựa vào hook + wrapper.
- `claude-sync kick`: `touch pending` rồi `systemctl --user start --no-block claude-sync.service` (không chờ — kịch bản **F10**).
- Shim `~/.local/bin/claude-sync` trỏ tới `~/.claude-sync/app/bin/claude-sync`.

## Tiêu chí nghiệm thu

- [x] Test (unit): unit file sinh ra giống mẫu; đổi interval sửa đúng dòng.
- [x] `kick` trả về ngay (< 1 s) kể cả khi service đang chạy.
- [ ] Kiểm thật trên Ubuntu: tắt máy, bật lại chưa đăng nhập → timer chạy bù (`Persistent`); `uninstall` gỡ sạch.

## Comments

- 2026-10-11: code + 8 test (`test/scheduler.bats`, systemctl/loginctl giả): unit file đúng §17.1, shim `~/.local/bin/claude-sync`, `config set interval` sửa OnCalendar + reload, `kick` (touch `pending`, `start --no-block`, không chờ; không có systemd thì chạy nền một lần), linger với hỏi sudo khi polkit từ chối, không systemd → không cài gì, cờ test `CS_SCHED_KIND`. Engine chạy thêm một vòng khi `pending` mới hơn lúc vòng hiện tại bắt đầu (`cs_run` / `cs_run_cycle`). Còn lại cho người: kiểm thật trên Ubuntu (reboot chưa đăng nhập → Persistent chạy bù, `uninstall` gỡ sạch) và chốt Q5 ở #04. `claude-sync config get|set` mới có các khoá interval, guard, throttle_live_min, lang, mode, scan_dirs, machine_name.
