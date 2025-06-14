#!/bin/bash

echo "1. Test the health check:"
curl http://localhost:3000/
echo -e "\n"

echo "2. Shorten a URL:"
curl -X POST http://localhost:3000/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://ziglang.org"}'
echo -e "\n"

echo "3. Shorten a URL with a custom code:"
curl -X POST http://localhost:3000/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://github.com", "custom_code": "github"}'
echo -e "\n"

echo "4. Use a short URL (replace G8 with the actual code you get):"
curl http://localhost:3000/G8
echo -e "\n"

echo "5. Get statistics for a short code:"
curl http://localhost:3000/stats/G8
echo -e "\n"

echo "6. List all URLs:"
curl http://localhost:3000/list
echo -e "\n"