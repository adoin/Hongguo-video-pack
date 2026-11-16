import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gitee_sync', Path(__file__).parents[1] / 'gitee-sync.py')
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


class ReleaseTransferTest(unittest.TestCase):
    def test_retention_orders_versions_numerically_and_removes_old_previews(self):
        releases = [
            {'id': 1, 'tag_name': 'v0.3.2', 'prerelease': False},
            {'id': 2, 'tag_name': 'v0.3.9', 'prerelease': False},
            {'id': 3, 'tag_name': 'v0.3.10', 'prerelease': True},
            {'id': 4, 'tag_name': 'v0.3.1', 'prerelease': True},
            {'id': 5, 'tag_name': 'v0.4.0-rc1', 'prerelease': True},
            {'id': 6, 'tag_name': 'v0.4.0', 'prerelease': True},
        ]
        with patch.object(mirror, 'request', side_effect=[releases, None, None]) as request:
            self.assertTrue(mirror.retain_two_releases('v0.3.10'))
        self.assertEqual([call.args for call in request.call_args_list[1:]], [
            (f'/repos/{mirror.REPOSITORY}/releases/1', 'DELETE'),
            (f'/repos/{mirror.REPOSITORY}/releases/4', 'DELETE')])

    def test_historical_rerun_does_not_delete_or_restore_releases(self):
        releases = [{'id': i, 'tag_name': tag, 'prerelease': False}
                    for i, tag in enumerate(['v0.3.6', 'v0.3.7'], 1)]
        with patch.object(mirror, 'request', return_value=releases) as request:
            self.assertFalse(mirror.retain_two_releases('v0.3.2'))
        self.assertEqual(request.call_count, 1)

    def test_retention_reads_all_pages_before_deleting(self):
        first = [{'id': i + 1, 'tag_name': f'v0.0.{i}', 'prerelease': False} for i in range(100)]
        last = [{'id': 101, 'tag_name': 'v0.0.100', 'prerelease': False}]
        with patch.object(mirror, 'request', side_effect=[first, last] + [None] * 100) as request:
            self.assertTrue(mirror.retain_two_releases('v0.0.101'))
        self.assertIn('page=2', request.call_args_list[1].args[0])
        self.assertEqual(len([c for c in request.call_args_list if len(c.args) > 1]), 100)

    def test_invalid_delete_plan_fails_before_any_delete(self):
        releases = [{'id': 1, 'tag_name': 'v0.3.1', 'prerelease': False},
                    {'id': 'bad', 'tag_name': 'v0.3.2', 'prerelease': False},
                    {'id': 3, 'tag_name': 'v0.3.6', 'prerelease': False}]
        with patch.object(mirror, 'request', return_value=releases) as request:
            with self.assertRaisesRegex(RuntimeError, 'Invalid Gitee release ID'):
                mirror.retain_two_releases('v0.3.7')
        self.assertEqual(request.call_count, 1)

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
             patch.object(mirror, 'retain_two_releases', return_value=True), \
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
