"""D-owned synthetic HTTP peer. No production accounts, mail, PG or object store are contacted.

The small record ledger supports the real canonical corpus window/ACK codec so native tests use
actual SQLite ports rather than a recording storage stub. It is deliberately not a backend clone.
"""
import base64
import hashlib
import json
import socket
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

KINDS = 'notebookSettings entry sense source occurrence interpretation collection selectedInterpretation senseExplanation interpretationExplanation contentBlock reviewDraft reviewTemplate meaningNode meaningLabel meaningRole usagePattern patternSlot meaningMapping roleBinding mappingEvidence meaningRelation retrievalCue cueTarget classificationFramework category categoryParent categoryMembership categoryOverride'.split()
WORKSPACES = {'a': '10000000-0000-0000-0000-000000000001', 'b': '20000000-0000-0000-0000-000000000001'}
OTHER_WORKSPACE = '10000000-0000-0000-0000-000000000010'
BOOKS = {'a': '10000000-0000-0000-0000-000000000002', 'b': '20000000-0000-0000-0000-000000000002'}
REPLICAS = {'a': '10000000-0000-0000-0000-000000000003', 'b': '20000000-0000-0000-0000-000000000003'}
STATE = {'mode': 'normal', 'bootstrapInstallations': {}, 'paths': [], 'checks': [], 'refreshes': 0, 'windows': {},
         'a': {'records': {}, 'sequence': 0, 'groups': {}, 'images': {}},
         'b': {'records': {}, 'sequence': 0, 'groups': {}, 'images': {}}}
enc = lambda x: json.dumps(x, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
sha = lambda x: hashlib.sha256(x).hexdigest()
b64 = lambda x: base64.b64encode(x).decode()


def settings():
    updated = STATE['mode'] == 'scheduler-updated'
    return {'algorithm': 'fsrs-6', 'desiredRetention': 0.93 if updated else 0.87, 'learningStepsMinutes': [2, 12],
            'relearningStepsMinutes': [8], 'maximumIntervalDays': 18000, 'enableFuzz': False,
            'clientUpdatedAt': '2028-01-01T00:00:00.000Z' if updated else '2025-01-01T00:00:00.000Z', 'lastModifiedByReplicaId': 'server-replica',
            'lastOperationId': 'server-custom-settings', 'updatedAt': '2025-01-01T00:00:00.000Z'}


def window(account, body):
    ledger = STATE[account]
    records = [r for _, r in sorted(ledger['records'].items())
               if body['afterSequence'] is None or int(r['version']) > int(body['afterSequence'])]
    data = enc(records)
    ident = str(uuid.uuid4())
    expiry = int(time.time() * 1000) + 600000
    pages_sha = sha(f'0:{sha(data)}:{len(data)}\n'.encode())
    high = str(ledger['sequence'])
    owner = 'business-owner-' + account
    owner64 = base64.urlsafe_b64encode(owner.encode()).decode().rstrip('=')
    fields = ['lingrove-corpus-window:1', WORKSPACES[account], BOOKS[account], REPLICAS[account], ident,
              owner64, body['mode'], body['afterSequence'] if body['afterSequence'] is not None else '-',
              high, '1' if ledger['sequence'] else '0', str(expiry), str(len(records)), '1', str(len(data)), pages_sha, '']
    STATE['windows'][ident] = data
    return {'protocolVersion': 1, 'ownerUserId': owner, 'workspaceId': WORKSPACES[account],
            'notebookId': BOOKS[account], 'replicaId': REPLICAS[account], 'windowId': ident, 'mode': body['mode'],
            'afterSequence': body['afterSequence'], 'highWaterSequence': high, 'initialized': bool(ledger['sequence']),
            'expiresAtMilliseconds': expiry, 'recordCount': len(records), 'pageCount': 1,
            'byteCount': len(data), 'pagesSha256': pages_sha, 'manifestSha256': sha('\n'.join(fields).encode())}


def apply(account, body, raw):
    ledger = STATE[account]
    if body['groupId'] in ledger['groups']:
        known = ledger['groups'][body['groupId']]
        assert known[0] == sha(raw), 'A retry changed the frozen body'
        return known[1]
    ledger['sequence'] += 1
    clock = str(ledger['sequence'])
    for member in body['members']:
        change = member['change']
        key = change['entityType'] + ':' + change['entityId']
        old = ledger['records'].get(key)
        if change['action'] in ('create', 'restore'):
            fields = change['fields']
            versions = {k: clock for k in fields}
            resets = versions.copy()
        elif change['action'] == 'delete':
            fields, versions, resets = {}, {}, {}
        else:
            assert old
            fields = dict(old['fields']); versions = dict(old['fieldVersions']); resets = dict(old['fieldResets'])
            for k, value in change['set'].items(): fields[k] = value; versions[k] = resets[k] = clock
            for k, values in change['add'].items():
                fields[k] = list(dict.fromkeys(fields.get(k, []) + values)); versions[k] = clock
        ledger['records'][key] = {'entityType': change['entityType'], 'entityId': change['entityId'],
            'fields': fields, 'version': clock, 'deleted': change['action'] == 'delete',
            'fieldVersions': versions, 'fieldResets': resets}
    reply = {'status': 'committed', 'receipt': {'protocolVersion': 1, 'notebookId': BOOKS[account],
        'groupId': body['groupId'], 'committedSequence': clock, 'memberIds': [m['memberId'] for m in body['members']]}}
    ledger['groups'][body['groupId']] = (sha(raw), reply)
    return reply


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, value, status=200, mime='application/json'):
        data = value if isinstance(value, bytes) else enc(value)
        self.send_response(status); self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def route(self):
        path = urlparse(self.path).path
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        is_png = self.headers.get('Content-Type') == 'image/png'
        body = json.loads(raw) if raw and not is_png else {}
        if path == '/fixture/mode':
            STATE['mode'] = body['mode']
            if body['mode'] == 'initialized-empty':
                STATE['a']['sequence'] = 1
                fields = {'documentVersion': 8, 'reviewTemplatesPresent': False}
                STATE['a']['records']['notebookSettings:' + BOOKS['a']] = {
                    'entityType': 'notebookSettings', 'entityId': BOOKS['a'], 'fields': fields,
                    'version': '1', 'deleted': False, 'fieldVersions': {k: '1' for k in fields},
                    'fieldResets': {k: '1' for k in fields}}
            self.reply({'ok': True}); return
        if path == '/fixture/stats':
            self.reply({'paths': STATE['paths'], 'checks': STATE['checks'], 'refreshes': STATE['refreshes'],
                        'groups': sum(len(STATE[k]['groups']) for k in ('a', 'b')),
                        'images': sum(len(STATE[k]['images']) for k in ('a', 'b'))}); return
        STATE['paths'].append(path)
        if path == '/auth/api/send-code':
            account = 'b' if body['email'].startswith('b@') else 'a'
            self.reply({'ok': True, 'csrfToken': 'csrf-' + account, 'otpSessionToken': 'otp-' + account}); return
        if path == '/auth/api/verify-code':
            account = body['otpSessionToken'][-1]
            STATE['checks'].append(body['csrfToken'] == 'csrf-' + account and body['code'] == '12345678')
            self.reply({'ok': True, 'idToken': 'jwt-subject-different-' + account,
                        'refreshToken': 'refresh-' + account, 'expiresIn': 3600}); return
        if path == '/auth/api/refresh-token':
            if STATE['mode'] == 'scheduler-unauthorized': self.reply({'code': 'UNAVAILABLE'}, 503); return
            if STATE['mode'] == 'token-invalid': self.reply({'code': 'UNAUTHORIZED'}, 401); return
            account = body['refreshToken'][-1]; STATE['refreshes'] += 1
            self.reply({'ok': True, 'idToken': 'rotated-' + account, 'refreshToken': 'refresh-' + account, 'expiresIn': 3600}); return
        token = self.headers.get('Authorization', '')
        if not token.startswith('Bearer ') or token[-1:] not in ('a', 'b'):
            self.reply({'code': 'UNAUTHORIZED'}, 401); return
        account = token[-1]
        if path == '/api/me':
            if STATE['mode'] == 'me-offline': self.reply({'code': 'UNAVAILABLE'}, 503); return
            owner = 'wrong-owner' if STATE['mode'] == 'wrong-owner' else 'business-owner-' + account
            self.reply({'userId': owner, 'canonicalAccountId': 'canonical-' + account,
                        'selectedWorkspaceId': WORKSPACES[account], 'profile': {'email': account + '@example.invalid'}}); return
        if path == '/api/workspaces':
            if STATE['mode'] == 'delay-workspaces': time.sleep(0.6)
            workspaces = [{'workspaceId': WORKSPACES[account], 'name': 'Synthetic ' + account,
                'createdAt': '2025-01-01T00:00:00.000Z', 'isSelected': True, 'isVisible': True}]
            if account == 'a': workspaces.append({**workspaces[0], 'workspaceId': OTHER_WORKSPACE, 'name': 'Second workspace', 'isSelected': False})
            self.reply({'workspaces': workspaces, 'nextCursor': None}); return
        requested_workspace = path.split('/')[3] if path.startswith('/api/workspaces/') else ''
        allowed = requested_workspace == WORKSPACES[account] or (account == 'a' and requested_workspace == OTHER_WORKSPACE)
        prefix = '/api/workspaces/' + (requested_workspace if allowed else WORKSPACES[account]) + '/'
        STATE['checks'].append(path.startswith(prefix))
        if not path.startswith(prefix): self.reply({'code': 'FORBIDDEN'}, 403); return
        endpoint = path[len(prefix):]
        if endpoint == 'sync/bootstrap':
            if STATE['mode'] == 'scheduler-unauthorized' or (STATE['mode'] == 'scheduler-token-expired' and 'rotated-' not in token):
                self.reply({'code': 'UNAUTHORIZED'}, 401); return
            STATE['bootstrapInstallations'][requested_workspace] = body['installationId']
            STATE['checks'].append(body['mode'] == 'pull' and body['cursor'] is None and body['limit'] == 1
                and body['platform'] == 'macos' and not body['includeMediaAssets'] and body['osName'] == 'macos' and body['deviceType'] == 'desktop')
            self.reply({'entries': [{'entityType': 'workspace_scheduler_settings', 'entityId': requested_workspace,
                'action': 'upsert', 'payload': settings()}], 'hasMore': True, 'nextCursor': 'unused',
                'bootstrapHotChangeId': 1, 'remoteIsEmpty': False}); return
        if not endpoint.startswith('notebook/'): self.reply({'code': 'UNKNOWN'}, 404); return
        endpoint = endpoint[len('notebook/'):]
        if STATE['mode'] == 'offline':
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            self.connection.close(); return
        if STATE['mode'] == 'expire-token' and 'rotated-' not in token:
            self.reply({'code': 'UNAUTHORIZED'}, 401); return
        if endpoint == 'capabilities':
            if STATE['mode'] == 'delay-caps': time.sleep(0.6)
            self.reply({'lane': 'lingrove.corpus', 'protocolVersion': 1, 'documentVersion': 8,
                'terminalGroups': True, 'readWindows': True, 'readOnlyCatalog': True, 'maximumGroupBytes': 2097152,
                'maximumGroupMembers': 10000, 'pageBytes': 262144, 'windowLifetimeMilliseconds': 600000,
                'entityTypes': KINDS}); return
        if endpoint == 'connect':
            STATE['checks'].append(body['isAutomation'] is False and body['isTestDistribution'] is False
                and self.headers.get('X-Client-Platform') == 'macos'
                and body['installationId'] == STATE['bootstrapInstallations'].get(requested_workspace))
            self.reply({'protocolVersion': 1, 'ownerUserId': 'business-owner-' + account, 'workspaceId': WORKSPACES[account],
                'notebookId': BOOKS[account], 'replicaId': REPLICAS[account], 'committedSequence': str(STATE[account]['sequence'])}); return
        if endpoint == 'groups/apply': self.reply(apply(account, body, raw)); return
        if endpoint == 'windows/open': self.reply(window(account, body)); return
        if endpoint == 'windows/page':
            data = STATE['windows'][body['windowId']]
            self.reply({'windowId': body['windowId'], 'ordinal': 0, 'encoding': 'base64', 'data': b64(data),
                        'sha256': sha(data), 'byteCount': len(data)}); return
        if endpoint == 'windows/release': self.reply({'released': True}); return
        if endpoint == 'review/sync':
            if STATE['mode'] == 'review-unavailable': self.reply({'code': 'NOTEBOOK_REVIEW_UNAVAILABLE'}, 503); return
            ids = [v['operationId'] for v in body['enrollments'] + body['links'] + body['historyAdoptions']]
            ids += [v['operation']['operationId'] for v in body['operations']]
            ids += [v['undoId'] for v in body['undos']]
            self.reply({'protocolVersion': 1, 'notebookId': BOOKS[account], 'replicaId': REPLICAS[account],
                'acknowledged': ids, 'confirmed': [v['cardId'] for v in body['confirmations']],
                'afterSequence': body['afterSequence'], 'hasMore': False, 'changes': []}); return
        if endpoint.startswith('media/'):
            action = endpoint[6:]
            if action == 'capabilities':
                self.reply({'protocolVersion': 1, 'mimeType': 'image/png', 'maximumBytes': 4194304, 'maximumDimension': 1600}); return
            if action == 'release': self.reply({'released': True}); return
            query = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
            if action == 'bytes' and self.command == 'GET': self.reply(STATE[account]['images'][query['digest']], mime='image/png'); return
            image = body.get('image') if not is_png else {'digest': query['digest'], 'width': int(query['width']),
                'height': int(query['height']), 'byteCount': int(query['byteCount'])}
            if is_png:
                STATE['checks'].append(sha(raw) == image['digest']); STATE[account]['images'][image['digest']] = raw
            self.reply({'protocolVersion': 1, 'ownerUserId': 'business-owner-' + account, 'workspaceId': WORKSPACES[account],
                'notebookId': BOOKS[account], 'replicaId': REPLICAS[account], 'image': image,
                'mediaAssetId': '30000000-0000-0000-0000-000000000004',
                'state': 'ready' if image['digest'] in STATE[account]['images'] else 'missing'}); return
        self.reply({'code': 'UNKNOWN'}, 404)
    do_GET = do_POST = do_PUT = route

for port in range(19480, 19483):
    try: server = ThreadingHTTPServer(('127.0.0.1', port), Handler); break
    except OSError: continue
else: raise RuntimeError('D-owned ports are busy; no other server was stopped')
print(server.server_port, flush=True)
server.serve_forever()
