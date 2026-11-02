"""Synthetic protocol peer only; no cloud, email provider, database or production credentials."""
import base64
import datetime
import hashlib
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORKSPACE = '00000000-0000-0000-0000-000000000001'
BOOK = '00000000-0000-0000-0000-000000000002'
REPLICA = '00000000-0000-0000-0000-000000000003'
OWNER = 'server-owner'
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
STATE = {'mode': 'normal', 'paths': [], 'refreshes': 0, 'leaks': 0, 'chunks': {}, 'upload': None}
KINDS = 'notebookSettings entry sense source occurrence interpretation collection selectedInterpretation senseExplanation interpretationExplanation contentBlock reviewDraft reviewTemplate meaningNode meaningLabel meaningRole usagePattern patternSlot meaningMapping roleBinding mappingEvidence meaningRelation retrievalCue cueTarget classificationFramework category categoryParent categoryMembership categoryOverride'.split()
sha = lambda b: hashlib.sha256(b).hexdigest()
enc = lambda x: json.dumps(x, sort_keys=True, separators=(',', ':')).encode()
b64 = lambda b: base64.b64encode(b).decode()
owner64 = base64.urlsafe_b64encode(OWNER.encode()).decode().rstrip('=')

def window(body):
    data = b'[]'
    window_id = str(uuid.uuid4())
    expires = int(time.time() * 1000) + 600000
    mode = body['mode']
    after = body['afterSequence']
    pages_sha = sha(f'0:{sha(data)}:{len(data)}\n'.encode())
    lines = ['lingrove-corpus-window:1', WORKSPACE, BOOK, REPLICA, window_id, owner64, mode,
             after if after is not None else '-', '1', '1', str(expires), '0', '1', str(len(data)), pages_sha, '']
    return {'protocolVersion': 1, 'ownerUserId': OWNER, 'workspaceId': WORKSPACE,
            'notebookId': BOOK, 'replicaId': REPLICA, 'windowId': window_id, 'mode': mode,
            'afterSequence': after, 'highWaterSequence': '1', 'initialized': True,
            'expiresAtMilliseconds': expires, 'recordCount': 0, 'pageCount': 1,
            'byteCount': len(data), 'pagesSha256': pages_sha, 'manifestSha256': sha('\n'.join(lines).encode())}

def progress(state='open', retired=False):
    u = STATE['upload']
    now = datetime.datetime.now(datetime.timezone.utc)
    fmt = lambda x: x.isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    return {'protocolVersion': 1, 'workspaceId': WORKSPACE, 'notebookId': BOOK, 'replicaId': REPLICA,
            'groupId': u['groupId'], 'bodySha256': u['bodySha256'], 'descriptorSha256': u['descriptorSha256'],
            'byteCount': u['byteCount'], 'memberCount': u['memberCount'], 'chunkBytes': 262144,
            'chunkCount': (u['byteCount'] - 1) // 262144 + 1, 'state': state,
            'receivedOrdinals': sorted(STATE['chunks']) if state == 'open' else [], 'payloadRetired': retired,
            'createdAt': fmt(now), 'expiresAt': fmt(now + datetime.timedelta(seconds=900))}

def confirmation():
    u = STATE['upload']
    body = b''.join(STATE['chunks'][i] for i in sorted(STATE['chunks']))
    assert sha(body) == u['bodySha256']
    parsed = json.loads(body)
    ids = [m['memberId'].lower() for m in parsed['members']]
    members = ''.join(x + '\n' for x in ids).encode()
    pages_sha = sha(('lingrove-corpus-confirmation-pages:1\n' + f'0:{sha(members)}:{len(members)}\n').encode())
    fields = ['lingrove-corpus-confirmation:1', WORKSPACE, owner64, BOOK, REPLICA, u['groupId'], u['descriptorSha256'],
              u['bodySha256'], str(u['byteCount']), sha(body), sha(members), pages_sha, str(len(ids)),
              'committed', '1', '-', '4096', '1', '']
    manifest = {'protocolVersion': 1, 'workspaceId': WORKSPACE, 'ownerUserId': OWNER, 'notebookId': BOOK,
                'replicaId': REPLICA, 'groupId': u['groupId'], 'descriptorSha256': u['descriptorSha256'],
                'bodySha256': u['bodySha256'], 'bodyByteCount': u['byteCount'], 'canonicalSha256': sha(body),
                'memberIdsSha256': sha(members), 'pagesSha256': pages_sha, 'memberCount': len(ids),
                'pageCount': 1, 'membersPerPage': 4096, 'status': 'committed', 'committedSequence': '1',
                'rejectionReason': None, 'manifestSha256': sha('\n'.join(fields).encode())}
    page = {'groupId': u['groupId'], 'manifestSha256': manifest['manifestSha256'], 'ordinal': 0,
            'firstMemberOrdinal': 0, 'memberCount': len(ids), 'encoding': 'base64', 'data': b64(members),
            'byteCount': len(members), 'sha256': sha(members)}
    return manifest, page

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def reply(self, obj, status=200, content_type='application/json', headers=None):
        data = obj if isinstance(obj, bytes) else enc(obj)
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def handle_request(self):
        path = urlparse(self.path).path
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        body = json.loads(raw) if raw and self.headers.get('Content-Type') != 'image/png' else {}
        if path == '/test/config':
            STATE.update(body)
            self.reply({'ok': True}); return
        if path == '/test/stats':
            self.reply({k: STATE[k] for k in ['paths', 'refreshes', 'leaks']}); return
        STATE['paths'].append(path)
        if path == '/test/leak':
            STATE['leaks'] += 1; self.reply({'ok': True}); return
        mode = STATE['mode']
        if path == '/test/non-200-success':
            self.reply(b'x' * 16384, 206)
            return
        if path == '/auth/api/send-code':
            email = body['email']
            if email.startswith('redirect'):
                self.reply({}, 307, headers={'Location': '/test/leak'}); return
            if email.startswith('oversized'):
                self.reply(b'x' * (600 * 1024)); return
            if email.startswith('streamed'):
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                try: self.wfile.write(b'x' * (600 * 1024))
                except (BrokenPipeError, ConnectionResetError): pass
                return
            token = base64.urlsafe_b64encode(enc({'t': int(time.time() * 1000)})).decode().rstrip('=') + '.synthetic'
            self.reply({'ok': True, 'csrfToken': 'synthetic-csrf', 'otpSessionToken': token}); return
        if path == '/auth/api/verify-code':
            assert body['csrfToken'] == 'synthetic-csrf' and body['otpSessionToken']
            if body['code'] != '12345678': self.reply({'code': 'OTP_CODE_INVALID'}, 400); return
            self.reply({'ok': True, 'idToken': 'subject-is-not-owner', 'refreshToken': 'synthetic-refresh', 'expiresIn': 3600}); return
        if path == '/auth/api/refresh-token':
            STATE['refreshes'] += 1
            if mode == 'delay-refresh': time.sleep(0.4)
            self.reply({'ok': True, 'idToken': 'rotated-id', 'refreshToken': 'rotated-refresh', 'expiresIn': 3600}); return
        if path == '/api/me':
            if mode == 'me-unavailable': self.reply({'code': 'UNAVAILABLE'}, 503); return
            if mode == 'delay-me': time.sleep(0.4)
            self.reply({'userId': OWNER, 'canonicalAccountId': 'canonical-owner', 'profile': {'email': 'synthetic@example.invalid'}}); return
        if '/notebook/' not in path: self.reply({'code': 'UNKNOWN'}, 404); return
        assert self.headers.get('Authorization') == 'Bearer synthetic-id'
        endpoint = path.split('/notebook/')[1]
        if endpoint == 'capabilities':
            if mode == 'delay-caps': time.sleep(0.4)
            if mode == 'caps-unavailable': self.reply({'code': 'NOTEBOOK_SYNC_UNAVAILABLE'}, 503); return
            self.reply({'lane': 'lingrove.corpus', 'protocolVersion': 1, 'documentVersion': 8,
                'terminalGroups': True, 'readWindows': True, 'readOnlyCatalog': True, 'maximumGroupBytes': 2097152,
                'maximumGroupMembers': 10000, 'pageBytes': 262144, 'windowLifetimeMilliseconds': 600000,
                'entityTypes': KINDS, 'stagedUploads': {'protocolVersion': 1, 'permanentClosures': True,
                 'pagedConfirmations': True, 'chunkBytes': 262144, 'confirmationMembersPerPage': 4096,
                 'lifetimeMilliseconds': 900000, 'maximumBodyBytes': 201326592, 'maximumMembers': 1000000}}); return
        if endpoint == 'connect':
            assert body['protocolVersion'] == 1 and body['isAutomation'] is True and body['isTestDistribution'] is True
            self.reply({'protocolVersion': 1, 'ownerUserId': OWNER, 'workspaceId': WORKSPACE,
                'notebookId': BOOK, 'replicaId': REPLICA, 'committedSequence': '1'}); return
        if endpoint in ('groups/apply', 'groups/cancel'):
            ids = [m['memberId'] for m in body['members']]
            if mode == 'bad-ack': ids.append(str(uuid.uuid4()))
            value = {'protocolVersion': 1, 'notebookId': body['notebookId'], 'groupId': body['groupId'], 'memberIds': ids}
            if endpoint.endswith('cancel'):
                value['reason'] = 'cancelled'; self.reply({'status': 'rejected', 'rejection': value})
            else:
                value['committedSequence'] = '1'; self.reply({'status': 'committed', 'receipt': value})
            return
        if endpoint == 'windows/open': self.reply(window(body)); return
        if endpoint == 'windows/page':
            data = b'[]'
            self.reply({'windowId': body['windowId'], 'ordinal': body['ordinal'], 'encoding': 'base64',
                        'data': b64(data), 'sha256': sha(data), 'byteCount': len(data)}); return
        if endpoint == 'windows/release': self.reply({'released': True}); return
        if endpoint == 'uploads/status':
            if STATE['upload'] is None: self.reply({'code': 'NOTEBOOK_UPLOAD_NOT_FOUND'}, 404)
            else: self.reply(progress('aborted' if mode == 'staged-aborted' else 'open', mode == 'staged-aborted'))
            return
        if endpoint == 'uploads/open':
            u = dict(body)
            lines = ['lingrove-corpus-upload-v1', WORKSPACE, BOOK, REPLICA, u['groupId'], owner64, '1', u['bodySha256'],
                     str(u['byteCount']), str(u['memberCount']), '262144', str((u['byteCount']-1)//262144+1), 'base64', '']
            u['descriptorSha256'] = sha('\n'.join(lines).encode()); STATE['upload'] = u; self.reply(progress()); return
        if endpoint == 'uploads/chunk':
            data = base64.b64decode(body['data']); assert sha(data) == body['sha256']; STATE['chunks'][body['ordinal']] = data
            self.reply(progress()); return
        if endpoint in ('uploads/finalize', 'uploads/confirmation'):
            self.reply(confirmation()[0]); return
        if endpoint == 'uploads/confirmation-page': self.reply(confirmation()[1]); return
        if endpoint == 'uploads/abort': self.reply(progress('aborted', True)); return
        if endpoint == 'review/sync':
            if mode == 'review-fails': self.reply({'code': 'NOTEBOOK_REVIEW_UNAVAILABLE'}, 503); return
            if mode == 'review-401': self.reply({'code': 'UNAUTHORIZED'}, 401); return
            assert body['protocolVersion'] == 1 and body['notebookId'] == BOOK and body['replicaId'] == REPLICA
            assert body['installationId'] and body['sourceSequence'] == '1'
            self.reply({'protocolVersion': 1, 'notebookId': BOOK, 'replicaId': REPLICA,
                        'acknowledged': [], 'confirmed': [x['cardId'] for x in body['confirmations']], 'afterSequence': 7,
                        'hasMore': False, 'changes': []}); return
        if endpoint.startswith('media/'):
            action = endpoint.split('/')[1]
            if action == 'capabilities':
                if mode == 'media-probe-fails': self.reply({'code': 'NOTEBOOK_MEDIA_UNAVAILABLE'}, 503); return
                self.reply({'protocolVersion': 1, 'mimeType': 'image/png', 'maximumBytes': 4194304, 'maximumDimension': 1600}); return
            if action == 'release': self.reply({'released': True}); return
            if action == 'bytes' and self.command == 'GET': self.reply(PNG, content_type='image/png'); return
            query = {k: v[0] for k,v in parse_qs(urlparse(self.path).query).items()}
            image = body.get('image') if raw and self.headers.get('Content-Type') != 'image/png' else {
                'digest': query['digest'], 'width': int(query['width']), 'height': int(query['height']), 'byteCount': int(query['byteCount'])}
            if self.command == 'PUT': assert sha(raw) == image['digest']
            self.reply({'protocolVersion': 1, 'notebookId': BOOK, 'replicaId': REPLICA, 'image': image,
                        'ownerUserId': OWNER, 'workspaceId': WORKSPACE,
                        'mediaAssetId': '00000000-0000-0000-0000-000000000004', 'state': 'ready'}); return
        self.reply({'code': 'UNKNOWN'}, 404)
    do_GET = do_POST = do_PUT = handle_request

for port in range(19180, 19183):
    try: server = ThreadingHTTPServer(('127.0.0.1', port), Handler); break
    except OSError: continue
else: raise RuntimeError('B-owned loopback range is busy; refusing to disturb another process')
print(server.server_port, flush=True)
server.serve_forever()
