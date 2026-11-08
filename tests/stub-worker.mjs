// Stub Worker for tests. Env: STUB_LOG (jsonl file), STUB_STATUS_FILE (optional file holding
// the status code for POST /note), STUB_QUEUE (optional fixture served at GET /queue).
import http from 'node:http';
import fs from 'node:fs';

const log = process.env.STUB_LOG;
const statusFile = process.env.STUB_STATUS_FILE;
const queueFile = process.env.STUB_QUEUE;
// STUB_EVENTS: JSON array of events; GET /queue?after=N serves seq>N, at most STUB_PAGE (default 100).
const eventsFile = process.env.STUB_EVENTS;
const pageSize = parseInt(process.env.STUB_PAGE || '100', 10);
// STUB_HEALTH_FILE: optional file holding the status code for GET /health (default 200).
const healthFile = process.env.STUB_HEALTH_FILE;

// STUB_REPORT_STATUS_FILE: optional file holding the status code for POST /report (default 204).
const reportStatusFile = process.env.STUB_REPORT_STATUS_FILE;

// STUB_ALERT_STATUS_FILE: optional file holding the status code for POST /alert (default 204).
const alertStatusFile = process.env.STUB_ALERT_STATUS_FILE;

// STUB_QUEUE_CTL: optional JSON file read per request: {"status":401} fails every /queue,
// {"failAfterGte":N} fails /queue?after>=N with 500, {"raw":{...}} serves that body verbatim.
const ctlFile = process.env.STUB_QUEUE_CTL;
function ctl() { try { return ctlFile ? JSON.parse(fs.readFileSync(ctlFile, 'utf8')) : {}; } catch { return {}; } }

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    if (log) {
      fs.appendFileSync(log, JSON.stringify({ method: req.method, path: req.url, headers: req.headers, body }) + '\n');
    }
    if (req.method === 'POST' && req.url === '/note') {
      let status = 204;
      try { if (statusFile) status = parseInt(fs.readFileSync(statusFile, 'utf8').trim(), 10) || 204; } catch {}
      res.writeHead(status);
      res.end();
    } else if (req.method === 'POST' && req.url === '/report') {
      let status = 204;
      try { if (reportStatusFile) status = parseInt(fs.readFileSync(reportStatusFile, 'utf8').trim(), 10) || 204; } catch {}
      res.writeHead(status);
      res.end();
    } else if (req.method === 'POST' && req.url === '/alert') {
      let status = 204;
      try { if (alertStatusFile) status = parseInt(fs.readFileSync(alertStatusFile, 'utf8').trim(), 10) || 204; } catch {}
      res.writeHead(status);
      res.end();
    } else if (req.method === 'GET' && req.url.split('?')[0] === '/queue' && eventsFile) {
      const after = parseInt(new URL(req.url, 'http://x').searchParams.get('after') || '0', 10) || 0;
      const c = ctl();
      if (c.status) { res.writeHead(c.status); res.end(); return; }
      if (c.failAfterGte !== undefined && after >= c.failAfterGte) { res.writeHead(500); res.end(); return; }
      if (c.raw) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(c.raw)); return; }
      const all = JSON.parse(fs.readFileSync(eventsFile, 'utf8')).filter((e) => e.seq > after).sort((a, b) => a.seq - b.seq);
      const events = all.slice(0, pageSize);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ events, next: events.length ? events[events.length - 1].seq : after }));
    } else if (req.method === 'GET' && req.url === '/health') {
      let status = 200;
      try { if (healthFile) status = parseInt(fs.readFileSync(healthFile, 'utf8').trim(), 10) || 200; } catch {}
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end('{"ok":true}');
    } else if (req.method === 'GET' && req.url.split('?')[0] === '/queue' && queueFile) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(fs.readFileSync(queueFile));
    } else {
      res.writeHead(404);
      res.end();
    }
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
