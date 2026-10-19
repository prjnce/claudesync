# Hướng dẫn: đưa lịch sử Claude sang một máy khác

[English](SECOND-MACHINE.md) · **Tiếng Việt**

Dùng khi bạn đã sync xong từ máy thứ nhất (ví dụ `Office-PC`) và muốn có cùng lịch sử Claude Code
trên máy thứ hai (ví dụ máy ở nhà). Cùng quy trình áp dụng cho máy thứ ba, thứ tư.

## 0. Cần có

| Thứ | Ghi chú |
|---|---|
| Cùng tài khoản Google | Tài khoản đã dùng ở máy thứ nhất |
| File OAuth client | `google_client_secret.json` của project Google Cloud bạn đã tạo cho claude-sync (hoặc Client ID + secret) |
| Bash 5, `curl`, `jq`, `gawk` | Trên Windows dùng Git Bash; trên Linux/WSL cài bằng apt |
| Code claude-sync | `git pull` / `git clone` về máy mới |

> **Quan trọng:** quyền `drive.file` chỉ thấy file do **chính OAuth client đó** tạo. Máy mới phải dùng **đúng client cũ**.
> Nếu tạo client mới, máy mới sẽ không thấy dữ liệu đã sync.

## 1. Trên máy thứ nhất: chắc chắn đã upload xong

```
claude-sync status
```

- Không có session nào "chờ upload", không có lỗi, lần chạy gần nhất thành công.
- Nếu chưa, chạy `claude-sync run` và chờ kết thúc (có hiển thị tiến độ `[k/N - %]`).
- Chỉ những session đã lên Drive mới về được máy mới.

## 2. Trên máy thứ hai: chạy setup

```
cd <thư mục claude_sync>
bash bin/claude-sync setup
```

| Bước | Làm gì |
|---|---|
| 0. Ngôn ngữ | Chọn `2` (Tiếng Việt) |
| 1. Công cụ | Tự kiểm tra; thiếu gì sẽ báo |
| 2. OAuth client | Nhập đường dẫn tới `google_client_secret.json`. Hoặc nhấn Enter rồi gõ Client ID và secret (secret không hiện khi gõ; chuỗi sai định dạng sẽ bị hỏi lại) |
| 3. Proxy | Nhấn Enter nếu không dùng |
| 4. Đăng nhập | Mở URL, đăng nhập **cùng tài khoản Google**, cấp quyền Drive. Xem mục *Đăng nhập trên WSL/SSH* nếu terminal không tự nhận |
| 5. Folder gốc | Chọn **đúng folder gốc cũ** trên Drive; setup nhận ra và dùng lại, không tạo mới |
| 6. Máy này | Đặt tên khác máy cũ, ví dụ `Home-PC` |
| 7. Kiểm tra transcript | Tự động |
| 8. Project | Xem mục bên dưới |
| 9. Retention | Giữ hoặc đổi `cleanupPeriodDays` (nên đủ lớn để Claude không dọn lịch sử cũ) |
| Cuối | Cài lịch tự chạy và chạy lần sync đầu: tải session về `~/.claude/projects/...` |

### Bước 8: chọn project và map thư mục

Bước này hiện danh sách các thư mục đang dùng Claude **trên máy này**, đánh số:

- Nhập số cách nhau bằng dấu phẩy (ví dụ `1,2`) để chỉ sync các project đó.
- Nhấn Enter để sync tất cả.
- Nhập `0` (hoặc `none`) nếu không muốn sync project nào từ máy này.
- Nếu danh sách trống (chưa có project nào dùng Claude) thì bước tự bỏ qua.

Các project đã có trên Drive nhưng máy này chưa có thư mục tương ứng sẽ ở trạng thái **chờ map**. Phải map để session của
chúng được cài về:

```
claude-sync projects pending                         # xem project đang chờ
claude-sync projects map <tên-project> <thư-mục>     # trỏ tới thư mục thật trên máy này
```

Đường dẫn ở máy mới được phép khác máy cũ (ví dụ `D:\Projects\X` ở cơ quan, `/home/frank/X` ở nhà). Sau khi map, chạy
`claude-sync run` để cài ngay.

## 3. Kiểm tra lịch sử đã về

```
claude-sync status          # không còn "chờ map", không lỗi
claude --resume             # thấy các session cũ
```

Mở Claude bằng `claude-sync claude` sẽ pull trước rồi mới mở.

## 4. Sau đó

- Mỗi máy tự sync theo lịch (mặc định 5 phút; đổi bằng `claude-sync config set interval <1..1440>`).
- Session mới ở máy này thấy ở máy kia ở lần sync kế tiếp, hoặc chạy ngay `claude-sync run`.
- Xem tiến độ: `claude-sync run --progress`; xem nhật ký: `claude-sync logs -f`.

## Đăng nhập trên WSL/SSH

Ở bước 4, nếu trình duyệt không mở hoặc terminal không tự nhận kết quả:

1. Mở URL được in ra bằng trình duyệt của bạn.
2. Sau khi xác nhận, trình duyệt hiện trang có **mã** (hoặc trang "refused to connect").
3. Sao chép **mã** đó (hoặc cả địa chỉ trên thanh địa chỉ) và dán vào terminal rồi nhấn Enter.

## Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| `invalid_client` khi đăng nhập | Client secret đã lưu sai: `claude-sync google client <file.json>` rồi chạy lại `claude-sync setup` |
| Máy mới không thấy dữ liệu cũ | Đã dùng sai OAuth client hoặc sai folder gốc. Kiểm tra bước 2 và bước 5 |
| Có project mà session không về | Project đang chờ map: `claude-sync projects pending` rồi `projects map` |
| Muốn làm lại từ đầu việc import trên máy này | `claude-sync reset` (chỉ xoá trạng thái local, không xoá gì trên Drive) rồi `claude-sync run` |
| Cần xem tất cả lệnh | `claude-sync help` |

## Giới hạn cần biết

- Session đã bị Claude dọn theo `cleanupPeriodDays` trên máy cũ thì không còn để sync.
- Kịch bản 3 máy thật chưa được kiểm thử thủ công; các test mô phỏng nhiều máy đều đạt. Nên thử với một project nhỏ
  trước khi dựa hoàn toàn vào nó.
