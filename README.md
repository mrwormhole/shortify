# zhortify
A lightweight URL shortener service built in Zig using the standard library HTTP server.

## Features

- [X] Shorten URLs with auto-generated Base62 codes
- [X] Custom short codes support
- [X] Click count tracking
- [X] URL validation (http/https only)
- [X] Reserved word protection

## Getting Started

### Prerequisites

- Zig 0.14.1

### Installation

```bash
  git clone https://github.com/mrwormhole/zhortify.git
  cd url-shortener
  zig run main.zig
```

The server will start on `http://localhost:3000`

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Health check |
| `POST` | `/shorten` | Create short URL |
| `GET` | `/:code` | Redirect to original URL |
| `GET` | `/stats/:code` | Get URL statistics |
| `GET` | `/list` | List all URLs |

### POST /shorten

Create a new short URL.

**Request Body:**
```json
{
  "url": "https://example.com",
  "custom_code": "optional-custom-code"
}
```

**Response:**
```json
{
  "short_url": "http://localhost:3000/G8",
  "short_code": "G8"
}
```

**Error Response:**
```json
{
  "error_message": "Invalid URL format"
}
```

### GET /:code

Redirects to the original URL and increments click count.

**Response:** HTTP 301 redirect

### GET /stats/:code

Get statistics for a short URL.

**Response:**
```json
{
  "original_url": "https://example.com",
  "short_code": "G8",
  "click_count": 42,
  "created_at": 1749861651
}
```

### GET /list

List all shortened URLs with statistics.

**Response:**
```json
[
  {
    "original_url": "https://example.com",
    "short_code": "G8",
    "click_count": 42,
    "created_at": 1749861651
  }
]
```

## Testing

Run the included smoke test to verify all functionality:

```bash
  chmod +x smoke.sh
  ./smoke.sh
```

## Configuration

- Length: 3-20 characters
- Allowed characters: letters, numbers, hyphens, underscores
- Reserved words: `api`, `stats`, `admin`, `www`, `app`, `short`, `url`, `list`
- Must start with `http://` or `https://`
- Maximum request body size: 1MB

## Future Improvements

- [ ] Persistent storage (SQLite)
- [ ] Rate limiting
- [ ] URL expiration/TTL
- [ ] Bulk URL operations
- [ ] Docker containerization
- [ ] Configuration file support
- [ ] Full CORS support
