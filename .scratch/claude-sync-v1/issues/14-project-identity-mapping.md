# 14 — Định danh và map project (§6)

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 07, 08, 13
Spec: SPEC §6, §16 bước 8, §20 (`projects`)

## Phạm vi

- `project_id` (8 hex ngẫu nhiên) + alias; lưu trong `projects.tsv`, một dòng cho mỗi root.
- Với mỗi root: `cwdRoot` (đúng như Claude ghi vào `cwd`; Linux `pwd -P`; Windows đối chiếu `cwd` của transcript local và tên thư mục slug có sẵn, chấp nhận cả `d:` và `D:`), `realRoot` (`realpath_disk`), `memDir` (`projects/<LA(git root của main worktree ?? root)>/memory` hoặc `autoMemoryDirectory`).
- `projects map` kiểm tra root với `cwd` thật của transcript local, cảnh báo khi lệch (symlink, NFC/NFD, hoa/thường) — kịch bản **P2**.
- Thành viên: `launchCwd(S)` nằm dưới `cwdRoot` của **chính máy này** (khớp theo ranh giới path). Session không thuộc project nào: không sync, `projects list` liệt kê để map.
- Sinh bảng root cho transform #13 (canonicalize chỉ dùng root của máy này; localize dùng root local của `project_id` trong manifest máy gốc).
- CLI: `projects list|select|map <alias|id> <path>|unmap|mode all|selected|exclude <id>`. `select` hiện bảng project local (thư mục khởi chạy, số session, dung lượng), gợi ý map project remote theo tên thư mục và git remote.
- Phát hiện project/path mới, gợi ý ứng viên và luồng xác nhận (`projects pending`, `projects map` không tham số) nằm ở #31. Ticket này chỉ cung cấp `projects map <alias|id> <path>` có tham số và phần kiểm tra root.
- Git remote **chỉ** dùng để gợi ý, không upload URL, không làm khoá. Hàm `remote_keys <dir>` theo §6.2: đọc mọi remote của git root (`git -C <dir> remote -v`), chuẩn hoá (bỏ scheme, **userinfo/token**, cổng, query, `.git`, `/` cuối; viết thường; `git@host:o/r` → `host/o/r`), rồi `sha256("claude-sync:remote:" + …)`. URL thô và chuỗi chuẩn hoá chỉ nằm trong biến cục bộ, không ghi ra file hay log. Lưu kết quả băm vào `projects.tsv` (cột `remote_keys`, phân tách bằng `,`).

## Tiêu chí nghiệm thu

- [ ] Test: root là symlink trên Linux; Windows gõ `d:\projects\transflow` trong khi Claude ghi `D:\Projects\TransFlow` (**P2**).
- [ ] Test: project chưa map ở máy này → session của nó ở trạng thái `waiting_map` (**P8** phần a).
- [ ] Test: URL git remote có credential không bao giờ xuất hiện trong config, log, manifest.
- [ ] Test `remote_keys`: các URL sau cho **cùng một** mã băm — `https://github.com/Owner/Repo.git`, `https://user:ghp_xxx@github.com/owner/repo`, `https://oauth2:glpat-xxx@github.com/owner/repo/`, `git@github.com:owner/repo.git`, `ssh://git@github.com:22/owner/repo`. Chứng minh token không ảnh hưởng tới mã băm.
- [ ] Test: URL không parse được (path local, `file://`) → bỏ qua, không băm chuỗi thô; thư mục không phải git → mảng rỗng.
- [ ] Test grep: sau khi chạy với URL có token giả, chuỗi token không xuất hiện ở bất kỳ file nào trong `~/.claude-sync/`.
- [ ] `projects list` trên máy này liệt kê TransFlow và claude_sync với số session đúng.
