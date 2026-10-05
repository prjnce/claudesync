# claude-sync v1 — spec và bản đồ ticket

Nguồn chuẩn: [docs/SPEC.md](../../docs/SPEC.md) (v1.2, 2026-10-05). File này **không chép lại spec**, chỉ ghi cách chia ticket và thứ tự phụ thuộc. Ticket mâu thuẫn với SPEC thì theo SPEC; SPEC mâu thuẫn với nghiên cứu thì theo `docs/research/cross-check.md`.

## Quy ước

- Ticket: `issues/NN-<slug>.md`. Mọi ticket mở với `Status: needs-triage`; dòng `Đề xuất:` là vai trò gợi ý sau khi triage (`ready-for-agent` / `ready-for-human`).
- `Blocked by:` liệt kê số ticket phải xong trước.
- Ticket M0 là spike trên máy thật, tài khoản Google thật, nên đề xuất `ready-for-human`. Kết quả M0 có thể làm đổi các ticket sau; khi đó cập nhật SPEC §25 rồi mới sửa ticket.
- Test tích hợp: #17 dựng bộ test 3 máy giả lập (3 `CLAUDE_CONFIG_DIR` + 3 `~/.claude-sync`, backend `localfs`). Mỗi ticket engine sau đó **tự thêm** các kịch bản phản biện (`docs/research/adversarial-review.md`) mà nó sở hữu (ghi trong từng ticket).

## Khác với SPEC §24

- **Transform (§7) được đưa lên trước Repair.** SPEC xếp Repair (M3) trước Engine (M4), nhưng bước 5 của repair (dịch cwd lạ) dùng transform §7. Vì vậy #13 (transform) và #14 (map project) phải xong trước #15 (repair). Thứ tự này vẫn giữ yêu cầu "repair chạy trước lần sync đầu" của §19.

## Bản đồ ticket

| # | Ticket | Mốc | Blocked by | Đề xuất |
|---|---|---|---|---|
| 01 | [Spike: publish OAuth app, đăng nhập 2 máy](issues/01-m0-oauth-publish-two-machines.md) | M0 | — | human |
| 02 | [Spike: launcher.exe, task XML, EventTrigger](issues/02-m0-launcher-task-scheduler.md) | M0 | — | human |
| 03 | [Spike: hook hiển thị và chặn](issues/03-m0-hook-display-guard.md) | M0 | — | human |
| 04 | [Spike: linger, loader CRLF, bridge, WSL config dir](issues/04-m0-environment-checks.md) | M0 | — | human |
| 05 | [Repo skeleton, bootstrap, core, CI](issues/05-repo-skeleton-bootstrap-ci.md) | M1 | — | agent |
| 06 | [Module platform: nat, cc_slug, realpath, khoá](issues/06-platform-module.md) | M1 | 05 | agent |
| 07 | [DB local và journal](issues/07-store-db-journal.md) | M1 | 05 | agent |
| 08 | [Module claude: quét session, registry, retention](issues/08-claude-module-scan.md) | M1 | 06 | agent |
| 09 | [Giao diện backend Drive + backend localfs](issues/09-drive-backend-localfs.md) | M2 | 05 | agent |
| 10 | [OAuth login/logout và lưu token](issues/10-oauth-login-token.md) | M2 | 01, 06 | agent |
| 11 | [Wrapper gd() cho Drive API thật](issues/11-drive-api-gd.md) | M2 | 09, 10 | agent |
| 12 | [Folder gốc, marker, setup bước 1–6](issues/12-root-folder-setup-1-6.md) | M2 | 07, 10, 11 | agent |
| 13 | [Transform dịch path (§7)](issues/13-path-transform.md) | M4→M1 | 06 | agent |
| 14 | [Định danh và map project (§6)](issues/14-project-identity-mapping.md) | M4 | 07, 08, 13 | agent |
| 15 | [Repair dữ liệu cũ (§19)](issues/15-repair.md) | M3 | 04, 08, 13, 14 | agent |
| 16 | [Chuỗi segment và mô hình manifest](issues/16-segment-chain-manifest.md) | M4 | 05 | agent |
| 17 | [Tracer: chu kỳ run, công bố/cài phần nối thêm](issues/17-tracer-run-cycle-append.md) | M4 | 06, 07, 09, 13, 14, 16 | agent |
| 18 | [Hội tụ đầy đủ: khởi tạo, viết lại, relocate, retention](issues/18-convergence-rewrite-retention.md) | M4 | 17 | agent |
| 19 | [Session đang mở và live.json](issues/19-open-sessions-live.md) | M4 | 17, 24 | agent |
| 20 | [Rẽ nhánh xác định và lệnh conflicts](issues/20-deterministic-fork.md) | M4 | 18 | agent |
| 21 | [Bundle, subagent, file-history](issues/21-bundle-subagent-file-history.md) | M4 | 17 | agent |
| 22 | [Memory merge 3 chiều và plans](issues/22-memory-plans.md) | M4 | 14, 17 | agent |
| 23 | [GC và lệnh machines](issues/23-gc-machines.md) | M4 | 17 | agent |
| 24 | [status.json, status, log, exit code](issues/24-status-logs-exit-codes.md) | M4 | 17 | agent |
| 25 | [Lập lịch Linux: systemd, linger, kick](issues/25-scheduler-linux.md) | M5 | 04, 17 | agent |
| 26 | [Lập lịch Windows: launcher, task, WSL, kick](issues/26-scheduler-windows.md) | M5 | 02, 17 | agent |
| 27 | [Hook Claude Code](issues/27-claude-hooks.md) | M5 | 03, 19, 24, 25, 26, 31 | agent |
| 28 | [Wrapper `claude-sync claude`](issues/28-claude-wrapper.md) | M5 | 17, 31 | agent |
| 29 | [Setup hoàn chỉnh, doctor, config, uninstall](issues/29-setup-doctor-uninstall.md) | M6 | 12, 14, 15, 25, 26, 27, 31 | agent |
| 30 | [E2E thật A1–A8, hiệu năng, README](issues/30-e2e-perf-readme.md) | M6 | 18–29, 31 | human |
| 31 | [Phát hiện path mới, gợi ý và xác nhận map (§6.1)](issues/31-detect-new-paths-confirm-map.md) | M4 | 14, 17, 24 | agent |
| 32 | [Ngôn ngữ giao diện en/vi (§20.1)](issues/32-ui-language-en-vi.md) | M1 | 05 | agent |

## Đường găng

`05 → 06 → 08/13 → 14 → 17` là tracer bullet: hai máy giả lập đồng bộ được một transcript chỉ nối thêm. Sau #17, các ticket 18–24 và 31 chạy song song được; 28 cần thêm 31. Các spike M0 (01–04) chạy song song với M1 và chỉ chặn 10, 15, 25, 26, 27.
