# 22 — Memory merge 3 chiều và plans

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 14, 17
Spec: SPEC §9.1 (`mem/`, `plans/`), §9.2 (`memory`, `plans`), §13 (dòng Plans, Memory, tên file không hợp lệ)

## Phạm vi

- Memory theo project (`memDir` từ #14): merge 3 chiều với `state/base/mem/<project_id>/`.
  - Một bên đổi → lấy bên đổi.
  - Một bên xoá, bên kia không đổi → xoá (có backup); ghi `deleted:true` trong manifest.
  - Cả hai đổi: `git merge-file`; `MEMORY.md` diff3 theo dòng, xung đột thì `--union`; file `.md` khác xung đột thì giữ local, bản remote vào `conflicts/`, báo trong status.
  - Không có git: giữ local + lưu bản conflict.
  - Bỏ qua `team/**`, `.memory-sync*`.
- Plans: chỉ sync `plans/<slug>*.md` mà session được sync tham chiếu (field `slug`). Một bên đổi → lấy; cả hai đổi → bản mtime mới hơn, bản kia vào `conflicts/`.
- Tên file không hợp lệ trên Windows (`:`, `?`, đuôi `.` hoặc dấu cách): bỏ qua và báo.

## Tiêu chí nghiệm thu

- [x] A xoá `foo.md` và dòng index của nó trong `MEMORY.md`, B không đổi → B cũng xoá, có backup (**M9**).
- [x] Cả hai sửa `MEMORY.md` ở dòng khác nhau → merge sạch; cùng dòng → union, không mất dòng nào.
- [x] Không có `git` trên PATH → quy tắc dự phòng chạy đúng.
- [x] File memory tên `a:b.md` từ Linux → Windows bỏ qua và báo, không lỗi chu kỳ.

## Comments

- 2026-10-08: `lib/memory.sh` (`cs_dsync_run` chung cho memory và plans), base + `.seen` (version đã từng dùng, chặn manifest cũ của máy khác kéo lùi), `git merge-file` (MEMORY.md `--union` khi xung đột; không git hoặc file khác → giữ local, bản kia vào `conflicts/` và `status.json.memory_conflicts`). Plans: chỉ slug có trong transcript của session đang sync. Tên không hợp lệ trên Windows: bỏ qua. Test `test/memory.bats` (6 ca, gồm M9). Ghi nhớ: test dùng hai máy POSIX vì memDir của máy Windows giả lập không phải đường dẫn thật. Lệnh `claude-sync conflicts` vẫn là #20.
