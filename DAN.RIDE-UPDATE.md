# DAN.RIDE — Hướng dẫn cập nhật

DAN.RIDE là bản fork của [macshot](https://github.com/sw33tLie/macshot) (tác giả: sw33tLie) kèm các chỉnh sửa riêng. Khi tác giả ra bản mới, bạn chỉ cần **chạy 1 workflow** rồi **bấm Update trong app**.

## Các link hay dùng

| Việc | Link |
|---|---|
| Chạy build bản mới (nút **Run workflow**) | [Actions → Release DAN.RIDE](https://github.com/ducanhnguyen1120/macshot/actions/workflows/release.yml) |
| Tải DMG / xem các bản đã phát hành | [Releases của fork](https://github.com/ducanhnguyen1120/macshot/releases) |
| Xem tác giả ra bản mới chưa | [Releases của upstream](https://github.com/sw33tLie/macshot/releases) |
| Kho code của fork | [ducanhnguyen1120/macshot](https://github.com/ducanhnguyen1120/macshot) |
| Các secret dùng để ký (không cần động vào) | [Settings → Secrets](https://github.com/ducanhnguyen1120/macshot/settings/secrets/actions) |
| Appcast (feed mà app đọc để biết có bản mới) | [appcast.xml](https://github.com/ducanhnguyen1120/macshot/releases/latest/download/appcast.xml) |

## Quy trình cập nhật (3 bước)

### Bước 1 — Xem upstream có bản mới không (tuỳ chọn)

Mở [Releases của upstream](https://github.com/sw33tLie/macshot/releases). Bản mới nhất ở trên cùng (kể cả beta). So với số phiên bản trong [Releases của fork](https://github.com/ducanhnguyen1120/macshot/releases) (tên dạng `DAN.RIDE 4.4.0-beta.5`). Nếu upstream cao hơn thì cập nhật.

Bạn cũng có thể bỏ qua bước này và chạy workflow luôn: nó tự lấy bản upstream mới nhất.

### Bước 2 — Chạy workflow build

**Cách A — trên web**
1. Mở [Actions → Release DAN.RIDE](https://github.com/ducanhnguyen1120/macshot/actions/workflows/release.yml).
2. Bấm **Run workflow** (góc phải, trên danh sách các lần chạy) → để nguyên nhánh `main` → bấm **Run workflow** màu xanh.
3. Đợi khoảng **4–5 phút** cho tới khi dòng chạy có dấu ✓ xanh.

**Cách B — bằng lệnh trong Terminal**

```bash
gh workflow run release.yml -R ducanhnguyen1120/macshot
```

Xem tiến độ:

```bash
gh run watch -R ducanhnguyen1120/macshot
```

Workflow sẽ tự động:
1. Lấy tag mới nhất của upstream.
2. Ghép các chỉnh sửa của bạn lên bản đó.
3. Build app, ký bằng chứng chỉ cố định `DAN.RIDE Self-Signed`.
4. Đóng DMG, ký Ed25519, tạo `appcast.xml`.
5. Phát hành lên [Releases](https://github.com/ducanhnguyen1120/macshot/releases) với nhãn **Latest**.

### Bước 3 — Cập nhật trong app

1. Bấm biểu tượng DAN.RIDE trên thanh menu.
2. Chọn **Check for Updates…**
3. Bấm **Install Update** → app tự tải, thay bản cũ và mở lại.

App cũng tự kiểm tra bản mới mỗi ngày và sẽ hiện hộp thoại nếu có.

Nếu bấm Check mà báo "up to date" dù bạn vừa chạy workflow: đợi workflow xanh hẳn rồi thử lại. Có thể kiểm tra [appcast.xml](https://github.com/ducanhnguyen1120/macshot/releases/latest/download/appcast.xml): thẻ `sparkle:version` phải lớn hơn bản đang cài.

## Nếu workflow báo đỏ

Mở lần chạy bị đỏ trong [Actions](https://github.com/ducanhnguyen1120/macshot/actions/workflows/release.yml) và xem bước nào lỗi.

### Bước "Sync with upstream" đỏ — xung đột với bản upstream mới

Nghĩa là chỉnh sửa của bạn đụng vào đoạn code mà tác giả vừa đổi. Workflow **không phát hành gì**, bản đang dùng vẫn chạy bình thường.

Cách xử lý: nhắn cho Claude: *"upstream conflict, giải quyết rồi chạy lại workflow"*. Claude sẽ:
1. Lấy tag upstream mới nhất.
2. Rebase các chỉnh sửa của bạn lên đó, giải quyết xung đột (ưu tiên cách làm mới của tác giả cho phần họ đã tự làm).
3. Đặt lại tag `fork-base`, push `main`, chạy lại workflow.

### Bước "Build" đỏ — lỗi biên dịch

Thường do tác giả đổi API mà code của bạn chưa theo kịp. Nhắn Claude kèm link lần chạy bị đỏ.

### Bước "Publish release and appcast" đỏ

Thường do thiếu một trong 3 secret ở [Settings → Secrets](https://github.com/ducanhnguyen1120/macshot/settings/secrets/actions): `SIGNING_CERT_P12_BASE64`, `SIGNING_CERT_PASSWORD`, `SPARKLE_ED_SEED`. Nhắn Claude để kiểm tra, không dán nội dung secret vào chat.

## Quyền Screen Recording / Accessibility

- Mọi bản build đều ký bằng cùng một chứng chỉ nên macOS nhận ra là **cùng một app** và giữ nguyên quyền sau khi update.
- Nếu sau update app vẫn hỏi cấp quyền lại: vào **System Settings → Privacy & Security → Screen & System Audio Recording**, tắt rồi bật lại DAN.RIDE, hoặc dùng nút **Quit & Relaunch** trong màn hình quyền của app. Sau đó báo Claude để kiểm tra phần chữ ký.
- macOS (từ Sequoia) có thể hỏi xác nhận lại quyền Screen Recording theo định kỳ — đây là hành vi của macOS, không phải lỗi của app.

## Cài lần đầu hoặc cài lại từ đầu

1. Mở [Releases của fork](https://github.com/ducanhnguyen1120/macshot/releases), tải `DAN.RIDE.dmg` của bản **Latest**.
2. Mở DMG, kéo `macshot.app` vào Applications.
3. Lần đầu mở: chuột phải vào app → **Open** → **Open** (vì chứng chỉ là tự ký, không phải của Apple).
4. Cấp quyền Screen Recording và Accessibility một lần.

## Quay lại bản cũ

Mỗi lần phát hành là một mục riêng trong [Releases](https://github.com/ducanhnguyen1120/macshot/releases). Muốn dùng lại bản cũ: tải `DAN.RIDE.dmg` của bản đó và cài đè. Lưu ý app có thể đề nghị update lên bản Latest ngay sau đó.

Nhánh `main` cũ (trước lần đồng bộ ngày 02/10/2026) được lưu ở tag `backup-main-20260907`:
[xem tag](https://github.com/ducanhnguyen1120/macshot/releases/tag/backup-main-20260907) · [xem code](https://github.com/ducanhnguyen1120/macshot/tree/backup-main-20260907)

## Khoá bí mật — QUAN TRỌNG

Chứng chỉ ký và khoá Sparkle được lưu trên máy bạn tại:

```
~/.dan-ride-signing/
```

Hãy **sao lưu thư mục này** vào nơi an toàn (không đưa lên GitHub, không gửi cho ai). Nếu mất cả thư mục này và các secret trên GitHub cũng mất, bạn phải tạo khoá mới, và khi đó mọi người dùng bản cũ phải cài tay một lần và cấp quyền lại.

## Cách hệ thống hoạt động (tóm tắt)

- Nhánh `main` của fork = bản upstream tại tag `fork-base` + các commit chỉnh sửa của bạn.
- Mỗi lần chạy workflow: ghép các commit đó lên tag upstream mới nhất **trong lúc build** (chưa ghi lại vào `main`), rồi build và phát hành.
- File workflow: [`.github/workflows/release.yml`](https://github.com/ducanhnguyen1120/macshot/blob/main/.github/workflows/release.yml). Script tạo appcast: [`.github/make_appcast.py`](https://github.com/ducanhnguyen1120/macshot/blob/main/.github/make_appcast.py).
- App kiểm tra bản mới qua [appcast.xml](https://github.com/ducanhnguyen1120/macshot/releases/latest/download/appcast.xml) bằng Sparkle, và chỉ chấp nhận bản được ký đúng bằng khoá Sparkle của bạn.
- Số build của mỗi bản là ngày giờ UTC dạng `YYYYMMDDHHMM`, luôn tăng dần nên Sparkle luôn nhận ra bản mới hơn.
