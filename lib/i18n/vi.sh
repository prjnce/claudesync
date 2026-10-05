# shellcheck shell=bash
# Vietnamese UI messages: printf formats. Keys and % specifiers must match lib/i18n/en.sh (test/i18n.bats).
# No backslashes in formats; pass paths and other data as %s arguments.

declare -gA CS_MSG_vi=(
  [usage]='cách dùng: claude-sync <lệnh> [tham số]

  setup                         trình cài đặt đầy đủ (chạy lại được)
  login [--device] | logout     đăng nhập / thu hồi quyền truy cập Google Drive
  folder [show]                 folder gốc, marker, các máy
  projects ...                  list|select|pending|map|unmap|mode|exclude
  sync [--pull-only|--push-only] [--project X] [--dry-run] [--verbose]
  run [--trigger=...]           chạy một chu kỳ không tương tác (dùng cho service)
  status [--json]               sức khoẻ, lần chạy trước/sau, behind, conflict, chờ map
  conflicts [list|show <sid>]   các session đã tách, bản thua của memory/plan
  restore <sid>                 cài lại session đã bị dọn theo retention
  repair [--dry-run]            sửa dữ liệu cũ (CRLF, JSON có dấu cách, cwd lạ, ID trùng)
  service install|uninstall|status|kick
  hooks install|uninstall
  config get|set <key> <value>  interval=5|10, guard=block|warn|off, lang=en|vi
  machines [list|forget <name>]
  claude [args...]              pull rồi mở claude
  doctor                        kiểm tra phụ thuộc và cài đặt
  logs [-f]
  uninstall [--purge]
  --version | help'
  [cli.unknown_command]='lệnh không tồn tại: %s'
  [cli.not_implemented]='lệnh "%s" chưa được làm'

  [boot.missing_tools]='thiếu công cụ bắt buộc: %s — %s'
  [boot.install_git]='cài Git for Windows (https://gitforwindows.org); jq: winget install jqlang.jq'
  [boot.install_apt]='sudo apt install %s'
  [boot.gnu_tool]='%s của GNU không đứng đầu PATH (%s)'

  [config.bad_key]='key config không hợp lệ: %s'
  [config.multiline]='giá trị config phải nằm trên một dòng'
  [claude.config_dir_empty]='CLAUDE_CONFIG_DIR được đặt nhưng rỗng'
  [settings.not_json]='settings: giá trị cho %s không phải JSON hợp lệ'
  [settings.not_object]='settings: %s không phải object JSON; không động vào file này'

  [doctor.title]='claude-sync %s doctor'
  [doctor.env]='bash %s, awk %s, hệ điều hành %s'
  [doctor.claude_dir]='thư mục config của Claude: %s'
  [doctor.claude_dir_missing]='không tìm thấy thư mục config của Claude: %s'
  [doctor.sessions]='%s session trong %s thư mục project'
  [doctor.retention]='retention (cleanupPeriodDays, settings của user): %s ngày'
  [doctor.junk_dir]='thư mục project không hợp lệ (chiếm chỗ --resume): projects/%s'
  [doctor.dup_ids]='%s session ID nằm ở nhiều hơn một thư mục project'
  [doctor.problems]='Có vấn đề: hãy chạy "claude-sync repair --dry-run" (repair chưa được làm).'
  [doctor.ok]='Không có vấn đề.'

  [auth.no_client]='chưa có OAuth client (%s): chạy "claude-sync login --client <file JSON client đã tải>" hoặc "claude-sync setup"'
  [auth.bad_client]='%s không phải file JSON OAuth client của Google (cần mục "installed" có client_id và client_secret)'
  [auth.open_url]='Mở URL này trong trình duyệt để đăng nhập (đang thử mở giúp bạn):'
  [auth.waiting]='Đang chờ Google... Nếu trình duyệt không quay lại được đây (SSH, WSL), hãy dán địa chỉ http://127.0.0.1:... cuối cùng trên trình duyệt rồi nhấn Enter.'
  [auth.browser_done]='claude-sync: đã đăng nhập. Bạn có thể đóng tab này và quay lại terminal.'
  [auth.timeout]='Không nhận được trả lời từ trình duyệt kịp thời. Hãy chạy lại "claude-sync login".'
  [auth.state_mismatch]='Trả lời từ trình duyệt không thuộc lần đăng nhập này (state không khớp). Hãy chạy lại "claude-sync login".'
  [auth.denied]='Google trả về lỗi: %s'
  [auth.exchange_failed]='Không đổi được mã đăng nhập lấy token: %s'
  [auth.no_drive_scope]='Chưa cấp quyền Google Drive (hãy tích ô Drive) - chạy lại "claude-sync login".'
  [auth.testing_mode]='Cảnh báo: OAuth app vẫn ở chế độ "Testing": đăng nhập hết hạn sau 7 ngày. Hãy Publish (Google Auth Platform > Audience).'
  [auth.signed_in]='Đã đăng nhập.'
  [auth.signed_in_as]='Đã đăng nhập: %s'
  [auth.logged_out]='Đã đăng xuất: token đã bị thu hồi và xoá khỏi máy này.'
  [auth.client_installed]='Đã lưu OAuth client vào %s'

  [setup.h_lang]='Bước 0 - Ngôn ngữ'
  [setup.ask_lang]='Language / Ngôn ngữ: 1 = English, 2 = Tiếng Việt'
  [setup.h_deps]='Bước 1 - Công cụ cần thiết'
  [setup.deps_ok]='Đã có đủ công cụ (bash %s, awk %s).'
  [setup.no_python]='Lưu ý: thiếu python3; khi đăng nhập bạn sẽ cần dán địa chỉ cuối cùng trên trình duyệt.'
  [setup.no_git]='Lưu ý: thiếu git; khi memory bị sửa xung đột, bản local được giữ và bản kia được lưu riêng.'
  [setup.h_client]='Bước 2 - Google OAuth client'
  [setup.client_have]='Đã có OAuth client (%s).'
  [setup.ask_client_replace]='Thay bằng file JSON client khác? (c/k)'
  [setup.client_guide]='claude-sync dùng OAuth client của riêng bạn (tạo một lần, rồi chép cùng file JSON sang mọi máy):
  1. console.cloud.google.com -> tạo project, ví dụ "claude-sync".
  2. APIs & Services -> bật "Google Drive API".
  3. Google Auth Platform -> Branding: tên app và email hỗ trợ.
  4. Audience: External -> thêm chính bạn làm test user -> PUBLISH APP (nếu không, đăng nhập hết hạn sau 7 ngày).
  5. Data access: thêm scope .../auth/drive.file.
  6. Clients -> Create client -> Desktop app -> tải file JSON ngay.'
  [setup.ask_client_path]='Đường dẫn tới file JSON client đã tải'
  [setup.h_proxy]='Bước 3 - Proxy'
  [setup.ask_proxy]='HTTPS proxy để gọi Google API ("-" nếu không dùng)'
  [setup.h_login]='Bước 4 - Đăng nhập Google Drive'
  [setup.ask_relogin]='Đăng nhập lại bằng tài khoản khác? (c/k)'
  [setup.h_root]='Bước 5 - Folder gốc trên Google Drive'
  [setup.ask_root_name]='Chưa có folder claude-sync nào. Tên folder sẽ tạo trong My Drive'
  [setup.root_created]='Đã tạo "%s" cùng file marker.'
  [setup.root_found]='Đã tìm thấy folder claude-sync có sẵn: "%s".'
  [setup.root_many]='Tìm thấy %s folder claude-sync; dùng folder cũ nhất, "%s". Các folder khác:'
  [setup.root_summary]='  Tài khoản: %s
  Folder:    %s
  Link:      %s
  Các máy đã tham gia:'
  [setup.no_machines]='    (chưa có: đây là máy đầu tiên)'
  [setup.h_machine]='Bước 6 - Máy này'
  [setup.ask_machine_name]='Tên của máy này'
  [setup.owner_conflict]='%s cho biết một bản cài claude-sync khác (máy %s) đang quản lý thư mục config Claude này. Không chiếm quyền.'
  [setup.machine_done]='Máy này là "%s" (%s).'
  [setup.bad_step]='bước setup không tồn tại: %s (các bước: %s)'
  [setup.step_failed]='bước setup "%s" bị lỗi; sửa lỗi rồi chạy lại "claude-sync setup" (các bước đã xong được giữ lại).'
  [setup.done_so_far]='Đã xong bước 0-6. Chọn project, lập lịch và lần sync đầu sẽ có ở phiên bản sau.'
  [folder.not_set]='Chưa thiết lập folder gốc: hãy chạy "claude-sync setup".'
  [folder.missing]='Folder gốc %s không còn hoặc đang ở thùng rác (ROOT_MISSING). claude-sync sẽ không tự tạo lại.'

  [projects.no_dir]='không phải thư mục trên máy này: %s'
  [projects.spelling]='Lưu ý: bạn gõ %s; trong transcript Claude ghi là %s, nên dùng cách viết đó.'
  [projects.no_sessions_here]='Lưu ý: (chưa) có session Claude nào trên máy này được mở trong %s.'
  [projects.nested]='Cảnh báo: %s chồng lên root %s của một project khác (mỗi session thuộc root dài nhất chứa nó).'
  [projects.unknown]='không có project nào có id hoặc tên %s'
  [projects.mapped_header]='Các project được sync từ máy này (chế độ: %s):'
  [projects.none_mapped]='  (chưa có: chạy "claude-sync projects select" hoặc "claude-sync projects map <tên> <thư mục>")'
  [projects.excluded_tag]='[đã loại]'
  [projects.unmapped_header]='Các thư mục có session Claude nhưng chưa sync (số session, dung lượng, thư mục):'
  [projects.nothing_to_select]='Mọi thư mục có session Claude đều đã được map.'
  [projects.ask_select]='Thư mục cần sync: các số cách nhau bằng dấu phẩy, "a" để chọn tất cả, để trống nếu không chọn'
  [projects.mapped]='Đã map %s (%s): %s'
  [projects.usage_map]='cách dùng: claude-sync projects map <tên|id> <thư mục>'
  [projects.usage_unmap]='cách dùng: claude-sync projects unmap <tên|id> [thư mục]'
  [projects.unmapped]='Đã bỏ map %s.'
  [projects.mode_set]='Chế độ project giờ là "%s".'
  [projects.usage_mode]='cách dùng: claude-sync projects mode all|selected'
  [projects.usage_exclude]='cách dùng: claude-sync projects exclude|include <tên|id>'
  [projects.excluded]='Đã loại %s: không còn sync từ máy này.'
  [projects.included]='Đã đưa %s vào sync trở lại.'

  [repair.h_scan]='Quét transcript tìm dữ liệu cũ bị hỏng'
  [repair.alias]='Path WSL/Windows %s sẽ được đổi thành root project của máy này %s'
  [repair.foreign_unmapped]='Path lạ %s không thuộc project nào đã map: hãy map trước ("claude-sync projects map <tên> <thư mục>"); các session của nó vẫn được sửa nhưng không dịch path.'
  [repair.ask_alias]='Đổi các path đó? (c/k)'
  [repair.nothing]='Không có gì cần sửa.'
  [repair.h_files]='Transcript'
  [repair.file_stats]='%s dòng: %s lấy từ bản gốc, %s ghi lại (%s), %s đã gọn sẵn, %s dòng không parse được giữ nguyên'
  [repair.verify_failed]='%s: kiểm tra thất bại (dòng %s -> %s, CR %s); giữ nguyên file.'
  [repair.skipped_live]='%s đang mở trong Claude: bỏ qua (đóng session rồi chạy lại repair).'
  [repair.h_junk]='Thư mục không phải thư mục project'
  [repair.junk_would_move]='sẽ chuyển projects/%s sang %s'
  [repair.ask_junk]='Chuyển projects/%s ra khỏi config Claude vào backup của claude-sync? (c/k)'
  [repair.junk_moved]='Đã chuyển projects/%s sang %s'
  [repair.summary_dry]='Chạy thử: %s transcript sẽ được ghi lại (%s dòng, giữ %s dòng không parse được), %s lỗi kiểm tra. Chưa thay đổi gì.'
  [repair.summary]='Đã ghi lại %s transcript (%s dòng, giữ %s dòng không parse được), %s lỗi kiểm tra. Backup: %s'

  [projects.col_sessions]='SESSION'
  [projects.col_size]='DUNG LƯỢNG'
  [projects.col_cwd]='THƯ MỤC KHỞI CHẠY (session mới nhất)'
  [projects.col_dir]='THƯ MỤC PROJECT'
)
