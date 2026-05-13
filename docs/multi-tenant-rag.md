# Multi-Tenant RAG Pipeline

Bu kurulumda dosya, vektör ve chat ilişkisi tek bir ortak havuz gibi değil, açık scope kurallarıyla çalışır. Her istek `tenant_id`, `user_id` ve `chat_id` ile gelir; retrieval sadece bu chat'in erişebildiği chunk'ları arar.

## Veri Modeli

Hiyerarşi:

```text
tenant
  group
    chat
  user
    chat
```

Dosya scope'ları:

| Scope | Ne zaman kullanılır? | Chat retrieval davranışı |
| --- | --- | --- |
| `tenant` | Şirket geneli politika, ürün dokümanı, herkesin görmesi gereken bilgi | Tenant içindeki erişilebilir tüm chat'lerde aranır |
| `group` | Proje/ekip dokümanı | Sadece o group'a bağlı chat'lerde aranır |
| `user` | Kullanıcının kişisel yüklediği dosya | Sadece kullanıcının private chat'lerinde aranır |
| `chat` | Belirli chat'e eklenen dosya | Sadece o chat'te aranır |

Bu ayrım sayesinde "her dosya her chat'e eklenmesin" kuralı varsayılan davranış olur. Bir dosya başka bir chat'te kullanılacaksa ayrıca `chat` scope'a attach edilir.

## Pipeline

1. **Auth context çıkar**: API gateway veya n8n webhook JWT/session'dan `tenant_id` ve `user_id` üretir.
2. **Chat context doğrula**: `chat_id` bu tenant'a ait mi, kullanıcı owner mı veya group üyesi mi kontrol edilir.
3. **Dosya yükle**: Dosya `documents` tablosuna yazılır ve tek bir başlangıç scope'u verilir: `tenant`, `group`, `user` veya `chat`.
4. **Ingestion job oluştur**: `ingestion_jobs` satırı `queued` açılır.
5. **Parse/OCR**: Docling dosyayı metne ve opsiyonel görsellere ayırır.
6. **Chunk + embed**: Metin chunk'lara bölünür, embedding üretilir ve `document_chunks` tablosuna yazılır.
7. **Ready işaretle**: `documents.status = 'ready'`, job `completed` olur.
8. **Chat message geldiğinde retrieval yap**: Soru embedding'e çevrilir ve sadece filtreli arama çağrılır:

```sql
SELECT *
FROM rag.match_chunks(
  :tenant_id,
  :user_id,
  :chat_id,
  :query_embedding,
  8,
  0.2
);
```

9. **LLM cevabı üret**: Dönen chunk'lar kaynak metadata'sı ile prompt'a eklenir.
10. **Mesajları sakla**: Kullanıcı ve asistan mesajları `chat_messages` tablosuna yazılır.

## Endpoint Önerisi

Tüm endpoint'ler auth sonrası tenant context ile çalışmalı. Client'tan gelen `tenant_id` güven kaynağı olmamalı; token veya API key üzerinden resolve edilmeli.

### Tenant ve Kullanıcı

```http
POST /v1/tenants
POST /v1/tenants/{tenantId}/users
GET  /v1/me
```

### Group

```http
POST   /v1/groups
GET    /v1/groups
PATCH  /v1/groups/{groupId}
PUT    /v1/groups/{groupId}/members/{userId}
DELETE /v1/groups/{groupId}/members/{userId}
```

### Chat

```http
POST /v1/chats
GET  /v1/chats
GET  /v1/chats/{chatId}
POST /v1/chats/{chatId}/messages
GET  /v1/chats/{chatId}/messages
```

`POST /v1/chats` gövdesi:

```json
{
  "title": "Q2 proje notları",
  "group_id": "uuid veya null"
}
```

`group_id = null` ise private user chat, doluysa group chat kabul edilir.

### Dosya

```http
POST   /v1/files
GET    /v1/files
GET    /v1/files/{fileId}
DELETE /v1/files/{fileId}
POST   /v1/chats/{chatId}/files/{fileId}
DELETE /v1/chats/{chatId}/files/{fileId}
```

`POST /v1/files` multipart alanları:

```json
{
  "scope": {
    "type": "tenant | group | user | chat",
    "id": "tenant_id | group_id | user_id | chat_id"
  }
}
```

Örnekler:

```json
{ "scope": { "type": "group", "id": "project-group-uuid" } }
```

```json
{ "scope": { "type": "chat", "id": "chat-uuid" } }
```

### Retrieval İç Servis

Bu endpoint public olmamalı; chat endpoint'i veya n8n workflow'u çağırmalı.

```http
POST /internal/retrieval/search
```

Gövde:

```json
{
  "tenant_id": "uuid",
  "user_id": "uuid",
  "chat_id": "uuid",
  "query": "Soru metni",
  "top_k": 8
}
```

Servis akışı:

1. `query` için embedding üret.
2. `rag.match_chunks(...)` çağır.
3. Chunk içeriklerini ve kaynakları LLM prompt'una taşı.

## Qdrant Kullanılacaksa

PostgreSQL şeması metadata ve yetki kaynağı olarak kalabilir. Qdrant'ta her point payload'unda şu alanlar zorunlu olmalı:

```json
{
  "tenant_id": "uuid",
  "document_id": "uuid",
  "scope_type": "tenant | group | user | chat",
  "scope_id": "uuid",
  "chat_id": "uuid veya null",
  "group_id": "uuid veya null",
  "user_id": "uuid veya null"
}
```

Yine de önerilen güvenli yol, önce PostgreSQL'den `rag.allowed_document_ids(tenant_id, user_id, chat_id)` ile erişilebilir dokümanları bulup Qdrant aramasını `document_id in (...)` filtresiyle yapmaktır.

## Mevcut Volume İçin Migration

`/docker-entrypoint-initdb.d` altındaki SQL sadece yeni PostgreSQL volume ilk kez oluşurken otomatik çalışır. Var olan DB için aynı şemayı elle uygulayın:

```bash
docker compose exec postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/001_multi_tenant_rag.sql'
```

Yeni kurulumda `postgres_storage` boşsa compose açılışında otomatik uygulanır.
