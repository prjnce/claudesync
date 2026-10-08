# 20 — Rẽ nhánh xác định và lệnh conflicts

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 18
Spec: SPEC §12.5, §11 (`forks.tsv`), §20 (`conflicts`), §1.4 A4

## Phạm vi

- Điểm rẽ = dòng chuẩn hoá đầu tiên khác nhau. Dòng chat = `type ∈ {user, assistant, attachment, system}` hoặc type lạ; còn lại là metadata.
- Nhánh chỉ khác ở metadata: thua, không tạo session tách; máy sở hữu lưu bản sao vào `backups/` rồi cài nhánh kia.
- Nhánh thắng = dòng chat đầu tiên sau điểm rẽ có `timestamp` sớm hơn; bằng nhau → `machine_id` nhỏ hơn. Kết quả không đổi khi các nhánh dài thêm.
- **Chỉ máy sở hữu nhánh thua** tạo session tách:
  - `fork_sid` = UUID v4 từ `sha256(sid + uuid dòng chat rẽ đầu tiên của nhánh thua)`.
  - Thay `"sessionId":"<sid>"` trong transcript chính và subagent (bằng awk, **không jq**); chép `S/` → `fork_sid/`; chép `file-history/S` của nhánh thua.
  - Plan slug `<slug>-c<4 hex>`; chép file plan.
  - Tiêu đề `custom-title.json` + dòng `custom-title` "[conflict <machine_name>] <tiêu đề cũ>".
  - mtime = min(mtime nhánh thua, mtime nhánh chính − 1 s).
  - Cài nhánh thắng vào S; ghi `forked{losing_version: fork_sid}` vào manifest và `forks.tsv`.
- Máy thắng bỏ qua ứng viên rẽ nhánh đến khi máy sở hữu thôi công bố; thêm `losing_version` vào `known`.
- `claude-sync conflicts [list|show <sid>]`.

## Tiêu chí nghiệm thu

- [ ] 2 máy offline cùng viết tiếp → online: không mất dòng, nhánh thắng giữ ID gốc, nhánh thua thành session tách mở được, không có session tách trùng (**A4**, **F1**).
- [ ] 2 máy tự tính độc lập ra cùng thắng/thua và cùng `fork_sid`, kể cả khi chạy theo thứ tự khác nhau (**H2**).
- [ ] Session tách có đủ subagent, file-history, plan, tiêu đề; chạy lại không sinh bản thứ 2 (**M10**).
- [ ] `claude --resume <fork_sid>` mở được (kiểm bằng `--resume` trên máy thật ở #30).

## Comments

- 2026-10-08: code xong, test chưa chạy hết. `lib/fork.sh` (`cs_fork_resolve`, `cs_fork_compare`, `cs_fork_materialize`, `cs_fork_known_from_manifests`, lệnh `claude-sync conflicts [list|show]`), `forks.tsv`, `forked{}` trong manifest (gộp sâu ở `cs_manifest_put_session`), `CS_INSTALL_FORCE` để cài bản thắng. Tiêu chí còn lại trong `test/fork.bats` (5 ca: A4/F1, H2, đối xứng, M10, nhánh chỉ metadata): ca A4/F1 đã qua, 4 ca còn lại chưa có kết quả khi dừng. Lỗi đã gặp: `cmp`/`awk exit` + `set -e -o pipefail` làm chu kỳ dừng im lặng; phải gắn `|| true` ở các phép gán từ pipeline có thể trả mã khác 0. Chưa tick tiêu chí nghiệm thu, status giữ nguyên needs-triage.
