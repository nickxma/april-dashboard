const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 3001;
const DATA_DIR = path.join(__dirname, 'live');

http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }
  
  const filePath = path.join(DATA_DIR, req.url.replace(/\?.*/, ''));
  if (!filePath.startsWith(DATA_DIR)) { res.writeHead(403); res.end(); return; }
  
  fs.readFile(filePath, 'utf8', (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    res.setHeader('Content-Type', 'application/json');
    res.writeHead(200);
    res.end(data);
  });
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Dashboard data server on http://127.0.0.1:${PORT}`);
});
