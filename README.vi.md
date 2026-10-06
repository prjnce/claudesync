<p align="center"><img src="docs/logo.png" alt="claude-sync" width="160"></p>

<h1 align="center">claude-sync</h1>

<p align="center">Đồng bộ các session Claude Code giữa Windows, Linux và WSL qua Google Drive của chính bạn.</p>

<p align="center"><a href="README.md">English</a> · <b>Tiếng Việt</b></p>

---

> **Trạng thái: đang phát triển (v0.1.0-dev).** Thiết lập, đăng nhập, map project, sửa dữ liệu cũ và
> phiên bản đầu của engine đồng bộ đã chạy được và có test, nhưng việc tự đồng bộ chạy nền, hook của
> Claude Code và xử lý xung đột chưa xong. **Chưa nên dùng để đồng bộ thật.** Xem mục [Trạng thái](#trạng-thái).

## Công cụ này làm gì

Bạn mở một session Claude Code trên một máy và muốn làm tiếp trên máy khác. claude-sync chép các session
qua một folder trong Google Drive của bạn, để sau tối đa một chu kỳ đồng bộ:

- session hiện trong `/resume` (CLI và VS Code) trên mọi máy khác,
- `claude --resume <id>` tiếp tục đúng như trên máy gốc, và
- không bao giờ mất dòng transcript nào — kể cả khi hai máy cùng viết tiếp lúc offline.

Path được dịch giữa các máy: session mở trong `D:\Projects\TransFlow` trên Windows sẽ resume trong
`~/projects/TransFlowX` trên Ubuntu, với thư mục làm việc, lịch sử file và memory trỏ đúng chỗ.

Đây là một ứng dụng Bash thuần (Git Bash trên Windows, Bash trên Linux), gọi Google Drive API bằng
`curl` — không có tiến trình thường trú, không dùng rclone, không có server riêng.

## Cách hoạt động

- **Một folder trên Drive của bạn.** `Claude Sync/` chứa một file marker và mỗi máy một vùng riêng
  (`machines/<machine-id>/`). Mỗi máy chỉ ghi vào vùng của mình và đọc vùng của các máy khác.
- **Dạng chuẩn hoá.** Trước khi tải lên, các path riêng của từng máy trong transcript được thay bằng token
  (`{P:<project>}`, `{R:…}`, `{MEM:…}`, `{CFG}`); máy nhận thay lại bằng path của chính nó. Chỉ các key
  JSON chứa path bị đụng tới; mọi byte khác giữ nguyên.
- **Segment chỉ nối thêm.** Một version transcript là chuỗi các segment đã nén gzip, định danh bằng một
  chuỗi hash. Thông thường chỉ những dòng mới được gửi đi; máy viết tiếp session của máy khác sẽ tham
  chiếu tới segment của máy đó.
- **Manifest.** Mỗi máy công bố một `manifest.json.gz` nhỏ liệt kê session và version của nó. Mỗi chu kỳ
  đồng bộ tải các manifest đã đổi, cài version mới hơn, rồi mới công bố thay đổi local.
- **Ghi an toàn.** Khi cài, công cụ ghi file tạm, kiểm tra, rồi chỉ đổi tên đè lên file đích nếu cả file
  lẫn registry session đang chạy của Claude không thay đổi trong lúc đó. Session đang mở không bao giờ bị
  ghi đè. Không có gì bị xoá vĩnh viễn trên Drive.

Thiết kế đầy đủ nằm trong [docs/SPEC.md](docs/SPEC.md).

## Yêu cầu

| | Windows | Ubuntu / WSL |
|---|---|---|
| Shell | Git for Windows (Git Bash, bash ≥ 4.4) | bash ≥ 4.4 |
| Công cụ | `jq`, `curl`, `perl`, `openssl`, `gzip`, `iconv` (Git for Windows có sẵn phần lớn; jq: `winget install jqlang.jq`) | `sudo apt install curl jq` (phần còn lại có sẵn) |
| Nhận kết quả đăng nhập | PowerShell (có sẵn) | `python3` (nếu thiếu, bạn dán URL cuối cùng trên trình duyệt) |
| Sửa dữ liệu cũ | `node` hoặc `python3` | `node` hoặc `python3` |
| Google | Một tài khoản Google cá nhân và OAuth client của riêng bạn (xem bên dưới) | như trên |

Chạy được với cả `gawk` lẫn `mawk`. WSL được tính là một máy riêng.

## Cài đặt

Chưa có trình cài đặt. Clone repo rồi chạy thẳng entry point:

```bash
git clone https://github.com/prjnce/claudesync.git
cd claudesync
bash bin/claude-sync --version
```

Có thể thêm `bin/` vào `PATH` hoặc đặt alias.

## Làm một lần: tạo Google OAuth client

claude-sync dùng OAuth client của chính bạn, nên không bên thứ ba nào thấy được dữ liệu. Tạo một lần,
rồi chép cùng file JSON sang mọi máy.

1. Mở <https://console.cloud.google.com> và tạo project, ví dụ `claude-sync`.
2. **APIs & Services** → bật **Google Drive API**.
3. **Google Auth Platform → Branding**: tên app và email hỗ trợ.
4. **Audience**: *External*, thêm chính bạn làm test user, rồi **Publish app**. Khi app còn ở *Testing*,
   đăng nhập hết hạn sau 7 ngày.
5. **Data access**: thêm scope `https://www.googleapis.com/auth/drive.file` (app chỉ thấy những file do
   chính nó tạo).
6. **Clients → Create client → Desktop app**, rồi tải file JSON ngay.

Đừng đưa file JSON vào git (`.gitignore` của repo này đã bỏ qua `*client_secret*.json`).

## Bắt đầu nhanh

```bash
# 1. Ngôn ngữ, OAuth client, proxy, đăng nhập Google, folder gốc, tên máy
bash bin/claude-sync setup

# 2. Xem thư mục nào có session Claude và chọn thứ cần sync
bash bin/claude-sync projects list
bash bin/claude-sync projects select        # hoặc: projects map <tên> <thư mục>

# 3. Kiểm tra dữ liệu Claude local; sửa dữ liệu cũ nếu doctor báo lỗi
bash bin/claude-sync doctor
bash bin/claude-sync repair --dry-run       # chỉ đọc, chỉ báo cáo
bash bin/claude-sync repair                 # hỏi trước khi sửa; backup trước
```

Chạy `setup` trên mọi máy với cùng file JSON OAuth client. Máy đầu tiên tạo folder `Claude Sync`; các
máy sau tự tìm thấy nó.

## Các lệnh

| Lệnh | | Chức năng |
|---|---|---|
| `setup [--step TÊN]` | ✅ bước 0–6 | Trình thiết lập: ngôn ngữ, công cụ, OAuth client, proxy, đăng nhập, folder gốc, tên máy. Chạy lại được. |
| `login [--client FILE]` / `logout` | ✅ | Đăng nhập Google Drive / thu hồi token. |
| `folder [show]` | ✅ | Tài khoản, link folder gốc và các máy đã tham gia. |
| `projects list\|select\|map\|unmap\|mode\|exclude\|include\|dirs` | ✅ | Map thư mục local thành project; chọn thứ được sync. |
| `doctor` | ✅ cơ bản | Công cụ, thư mục config của Claude, số session, thư mục rác, ID trùng, retention. |
| `repair [--dry-run] [--yes] [--project X]` | ✅ | Sửa transcript cũ (CRLF, JSON bị ghi lại có dấu cách, path WSL/Windows, thư mục backup lạc chỗ). |
| `run` / `sync [--dry-run]` | 🚧 | Một chu kỳ đồng bộ. Hiện chỉ cho session chỉ nối thêm; xem Trạng thái. |
| `status`, `conflicts`, `restore`, `service`, `hooks`, `config`, `machines`, `claude`, `logs`, `uninstall` | ⏳ | Chưa làm. |

Mã thoát: `0` OK · `1` lỗi · `2` sai cú pháp · `3` cần đăng nhập · `4` offline · `5` đang có lần chạy khác ·
`6` cần repair.

## Cấu hình

| | |
|---|---|
| `~/.claude-sync/` | Dữ liệu của claude-sync (Windows: `%USERPROFILE%\.claude-sync`): `config`, token, trạng thái, log, backup. Đổi bằng `CLAUDE_SYNC_HOME`. |
| Thư mục config của Claude | `CLAUDE_CONFIG_DIR` nếu có, ngược lại `~/.claude` — đúng quy tắc của Claude Code. |
| Ngôn ngữ | Tiếng Anh hoặc tiếng Việt, chọn trong `setup`; `CLAUDE_SYNC_LANG=en\|vi` ghi đè. Log luôn bằng tiếng Anh. |
| Proxy | `setup` lưu lại và export thành `HTTPS_PROXY`. |

## Riêng tư và an toàn

- **Scope `drive.file`:** app chỉ thấy file do nó tạo, không bao giờ thấy phần còn lại của Drive.
- **Token:** trên Windows được mã hoá bằng DPAPI (chỉ tài khoản Windows của bạn giải mã được); trên Linux
  là file quyền 600. Token, mã đăng nhập và secret không bao giờ được ghi vào log.
- **Transcript là văn bản thường** và có thể chứa secret do các tool in ra. Hãy để folder Drive ở chế độ riêng tư.
- **Không bao giờ sync:** registry session đang chạy của Claude, credential, `~/.claude.json`, cache và
  file tạm.
- **Git remote** chỉ dùng để gợi ý map project; thứ duy nhất được tải lên là mã băm của dạng chuẩn hoá
  `host/owner/repo` (credential đã bị bỏ trước khi băm).
- **Việc xoá không lan sang máy khác**, object trên Drive chỉ được chuyển vào thùng rác, và `repair` backup
  mọi file trước khi sửa (`~/.claude-sync/backups/`).

## Trạng thái

Đã xong và có test: khởi động môi trường, xử lý path Windows/Linux, quét session local, OAuth và lưu token,
client Google Drive (đã kiểm với Drive thật), folder gốc và định danh máy, `setup` bước 0–6, map project,
dịch path, sửa dữ liệu cũ (đã chạy trên dữ liệu thật), chuỗi version và manifest, giao diện Anh/Việt, và
engine đồng bộ đầu tiên cho session chỉ nối thêm giữa các máy giả lập.

Chưa xong: lần đồng bộ đầu khi hai máy chưa có version chung và transcript bị viết lại, tách nhánh khi
xung đột, xử lý session đang mở và `live.json`, đồng bộ subagent / lịch sử file / memory / plan, dọn rác
trên Drive, các lệnh status và logs, chạy nền theo lịch (systemd / Task Scheduler), hook Claude Code,
wrapper `claude`, phần còn lại của `setup`, và kiểm thử đầu-cuối trên máy thật. Công việc được theo dõi
bằng các ticket trong [.scratch/claude-sync-v1/](.scratch/claude-sync-v1/spec.md).

## Phát triển

```
bin/claude-sync        entry point và phân lệnh
lib/*.sh               các module (core, platform, claude, transform, drive/gdrive/auth, store,
                       version/manifest, projects, repair, root/setup, engine, i18n, ui)
lib/transform.awk      dịch path chính xác đến từng byte (POSIX awk: mawk và gawk)
test/*.bats            test bats-core (bats nằm sẵn trong test/vendor/)
test/run-all.sh        thay CI khi chạy local: Git Bash + WSL (gawk và mawk) + shellcheck, chạy song song
docs/SPEC.md           đặc tả; docs/research/ chứa các bằng chứng làm nền cho đặc tả
```

```bash
test/vendor/bats-core/bin/bats test             # mọi test trên shell hiện tại
test/vendor/bats-core/bin/bats test/engine.bats # một bộ test
test/run-all.sh                                 # toàn bộ ma trận (máy Windows có WSL)
CS_TEST_GDRIVE=1 test/vendor/bats-core/bin/bats test/drive_contract.bats   # chạy với Drive thật
```

CI (`.github/workflows/test.yml`) chạy Ubuntu với gawk, Ubuntu với mawk (kèm shellcheck) và Windows với
Git Bash. Test engine giả lập nhiều máy trên cùng một Drive giả (`test/sim_helper.bash`), nên không cần mạng.

Quy ước:

- Không bao giờ đổi line ending (`.gitattributes`: `* -text`); script phải là LF — có test lint kiểm tra.
- File thực thi phải có mode `100755` trong git (trên Windows dùng `git update-index --chmod=+x`).
- Comment code viết bằng tiếng Anh; đặc tả và ticket viết bằng tiếng Việt.
- Tên test phải là ASCII (bats trên runner Windows không tra được tên khác).
- Không bao giờ dùng `jq` để ghi transcript; awk làm phần byte, jq chỉ đọc.
