import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gitee_sync', Path(__file__).parents[1] / 'gitee-sync.py')
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


class ReleaseTransferTest(unittest.TestCase):
    def test_upload_error_diagnostic_redacts_credentials_and_urls(self):
        with patch.object(mirror, 'TOKEN', 'secret-value'):
            detail = mirror.upload_error_detail(b'{"message":"quota exceeded", "access_token":"secret-value", "url":"https://example.com/private?token=other"}')
        self.assertIn('quota exceeded', detail)
        self.assertNotIn('secret-value', detail)
        self.assertNotIn('example.com', detail)
        self.assertLessEqual(len(detail), 600)

    def test_upload_stops_after_three_failed_attempts(self):
        with patch.object(mirror, 'upload', side_effect=RuntimeError('network')) as upload, \
             patch.object(mirror, 'request', return_value={'assets': []}):
            with self.assertRaisesRegex(RuntimeError, '3 attempts'):
                mirror.upload_with_retries(1, Path('setup.exe'), '/metadata')
            self.assertEqual(upload.call_count, 3)

    def test_upload_success_does_not_fetch_metadata_or_download(self):
        with patch.object(mirror, 'upload') as upload, \
             patch.object(mirror, 'request') as request:
            mirror.upload_with_retries(1, Path('setup.exe'), '/metadata')
            upload.assert_called_once()
            request.assert_not_called()

    def test_lost_response_with_existing_attachment_does_not_duplicate(self):
        with patch.object(mirror, 'upload', side_effect=RuntimeError('timeout')) as upload, \
             patch.object(mirror, 'request', return_value={'assets': [{'name': 'setup.exe'}]}):
            mirror.upload_with_retries(1, Path('setup.exe'), '/metadata')
            upload.assert_called_once()

    def test_success_on_third_attempt_stops_retrying(self):
        with patch.object(mirror, 'upload', side_effect=[RuntimeError('one'), RuntimeError('two'), None]) as upload, \
             patch.object(mirror, 'request', return_value={'assets': []}):
            mirror.upload_with_retries(1, Path('setup.exe'), '/metadata')
            self.assertEqual(upload.call_count, 3)

    def test_finalization_preserves_required_metadata_and_removes_local_files(self):
        release = {'id': 1, 'name': 'Release title', 'body': 'Existing notes',
                   'prerelease': True, 'assets': []}
        operations = []

        def request(path, method='GET', body=None):
            operations.append((method, body))
            return {'prerelease': False} if method == 'PATCH' else release

        with patch.object(mirror, 'packages', return_value=(
                ['setup.exe', 'app.apk', 'source.zip'], {})), \
             patch.object(mirror.subprocess, 'check_output', return_value=
                b'{"isDraft":false,"isPrerelease":false,"body":"Original notes"}'), \
             patch.object(mirror, 'request', side_effect=request), \
             patch.object(mirror, 'upload_with_retries') as upload, \
             patch.object(Path, 'unlink') as remove:
            mirror.mirror_release('v0.3.0', Path('unused-test-directory'))
        self.assertEqual(upload.call_count, 4)
        self.assertEqual(remove.call_count, 4)
        self.assertEqual([method for method, _ in operations], ['GET', 'PATCH'])
        self.assertEqual(operations[-1][1], {
            'tag_name': 'v0.3.0', 'name': 'Release title',
            'body': 'Existing notes', 'prerelease': False})


if __name__ == '__main__':
    unittest.main()
