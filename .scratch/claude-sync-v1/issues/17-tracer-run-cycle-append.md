# 17 — Tracer: chu kỳ run, công bố/cài phần nối thêm

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 06, 07, 09, 13, 14, 16
Spec: SPEC §8, §12.1, §12.3 (trường hợp nối thêm), §12.7, §12.8, §14, §14.1, §23.2

## Mục tiêu

Lát cắt dọc đầu tiên: session tạo trên máy giả lập A xuất hiện đúng thư mục slug trên máy B sau một lần `run`, và phần A viết thêm tới B ở lần sau. Chỉ xử lý trường hợp **nối thêm**, không mở, không rẽ nhánh.

## Phạm vi

- **Bộ test 3 máy giả lập** (dùng cho mọi ticket engine sau): 3 `CLAUDE_CONFIG_DIR` + 3 `~/.claude-sync` + một backend `localfs` chung; máy kiểu Windows (cwd `D:\...`), Linux, WSL. Helper để "Claude viết thêm dòng", chạy `run` trên một máy, so nội dung.
- `claude-sync run [--trigger=…]` và `sync [--pull-only|--push-only] [--project X] [--dry-run] [--verbose]` theo §14: khoá fd → khôi phục journal → cổng offline → token → marker → `changes.list` → tải manifest đổi vào cache → quét local → quyết định → **cài trước rồi công bố** → manifest ghi dần.
- Phát hiện thay đổi nhanh theo `size,mtime`, rồi prefix `installed_len/installed_sha`; chỉ canonicalize phần đuôi (§7.3).
- Công bố §12.8: segment `gzip -n`, `files.generateIds` + journal trước khi upload, `csSha`, kiểm tra checksum, manifest ghi sau cùng.
- Cài §12.7 (chỉ transcript chính): tải segment thiếu, kiểm `csSha`, ghép → localize → kiểm mọi dòng → temp cùng ổ → `touch -d @mtime` → so-và-đổi (stat lại, kiểm registry) → `mv -f` với backoff → cập nhật DB.
- Vị trí đặt §8: ancestor gần nhất đang tồn tại, khớp hoa/thường với thư mục slug có sẵn, `dir` cố định trong DB, kiểm tra trùng toàn cục bằng `-ef`.
- `known/<sid>` cập nhật khi cài và khi công bố, để không cài lại version cũ của chính mình (kịch bản **C1**).
- Hạn mềm 7 phút; `pending` mới hơn lúc bắt đầu → chạy lại bước 6 một lần.

## Tiêu chí nghiệm thu

- [ ] A (Windows giả) tạo session → `run` A → `run` B (Linux giả) → B có file đúng thư mục slug, cwd đã dịch, mtime đúng.
- [ ] A viết thêm → B nhận phần mới; B viết thêm → A nhận (chiều ngược lại của **A2**).
- [ ] 3 máy luân phiên viết tiếp: không cài lại version cũ, không vòng lặp công bố (**C1**).
- [ ] Thư mục slug viết thường `d--Projects-x` có sẵn → dùng đúng tên đó (**P1**); thư mục con chỉ có ở A → B đặt vào ancestor gần nhất (**P7**).
- [ ] Kill ở mọi bước rồi chạy lại → không có file hỏng, không object trùng (journal).
- [ ] Mỗi session ID chỉ có đúng một file trong `projects/*/` trên mọi máy (**A5**).
- [ ] Hai `run` song song → lần thứ 2 thoát ngay với exit 5.

## Comments

**2026-10-05 — Claude (từ #13):** Trên máy Windows này, lần đọc đầu tiên một file vừa ghi mất ~1,7 s/MB (antivirus/EDR, Defender đang tắt); awk chỉ ~0,05 s/MB. Cài và công bố phải xử lý theo luồng: tải → `gzip -d` → localize → (`tee` sang sha256/đếm dòng) → ghi `*.csync-tmp` đúng một lần → `mv`. Không ghi file trung gian rồi đọc lại; `cs_transform_verify` (đọc lại cả 2 file) chỉ dùng trong test hoặc cho file nhỏ — cần bản kiểm tra theo luồng. Xem SPEC §25 R2.

**2026-10-05 — Claude:** Code xong; 10/10 test `test/engine.bats` pass trên Git Bash (11 phút 46 — chậm do tạo tiến trình trên Windows; tối ưu sau).
- `lib/engine.sh`: `run|sync [--dry-run] [--trigger=…]`; khoá fd 9 (rc 5 khi bận), dọn journal, kiểm tra root, tải manifest các máy khác qua một truy vấn `csKind=manifest` (chỉ tải khi md5 đổi), quét local, quyết định, **cài trước rồi công bố**, ghi manifest khi khác lần upload thành công gần nhất (F9).
- Công bố: chỉ chuẩn hoá phần đuôi `[installed_len, complete_len)` thành một segment `gzip -n`, ID cấp trước + journal, nối vào chuỗi của base (segment máy khác được tham chiếu bằng `m`).
- Cài: phần local + segment sau base (append) hoặc toàn bộ (session mới); đếm dòng/CR và băm trong luồng; giữ mtime gốc (không bao giờ ở tương lai); so-và-đổi (stat + registry) rồi `mv`; đặt file theo §8 (ancestor gần nhất, tái dùng thư mục slug khác hoa/thường); chặn khi trùng ID ở thư mục khác.
- C1: sau khi cài, manifest của mình chuyển sang version mới; ứng viên đã biết hoặc là tổ tiên của base bị bỏ qua.
- Hoãn (ghi log, không làm gì): viết lại local (#18), không có base mà có ứng viên (#18), hai bên cùng đổi (#20), session đang mở (#19), project chưa map (#31), file đã cài bị xoá (#18).
- **Lệch SPEC §9.1:** segment để phẳng trong `machines/<id>/` (`t-<sid>-<seq>-<sha16>.jsonl.gz`), không tạo folder con theo session — ít lần gọi API hơn.
- Bộ test giả lập: `test/sim_helper.bash` (máy Windows mô phỏng bằng root dạng chuỗi + `CS_SEP=w`; máy Linux root thật; chung một Drive localfs).
