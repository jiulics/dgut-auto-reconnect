"""Offline OCR bridge: accepts captcha pixels, never credentials or URLs."""
import base64
import io
import json
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime
from pathlib import Path
import re
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

ROOT = Path(__file__).resolve().parent
PORT = 18761

class AttemptBudget:
    def __init__(self): self.reset()
    def reset(self): self.times = []
    def claim(self, now):
        self.times = [t for t in self.times if now - t < 900]
        if len(self.times) >= 3: return False
        delay = 30 * 2 ** max(0, len(self.times) - 1)
        if self.times and now - self.times[-1] < delay: return False
        self.times.append(now)
        return True

def validate_code(text):
    if not isinstance(text, str) or not re.fullmatch(r'[0-9]{4}', text):
        raise ValueError('not_four_digits')
    return text

def decode_image(value):
    if not isinstance(value, str) or len(value) > 262144 or not value.startswith('data:image/png;base64,'):
        raise ValueError('invalid_image')
    try:
        raw = base64.b64decode(value.split(',', 1)[1], validate=True)
        from PIL import Image
        with Image.open(io.BytesIO(raw)) as img:
            if img.format != 'PNG' or not (1 <= img.width <= 1024 and 1 <= img.height <= 512):
                raise ValueError('image_size')
            img.verify()
        return raw
    except Exception as exc: raise ValueError('invalid_image') from exc

def online_state():
    try:
        state = json.loads((ROOT / 'guardian-status.json').read_text(encoding='utf-8-sig'))
        age = time.time() - datetime.fromisoformat(state['Updated']).timestamp()
        return state['Online'] if 0 <= age <= 60 and isinstance(state['Online'], bool) else None
    except (OSError, ValueError, KeyError): return None

def write_json(name, value):
    path = ROOT / name
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value), encoding='utf-8')
    temp.replace(path)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def setup(self):
        super().setup()
        self.connection.settimeout(5)
    def reply(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def trusted(self):
        return (self.headers.get('Host') == f'127.0.0.1:{PORT}'
                and self.headers.get('X-DGUT-Client') == 'local-v2'
                and self.headers.get('Origin') in (None, 'http://login.dgut.edu.cn', 'https://login.dgut.edu.cn', 'http://172.31.252.91:8080'))
    def do_GET(self):
        if not self.trusted(): return self.reply(403, {'error':'forbidden'})
        if self.path != '/health': return self.reply(404, {'error':'not_found'})
        self.reply(200, {'ready':True, 'offline_ocr':True, 'version':2})
    def do_POST(self):
        if not self.trusted(): return self.reply(403, {'error':'forbidden'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 270000 or self.headers.get_content_type() != 'application/json':
                return self.reply(400, {'error':'invalid_request'})
            data = json.loads(self.rfile.read(size))
            if not isinstance(data, dict): raise ValueError('invalid_request')
            now = time.time()
            online = online_state()
            if online is True: self.server.budget.reset()
            if self.path == '/state':
                write_json('portal-lease.json', {'Until':now + 60})
                return self.reply(200, {'online':online})
            if self.path == '/attempt':
                allowed = online is False and self.server.budget.claim(now)
                if allowed: logging.info('attempt_reserved')
                return self.reply(200, {'allowed':allowed, 'online':online})
            if self.path == '/event':
                event = data.get('event')
                if event not in {'submitted','ocr_failed','stale_image','legacy_conflict','paused'}: raise ValueError('invalid_event')
                logging.info(event)
                return self.reply(200, {'ok':True})
            if self.path == '/ocr':
                if now - self.server.last_ocr < 2: return self.reply(429, {'error':'rate_limit'})
                self.server.last_ocr = now
                code = validate_code(self.server.ocr.classification(decode_image(data.get('image'))))
                logging.info('ocr_recognized_four_digits')
                return self.reply(200, {'code':code})
            self.reply(404, {'error':'not_found'})
        except (ValueError, OSError, TimeoutError): self.reply(400, {'error':'invalid_input_or_recognition'})
        except Exception:
            logging.error('request_failed')
            self.reply(500, {'error':'local_service_error'})

def main():
    handler = RotatingFileHandler(ROOT / 'ocr.log', maxBytes=1048576, backupCount=1, encoding='utf-8')
    logging.basicConfig(level=logging.INFO, handlers=[handler], format='%(asctime)s %(message)s')
    try: server = HTTPServer(('127.0.0.1', PORT), Handler)
    except OSError:
        logging.error('port_in_use_service_not_started')
        return
    try:
        import ddddocr
        server.ocr = ddddocr.DdddOcr(show_ad=False)
        server.budget = AttemptBudget()
        server.last_ocr = 0
        server.timeout = 1
        logging.info('offline_ocr_ready_loopback_only')
        while not (ROOT / 'guardian.stop').exists(): server.handle_request()
    finally:
        server.server_close()
        logging.info('offline_ocr_stopped')

if __name__ == '__main__': main()
