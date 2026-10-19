# Sơ đồ đồng bộ history giữa các máy

[English](SYNC-DIAGRAM.md) · **Tiếng Việt**

Tài liệu minh hoạ cách claude-sync đồng bộ history (session) của Claude Code giữa nhiều máy, với ví dụ **4 máy**:

| Tên trong tài liệu | Loại | Ghi chú |
|---|---|---|
| **Win-Office** | Windows (Git Bash) | máy ở công ty |
| **Win-Home** | Windows (Git Bash) | máy ở nhà |
| **WSL-Office** | WSL Ubuntu | trên cùng máy vật lý với Win-Office nhưng **là một máy riêng** (có `~/.claude` riêng, `machine_id` riêng) |
| **WSL-Home** | WSL Ubuntu | trên cùng máy vật lý với Win-Home, cũng là một máy riêng |

Nguồn: `lib/engine.sh` (`cs_run_cycle`, `cs_eng_pick`, `cs_eng_install`, `cs_eng_publish`, `cs_fork_resolve`).
Khái niệm cốt lõi: **không có máy chủ trung tâm** và **không có máy nào là "chính"**. Mỗi máy chỉ ghi vào vùng riêng của mình trên Google Drive, và đọc vùng của các máy khác.

---

## 1. Bức tranh tổng thể

```mermaid
flowchart TB
    subgraph WO["Win-Office (Windows)"]
        WO_C["~/.claude/projects/<br/>D--Projects-TransFlow/"]
        WO_E["claude-sync engine<br/>(Task Scheduler, mỗi 5 phút)"]
        WO_C <--> WO_E
    end
    subgraph WH["Win-Home (Windows)"]
        WH_C["~/.claude/projects/<br/>C--dev-TransFlow/"]
        WH_E["claude-sync engine<br/>(Task Scheduler, mỗi 5 phút)"]
        WH_C <--> WH_E
    end
    subgraph LO["WSL-Office (Ubuntu)"]
        LO_C["~/.claude/projects/<br/>-home-frank-work-TransFlow/"]
        LO_E["claude-sync engine<br/>(systemd timer, mỗi 5 phút)"]
        LO_C <--> LO_E
    end
    subgraph LH["WSL-Home (Ubuntu)"]
        LH_C["~/.claude/projects/<br/>-home-frank-src-tf-server/"]
        LH_E["claude-sync engine<br/>(systemd timer, mỗi 5 phút)"]
        LH_C <--> LH_E
    end

    subgraph DRV["Google Drive - folder 'Claude Sync'"]
        D_WO["machines/Win-Office/<br/>manifest + segments"]
        D_WH["machines/Win-Home/<br/>manifest + segments"]
        D_LO["machines/WSL-Office/<br/>manifest + segments"]
        D_LH["machines/WSL-Home/<br/>manifest + segments"]
    end

    WO_E -- "ghi (publish)" --> D_WO
    WH_E -- "ghi (publish)" --> D_WH
    LO_E -- "ghi (publish)" --> D_LO
    LH_E -- "ghi (publish)" --> D_LH

    D_WH -. "đọc (install)" .-> WO_E
    D_LO -. "đọc (install)" .-> WO_E
    D_LH -. "đọc (install)" .-> WO_E
    D_WO -. "đọc (install)" .-> WH_E
    D_LO -. "đọc (install)" .-> WH_E
    D_LH -. "đọc (install)" .-> WH_E
    D_WO -. "đọc (install)" .-> LO_E
    D_WH -. "đọc (install)" .-> LO_E
    D_LH -. "đọc (install)" .-> LO_E
    D_WO -. "đọc (install)" .-> LH_E
    D_WH -. "đọc (install)" .-> LH_E
    D_LO -. "đọc (install)" .-> LH_E
```

Ý chính:

- **Mỗi máy chỉ ghi vào `machines/<machine_id của mình>/`**, nên không bao giờ hai máy ghi đè lên nhau trên Drive.
- Cùng một project có thể nằm ở **path khác nhau, thậm chí tên thư mục khác nhau** trên mỗi máy (ví dụ `TransFlow` và `tf-server`). Người dùng map một lần bằng `claude-sync projects map`; sau đó claude-sync dịch path tự động (xem §3).
- Mỗi máy có engine chạy độc lập theo chu kỳ. Máy nào bật thì máy đó tự sync, không cần các máy còn lại cùng online.

---

## 2. Cấu trúc dữ liệu trên Drive

```mermaid
flowchart LR
    ROOT["Claude Sync/<br/>.claude-sync-root (marker)"]
    ROOT --> MA["machines/"]
    MA --> M1["Win-Office/"]
    MA --> M2["Win-Home/"]
    MA --> M3["WSL-Office/"]
    MA --> M4["WSL-Home/"]

    M1 --> MF["manifest.json.gz<br/>danh sách session + chuỗi segment + head"]
    M1 --> LV["live.json<br/>session đang mở (nhịp tim)"]
    M1 --> SEG["t-sid-seq-sha16.jsonl.gz<br/>segment transcript, không bao giờ sửa"]
    M1 --> SF["s/sid/f/...<br/>file trong bundle, file-history, tasks"]
    M1 --> SA["s/sid/sa/agent-id/...<br/>transcript subagent"]
    M1 --> MEM["mem/project_id/*.md<br/>memory"]
    M1 --> PL["plans/*.md"]
```

- **manifest** là "mục lục" của một máy: mỗi session có `head` (version hiện tại), danh sách `segs` (các đoạn transcript, mỗi đoạn có `m` = máy sở hữu), `from` (các version bị thay thế khi viết lại), `forked`.
- **Segment** là phần transcript **nối thêm**, đã chuẩn hoá path, nén gzip, đặt tên theo hash nên không bao giờ bị sửa.
- Các máy khác chỉ cần tải manifest (so `md5Checksum`, chỉ tải khi đổi) rồi tải đúng những segment còn thiếu.

---

## 3. Dịch path giữa các máy

Transcript `.jsonl` có các field chứa path (`cwd`, `relocatedCwd`, `trackingPath`...). Khi **đẩy lên**, path của máy mình được đổi thành token trung lập; khi **cài về**, token được đổi thành path của máy nhận.

```mermaid
flowchart LR
    A["Win-Office<br/>D:\Projects\TransFlow\apps\server"]
    B["Win-Home<br/>C:\dev\TransFlow\apps\server"]
    C["WSL-Office<br/>/home/frank/work/TransFlow/apps/server"]
    D["WSL-Home<br/>/home/frank/src/tf-server/apps/server"]
    T(("Dạng chuẩn<br/>P:3fa1c2d9 / apps/server"))

    A -- "canonicalize" --> T
    B -- "canonicalize" --> T
    C -- "canonicalize" --> T
    D -- "canonicalize" --> T
    T -- "localize" --> A
    T -- "localize" --> B
    T -- "localize" --> C
    T -- "localize" --> D
```

Mỗi máy lưu session vào **thư mục slug của chính path máy đó**, vì `/resume` chỉ liệt kê session nằm đúng thư mục slug của thư mục đang chạy Claude:

| Máy | Root của project | Thư mục slug trong `~/.claude/projects/` |
|---|---|---|
| Win-Office | `D:\Projects\TransFlow` | `D--Projects-TransFlow` |
| Win-Home | `C:\dev\TransFlow` | `C--dev-TransFlow` |
| WSL-Office | `/home/frank/work/TransFlow` | `-home-frank-work-TransFlow` |
| WSL-Home | `/home/frank/src/tf-server` | `-home-frank-src-tf-server` |

---

## 4. Một chu kỳ sync trên mỗi máy

Mỗi máy chạy `claude-sync run` theo timer (mặc định 5 phút), khi đăng nhập, khi resume từ sleep, hoặc khi hook `SessionEnd` đánh thức. Thứ tự **pull trước, push sau**.

```mermaid
flowchart TD
    S(["Bắt đầu: timer / logon / resume / kick"]) --> L{"Lấy được khoá<br/>sync.lock?"}
    L -- "không" --> X1(["Thoát: đã có lần chạy khác"])
    L -- "có" --> J["Xử lý journal dở dang<br/>(lần chạy trước bị ngắt)"]
    J --> N{"Có mạng?"}
    N -- "không" --> X2(["Trạng thái OFFLINE<br/>chờ backoff tối đa 30 phút"])
    N -- "có" --> T{"Token còn dùng được?"}
    T -- "không" --> X3(["LOGIN_REQUIRED"])
    T -- "có" --> R["Tải manifest của các máy khác<br/>(chỉ cái nào đổi md5)"]
    R --> SC["Quét session local<br/>so sánh với DB state/sessions.tsv"]
    SC --> D["Quyết định từng session<br/>(xem §5)"]
    D --> I["1. CÀI các version mới từ máy khác"]
    I --> P["2. CÔNG BỐ phần mới của máy này"]
    P --> B["3. Đồng bộ bundle, subagent,<br/>memory, plans"]
    B --> LV["4. Ghi live.json,<br/>ghi manifest, GC"]
    LV --> ST(["Ghi status.json, xong"])
```

Hạn mềm 7 phút: quá hạn thì không bắt đầu việc mới, phần dở được làm tiếp ở chu kỳ sau.

---

## 5. Quyết định cho từng session

Với mỗi session, engine so sánh bản local (`L`) với version đã biết (`base`) và các version mà máy khác công bố (ứng viên).

```mermaid
flowchart TD
    A["Một session S"] --> B{"Session đang mở<br/>trên máy này?"}
    B -- "có, có version mới từ máy khác" --> BH["KHÔNG cài.<br/>Đánh dấu behind;<br/>hook cảnh báo người dùng"]
    B -- "có, chỉ local có thay đổi" --> TH["Chỉ công bố phần nối thêm,<br/>tối đa 1 lần / 15 phút"]
    B -- "không" --> C{"Local có thay đổi<br/>so với base?"}

    C -- "không" --> D{"Máy khác có version<br/>mới hơn base?"}
    D -- "không" --> N1(["Không làm gì"])
    D -- "có (base là tổ tiên)" --> INS["CÀI version mới nhất<br/>(chỉ tải segment còn thiếu)"]

    C -- "có" --> E{"Máy khác có version<br/>mới hơn?"}
    E -- "không" --> PUB["CÔNG BỐ:<br/>thêm 1 segment mới"]
    E -- "có" --> FORK["RẼ NHÁNH<br/>(xem §7)"]
```

Trường hợp session chưa từng có `base` (máy mới, DB bị mất): engine so byte của file local với từng ứng viên để chọn `equal` (giống hệt), `publish` (local dài hơn), `install` (local là bản cũ), hoặc `conflict` (không liên quan, sang nhánh fork).

---

## 6. Kịch bản bình thường: 4 máy nối tiếp nhau trên một session

Win-Office chat trước, sau đó chuyển sang WSL-Home viết tiếp, rồi Win-Home viết tiếp. Mỗi lần "viết tiếp" chỉ sinh **một segment mới**; máy mới **tham chiếu** segment của máy trước, không upload lại.

```mermaid
sequenceDiagram
    autonumber
    participant WO as Win-Office
    participant DR as Google Drive
    participant WH as Win-Home
    participant LO as WSL-Office
    participant LH as WSL-Home

    Note over WO: Chat session S, transcript dài thêm
    WO->>DR: Chu kỳ 5 phút: upload segment 0 (t-S-0-...)
    WO->>DR: Cập nhật manifest (head = v1)

    WH->>DR: Chu kỳ: tải manifest Win-Office (md5 đổi)
    WH->>DR: Tải segment 0, kiểm tra sha
    Note over WH: Localize path, ghi file tạm, kiểm tra,<br/>mv vào C--dev-TransFlow, đặt mtime gốc
    LO->>DR: Chu kỳ: tải manifest rồi segment 0
    Note over LO: Cài vào -home-frank-work-TransFlow
    LH->>DR: Chu kỳ: tải manifest rồi segment 0
    Note over LH: Cài vào -home-frank-src-tf-server

    Note over LH: /resume thấy session S, chat tiếp
    LH->>DR: Upload segment 1 (chỉ phần mới), manifest head = v2
    Note over LH: manifest tham chiếu segment 0 của Win-Office,<br/>không upload lại

    WO->>DR: Chu kỳ: thấy v2 là hậu duệ của v1
    WO->>DR: Chỉ tải segment 1
    Note over WO: Nối vào file local rồi cài
    WH->>DR: Tương tự, chỉ tải segment 1
    LO->>DR: Tương tự, chỉ tải segment 1

    Note over WH: Chat tiếp trên S
    WH->>DR: Upload segment 2, manifest head = v3
    Note over WO,LH: Ba máy còn lại tự nhận v3 ở chu kỳ kế tiếp
```

### Version là một chuỗi segment

```mermaid
flowchart LR
    V0["cum0<br/>sha256 của claude-sync + sid"] --> S0["segment 0<br/>chủ: Win-Office"]
    S0 --> V1["cum1 = v1"]
    V1 --> S1["segment 1<br/>chủ: WSL-Home"]
    S1 --> V2["cum2 = v2"]
    V2 --> S2["segment 2<br/>chủ: Win-Home"]
    S2 --> V3["cum3 = v3 = head"]
```

`version_id` = hash cộng dồn của các segment đến đó. Nhờ vậy engine chỉ cần kiểm tra "a có nằm trong chuỗi của b không" để biết một version là tổ tiên hay nhánh khác, mà không phải so cả file.

---

## 7. Xung đột: hai máy cùng viết tiếp một session khi offline

Ví dụ: Win-Office và WSL-Home cùng ở version `v2`, cùng bị mất mạng, cùng chat tiếp session S.

```mermaid
sequenceDiagram
    autonumber
    participant WO as Win-Office
    participant DR as Google Drive
    participant LH as WSL-Home

    Note over WO,LH: Cả hai đang ở v2, mất mạng
    Note over WO: Chat lúc 10:00 (dòng chat đầu sau điểm rẽ)
    Note over LH: Chat lúc 10:05

    WO->>DR: Online lại: công bố v3a (con của v2)
    LH->>DR: Online lại: thấy v3a, local cũng đã đổi, không phải tổ tiên nhau
    Note over LH: Tính nhánh thắng theo quy tắc xác định:<br/>dòng chat đầu sau điểm rẽ có timestamp sớm hơn thắng.<br/>Win-Office 10:00 thắng, WSL-Home thua

    Note over LH: Chỉ máy sở hữu nhánh thua tạo session tách:<br/>fork_sid tính từ sha256 của sid và uuid dòng rẽ,<br/>nên chạy lại không sinh bản trùng
    LH->>LH: Tạo session mới "[conflict WSL-Home] tiêu đề cũ"<br/>chứa phần chung và phần rẽ của nhánh thua
    LH->>LH: Cài nhánh thắng (v3a) vào session S gốc
    LH->>DR: Công bố session tách (fork) và ghi forked vào manifest

    WO->>DR: Chu kỳ sau: nhận session tách như một session mới
    Note over WO,LH: Kết quả: không mất dòng nào.<br/>S giữ ID gốc với nhánh thắng, nhánh thua là session riêng, cả hai mở được
```

Quy tắc chi tiết:

- Điểm rẽ = dòng đầu tiên mà hai nhánh khác nhau.
- Nếu phần rẽ của một nhánh **chỉ toàn metadata** (không có dòng chat) thì nhánh đó thua âm thầm, **không** sinh session tách; bản sao được lưu vào `backups/`. Chỉ **mở lại** một session (hook `SessionStart:resume`, thông báo task nền chưa xong, `cost-state`...) cũng tính là metadata, nên mở xem session ở máy thứ hai không tạo ra `[conflict]`.
- Tiêu đề của session tách lấy theo thứ tự: tên bạn đặt bằng `/rename`, rồi tên Claude tự đặt (`aiTitle`), rồi "(untitled)".
- Bằng nhau về timestamp thì chọn `machine_id` nhỏ hơn. Mọi máy tính ra cùng kết quả, không cần máy nào điều phối.

---

## 8. Session đang mở trên máy nhận

Engine **không bao giờ thay file transcript dưới chân một Claude đang chạy** (đã tái hiện là làm mất dòng).

```mermaid
sequenceDiagram
    autonumber
    participant WO as Win-Office
    participant DR as Google Drive
    participant WH as Win-Home
    participant HK as Hook của Claude trên Win-Home

    WO->>DR: Công bố version mới của session S
    Note over WH: Session S đang mở trên Win-Home<br/>(registry sessions/pid.json còn sống)
    WH->>DR: Chu kỳ: thấy có version mới
    WH->>WH: KHÔNG cài. Ghi status = behind,<br/>cập nhật status.json
    HK->>WH: SessionStart / UserPromptSubmit đọc status.json
    HK-->>WH: Cảnh báo hoặc chặn: "Tab này đang cũ, S có thêm N dòng ở Win-Office"
    Note over WH: Người dùng đóng session
    WH->>DR: Chu kỳ kế tiếp: session không còn mở nên CÀI version mới
    WH->>WH: Xoá cờ behind
```

Ngoài ra `live.json` của mỗi máy cho biết session nào đang mở ở máy đó. Máy khác đọc để hiện "session này đang mở ở Win-Office". Độ mới tính theo giờ server của Drive, không dùng đồng hồ máy.

---

## 9. Vòng đời trạng thái của một session trên một máy

```mermaid
stateDiagram-v2
    [*] --> new: Phát hiện session local hoặc remote
    new --> unmapped: Thư mục chưa map vào project nào
    unmapped --> new: Người dùng map project
    new --> synced: Công bố lần đầu hoặc cài xong
    synced --> synced: Nối thêm, mỗi chu kỳ 5 phút
    synced --> behind: Máy khác có bản mới nhưng session đang mở
    behind --> synced: Session đóng, cài bản mới
    synced --> conflict: Hai nhánh rẽ và chưa xử lý được
    conflict --> synced: Fork xong, nhánh thắng được cài
    synced --> needs_repair: Trùng session id ở thư mục khác
    needs_repair --> synced: claude-sync repair
    synced --> local_absent_retention: File biến mất do Claude dọn theo retention
    synced --> local_absent_user: File biến mất do người dùng xoá
    local_absent_retention --> synced: Có version mới hơn hoặc lệnh restore
    local_absent_user --> synced: Có version mới hơn hoặc lệnh restore
```

---

## 10. Các tình huống đặc biệt

### 10.1 Máy bật lại sau khi tắt lâu (sync bù)

```mermaid
flowchart TD
    A(["Bật Win-Home sau vài ngày"]) --> B["Task Scheduler chạy khi đăng nhập<br/>trigger = logon"]
    B --> C["Chờ mạng với backoff 5s đến 30s"]
    C --> D["Tải manifest của 3 máy còn lại"]
    D --> E["Cài tất cả version mới<br/>(pull trước push)"]
    E --> F{"Mở Claude trước khi<br/>sync bù xong?"}
    F -- "không" --> G(["Mọi session đã có sẵn trong /resume"])
    F -- "có" --> H["Hook SessionStart cảnh báo<br/>hoặc wrapper claude-sync claude kéo trước project đó"]
```

### 10.2 Xoá và retention (không lan truyền)

```mermaid
flowchart LR
    A["Xoá session ở Win-Office<br/>hoặc Claude dọn theo retention"] --> B["Manifest máy khác vẫn giữ session"]
    B --> C["Các máy khác KHÔNG bị xoá theo"]
    A --> D["Trên Win-Office: trạng thái<br/>local_absent_user hoặc local_absent_retention"]
    D --> E["Không tự tải lại,<br/>trừ khi có version mới hơn<br/>hoặc chạy claude-sync restore sid"]
```

Ngược lại, session có `mtime` cũ hơn ngưỡng `cleanupPeriodDays` của máy nhận sẽ **không được cài** (tránh bị Claude dọn ngay); nó vẫn nằm trên Drive và cài được bằng `restore`. Setup đề nghị đặt `cleanupPeriodDays = 3650` trên mọi máy.

### 10.3 Thư mục mới hoặc project chưa map trên một máy

```mermaid
flowchart TD
    A["Win-Office tạo project mới 'Foo'"] --> B["Công bố session kèm project_id trong manifest"]
    B --> C["WSL-Home đọc manifest:<br/>project_id này chưa có trong projects.tsv"]
    C --> D["Ghi vào pending_map.tsv<br/>và gợi ý ứng viên thư mục"]
    D --> E["status, hook SessionStart, wrapper<br/>nhắc người dùng"]
    E --> F["claude-sync projects map<br/>(người dùng xác nhận thư mục)"]
    F --> G["Chu kỳ kế tiếp cài các session đang chờ map"]
```

Gợi ý ứng viên xếp theo độ tin cậy: path tương đương (`D:\a\b` và `/mnt/d/a/b`), thư mục Claude local đã từng chạy, cùng git remote (so mã băm, không upload URL), rồi mới đến tên thư mục gần giống. Không bao giờ tự map, trừ trường hợp chế độ `all` gặp thư mục local hoàn toàn mới.

---

## 11. Tóm tắt các bất biến

| Bất biến | Cơ chế |
|---|---|
| Không mất dòng transcript nào | Segment bất biến; xung đột thì fork, không ghi đè |
| Không hai máy ghi cùng một chỗ | Mỗi máy chỉ ghi `machines/<id>/` của mình |
| Không đè lên session đang mở | Kiểm tra registry trước khi cài và so-và-đổi (compare-and-swap) ngay trước `mv` |
| Cài file an toàn | Ghi file tạm, kiểm số dòng và không có CR, rồi `mv -f` |
| Mỗi session ID đúng một file trên mỗi máy | Kiểm tra trùng trên toàn bộ `projects/*/`; trùng thì `needs_repair` |
| Chạy lại không sinh bản trùng | ID file Drive cấp trước và ghi journal; `fork_sid` tính xác định |
| Resume đúng ở máy khác | Dịch path + đặt vào đúng thư mục slug + giữ `mtime` gốc |

Giới hạn của v1: không hỗ trợ hai máy chat cùng lúc trong cùng một session theo thời gian thực (nếu xảy ra thì kết quả là fork như §7), không mã hoá đầu-cuối, không sync settings/skills/CLAUDE.md.
