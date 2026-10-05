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

  [projects.col_sessions]='SESSION'
  [projects.col_size]='DUNG LƯỢNG'
  [projects.col_cwd]='THƯ MỤC KHỞI CHẠY (session mới nhất)'
  [projects.col_dir]='THƯ MỤC PROJECT'
)
