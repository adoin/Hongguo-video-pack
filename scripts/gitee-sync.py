"""Mirror public source/releases using GITEE_ACCESS; never log credentials."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

REPOSITORY = os.environ.get('GITEE_REPOSITORY', 'adoin/Hongguo-video-pack')
TOKEN = os.environ.get('GITEE_ACCESS', '')


def request(path, method='GET', body=None, raw=None, content_type=None, authenticated=True):
    headers = {'User-Agent': 'Hongputao-Release-Mirror', 'Accept': 'application/json'}
    if authenticated:
        headers['Authorization'] = 'Bearer ' + TOKEN
    if body is not None:
        raw = json.dumps(body).encode()
        content_type = 'application/json'
    if content_type:
        headers['Content-Type'] = content_type
    url = path if path.startswith('https://') else 'https://gitee.com/api/v5' + path
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=raw, headers=headers, method=method), timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == 'GET':
            return None
        raise RuntimeError(f'Gitee API {method} failed: HTTP {error.code}') from None


def git_sync():
    auth = base64.b64encode((REPOSITORY.split('/')[0] + ':' + TOKEN).encode()).decode()
    env = dict(os.environ, GIT_TRACE='0', GIT_CURL_VERBOSE='0', GIT_TERMINAL_PROMPT='0')
    # Keep credentials out of process arguments on shared publisher hosts.
    env.update(GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='credential.helper', GIT_CONFIG_VALUE_0='',
               GIT_CONFIG_KEY_1='http.https://gitee.com/.extraheader', GIT_CONFIG_VALUE_1='Authorization: Basic ' + auth)
    if os.environ.get('REPAIR_FAILED_V031') == 'true':
        # User-approved repair of one failed, unpublished tag. Never force main
        # or any other tag; the lease also rejects unexpected concurrent changes.
        if request(f'/repos/{REPOSITORY}/releases/tags/v0.3.1') is not None:
            raise RuntimeError('Refusing tag repair because a Gitee release already exists')
        repair = subprocess.run([
            'git', 'push',
            '--force-with-lease=refs/tags/v0.3.1:056d0b34dc802c9972f752004635359634fd3fdc',
            'https://gitee.com/' + REPOSITORY + '.git',
            'refs/tags/v0.3.1:refs/tags/v0.3.1'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if repair.returncode:
            raise RuntimeError('Scoped v0.3.1 tag repair failed; no broader force push attempted')
    command = ['git', 'push', 'https://gitee.com/' + REPOSITORY + '.git', 'refs/remotes/origin/main:refs/heads/main', '--tags']
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError('Gitee source sync failed; check token permission or divergent branches (no force push attempted)')
    print('Source main branch and tags synchronized to Gitee.')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def packages(directory, version):
    hashes = {}
    for line in (directory / 'SHA256SUMS.txt').read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?([^/\\]+)', line)
        if match:
            hashes[match[2]] = match[1].lower()
    # Portable ZIP remains on GitHub; keep core mirror attachments below 100 MiB.
    names = [f'Hongputao-Windows-{version}-Setup.exe', f'Hongputao-Android-arm64-{version}.apk',
             f'Hongputao-Source-{version}.zip']
    for name in names:
        file = directory / name
        if not file.is_file() or file.stat().st_size >= 100 * 1024 * 1024:
            raise RuntimeError('Missing package or package exceeds mirror size budget: ' + name)
        if digest(file) != hashes.get(name):
            raise RuntimeError('Source package checksum mismatch: ' + name)
    return names, hashes


def upload_error_detail(raw):
    """Expose bounded API diagnostics without credentials or response URLs."""
    detail = raw.decode('utf-8', errors='replace')[:4096]
    if TOKEN:
        detail = detail.replace(TOKEN, '[redacted]')
    detail = re.sub(r'https?://[^\s"<>]+', '[url]', detail)
    detail = re.sub(r'(?i)(access_token|authorization|password)(["\s:=]+)[^\s,}<]+', r'\1\2[redacted]', detail)
    return ' '.join(detail.split())[:600]


def upload(release_id, path):
    print('Uploading mirror attachment: ' + path.name, flush=True)
    # Stream multipart with curl rather than buffering a large request body.
    # Authentication is passed on stdin, not in command arguments or logs.
    url = f'https://gitee.com/api/v5/repos/{REPOSITORY}/releases/{release_id}/attach_files'
    config = 'url = ' + json.dumps(url) + '\nheader = ' + json.dumps('Authorization: Bearer ' + TOKEN) + '\n'
    timeout = '60' if path.stat().st_size < 10 * 1024 * 1024 else '900'
    result = subprocess.run(['curl', '--config', '-', '--http1.1', '--header', 'Expect:', '--silent', '--show-error',
                             '--connect-timeout', '20', '--max-time', timeout, '--speed-limit', '1024', '--speed-time', '60',
                             '--form', 'file=@' + str(path), '--write-out', '\n%{http_code} %{size_upload} %{time_total}'],
                            input=config.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    response_body, _, metrics = result.stdout.rpartition(b'\n')
    status = metrics.split(b' ')[0]
    if result.returncode or status not in (b'200', b'201'):
        raise RuntimeError('Attachment upload failed (curl code ' + str(result.returncode) + ', HTTP/bytes/seconds ' + metrics.decode(errors='replace') + '): ' + upload_error_detail(response_body))


def upload_with_retries(release_id, path, endpoint):
    for attempt in range(3):
        try:
            upload(release_id, path)
            return
        except RuntimeError as error:
            print(str(error), flush=True)
            # A lost response can occur after Gitee accepted the file. Only
            # consult attachment metadata to avoid a duplicate; never download it.
            try:
                after = request(endpoint)
                if any(asset.get('name') == path.name for asset in (after or {}).get('assets', [])):
                    print('Gitee attachment is present after interrupted response: ' + path.name)
                    return
            except (RuntimeError, OSError):
                print('Could not confirm attachment metadata after interrupted response.', flush=True)
            if attempt == 2:
                raise RuntimeError('Attachment upload failed after 3 attempts: ' + path.name) from None
            print(f'Retrying attachment upload ({attempt + 2}/3).', flush=True)


def mirror_release(tag, directory):
    if not re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag):
        raise RuntimeError('Only stable vMAJOR.MINOR.PATCH tags may be mirrored')
    names, _ = packages(directory, tag[1:])
    metadata = json.loads(subprocess.check_output(['gh', 'release', 'view', tag, '--repo', 'adoin/Hongguo-video-pack',
                                                 '--json', 'isDraft,isPrerelease,body']))
    if metadata['isDraft'] or metadata['isPrerelease']:
        raise RuntimeError('Refusing to mirror draft/prerelease')
    # Source/tag pushes have their own workflow. A newer main may already have
    # reached Gitee while this release job was downloading packages; pushing the
    # older checkout here would fail non-fast-forward and block attachments.
    endpoint = f'/repos/{REPOSITORY}/releases/tags/{tag}'
    release = request(endpoint)
    if release is None:
        release = request(f'/repos/{REPOSITORY}/releases', 'POST', {
            'tag_name': tag, 'name': '红葡萄 ' + tag[1:], 'body': metadata['body'] + '\n\nWindows 安装包 / Android APK 与 GitHub 使用相同 SHA256。便携 ZIP 请从 GitHub 下载。',
            'target_commitish': tag, 'prerelease': True})
    release_id = release['id']
    # Upload small files first; successful uploads do not trigger a re-download.
    names = ['SHA256SUMS.txt', names[2], names[1], names[0]]
    for name in names:
        asset = next((asset for asset in release.get('assets', []) if asset.get('name') == name), None)
        if asset is None:
            if not release['prerelease']:
                raise RuntimeError('Existing stable mirror is incomplete; refusing to alter published release')
            upload_with_retries(release_id, directory / name, endpoint)
        (directory / name).unlink(missing_ok=True)
        print('Gitee attachment accepted; local file removed: ' + name)
    if release['prerelease'] is False:
        print('Stable Gitee mirror is already ready: ' + tag)
        return
    # Gitee requires tag, title and body even when changing only prerelease.
    updated = request(f'/repos/{REPOSITORY}/releases/{release_id}', 'PATCH', {
        'tag_name': tag,
        'name': release['name'],
        'body': release.get('body') or metadata['body'],
        'prerelease': False})
    if updated.get('prerelease') is not False:
        raise RuntimeError('Gitee did not confirm the stable release state')
    print('Stable Gitee mirror is ready: ' + tag)


def main():
    if not TOKEN or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', REPOSITORY):
        raise RuntimeError('Configure GITEE_ACCESS secret and GITEE_REPOSITORY variable')
    if len(sys.argv) == 2 and sys.argv[1] == 'source':
        git_sync()
    elif len(sys.argv) == 4 and sys.argv[1] == 'release':
        mirror_release(sys.argv[2], Path(sys.argv[3]))
    else:
        raise RuntimeError('Usage: gitee-sync.py source | release vVERSION DIRECTORY')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never print exception URLs, payloads, subprocess arguments or credentials.
        print('Mirror failed: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
