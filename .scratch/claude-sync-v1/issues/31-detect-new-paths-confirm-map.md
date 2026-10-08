# 31 — Phát hiện path mới, gợi ý và xác nhận map

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 14, 17, 24
Spec: SPEC §6.1, §6.2 (mới ở v1.1), §9.2 (`remote_keys`), §11 (`pending_map.tsv`), §20 (`projects pending`, `projects map` không tham số), §21 (`waiting_map`)

## Bối cảnh

Cùng một project có thể có path và **tên thư mục** khác nhau trên từng máy:

| Máy | Root |
|---|---|
| A (Windows) | `D:\Projects\TransFlow` |
| B (WSL) | `/mnt/d/projects/TransFlowY` |
| C (Ubuntu) | `~/projects/TransFlowX` |

Không suy ra được path ở máy nhận một cách chắc chắn, nên engine chỉ phát hiện và gợi ý; người dùng luôn xác nhận.

## Phạm vi

- **Phát hiện** (trong `run`, mỗi chu kỳ, sau khi tải manifest):
  - (a) `project_id` trong manifest máy khác mà chưa có trong `projects.tsv` và không bị `exclude` → mục `remote`.
  - (b) session local có `launchCwd` không nằm dưới root nào đã map → gom theo thư mục khởi chạy → mục `local`.
  - Ghi `state/pending_map.tsv` và `status.json.waiting_map`. Không báo lại mục đã biết trừ khi số session tăng.
- **Công bố `remote_keys`**: ghi mảng `remote_keys` (tính bằng hàm của #14) vào `projects.<id>` trong manifest. Không bao giờ ghi URL.
- **Gợi ý ứng viên** theo thứ tự của §6.1: path tương đương (`D:\a` ↔ `/mnt/d/a`) → thư mục Claude local đã chạy có tên khớp → cùng git remote (`remote_keys` của ứng viên giao với `remote_keys` trong manifest) → tên (giống hệt, giống sau chuẩn hoá, prefix hoặc khoảng cách sửa ≤ 2). Tìm trong thư mục cha của các root đã map và `scan_dirs`, độ sâu 2, có giới hạn thời gian (mặc định 5 s mỗi chu kỳ; hết giờ thì làm tiếp ở chu kỳ sau).
- **Xác nhận** — `claude-sync projects pending` (liệt kê) và `claude-sync projects map` không tham số (duyệt từng mục): hiện alias, máy gốc, root ở từng máy, số session, dung lượng, ứng viên kèm lý do. Lựa chọn: dùng ứng viên N / nhập path / thêm làm root phụ cho project đã có / bỏ qua lần này / `exclude`.
- **Kiểm tra trước khi ghi map**: tồn tại và là thư mục; không trùng hoặc lồng với root project khác (lồng thì cảnh báo); kiểm tra `cwd` thật như #14; root trong `/mnt/<x>` trên WSL thì cảnh báo dùng chung file với Windows + I/O chậm.
- Map xong: các session `waiting_map` được cài ở chu kỳ kế tiếp (hoặc ngay nếu chạy `sync --project <alias>`).
- Hàm dùng chung cho #27 (hook đọc `waiting_map`), #28 (wrapper hỏi khi `cwd` là ứng viên) và #29 (setup bước 8).

## Ngoài phạm vi

- Tự map khi chỉ có một ứng viên (bị cấm theo §6.1).

## Tiêu chí nghiệm thu

- [x] 3 máy giả lập với root như bảng trên: B và C thấy mục chờ map `TransFlow`; ứng viên hạng 1 của C là `~/projects/TransFlowX` (lý do: tên prefix); của B là `/mnt/d/projects/TransFlowY`.
- [x] B có sẵn `/mnt/d/Projects/TransFlow` (cùng ổ với A) → ứng viên hạng 1 là path tương đương, kèm cảnh báo `/mnt`.
- [x] Máy C có repo cùng remote nhưng tên thư mục khác hẳn (`~/code/tf-server`) → vẫn là ứng viên, lý do "cùng git remote", xếp trên ứng viên chỉ khớp tên.
- [x] Manifest sinh ra chỉ có `remote_keys` dạng hex 64 ký tự; không có `github.com`, `@`, hay token giả trong nội dung manifest đã giải nén.
- [x] Không bao giờ tự map: chạy `run` nhiều lần với một ứng viên duy nhất → vẫn ở trạng thái chờ.
- [x] Người dùng đổi tên `D:\Projects\TransFlow` → `D:\Projects\TransFlow2` và chạy Claude ở đó → mục `local` được tạo, ứng viên là "thêm làm root phụ của TransFlow"; chọn xong thì session mới được sync vào cùng project.
- [x] `exclude` thì không bao giờ báo lại; `skip` thì báo lại khi có session mới.
- [x] Chọn path lồng trong root của project khác → cảnh báo, phải xác nhận lần 2.
- [x] Sau khi map: session `waiting_map` được cài vào đúng thư mục slug, cwd được dịch sang root mới.
- [x] Bước tìm ứng viên không vượt giới hạn thời gian khi `scan_dirs` có hàng nghìn thư mục.

## Comments

**2026-10-06 — quyết định của người dùng (SPEC §6.1 đã cập nhật):** ở chế độ `all`, thư mục local mới không giống project nào → **tự thêm** thành project mới (ghi log + báo trong `status`); thư mục mới giống project đã có (cùng `remote_keys` / ứng viên tên-path) → hỏi gộp làm root phụ; project từ máy khác → luôn hỏi thư mục. Chế độ `selected` → không tự thêm gì. Cần thêm tiêu chí nghiệm thu:
- [x] `mode all`: mở Claude trong thư mục mới hoàn toàn → chu kỳ sau thư mục đó thành project và session được công bố, không cần người dùng làm gì.
- [x] `mode all`: thư mục mới cùng git remote với project đã có → không tự thêm, xuất hiện trong `projects pending` với gợi ý "root phụ".
- [x] `mode selected`: thư mục mới chỉ hiện trong `projects list` mục chưa sync.

- 2026-10-08: xong. `lib/pending.sh`: manifest.projects (chỉ băm remote_keys), phát hiện (a) remote / (b) local, `pending_map.tsv` + `status.waiting_map` (+ `auto_added`), ứng viên (path tương đương, thư mục Claude đã chạy + tên, cùng git remote, tên; quét có ngân sách `CS_PEND_SCAN_BUDGET` và cache `state/scan_cache.tsv`, làm tiếp ở chu kỳ sau), `projects pending`, `projects map` không tham số (duyệt: số / p / r / s / x; kiểm tra tồn tại, lồng root hỏi lại, cảnh báo /mnt), `cs_project_map` nhận project_id của máy khác, mode `all` tự thêm thư mục không giống gì, mode `selected` không thêm. Dạng ứng viên trong cột `candidates`: `path|lý do|điểm;...` (dùng `|` vì path Windows có `:`). Test `test/pending.bats` (8 ca). Chưa có: `sync --project <alias>` (cài ngay sau khi map) và việc hook/wrapper/setup đọc `waiting_map` (#27, #28, #29).
