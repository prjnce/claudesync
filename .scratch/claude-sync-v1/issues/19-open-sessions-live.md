# 19 — Session đang mở và live.json

Status: done (thiếu test M5)
Đề xuất: ready-for-agent
Type: task
Mốc: M4
Blocked by: 17, 24
Spec: SPEC §9.3, §12.4, §12.7 bước 6–7

## Phạm vi

- Session đang mở trên máy này (registry + PID + `procStart` khớp): **không cài**; `status=behind`; ghi `behind[sid]{machine,lines,since}` vào `status.json` (#24) để hook đọc.
- Công bố khi đang mở: chỉ bản chụp nối thêm (B là prefix); throttle 1 lần / `throttle_live_min` (mặc định 15); đẩy ngay khi session đóng.
- Bản chụp ngắn đi khi đang mở: hoãn đến khi session đóng **và** 2 lần đọc cách 2 s cùng size + hash.
- Máy nhận chỉ chấp nhận bản viết lại khi số uuid dòng chat bị xoá ≤ 3, hoặc là relocate / gộp chuỗi có `from` hợp lệ; ngược lại xử lý như rẽ nhánh.
- Kiểm tra lại registry ngay trước và ngay sau `mv` (so-và-đổi); session vừa mở sau điểm chốt → gắn `behind`.
- `live.json` `{"sessions":[…]}`: ghi mỗi chu kỳ khi có session mở, xoá khi không còn. Độ mới theo `modifiedTime` của Drive so với header `Date` của response; cũ hơn 3 × interval của máy đó thì bỏ qua. Xuất `live_elsewhere[sid]` vào status.

## Tiêu chí nghiệm thu

- [ ] Session mở nhiều ngày trên B trong khi A viết tiếp → B không cài, đánh dấu behind; đóng trên B → chu kỳ sau cài (**H3**).
- [ ] Claude ghi lại cả file không atomic (truncate rồi ghi) giữa lúc chụp → không công bố bản cụt (**H4**).
- [ ] Người dùng `/resume` đúng lúc engine đang localize file lớn → huỷ cài, không mất dòng (**M5**).
- [ ] Session 58 MB mở cả ngày → mỗi lần công bố chỉ upload phần đuôi (**M8**).
- [ ] Máy C chết khi đang mở S; đồng hồ máy lệch → `live.json` cũ bị bỏ qua đúng hạn (**F8**).

## Comments

- 2026-10-07: làm `behind` (DB + status.json), throttle `throttle_live_min`, hoãn viết lại khi đang mở + đọc ổn định 2 lần (`CS_STABLE_WAIT`), kiểm tra registry sau `mv` → behind, `live.json` ghi/xoá (trash) và đọc theo độ mới của server (`live_elsewhere`). Test `test/live.bats`: H3, throttle, M8, H4, F8. Chưa có test riêng cho M5 (huỷ cài khi `/resume` đúng lúc localize): so-và-đổi trước `mv` đã có từ #17 nhưng cần hook test để chèn registry giữa chừng.
