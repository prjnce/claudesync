# 13 — Transform dịch path (§7)

Status: done
Đề xuất: ready-for-agent
Type: task
Mốc: M4 (đưa lên trước vì #15 repair cần)
Blocked by: 06
Spec: SPEC §4.7, §7; code tham chiếu `docs/research/bash.md` (`cs_rewrite.awk`, `cs_rewrite_file`), `docs/prototypes/xf.awk`

## Mục tiêu

Hàm thuần theo từng dòng, chuyển transcript giữa dạng local và dạng chuẩn hoá (token `{P:id}`, `{R:id}`, `{MEM:id}`, `{CFG}`), giữ nguyên byte ở mọi chỗ khác.

## Phạm vi (`lib/transform.sh` + `lib/cs_rewrite.awk`)

- Đầu vào: bảng root (truyền qua `ENVIRON`): danh sách `(token, root, kiểu khớp)`. Trong ticket này, bảng root nhận từ tham số; #14 cung cấp bảng thật.
- Chỉ thay giá trị chuỗi JSON (hoặc key) **bắt đầu** bằng root đã map, ở đúng ngữ cảnh key: `"cwd":"` (mọi chỗ), `"relocatedCwd":"`, `"trackingPath":"`, `"realParentDir":"` (dùng `{R:}`), và key object đứng ngay trước `{"backupFileName"`.
- Khớp không phân biệt hoa/thường ASCII với path Windows và `/mnt/<x>`; đúng ranh giới (sau prefix là `"`, `\\` hoặc `/`); root lồng nhau thì chọn **root dài nhất**.
- Canonicalize: phần sau token đổi `\\` → `/`. Localize trên Windows: `/` → `\\`. `trackingPath` tương đối: chỉ đổi dấu phân cách.
- `cwd` lồng nhau dạng Git Bash (`/d/Projects/...`) không phải root đã map → giữ nguyên.
- POSIX awk chạy được trên mawk 1.3.4 và gawk: `LC_ALL=C awk -v BINMODE=3`; **không dùng `sub/gsub` với chuỗi thay thế động**; vòng `index/substr`. Input không có newline cuối thì cắt newline awk tự thêm.
- **Không bao giờ** dùng jq để ghi (kịch bản **P6**).
- `cs_rewrite_file in out`: chuyển cả file hoặc chỉ phần đuôi từ offset (§7.3); kiểm tra trước khi đổi tên: mọi dòng parse được (`jq -R 'fromjson? // error'`), không có `\r`, số dòng không đổi.

## Tiêu chí nghiệm thu

- [ ] Fixture: backslash, `\"`, `\uXXXX`, tiếng Việt, `&`, CRLF, thiếu newline cuối, ranh giới `TransFlow` vs `TransFlowOld`, `d:` và `D:`.
- [ ] Chạy 2 chiều trên mawk và gawk → output giống byte (kịch bản **P10**); canonicalize(localize(x)) == x; idempotent.
- [ ] `realParentDir` dùng `realRoot` (kịch bản **P3**); path memory và plans dùng `{MEM:}` / `{CFG}` (kịch bản **P4**).
- [ ] Root lồng nhau khác nhau giữa 2 máy (kịch bản **P5**).
- [ ] Prefix-preserving: transform(prefix của file) == prefix của transform(file).
- [ ] Hiệu năng trên Git Bash: file 60 MB ≤ ~3 s.

## Comments

**2026-10-05 — Claude:** Đã làm xong, chờ duyệt.
- `lib/transform.awk` (phát triển từ `docs/prototypes/xf.awk`): ngữ cảnh key (`cwd`, `relocatedCwd`, `trackingPath`, `realParentDir`, key của `trackedFileBackups`), root dài nhất thắng, scope `P`/`R`/`A` (`realParentDir` chỉ dùng `{R:}`; `{MEM:}`, `{CFG}/plans` dùng cho mọi key), khớp không phân biệt hoa/thường cho path Windows và `/mnt/<x>`, path tương đối chỉ đổi dấu phân cách; bảng root qua `ENVIRON`.
- `lib/transform.sh`: `cs_json_escape`, `cs_transform_row`, `cs_transform`, `cs_transform_file` (có OFFSET để chỉ chuyển phần đuôi, giữ nguyên việc thiếu newline cuối), `cs_complete_len`, `cs_transcript_stats`, `cs_transform_verify`.
- **Khác SPEC §7.2:** "mọi dòng phải parse được" đổi thành "transform không làm hỏng thêm": số dòng, số CR và số dòng không parse được phải giống nhau trước/sau. Lý do: chính Claude có thể để lại dòng bị cắt giữa file (§4.4).
- Dữ liệu thật (file native 27 MB, 12.168 dòng): canonicalize 1,5 s; 10.881 `{P:}`, 1.627 `{R:}`, 156 `{MEM:}`, 36 `{CFG}`; vòng Windows → chuẩn → Linux → chuẩn ổn định; verify đạt. File legacy (JSON có dấu cách) không bị đụng tới — phải repair trước (#15).
- Phát hiện: đọc lần đầu một file vừa ghi mất ~1,7 s/MB (antivirus) → ghi vào SPEC §25 R2 và #17.
- Bẫy: `RT` là biến có sẵn của gawk — không dùng làm tên mảng.
- 18 test mới; toàn bộ 108/108 pass trên 3 cấu hình (gồm so byte mawk vs gawk trong WSL).
