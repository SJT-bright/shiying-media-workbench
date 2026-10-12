import os,sys,unittest,tempfile,threading
from pathlib import Path
from unittest.mock import patch
sys.path[:0]=['Backend','Backend/upstream/src']
import worker

class WindowsWorkerChecks(unittest.TestCase):
    def test_windows_tool_suffix_is_resolved_without_shell(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder)/'ffmpeg.exe').write_bytes(b'fixture')
            with patch.object(worker.sys,'platform','win32'),patch.object(worker,'Path',Path),patch.dict(os.environ,{'POCKET_TOOLS':folder}):
                self.assertTrue(worker.tool('ffmpeg').endswith('ffmpeg.exe'))

    def test_reserved_and_invalid_windows_file_names(self):
        self.assertEqual(worker.file_component('CON',120),'_CON')
        self.assertEqual(worker.file_component('标题:*?<>|. ',120),'标题______')
        self.assertEqual(worker.file_component('nul.txt',120),'_nul.txt')

    def test_job_staging_is_bound_to_valid_own_token(self):
        with patch.dict(os.environ,{'SHIYING_JOB_TOKEN':'a'*32}):
            self.assertEqual(worker.stage_prefix('download'),'.shiying-'+'a'*32+'-download-')
        with patch.dict(os.environ,{'SHIYING_JOB_TOKEN':'../invalid'}):
            self.assertEqual(worker.stage_prefix('download'),'.shiying-download-')

    def test_cancel_watcher_interrupts_only_own_child(self):
        with tempfile.TemporaryDirectory() as folder:
            token=Path(folder)/'cancel';token.touch();stop=threading.Event()
            with patch.object(worker._thread,'interrupt_main') as interrupted,patch.object(worker,'active_child',None):
                worker.watch_cancel(token,stop)
                interrupted.assert_called_once()

if __name__=='__main__':unittest.main()
