# 32 — Ngôn ngữ giao diện en/vi

Status: needs-triage
Đề xuất: ready-for-agent
Type: task
Mốc: M1
Blocked by: 05
Spec: SPEC §20.1 (mới ở v1.2), §16 bước 0

## Bối cảnh

Người dùng (2026-10-05): "Tiếng Anh, hoặc tốt nhất là ở bước setup thêm bước chọn ngôn ngữ Anh/Việt". Làm sớm để mọi ticket giao diện sau dùng catalog ngay từ đầu, không phải sửa lại.

## Phạm vi

- `lib/i18n.sh`: `cs_lang` (`CLAUDE_SYNC_LANG` > config `lang` > `en`; giá trị lạ → `en`), `cs_t KEY ARGS...` (chuỗi đã định dạng, theo ngôn ngữ hiện tại, thiếu key ở `vi` thì dùng `en`), `cs_t_en` (luôn tiếng Anh, dùng cho log), `cs_die_t CODE KEY ARGS...` (stderr theo ngôn ngữ, log tiếng Anh).
- Catalog `lib/i18n/en.sh`, `lib/i18n/vi.sh`.
- Chuyển các chuỗi người dùng thấy đã có (usage, lệnh lạ, chưa làm, thiếu công cụ, config sai, `doctor`, `projects list`) sang catalog.
- Bước 0 của `setup` (chọn ngôn ngữ) và `config set lang` thuộc #29 / #12; ticket này chỉ cần đọc được `lang` từ config.

## Ngoài phạm vi

- Log và lỗi nội bộ cho lập trình viên (luôn tiếng Anh).

## Tiêu chí nghiệm thu

- [ ] Test: hai catalog có cùng tập key; mỗi key có cùng chuỗi đặc tả `printf` (`%s`, `%d`…) theo đúng thứ tự.
- [ ] Test: `CLAUDE_SYNC_LANG=vi claude-sync help` ra tiếng Việt; mặc định ra tiếng Anh; `lang=xx` → tiếng Anh.
- [ ] Test: thiếu key ở `vi` thì dùng bản `en`.
- [ ] Test: khi chạy ở `vi`, dòng log vẫn là tiếng Anh.

## Comments

**2026-10-05 — Claude:** Đã làm xong, chờ duyệt.
- `lib/i18n.sh` (`cs_lang_init`, `cs_t`, `cs_t_lang`, `cs_say`, `cs_die_t`, `cs_pad`), catalog `lib/i18n/en.sh` + `vi.sh` (25 key + usage). `core.sh` tách `cs_bootstrap_ui` (OS, home, ngôn ngữ) để `help` và lỗi cú pháp cũng theo ngôn ngữ.
- Đã chuyển: usage, lệnh lạ, chưa làm, thiếu công cụ, GNU tool, config sai, CLAUDE_CONFIG_DIR rỗng, settings sai, `doctor`, `projects list`. Tag `OK/WARN/FAIL` giữ nguyên.
- Test 9 cái, gồm: hai catalog cùng key, cùng đặc tả `printf` (đã thử cố tình làm lệch → test bắt được), mọi key dùng trong code đều có trong catalog, log luôn tiếng Anh. Toàn bộ 90/90 pass trên 3 cấu hình.
