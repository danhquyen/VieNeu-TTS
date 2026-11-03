"""Hướng dẫn sử dụng API streaming (apps/openai_speech.py), hiển thị trong Web UI.

Địa chỉ API trong ví dụ lấy từ VIENEU_API_PUBLIC_URL (scripts/deploy.sh tự đặt),
mặc định http://<IP-server>:8600. Không bao giờ hiển thị API key thật ở đây.
"""

import os


def api_base_url() -> str:
    return (os.getenv("VIENEU_API_PUBLIC_URL") or "http://<IP-server>:8600").rstrip("/")


def api_docs_markdown() -> str:
    base = api_base_url()
    return f"""
## 📘 Hướng dẫn tích hợp API VieNeu-TTS

API chuẩn **OpenAI** (`POST /v1/audio/speech`), trả âm thanh **streaming** — phát tới đâu nghe tới đó.
Dùng cho hệ thống bên ngoài (HRM, chatbot, tổng đài...): hệ thống tạo câu chữ, gọi API này để lấy giọng nói.

| | |
|---|---|
| **Địa chỉ API** | `{base}` |
| **Xác thực** | Header `Authorization: Bearer <API_KEY>` — key nằm trong `docker/.env` trên server (`VIENEU_API_KEY`) |
| **Swagger (thử trực tiếp)** | [{base}/docs]({base}/docs) — bấm **Try it out**, điền `Bearer <API_KEY>` vào ô `authorization` |
| **Định dạng âm thanh** | `pcm` (s16le mono, không header) hoặc `wav` |
| **Tần số mẫu** | 48000 (gốc) · 24000 · 16000 · 8000 |

> ⚠️ Chỉ gọi API từ **backend**. Không đặt API key trong code chạy trên trình duyệt hay app mobile.

---

### 1. Tạo giọng nói — `POST /v1/audio/speech`

| Trường | Bắt buộc | Mặc định | Mô tả |
|---|---|---|---|
| `input` | ✅ | — | Văn bản cần đọc, tối đa 20 000 ký tự (server tự cắt câu) |
| `voice` | | giọng mặc định | Tên giọng — lấy từ `GET /v1/voices` (vd. `Mai Anh`, `Trúc Ly`) |
| `response_format` | | `wav` | `pcm` hoặc `wav`. `mp3`/`opus`/`aac`/`flac` → lỗi 400 |
| `stream_format` | | `audio` | `audio`: body là bytes (chunked) · `sse`: Server-Sent Events, mỗi event chứa audio base64 |
| `sample_rate` | | 48000 | 48000 · 24000 · 16000 · 8000 |
| `temperature` | | 0.8 | 0–2. Cao = biểu cảm hơn nhưng dễ lỗi |
| `top_k` / `top_p` | | 25 / 0.95 | Tham số sampling |
| `repetition_penalty` | | 1.2 | 1–2 |
| `max_chars` | | 256 | Độ dài tối đa mỗi đoạn văn bản, 64–512 |
| `model`, `speed`, `instructions` | | | Nhận để tương thích OpenAI, **bị bỏ qua** |

Tag cảm xúc (thử nghiệm) chèn thẳng vào `input`: `[cười]`, `[thở dài]`, `[hắng giọng]`.

**Response:** `200`, `Transfer-Encoding: chunked`, header `X-Sample-Rate` và `X-Request-Id`.

**curl** — lưu ra file:
```bash
curl -N {base}/v1/audio/speech \\
  -H "Authorization: Bearer $VIENEU_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{{"input":"Chào bạn, cảm ơn bạn đã tham gia buổi phỏng vấn hôm nay.","voice":"Mai Anh","response_format":"wav"}}' \\
  -o out.wav
```

**Python** (SDK OpenAI):
```python
from openai import OpenAI

client = OpenAI(base_url="{base}/v1", api_key=VIENEU_API_KEY)
with client.audio.speech.with_streaming_response.create(
    model="vieneu-v3-turbo",
    voice="Mai Anh",
    input="Bạn có thể giới thiệu ngắn gọn về bản thân không?",
    response_format="pcm",
    extra_body={{"sample_rate": 24000}},
) as r:
    for chunk in r.iter_bytes(4096):   # PCM s16le mono 24 kHz
        player.write(chunk)
```

**Node.js / TypeScript** (backend, chuyển tiếp stream về trình duyệt):
```ts
const r = await fetch("{base}/v1/audio/speech", {{
  method: "POST",
  headers: {{
    "Content-Type": "application/json",
    Authorization: `Bearer ${{process.env.VIENEU_API_KEY}}`,
  }},
  body: JSON.stringify({{
    input: text,
    voice: "Mai Anh",
    response_format: "pcm",
    sample_rate: 24000,
  }}),
}});
if (!r.ok) throw new Error(`TTS ${{r.status}}: ${{await r.text()}}`);
for await (const chunk of r.body) ws.send(chunk);   // gửi PCM về client qua WebSocket
```

**Phát PCM trên trình duyệt** (nhận các chunk Int16 từ backend):
```js
const ctx = new AudioContext({{ sampleRate: 24000 }});
let playAt = 0;
function playPcm(arrayBuffer) {{
  const pcm = new Int16Array(arrayBuffer);
  const buf = ctx.createBuffer(1, pcm.length, 24000);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 32768;
  const src = ctx.createBufferSource();
  src.buffer = buf;
  src.connect(ctx.destination);
  playAt = Math.max(playAt, ctx.currentTime);
  src.start(playAt);
  playAt += buf.duration;           // xếp các chunk nối tiếp, không bị vấp
}}
ws.onmessage = (e) => playPcm(e.data);   // ws.binaryType = "arraybuffer"
```

**SSE** (`"stream_format": "sse"`) — mỗi event một dòng `data:`:
```
data: {{"type":"speech.audio.delta","audio":"<base64 PCM>"}}
data: {{"type":"speech.audio.done","usage":{{"output_samples":222720,"sample_rate":48000,"seconds":4.64}}}}
```

---

### 2. Các endpoint khác

| Endpoint | Mô tả |
|---|---|
| `GET /v1/voices` | Danh sách giọng có sẵn (`id`, `name`, `description`, `gender`) |
| `POST /v1/voices` | Tạo giọng mới từ clip mẫu 3–8 giây (multipart: `name`, `file`, `denoise`). Giọng chỉ lưu trong bộ nhớ — restart server phải đăng ký lại |
| `GET /v1/models` | Thông tin model, backend, số luồng tối đa |
| `GET /health` | Trạng thái: `active` (đang phát), `waiting` (đang chờ). Không cần key |

```bash
curl -H "Authorization: Bearer $VIENEU_API_KEY" {base}/v1/voices

curl -H "Authorization: Bearer $VIENEU_API_KEY" {base}/v1/voices \\
  -F name="Người phỏng vấn" -F file=@mau_giong.wav -F denoise=true
```

---

### 3. Mã lỗi

Lỗi trả về theo dạng OpenAI: `{{"error": {{"message": "...", "type": "...", "code": ...}}}}`

| Mã | Nguyên nhân | Xử lý |
|---|---|---|
| `400` | Tham số sai (định dạng không hỗ trợ, giá trị ngoài khoảng) | Sửa request |
| `401` | Thiếu hoặc sai API key | Kiểm tra header `Authorization` |
| `409` | `POST /v1/voices` trùng tên giọng có sẵn | Đổi tên |
| `429` | Hết luồng xử lý, chờ quá lâu trong hàng đợi | Thử lại sau `Retry-After` giây |
| `503` | Engine streaming lỗi | Container sẽ tự khởi động lại |

---

### 4. Mẹo cho hội thoại thời gian thực (vd. phỏng vấn với LLM)

- **Gửi từng câu**, đừng chờ LLM viết xong cả đoạn: stream chữ từ LLM, cắt ở `.` `?` `!` rồi gọi API cho từng câu → người nghe nghe câu đầu sau ~0,1–0,3 s.
- Dùng `response_format: "pcm"` + `sample_rate: 24000` để giảm dung lượng truyền và dễ phát bằng Web Audio.
- Dùng **cùng một giọng** (`voice`) cho cả buổi để giọng nhất quán.
- Nhiều phiên cùng lúc: GPU phục vụ tới 16 luồng đồng thời (chỉnh `VIENEU_MAX_STREAMS` trong `docker/.env`). Vượt quá sẽ bị xếp hàng rồi `429`.
"""
