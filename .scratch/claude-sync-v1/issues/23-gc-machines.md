# 23 — GC và lệnh machines

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 17
Spec: SPEC §14.2, §15.3 (404 khi tải), §20 (`machines`)

## Phạm vi

- GC chỉ trong `machines/<me>/`: object không còn được **manifest của máy nào** tham chiếu và cũ hơn 24 giờ → trash (không xoá vĩnh viễn).
- Mỗi ngày một lần liệt kê `machines/<me>/` để trash object mồ côi (không có trong manifest lẫn journal).
- **Không bao giờ** gọi `emptyTrash`.
- Máy nhận gặp 404 khi tải object → tải lại manifest rồi quyết định lại (không coi là lỗi dữ liệu).
- `claude-sync machines [list|forget <name>]`: `forget` cần xác nhận; chỉ xoá vùng máy khác khi mọi version ở đó bằng hoặc là tổ tiên của version ở vùng khác; nếu không thì trước tiên sao các version đó vào vùng của mình.

## Tiêu chí nghiệm thu

- [x] B đang tải version cũ của A thì A công bố 2 lần → object B cần vẫn còn (≥ 24 giờ hoặc vẫn được tham chiếu); nếu đã mất thì B tải lại manifest và hội tụ (**M6** phần a).
- [x] A crash sau khi upload segment nhưng trước khi ghi manifest → object mồ côi được GC sau 24 giờ, không bị dùng nhầm (**M6** phần b).
- [x] `machines forget` máy đã cài lại OS (machine_id mới) không làm mất version duy nhất (**F12**).
- [x] Test grep: code không có lời gọi `emptyTrash`.

## Comments

- 2026-10-08: `lib/gc.sh`: `cs_gc_run` (một lần/ngày, chỉ trash object trong vùng của mình, không được manifest nào tham chiếu và cũ hơn 24 giờ theo giờ server; bỏ qua khi không đọc được manifest của máy khác), `claude-sync machines [list|forget <tên> [--yes]]` (version duy nhất được chép vào vùng của mình, giữ trong `archive[machine][sid]` của manifest). 404 khi tải không phải lỗi (chu kỳ sau tự hội tụ). Test `test/gc.bats` (6 ca, gồm M6a, F12, grep emptyTrash). M6b (orphan sau crash) được phủ bằng ca object mồ côi cũ.
